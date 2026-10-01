#!/usr/bin/env bash
# One-time cert-manager bootstrap for one stage's cluster, run by the captain (never a pipeline) after `az login`.
# See bootstrap/cert-manager/README.md for why this is manual and what to check before and after.
#
#   export AZFLOW_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
#   bootstrap/cert-manager/install.sh <staging|production> --email <address>                 # staging issuer
#   bootstrap/cert-manager/install.sh <staging|production> --email <address> --issuer prod   # later
#
# Options: --email <address> (or AZFLOW_ACME_EMAIL; required, the Let's Encrypt account contact),
#          --issuer staging|prod (default staging: Let's Encrypt's staging server; prod only after a staging
#          certificate has issued on the same cluster).
#
# Steps (idempotent: re-running is safe):
#   1. assigns you Azure Kubernetes Service RBAC Cluster Admin on the stage's cluster, unless you already have it
#   2. gets the cluster's credentials into a temporary kubeconfig (deleted on exit; ~/.kube/config is untouched)
#   3. installs or upgrades cert-manager with Helm
#   4. applies the chosen ClusterIssuer with your email substituted into a temporary copy (the checked-in YAML
#      keeps its placeholder)
# Needs az, kubectl, kubelogin (az aks install-cli), helm and jq on PATH.

set -euo pipefail
# shellcheck source=bootstrap/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

usage() {
  sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

CLUSTER_ADMIN_ROLE="Azure Kubernetes Service RBAC Cluster Admin"
CERT_MANAGER_CHART="oci://quay.io/jetstack/charts/cert-manager"
CERT_MANAGER_NAMESPACE="cert-manager"
RETRY_SLEEP="${AZFLOW_RETRY_SLEEP:-10}"
RBAC_WAIT_TRIES="${AZFLOW_RBAC_WAIT_TRIES:-30}"
HERE="$AZFLOW_ROOT/bootstrap/cert-manager"

stage=""
email="${AZFLOW_ACME_EMAIL:-}"
issuer="staging"
while [ $# -gt 0 ]; do
  case "$1" in
    --email)
      [ $# -ge 2 ] || die "--email needs a value"
      email="$2"
      shift 2
      ;;
    --issuer)
      [ $# -ge 2 ] || die "--issuer needs a value"
      issuer="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown argument: $1 (see --help)" ;;
    *)
      [ -z "$stage" ] || die "only one stage at a time (got '$stage' and '$1')"
      stage="$1"
      shift
      ;;
  esac
done

[ -n "$stage" ] || die "which stage? Usage: bootstrap/cert-manager/install.sh <staging|production> --email <address> (see --help)"
case " $ALL_STAGES " in
  *" $stage "*) ;;
  *) die "unknown stage '$stage' (expected one of: $ALL_STAGES)" ;;
esac
case "$issuer" in
  staging | prod) ;;
  *) die "unknown issuer '$issuer' (expected staging or prod)" ;;
