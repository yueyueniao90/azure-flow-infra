#!/usr/bin/env bash
# One-time ingress bootstrap for one stage's cluster, run by the captain (never a pipeline) after `az login`: binds the
# application-routing add-on's default NGINX ingress controller to the stage's static public IP, the same IP the
# cluster already uses for outbound traffic, so each stage needs one public IP in total.
# See bootstrap/ingress-ip/README.md for why this is manual and when to run it.
#
#   export AZFLOW_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
#   bootstrap/ingress-ip/bind.sh <staging|production>
#
# Steps (idempotent: re-running is safe):
#   1. assigns you Azure Kubernetes Service RBAC Cluster Admin on the stage's cluster, unless you already have it
#   2. gets the cluster's credentials into a temporary kubeconfig (deleted on exit; ~/.kube/config is untouched)
#   3. reads the stage's static public IP (pip-<cluster>, created by the infra apply)
#   4. sets the default NginxIngressController's load-balancer annotations to that IP (merge patch)
#   5. waits until the add-on's nginx Service reports that IP
# Needs az, kubectl, kubelogin (az aks install-cli) and jq on PATH.

set -euo pipefail
# shellcheck source=bootstrap/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# shellcheck source=bootstrap/cluster-admin.sh
. "$(dirname "${BASH_SOURCE[0]}")/../cluster-admin.sh"

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# The add-on's default controller (README, "One public IP per stage"); its Service keeps the name ci/stage.sh reads.
CONTROLLER="default"
INGRESS_NAMESPACE="app-routing-system"
INGRESS_SERVICE="nginx"
BIND_WAIT_TRIES="${AZFLOW_BIND_WAIT_TRIES:-30}"

stage=""
while [ $# -gt 0 ]; do
  case "$1" in
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

[ -n "$stage" ] || die "which stage? Usage: bootstrap/ingress-ip/bind.sh <staging|production> (see --help)"
case " $ALL_STAGES " in
  *" $stage "*) ;;
  *) die "unknown stage '$stage' (expected one of: $ALL_STAGES)" ;;
esac

require_cmd jq "Install jq (brew install jq)."
require_cmd az "Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli"
require_cmd kubectl "Run: az aks install-cli"
require_cmd kubelogin "Run: az aks install-cli"

if ! out="$(validate_stage "$stage")"; then
  printf '%s\n' "$out" >&2
  die "stage file problems above"
fi
sub="$(resolve_ref "$(stage_get "$stage" .subscriptionId)")" ||
  die "stage '$stage': subscriptionId is $(stage_get "$stage" .subscriptionId) but that environment variable is not set. Try: export AZFLOW_SUBSCRIPTION_ID=\"\$(az account show --query id -o tsv)\""
rg="$(stage_get "$stage" .resourceGroup)"
cluster="$(stage_get "$stage" .cluster)"
pip="$(public_ip_name "$stage")"

az account show >/dev/null 2>&1 || die "not signed in to Azure. Run: az login (as yourself, never a pipeline identity)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
KUBECONFIG_FILE="$WORK/kubeconfig"

log "ingress IP bootstrap: stage $stage, cluster $cluster in $rg, public IP $pip"

cluster_admin_kubeconfig "$sub" "$rg" "$cluster" "$KUBECONFIG_FILE" "patch the ingress controller" \
  patch nginxingresscontrollers.approuting.kubernetes.azure.com

# ---- 3. the static public IP --------------------------------------------------------------------

log
log "3. Static public IP $pip"
address="$(az network public-ip show --resource-group "$rg" --name "$pip" --subscription "$sub" --query ipAddress -o tsv 2>/dev/null || true)"
[ -n "$address" ] ||
  die "public IP $pip not found in $rg (or it has no address yet). Run that stage's infra apply first (README, \"One public IP per stage\")."
log "  = $address (also the cluster's outbound IP)"

# ---- 4. bind the default controller -------------------------------------------------------------

log
log "4. NginxIngressController $CONTROLLER -> $pip"
# Microsoft's documented annotations for a static IP outside the node resource group
# (https://learn.microsoft.com/azure/aks/app-routing-nginx-configuration). The cluster's control-plane identity holds
# Network Contributor on $rg (bicep/modules/aks.bicep), which the cloud provider needs to use the IP.
patch="$(jq -cn --arg pip "$pip" --arg rg "$rg" '{spec: {loadBalancerAnnotations: {
  "service.beta.kubernetes.io/azure-pip-name": $pip,
  "service.beta.kubernetes.io/azure-load-balancer-resource-group": $rg}}}')"
kubectl --kubeconfig "$KUBECONFIG_FILE" patch nginxingresscontroller "$CONTROLLER" --type merge -p "$patch" >/dev/null
log "  + annotations set"

# ---- 5. wait for the Service --------------------------------------------------------------------

log
log "5. Service $INGRESS_NAMESPACE/$INGRESS_SERVICE on $address"
tries=0
while :; do
  ip="$(kubectl --kubeconfig "$KUBECONFIG_FILE" get service "$INGRESS_SERVICE" --namespace "$INGRESS_NAMESPACE" \
    -o 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ "$ip" = "$address" ] && break
  tries=$((tries + 1))
  [ "$tries" -lt "$BIND_WAIT_TRIES" ] ||
    die "the ingress Service still reports '${ip:-no IP}' instead of $address after $tries checks. Look at its events: kubectl describe service $INGRESS_SERVICE -n $INGRESS_NAMESPACE (README, \"One public IP per stage\")."
  log "  Service reports '${ip:-no IP yet}', waiting (check $tries/$BIND_WAIT_TRIES)..."
  sleep "$RETRY_SLEEP"
done
log "  = the ingress answers on $address, the stage's one public IP"

# ---- next steps ---------------------------------------------------------------------------------

log
log "Next:"
log "  Re-run the infra apply workflow for $stage: its api-dns step points $(stage_get "$stage" .apiHost) at $address."
log "  On a new cluster, also run bootstrap/cert-manager/install.sh $stage --email <address> (README, \"HTTPS\")."
