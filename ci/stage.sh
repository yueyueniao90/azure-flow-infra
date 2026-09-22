#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks in the printf formats are literal markdown
# Helper the GitHub Actions workflows call, so the logic can be tested offline against a fake `az`
# (tests/test_ci.sh). Every command expects the workflow to have signed in already (Azure OIDC login) and reads its
# inputs from environment variables set by the workflow, never from event text.
#
#   ci/stage.sh missing-vars <NAME>...      print the names of unset or empty variables (always exits 0)
#   ci/stage.sh what-if <stage>             markdown preview of the stage deployment on stdout; non-zero if what-if failed
#   ci/stage.sh apply <stage>               deploy bicep/main.bicep with bicep/<stage>.bicepparam; summary with name servers
#   ci/stage.sh aks <stop|start> <stage>    switch the stage's cluster off or on (idempotent)
#   ci/stage.sh destroy <stage> [--shared]  delete the stage resource group, and with --shared the shared one too
#
# Environment: AZFLOW_SUBSCRIPTION_ID (subscription of the stage; the stage files reference it), and for apply and
# what-if also AZFLOW_NAME_SUFFIX, AZFLOW_API_PRINCIPAL_ID, AZFLOW_WEB_PRINCIPAL_ID (read by bicep/*.bicepparam).
# The job summary goes to $GITHUB_STEP_SUMMARY when set.
set -euo pipefail
# shellcheck source=bootstrap/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bootstrap/lib.sh"

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

summary() { printf '%s\n' "$*" >>"$SUMMARY"; }

usage() {
  sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

need_stage() {
  case " $ALL_STAGES " in
    *" ${1:-} "*) ;;
    *) die "unknown stage '${1:-}' (expected one of: $ALL_STAGES)" ;;
  esac
  validate_stage "$1" >/dev/null || die "stage file for '$1' is invalid: $(validate_stage "$1")"
}

need_subscription() {
  [ -n "${AZFLOW_SUBSCRIPTION_ID:-}" ] ||
    die "AZFLOW_SUBSCRIPTION_ID is empty. The seed writes it as a repository variable (README, \"First-run order\")."
}

group_exists() { # <resource group> <subscription>
  [ "$(az group exists --name "$1" --subscription "$2" 2>/dev/null || echo false)" = true ]
}

# Shared group subscription: the stage file's reference, resolved from the environment like the bicepparam does.
shared_subscription() {
  resolve_ref "$(stage_get "$1" .shared.subscriptionId)" ||
    die "the shared subscription reference in stages/$1.json is not set in the environment"
}

