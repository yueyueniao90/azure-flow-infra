#!/usr/bin/env bash
# bootstrap/cert-manager/install.sh against a fake `az`, `kubectl`, `kubelogin` and `helm`: argument checks, the
# idempotent Cluster Admin self-assignment, and the email substitution that never touches the checked-in YAML.
set -euo pipefail
# shellcheck source=tests/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=bootstrap/lib.sh
. "$REPO_ROOT/bootstrap/lib.sh"

INSTALL="$REPO_ROOT/bootstrap/cert-manager/install.sh"
ISSUERS="$REPO_ROOT/bootstrap/cert-manager"
PLACEHOLDER="REPLACE-WITH-YOUR-EMAIL-BEFORE-APPLYING"
EMAIL="captain@example.com"
ADMIN="Azure Kubernetes Service RBAC Cluster Admin"
export AZFLOW_SUBSCRIPTION_ID="sub-test" AZFLOW_RETRY_SLEEP=0
unset AZFLOW_ACME_EMAIL || true

run_install() { # sets OUT and RC
  set +e
  OUT="$(with_fakes "$INSTALL" "$@" 2>&1)"
  RC=$?
  set -e
}

cluster_state() { # fresh fake state with both stages' clusters running
  new_state
  echo Running >"$FAKE_AZ_STATE/aks.aks-azflow-staging"
  echo Running >"$FAKE_AZ_STATE/aks.aks-azflow-prod"
}

checksum() { cksum "$ISSUERS"/cluster-issuer-*.yaml; }
SUMS_BEFORE="$(checksum)"

section "usage errors"
cluster_state
run_install
assert_eq "no stage exit code" 2 "$RC"
assert_contains "no stage hint" "$OUT" "which stage?"
run_install nope --email "$EMAIL"
assert_eq "unknown stage exit code" 2 "$RC"
assert_contains "unknown stage" "$OUT" "unknown stage 'nope'"
run_install staging production --email "$EMAIL"
assert_eq "two stages exit code" 2 "$RC"
run_install staging --email "$EMAIL" --issuer production
assert_eq "unknown issuer exit code" 2 "$RC"
assert_contains "issuer names" "$OUT" "expected staging or prod"
run_install staging
assert_eq "missing email exit code" 2 "$RC"
assert_contains "email hint" "$OUT" "AZFLOW_ACME_EMAIL"
run_install staging --email
assert_eq "--email without value" 2 "$RC"
run_install staging --email "not-an-email"
assert_eq "malformed email exit code" 2 "$RC"
run_install staging --email "a@b.com|evil"
assert_eq "sed metacharacter in email exit code" 2 "$RC"
run_install staging --email "$EMAIL" --bogus
assert_eq "unknown option exit code" 2 "$RC"
assert_eq "argument errors never reach az" "" "$(cat "$FAKE_AZ_STATE/calls.log" 2>/dev/null || true)"
run_install --help
assert_eq "help exit code" 0 "$RC"
assert_contains "help shows usage" "$OUT" "install.sh <staging|production> --email"

section "required tools"
cluster_state
tmpbin="$(mktemp -d)"
for t in bash env jq sed grep mktemp basename dirname rm cat sleep; do ln -s "$(command -v "$t")" "$tmpbin/$t"; done
for t in az kubectl kubelogin; do ln -s "$FAKE_BIN/$t" "$tmpbin/$t"; done
set +e
OUT="$(PATH="$tmpbin" "$INSTALL" staging --email "$EMAIL" 2>&1)"
RC=$?
set -e
assert_eq "missing helm exit code" 2 "$RC"
assert_contains "names helm" "$OUT" "'helm' is required"
rm -f "$tmpbin/kubectl"
ln -s "$FAKE_BIN/helm" "$tmpbin/helm"
set +e
OUT="$(PATH="$tmpbin" "$INSTALL" staging --email "$EMAIL" 2>&1)"
RC=$?
set -e
assert_eq "missing kubectl exit code" 2 "$RC"
assert_contains "names kubectl" "$OUT" "'kubectl' is required"
rm -rf "$tmpbin"

section "first run on staging: self-assigns Cluster Admin, installs cert-manager, applies the staging issuer"
cluster_state
run_install staging --email "$EMAIL"
assert_eq "exit code" 0 "$RC"
CLUSTER_ID="/subscriptions/sub-test/resourceGroups/rg-azflow-staging/providers/Microsoft.ContainerService/managedClusters/aks-azflow-staging"
assert_count "one Cluster Admin assignment" 1 "$FAKE_AZ_STATE/calls.log" "role assignment create"
assert_file_contains "assigned to the signed-in user as a User on the cluster" "$FAKE_AZ_STATE/calls.log" \
  "role assignment create --assignee-object-id user-fake --assignee-principal-type User --role $ADMIN --scope $CLUSTER_ID --subscription sub-test"