esac
[ -n "$email" ] || die "an email address is required for the Let's Encrypt account: pass --email <address> or set AZFLOW_ACME_EMAIL"
# Restricted to plain address characters, which also keeps it safe to substitute with sed below.
[[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "'$email' does not look like an email address"

require_cmd jq "Install jq (brew install jq)."
require_cmd az "Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli"
require_cmd kubectl "Run: az aks install-cli"
require_cmd kubelogin "Run: az aks install-cli"
require_cmd helm "Install Helm: https://helm.sh/docs/intro/install/"

if ! out="$(validate_stage "$stage")"; then
  printf '%s\n' "$out" >&2
  die "stage file problems above"
fi
sub="$(resolve_ref "$(stage_get "$stage" .subscriptionId)")" ||
  die "stage '$stage': subscriptionId is $(stage_get "$stage" .subscriptionId) but that environment variable is not set. Try: export AZFLOW_SUBSCRIPTION_ID=\"\$(az account show --query id -o tsv)\""
rg="$(stage_get "$stage" .resourceGroup)"
cluster="$(stage_get "$stage" .cluster)"
issuer_file="$HERE/cluster-issuer-$issuer.yaml"
issuer_name="letsencrypt-$issuer"
[ -f "$issuer_file" ] || die "$issuer_file is missing"

az account show >/dev/null 2>&1 || die "not signed in to Azure. Run: az login (as yourself, never a pipeline identity)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
KUBECONFIG_FILE="$WORK/kubeconfig"

log "cert-manager bootstrap: stage $stage, cluster $cluster in $rg, issuer $issuer_name"
if [ "$stage" = production ]; then
  log "  (Bootstrap the staging stage's cluster first; see bootstrap/cert-manager/README.md.)"
fi

# ---- 1. Cluster Admin for the signed-in user ----------------------------------------------------

log
log "1. $CLUSTER_ADMIN_ROLE for you on $cluster"
me="$(az ad signed-in-user show --query id -o tsv)"
[ -n "$me" ] || die "could not read your object ID (az ad signed-in-user show); sign in as a user, not a service principal"
cluster_id="$(az aks show --resource-group "$rg" --name "$cluster" --subscription "$sub" --query id -o tsv 2>/dev/null)" ||
  die "cluster $cluster not found in $rg. Run that stage's first infra apply before this bootstrap."
existing="$(az role assignment list --assignee "$me" --role "$CLUSTER_ADMIN_ROLE" --scope "$cluster_id" \
  --subscription "$sub" -o json)"
fresh=0
if [ "$(printf '%s' "$existing" | jq 'length')" -gt 0 ]; then
  log "  = already assigned"
else
  az role assignment create --assignee-object-id "$me" --assignee-principal-type User \
    --role "$CLUSTER_ADMIN_ROLE" --scope "$cluster_id" --subscription "$sub" -o none
  log "  + assigned"
  fresh=1
fi

# ---- 2. credentials -----------------------------------------------------------------------------

log
log "2. Cluster credentials"
# Entra-only cluster: the kubeconfig carries no credential; kubelogin fetches a token from your az sign-in.
az aks get-credentials --resource-group "$rg" --name "$cluster" --subscription "$sub" \
  --file "$KUBECONFIG_FILE" --overwrite-existing >/dev/null
kubelogin convert-kubeconfig --login azurecli --kubeconfig "$KUBECONFIG_FILE"
log "  + temporary kubeconfig for $cluster"

# A new role assignment takes a few minutes to reach the cluster; until then the API server answers Forbidden.
tries=0
until [ "$(kubectl --kubeconfig "$KUBECONFIG_FILE" auth can-i create customresourcedefinitions.apiextensions.k8s.io 2>/dev/null || true)" = yes ]; do
  tries=$((tries + 1))
  [ "$tries" -lt "$RBAC_WAIT_TRIES" ] ||
    die "you still cannot create CRDs on $cluster after $tries checks. If the role was just assigned, wait a few minutes and re-run."
  if [ "$fresh" -eq 1 ]; then
    log "  waiting for the new role assignment to reach the cluster (check $tries/$RBAC_WAIT_TRIES)..."
  else
    log "  cluster does not grant you cluster-admin yet (check $tries/$RBAC_WAIT_TRIES)..."
  fi
  sleep "$RETRY_SLEEP"
done
log "  = you can manage cluster-scoped resources"

# ---- 3. cert-manager ----------------------------------------------------------------------------

log
log "3. cert-manager (helm upgrade --install)"
helm upgrade --install cert-manager "$CERT_MANAGER_CHART" \
  --namespace "$CERT_MANAGER_NAMESPACE" --create-namespace --set crds.enabled=true \
  --kubeconfig "$KUBECONFIG_FILE" --wait
log "  + cert-manager installed or up to date in namespace $CERT_MANAGER_NAMESPACE"
log "  Its three pods (controller, webhook, cainjector) share the single node with the API; confirm they are"
log "  Running: kubectl get pods -n $CERT_MANAGER_NAMESPACE (README, \"Node capacity\")."

# ---- 4. ClusterIssuer ---------------------------------------------------------------------------

log
log "4. ClusterIssuer $issuer_name"
if [ "$issuer" = prod ]; then
  # Let's Encrypt production allows only 5 failed validations per hostname per hour (README, "Rate limits").
  kubectl --kubeconfig "$KUBECONFIG_FILE" get clusterissuer letsencrypt-staging >/dev/null 2>&1 ||
    die "letsencrypt-staging is not on $cluster. Run this script without --issuer prod first and confirm a staging certificate issues (README, \"Rate limits\")."
  log "  Caution: Let's Encrypt production has tight rate limits (5 failed validations per hostname per hour,"
  log "  5 duplicate certificates per 7 days). Only continue if a letsencrypt-staging certificate issued on this cluster."
fi
issuer_copy="$WORK/$(basename "$issuer_file")"
sed "s|REPLACE-WITH-YOUR-EMAIL-BEFORE-APPLYING|$email|" "$issuer_file" >"$issuer_copy"
grep -qF "email: $email" "$issuer_copy" ||
  die "could not substitute the email into $issuer_file (placeholder REPLACE-WITH-YOUR-EMAIL-BEFORE-APPLYING not found)"
kubectl --kubeconfig "$KUBECONFIG_FILE" apply -f "$issuer_copy"
log "  + applied (the checked-in $(basename "$issuer_file") still holds its placeholder)"

# ---- next steps ---------------------------------------------------------------------------------

log
log "Next:"
if [ "$issuer" = staging ]; then
  log "  5. Annotate the API's Ingress with cert-manager.io/cluster-issuer: letsencrypt-staging and a tls: block for"
  log "     $(stage_get "$stage" .apiHost) (in azure-flow-api), then confirm a certificate issues:"
  log "       az aks get-credentials --resource-group $rg --name $cluster --subscription $sub"
  log "       kubectl get certificate -A"
  log "       kubectl describe certificate <name> -n <namespace>   # Ready: True once issued"
  log "  6. Then switch to the production issuer (tight rate limits; README, \"Rate limits\"):"
  log "       bootstrap/cert-manager/install.sh $stage --email <address> --issuer prod"
else
  log "  Change the Ingress annotation from letsencrypt-staging to letsencrypt-prod (in azure-flow-api) and confirm"
  log "  a real certificate issues: kubectl get certificate -A; kubectl describe certificate <name> -n <namespace>."
fi
if [ "$stage" = staging ]; then
  log "  Afterwards repeat for production: bootstrap/cert-manager/install.sh production --email <address>"
fi
log "  Renewal is automatic. Re-run this script if the cluster is ever destroyed and recreated."