strip_ansi() { sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g'; }

cluster_state() { # <stage>: Running, Stopped, ... or nothing when the cluster does not exist
  az aks list --resource-group "$(stage_get "$1" .resourceGroup)" --subscription "$AZFLOW_SUBSCRIPTION_ID" \
    --query "[?name=='$(stage_get "$1" .cluster)'].powerState.code | [0]" -o tsv
}

cmd_missing_vars() {
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || printf '%s\n' "$name"
  done
  return 0
}

cmd_what_if() {
  local stage="$1" rg shared_rg shared_sub out rc
  need_stage "$stage"
  need_subscription
  rg="$(stage_get "$stage" .resourceGroup)"
  shared_rg="$(stage_get "$stage" .shared.resourceGroup)"
  shared_sub="$(shared_subscription "$stage")"
  printf '### %s (`%s`)\n\n' "$stage" "$rg"
  if ! group_exists "$rg" "$AZFLOW_SUBSCRIPTION_ID"; then
    printf 'Resource group `%s` does not exist yet (or the preview identity can not see it), so there is nothing to compare. It is created by `bootstrap/seed.sh` (README, "First-run order"); this preview works after the seed has run.\n\n' "$rg"
    return 0
  fi
  if ! group_exists "$shared_rg" "$shared_sub"; then
    printf 'Shared resource group `%s` does not exist yet (it holds the DNS zone and is created by `bootstrap/seed.sh`), so the preview cannot run.\n\n' "$shared_rg"
    return 0
  fi
  rc=0
  out="$(az deployment group what-if --resource-group "$rg" --subscription "$AZFLOW_SUBSCRIPTION_ID" \
    --template-file "$AZFLOW_ROOT/bicep/main.bicep" --parameters "$AZFLOW_ROOT/bicep/$stage.bicepparam" 2>&1)" || rc=$?
  out="$(printf '%s\n' "$out" | strip_ansi)"
  printf '%s\n' "$out" >&2
  if [ "$rc" -ne 0 ]; then
    printf '**What-if failed** (exit %s):\n\n```text\n%s\n```\n\n' "$rc" "$out"
    return 1
  fi
  printf '```text\n%s\n```\n\n' "$out"
}

cmd_apply() {
  local stage="$1" rg shared_rg shared_sub state outputs name suffix_note
  need_stage "$stage"
  need_subscription
  rg="$(stage_get "$stage" .resourceGroup)"
  shared_rg="$(stage_get "$stage" .shared.resourceGroup)"
  shared_sub="$(shared_subscription "$stage")"
  group_exists "$rg" "$AZFLOW_SUBSCRIPTION_ID" || die "resource group $rg does not exist. Run bootstrap/seed.sh first (README, \"First-run order\")."
  group_exists "$shared_rg" "$shared_sub" || die "shared resource group $shared_rg does not exist. Run bootstrap/seed.sh first."
  if [ -z "${AZFLOW_API_PRINCIPAL_ID:-}" ] || [ -z "${AZFLOW_WEB_PRINCIPAL_ID:-}" ]; then
    warn "AZFLOW_API_PRINCIPAL_ID or AZFLOW_WEB_PRINCIPAL_ID is empty: the role assignments for that identity are skipped."
  fi
  # A stopped AKS cluster only accepts start and delete, so an update would fail half way through.
  state="$(cluster_state "$stage" || true)"
  if [ "$state" = Stopped ]; then
    die "cluster $(stage_get "$stage" .cluster) is stopped and Azure rejects updates to a stopped cluster. Run the 'cluster-start' workflow for $stage, then re-run this deployment (it can be stopped again afterwards)."
  fi
  name="azflow-$stage-${GITHUB_RUN_ID:-manual}"
  outputs="$(az deployment group create --name "$name" --resource-group "$rg" --subscription "$AZFLOW_SUBSCRIPTION_ID" \
    --template-file "$AZFLOW_ROOT/bicep/main.bicep" --parameters "$AZFLOW_ROOT/bicep/$stage.bicepparam" \
    --query properties.outputs -o json)"
  suffix_note=""
  [ -z "${AZFLOW_NAME_SUFFIX:-}" ] || suffix_note=" (name suffix \`$AZFLOW_NAME_SUFFIX\`)"
  summary "### Applied \`$stage\` to \`$rg\`$suffix_note"
  summary ""
  summary "| Output | Value |"
  summary "| --- | --- |"
  summary "| Registry login server | \`$(printf '%s' "$outputs" | jq -r '.registryLoginServer.value // "-"')\` |"
  summary "| Static Web App default hostname | \`$(printf '%s' "$outputs" | jq -r '.staticWebAppDefaultHostname.value // "-"')\` |"
  summary ""
  summary "**DNS zone \`$(stage_get "$stage" .shared.dnsZone)\` name servers** (for the Route 53 NS record named \`demo\`, see README \"DNS\"):"
  summary ""
  printf '%s' "$outputs" | jq -r '(.dnsNameServers.value // [])[] | "- `" + . + "`"' >>"$SUMMARY"
  summary ""
  log "Deployment $name finished. Name servers:"
  printf '%s' "$outputs" | jq -r '(.dnsNameServers.value // [])[]'
}

cmd_aks() {
  local action="$1" stage="$2" state cluster rg
  case "$action" in stop | start) ;; *) die "aks: expected stop or start, got '$action'" ;; esac
  need_stage "$stage"
  need_subscription
  rg="$(stage_get "$stage" .resourceGroup)"
  cluster="$(stage_get "$stage" .cluster)"
  if ! group_exists "$rg" "$AZFLOW_SUBSCRIPTION_ID"; then
    if [ "$action" = stop ]; then
      log "Resource group $rg does not exist: nothing to stop."
      summary "- \`$stage\`: resource group \`$rg\` does not exist, nothing to stop."
      return 0
    fi
    die "resource group $rg does not exist. Run the seed and the apply workflow first."
  fi
  state="$(cluster_state "$stage")"
  if [ -z "$state" ]; then
    if [ "$action" = stop ]; then
      log "Cluster $cluster does not exist: nothing to stop."
      summary "- \`$stage\`: cluster \`$cluster\` does not exist, nothing to stop."
      return 0
    fi
    die "cluster $cluster does not exist in $rg. Run the apply workflow first."
  fi
  case "$action:$state" in
    stop:Stopped | start:Running)
      log "Cluster $cluster is already $state."
      summary "- \`$stage\`: cluster \`$cluster\` was already $state."
      return 0
      ;;
  esac
  log "Cluster $cluster is $state; running az aks $action (takes a few minutes)."
  az aks "$action" --resource-group "$rg" --name "$cluster" --subscription "$AZFLOW_SUBSCRIPTION_ID"
  state="$(cluster_state "$stage")"
  summary "- \`$stage\`: cluster \`$cluster\` is now ${state:-unknown} (after \`az aks $action\`)."
}

