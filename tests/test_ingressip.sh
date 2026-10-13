#!/usr/bin/env bash
# bootstrap/ingress-ip/bind.sh against a fake `az`, `kubectl` and `kubelogin`: argument checks, the idempotent
# Cluster Admin self-assignment (shared with the cert-manager bootstrap) and the binding of the add-on's default
# NginxIngressController to the stage's static public IP.
set -euo pipefail
# shellcheck source=tests/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=bootstrap/lib.sh
. "$REPO_ROOT/bootstrap/lib.sh"

BIND="$REPO_ROOT/bootstrap/ingress-ip/bind.sh"
export AZFLOW_SUBSCRIPTION_ID="sub-test" AZFLOW_RETRY_SLEEP=0 AZFLOW_BIND_WAIT_TRIES=3

run_bind() { # sets OUT and RC
  set +e
  OUT="$(with_fakes "$BIND" "$@" 2>&1)"
  RC=$?
  set -e
}

# fresh fake state: both stages' clusters running, their static IPs created by the apply, the ingress Service on a
# temporary address of its own (what a new cluster's default controller gets before it is bound)
cluster_state() {
  new_state
  : >"$FAKE_AZ_STATE/rg.rg-azflow-staging"
  : >"$FAKE_AZ_STATE/rg.rg-azflow-prod"
  echo Running >"$FAKE_AZ_STATE/aks.aks-azflow-staging"
  echo Running >"$FAKE_AZ_STATE/aks.aks-azflow-prod"
  printf '20.0.0.1' >"$FAKE_AZ_STATE/pip.rg-azflow-staging.pip-aks-azflow-staging"
  printf '20.0.0.2' >"$FAKE_AZ_STATE/pip.rg-azflow-prod.pip-aks-azflow-prod"
  printf '51.9.9.9' >"$FAKE_AZ_STATE/ingress-ip"
}

section "usage errors"
cluster_state
run_bind
assert_eq "no stage exit code" 2 "$RC"
assert_contains "no stage hint" "$OUT" "which stage?"
run_bind nope
assert_eq "unknown stage exit code" 2 "$RC"
run_bind staging production
assert_eq "two stages exit code" 2 "$RC"
run_bind staging --bogus
assert_eq "unknown option exit code" 2 "$RC"
assert_eq "argument errors never reach az" "" "$(cat "$FAKE_AZ_STATE/calls.log" 2>/dev/null || true)"
run_bind --help
assert_eq "help exit code" 0 "$RC"
assert_contains "help shows usage" "$OUT" "bind.sh <staging|production>"

section "first run on staging: Cluster Admin, then the default controller is bound to the static IP"
cluster_state
run_bind staging
assert_eq "exit code" 0 "$RC"
CLUSTER_ID="/subscriptions/sub-test/resourceGroups/rg-azflow-staging/providers/Microsoft.ContainerService/managedClusters/aks-azflow-staging"
assert_file_contains "Cluster Admin self-assigned on the cluster" "$FAKE_AZ_STATE/calls.log" \
  "role assignment create --assignee-object-id user-fake --assignee-principal-type User --role Azure Kubernetes Service RBAC Cluster Admin --scope $CLUSTER_ID --subscription sub-test"
assert_file_contains "checks it may patch the controller" "$FAKE_AZ_STATE/kubectl-calls.log" \
  "auth can-i patch nginxingresscontrollers.approuting.kubernetes.azure.com"
assert_file_contains "reads the stage's static IP" "$FAKE_AZ_STATE/calls.log" \
  "network public-ip show --resource-group rg-azflow-staging --name pip-aks-azflow-staging --subscription sub-test --query ipAddress"
assert_eq "patch names the IP and its resource group" "pip-aks-azflow-staging rg-azflow-staging" \
  "$(jq -r '.spec.loadBalancerAnnotations | [.["service.beta.kubernetes.io/azure-pip-name"], .["service.beta.kubernetes.io/azure-load-balancer-resource-group"]] | join(" ")' "$FAKE_AZ_STATE/nginx-patch.aks-azflow-staging")"
assert_eq "patch touches only the load-balancer annotations" '["loadBalancerAnnotations"]' \
  "$(jq -c '.spec | keys' "$FAKE_AZ_STATE/nginx-patch.aks-azflow-staging")"
assert_file_contains "patches the add-on's default controller" "$FAKE_AZ_STATE/kubectl-calls.log" "patch nginxingresscontroller default --type merge"
assert_contains "reports the bound address" "$OUT" "the ingress answers on 20.0.0.1"
assert_contains "next: re-run apply for the A record" "$OUT" "Re-run the infra apply workflow for staging"
assert_contains "next: cert-manager on a new cluster" "$OUT" "bootstrap/cert-manager/install.sh staging"
assert_not_contains "never signs in for the caller" "$(cat "$FAKE_AZ_STATE/calls.log")" "login"

section "second run: nothing re-assigned, same patch"
: >"$FAKE_AZ_STATE/calls.log"
run_bind staging
assert_eq "exit code" 0 "$RC"
assert_contains "reports existing assignment" "$OUT" "= already assigned"
assert_count "no new role assignment" 0 "$FAKE_AZ_STATE/calls.log" "role assignment create"

section "production binds its own cluster to its own IP"
run_bind production
assert_eq "exit code" 0 "$RC"
assert_eq "production patch" "pip-aks-azflow-prod rg-azflow-prod" \
  "$(jq -r '.spec.loadBalancerAnnotations | [.["service.beta.kubernetes.io/azure-pip-name"], .["service.beta.kubernetes.io/azure-load-balancer-resource-group"]] | join(" ")' "$FAKE_AZ_STATE/nginx-patch.aks-azflow-prod")"
assert_contains "production address" "$OUT" "the ingress answers on 20.0.0.2"

section "the Service never moves to the static IP: gives up with a pointer"
cluster_state
: >"$FAKE_AZ_STATE/bind-slow"
run_bind staging
assert_eq "exit code" 2 "$RC"
assert_contains "names the Service's address" "$OUT" "still reports '51.9.9.9' instead of 20.0.0.1"
assert_contains "points at the Service events" "$OUT" "kubectl describe service nginx -n app-routing-system"

section "preconditions: signed in, cluster exists, static IP exists"
cluster_state
: >"$FAKE_AZ_STATE/not-logged-in"
run_bind staging
assert_eq "not signed in exit code" 2 "$RC"
assert_contains "login hint" "$OUT" "Run: az login"
cluster_state
rm -f "$FAKE_AZ_STATE/aks.aks-azflow-staging"
run_bind staging
assert_eq "missing cluster exit code" 2 "$RC"
assert_contains "apply first" "$OUT" "first infra apply"
cluster_state
rm -f "$FAKE_AZ_STATE/pip.rg-azflow-staging.pip-aks-azflow-staging"
run_bind staging
assert_eq "missing static IP exit code" 2 "$RC"
assert_contains "apply first" "$OUT" "public IP pip-aks-azflow-staging not found"
assert_eq "no patch without the IP" "" "$(ls "$FAKE_AZ_STATE"/nginx-patch.* 2>/dev/null || true)"

finish "ingress-ip"