assert_file_contains "credentials for the stage's cluster" "$FAKE_AZ_STATE/calls.log" \
  "aks get-credentials --resource-group rg-azflow-staging --name aks-azflow-staging --subscription sub-test"
assert_eq "helm installed into that cluster" "aks-azflow-staging" "$(cat "$FAKE_AZ_STATE/helm.cert-manager")"
assert_file_contains "applied issuer carries the email" "$FAKE_AZ_STATE/clusterissuer.letsencrypt-staging" "email: $EMAIL"
assert_count "applied issuer has no placeholder" 0 "$FAKE_AZ_STATE/clusterissuer.letsencrypt-staging" "$PLACEHOLDER"
assert_file_contains "applied issuer is the staging server" "$FAKE_AZ_STATE/clusterissuer.letsencrypt-staging" \
  "acme-staging-v02.api.letsencrypt.org"
assert_eq "no prod issuer yet" "" "$(ls "$FAKE_AZ_STATE"/clusterissuer.letsencrypt-prod 2>/dev/null || true)"
assert_eq "checked-in issuer YAMLs unchanged" "$SUMS_BEFORE" "$(checksum)"
assert_count "staging YAML still holds the placeholder" 1 "$ISSUERS/cluster-issuer-staging.yaml" "email: $PLACEHOLDER"
assert_count "prod YAML still holds the placeholder" 1 "$ISSUERS/cluster-issuer-prod.yaml" "email: $PLACEHOLDER"
assert_count "the email is never written into the repo" 0 "$ISSUERS/cluster-issuer-staging.yaml" "$EMAIL"
assert_contains "guidance: credentials for the stage subscription" "$OUT" "az aks get-credentials --resource-group rg-azflow-staging --name aks-azflow-staging --subscription sub-test"
assert_contains "guidance: confirm a certificate" "$OUT" "kubectl get certificate -A"
assert_contains "guidance: prod issuer next" "$OUT" "--issuer prod"
assert_contains "guidance: production stage afterwards" "$OUT" "repeat for production"
assert_contains "guidance: rate limits" "$OUT" "Rate limits"
assert_contains "guidance: node capacity" "$OUT" "kubectl get pods -n cert-manager"
assert_not_contains "never signs in for the caller" "$(cat "$FAKE_AZ_STATE/calls.log")" "login"

section "second run: Cluster Admin already assigned, nothing re-assigned"
: >"$FAKE_AZ_STATE/calls.log"
run_install staging --email "$EMAIL"
assert_eq "exit code" 0 "$RC"
assert_contains "reports existing assignment" "$OUT" "= already assigned"
assert_count "no new role assignment" 0 "$FAKE_AZ_STATE/calls.log" "role assignment create"
assert_eq "still one assignment" 1 "$(wc -l <"$FAKE_AZ_STATE/roles.jsonl" | tr -d ' ')"

section "Cluster Admin assigned before the script ever ran (by hand)"
cluster_state
jq -cn --arg s "$CLUSTER_ID" --arg r "$ADMIN" '{id: "ra-manual", principalId: "user-fake", roleDefinitionName: $r, scope: $s}' \
  >"$FAKE_AZ_STATE/roles.jsonl"
AZFLOW_ACME_EMAIL="$EMAIL" run_install staging
assert_eq "exit code (email from AZFLOW_ACME_EMAIL)" 0 "$RC"
assert_count "no role assignment create" 0 "$FAKE_AZ_STATE/calls.log" "role assignment create"
assert_file_contains "env email substituted" "$FAKE_AZ_STATE/clusterissuer.letsencrypt-staging" "email: $EMAIL"
run_install staging --email other@example.org
assert_file_contains "--email wins over a re-run" "$FAKE_AZ_STATE/clusterissuer.letsencrypt-staging" "email: other@example.org"

section "fresh assignment still propagating: waits until the cluster grants it"
cluster_state
echo 2 >"$FAKE_AZ_STATE/kubectl-forbidden-first"
run_install staging --email "$EMAIL"
assert_eq "exit code" 0 "$RC"
assert_contains "waits" "$OUT" "waiting for the new role assignment"
assert_eq "applied after the wait" "letsencrypt-staging" "$(sed -n 's/^  name: //p' "$FAKE_AZ_STATE/clusterissuer.letsencrypt-staging")"
cluster_state
echo 5 >"$FAKE_AZ_STATE/kubectl-forbidden-first"
AZFLOW_RBAC_WAIT_TRIES=3 run_install staging --email "$EMAIL"
assert_eq "gives up after the configured checks" 2 "$RC"
assert_contains "re-run hint" "$OUT" "wait a few minutes and re-run"
assert_eq "no helm install without the role" "" "$(ls "$FAKE_AZ_STATE"/helm.cert-manager 2>/dev/null || true)"