# Only groups this project created may be deleted.
delete_group() { # <resource group> <subscription>
  case "$1" in
    rg-azflow-*) ;;
    *) die "refusing to delete '$1': only resource groups named rg-azflow-* are ever deleted" ;;
  esac
  if ! group_exists "$1" "$2"; then
    log "Resource group $1 does not exist (already gone)."
    summary "- \`$1\`: already gone."
    return 0
  fi
  log "Deleting resource group $1 (takes a few minutes)."
  az group delete --name "$1" --subscription "$2" --yes
  group_exists "$1" "$2" && die "resource group $1 still exists after the delete"
  summary "- \`$1\`: deleted."
  return 0
}

cmd_destroy() {
  local stage="$1" shared="${2:-}"
  need_stage "$stage"
  need_subscription
  case "$shared" in "" | --shared) ;; *) die "destroy: unknown option '$shared'" ;; esac
  delete_group "$(stage_get "$stage" .resourceGroup)" "$AZFLOW_SUBSCRIPTION_ID"
  if [ "$shared" = --shared ]; then
    delete_group "$(stage_get "$stage" .shared.resourceGroup)" "$(shared_subscription "$stage")"
    summary ""
    summary "> **Now delete the Route 53 record.** In AWS, open Route 53 > Hosted zones > \`zzll.de\` and delete the"
    summary "> \`NS\` record named \`demo\` (\`$(stage_get "$stage" .shared.dnsZone)\`). The Azure DNS zone is gone, and a delegation left"
    summary "> behind would let anyone who creates a zone with that name in their own Azure account take over the subdomain."
  fi
}

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  require_cmd jq "Install jq."
  case "$cmd" in
    missing-vars) cmd_missing_vars "$@" ;;
    what-if | apply | destroy)
      [ $# -ge 1 ] || die "$cmd needs a stage (see --help)"
      "cmd_${cmd//-/_}" "$@"
      ;;
    aks)
      [ $# -eq 2 ] || die "aks needs an action and a stage (see --help)"
      cmd_aks "$@"
      ;;
    -h | --help | help | "") usage ;;
    *) die "unknown command '$cmd' (see --help)" ;;
  esac
}

main "$@"
