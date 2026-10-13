#!/usr/bin/env bash
# Shared by the captain-run, once-per-cluster scripts (bootstrap/cert-manager/install.sh, bootstrap/ingress-ip/bind.sh):
# make the signed-in user Cluster Admin on a stage's cluster and write a temporary kubeconfig for it. Source it after
# bootstrap/lib.sh; never used by a pipeline. Bash 3.2.

# shellcheck disable=SC2034  # constants are used by the scripts that source this file
CLUSTER_ADMIN_ROLE="Azure Kubernetes Service RBAC Cluster Admin"
RETRY_SLEEP="${AZFLOW_RETRY_SLEEP:-10}"
RBAC_WAIT_TRIES="${AZFLOW_RBAC_WAIT_TRIES:-30}"

# cluster_admin_kubeconfig <subscription> <resource group> <cluster> <kubeconfig file> <what, for messages> <can-i args...>
# 1. assigns you Azure Kubernetes Service RBAC Cluster Admin on the cluster, unless you already have it
# 2. gets the cluster's credentials into <kubeconfig file> and waits until `kubectl auth can-i <can-i args>` says yes
cluster_admin_kubeconfig() {
  local sub="$1" rg="$2" cluster="$3" kubeconfig="$4" what="$5" me cluster_id existing fresh=0 tries=0
  shift 5

  log
  log "1. $CLUSTER_ADMIN_ROLE for you on $cluster"
  me="$(az ad signed-in-user show --query id -o tsv)"
  [ -n "$me" ] || die "could not read your object ID (az ad signed-in-user show); sign in as a user, not a service principal"
  cluster_id="$(az aks show --resource-group "$rg" --name "$cluster" --subscription "$sub" --query id -o tsv 2>/dev/null)" ||
    die "cluster $cluster not found in $rg. Run that stage's first infra apply before this bootstrap."
  existing="$(az role assignment list --assignee "$me" --role "$CLUSTER_ADMIN_ROLE" --scope "$cluster_id" \
    --subscription "$sub" -o json)"
  if [ "$(printf '%s' "$existing" | jq 'length')" -gt 0 ]; then
    log "  = already assigned"
  else
    az role assignment create --assignee-object-id "$me" --assignee-principal-type User \
      --role "$CLUSTER_ADMIN_ROLE" --scope "$cluster_id" --subscription "$sub" -o none
    log "  + assigned"
    fresh=1
  fi

  log
  log "2. Cluster credentials"
  # Entra-only cluster: the kubeconfig carries no credential; kubelogin fetches a token from your az sign-in.
  az aks get-credentials --resource-group "$rg" --name "$cluster" --subscription "$sub" \
    --file "$kubeconfig" --overwrite-existing >/dev/null
  kubelogin convert-kubeconfig --login azurecli --kubeconfig "$kubeconfig"
  log "  + temporary kubeconfig for $cluster"

  # A new role assignment takes a few minutes to reach the cluster; until then the API server answers Forbidden.
  until [ "$(kubectl --kubeconfig "$kubeconfig" auth can-i "$@" 2>/dev/null || true)" = yes ]; do
    tries=$((tries + 1))
    [ "$tries" -lt "$RBAC_WAIT_TRIES" ] ||
      die "you still cannot $what on $cluster after $tries checks. If the role was just assigned, wait a few minutes and re-run."
    if [ "$fresh" -eq 1 ]; then
      log "  waiting for the new role assignment to reach the cluster (check $tries/$RBAC_WAIT_TRIES)..."
    else
      log "  cluster does not grant you cluster-admin yet (check $tries/$RBAC_WAIT_TRIES)..."
    fi
    sleep "$RETRY_SLEEP"
  done
  log "  = you can manage cluster-scoped resources"
}