section "production issuer: refused until the staging issuer is on the cluster"
cluster_state
run_install production --email "$EMAIL" --issuer prod
assert_eq "exit code" 2 "$RC"
assert_contains "explains staging first" "$OUT" "letsencrypt-staging is not on aks-azflow-prod"
assert_eq "no prod issuer applied" "" "$(ls "$FAKE_AZ_STATE"/clusterissuer.letsencrypt-prod 2>/dev/null || true)"
run_install production --email "$EMAIL"
assert_eq "staging issuer on production cluster" 0 "$RC"
assert_file_contains "production stage uses its own cluster" "$FAKE_AZ_STATE/calls.log" \
  "aks get-credentials --resource-group rg-azflow-prod --name aks-azflow-prod"
run_install production --email "$EMAIL" --issuer prod
assert_eq "prod issuer exit code" 0 "$RC"
assert_contains "rate-limit caution" "$OUT" "5 failed validations per hostname per hour"
assert_file_contains "prod issuer carries the email" "$FAKE_AZ_STATE/clusterissuer.letsencrypt-prod" "email: $EMAIL"
assert_file_contains "prod issuer is the production server" "$FAKE_AZ_STATE/clusterissuer.letsencrypt-prod" \
  "acme-v02.api.letsencrypt.org"
assert_eq "checked-in issuer YAMLs still unchanged" "$SUMS_BEFORE" "$(checksum)"

section "re-run on AKS: admissions-enforcer conflict on the webhook is retried once with --force-conflicts"
cluster_state
: >"$FAKE_AZ_STATE/helm-ssa-conflict"
run_install staging --email "$EMAIL"
assert_eq "exit code" 0 "$RC"
assert_contains "original helm error shown" "$OUT" 'conflict with "admissionsenforcer"'
assert_count "two helm calls" 2 "$FAKE_AZ_STATE/helm-calls.log" "upgrade --install cert-manager"
assert_count "exactly one forced retry" 1 "$FAKE_AZ_STATE/helm-calls.log" "--force-conflicts"
assert_eq "helm installed after the retry" "aks-azflow-staging" "$(cat "$FAKE_AZ_STATE/helm.cert-manager")"
assert_file_contains "issuer applied after the retry" "$FAKE_AZ_STATE/clusterissuer.letsencrypt-staging" "email: $EMAIL"

section "any other helm failure: no forced retry, the script fails"
cluster_state
: >"$FAKE_AZ_STATE/helm-fail"
run_install staging --email "$EMAIL"
assert_eq "exit code" 2 "$RC"
assert_contains "original helm error shown" "$OUT" "context deadline exceeded"
assert_count "one helm call" 1 "$FAKE_AZ_STATE/helm-calls.log" "upgrade --install cert-manager"
assert_count "never forced" 0 "$FAKE_AZ_STATE/helm-calls.log" "--force-conflicts"
assert_eq "no issuer applied" "" "$(ls "$FAKE_AZ_STATE"/clusterissuer.letsencrypt-staging 2>/dev/null || true)"

section "preconditions: signed in, subscription set, cluster exists"
cluster_state
: >"$FAKE_AZ_STATE/not-logged-in"
run_install staging --email "$EMAIL"
assert_eq "not signed in exit code" 2 "$RC"
assert_contains "login hint" "$OUT" "Run: az login"
assert_not_contains "does not sign in itself" "$(cat "$FAKE_AZ_STATE/calls.log")" "login"
cluster_state
(
  unset AZFLOW_SUBSCRIPTION_ID
  run_install staging --email "$EMAIL"
  assert_eq "unset subscription exit code" 2 "$RC"
  assert_contains "subscription hint" "$OUT" "AZFLOW_SUBSCRIPTION_ID"
  finish "certmanager (subshell)" >/dev/null
) || fail "unset subscription checks"
new_state
run_install staging --email "$EMAIL"
assert_eq "missing cluster exit code" 2 "$RC"
assert_contains "apply first" "$OUT" "first infra apply"
assert_count "no role assignment without a cluster" 0 "$FAKE_AZ_STATE/calls.log" "role assignment create"

finish "certmanager"
