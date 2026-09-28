#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks in the printf formats are literal markdown
# Helper the GitHub Actions workflows call, so the logic can be tested offline against a fake `az`
# (tests/test_ci.sh). Every command expects the workflow to have signed in already (Azure OIDC login) and reads its
# inputs from environment variables set by the workflow, never from event text.
#
#   ci/stage.sh missing-vars <NAME>...      print the names of unset or empty variables (always exits 0)
#   ci/stage.sh what-if <stage>             markdown preview of the stage deployment on stdout; non-zero if what-if failed
#   ci/stage.sh apply <stage>               deploy bicep/main.bicep with bicep/<stage>.bicepparam, writing the custom
#                                            domain's TXT record while it runs; summary with name servers
#   ci/stage.sh dns-auth <stage>            write the Static Web App custom domain's `_dnsauth.<host>` TXT record
#                                            into the shared zone, if the domain is not already validated (idempotent)
#   ci/stage.sh api-dns <stage>             point the stage's apiHost A record in the shared zone at the cluster's
#                                            ingress IP (read with kubectl); no-op when it already does (idempotent)
#   ci/stage.sh aks <stop|start> <stage>    switch the stage's cluster off or on (idempotent)
#   ci/stage.sh destroy <stage> [--shared]  delete the stage resource group, and with --shared the shared one too
#
# Environment: AZFLOW_SUBSCRIPTION_ID (subscription of the stage; the stage files reference it), and for apply and
# what-if also AZFLOW_NAME_SUFFIX, AZFLOW_API_PRINCIPAL_ID, AZFLOW_WEB_PRINCIPAL_ID (read by bicep/*.bicepparam).
# api-dns also needs AZFLOW_INFRA_PRINCIPAL_ID (object ID of the signed-in infra identity, written by the seed), plus
# kubectl and kubelogin on PATH (az aks install-cli).
# AZFLOW_POLL_SECONDS: how often apply polls the running deployment, and api-dns the ingress IP (default 20).
# AZFLOW_INGRESS_ATTEMPTS: how many times api-dns reads the ingress IP before giving up (default 30).
# The job summary goes to $GITHUB_STEP_SUMMARY when set.
set -euo pipefail
# shellcheck source=bootstrap/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bootstrap/lib.sh"

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

summary() { printf '%s\n' "$*" >>"$SUMMARY"; }

usage() {
  sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
  # ProviderNoRbac: the preview identity is read-only on purpose; the default validation level would also demand the
  # write permissions a real deployment needs.
  out="$(az deployment group what-if --resource-group "$rg" --subscription "$AZFLOW_SUBSCRIPTION_ID" \
    --validation-level ProviderNoRbac --template-file "$AZFLOW_ROOT/bicep/main.bicep" --parameters "$AZFLOW_ROOT/bicep/$stage.bicepparam" 2>&1)" || rc=$?
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
  # The customDomains resource only finishes once Azure sees the `_dnsauth.<host>` TXT record, and its validation
  # token is only readable after the deployment has created that resource. A blocking create would wait for a record
  # nobody writes yet, so start the deployment without waiting, write the record as soon as the token appears, then
  # wait for the deployment to finish. The job's timeout-minutes is only a backstop for slow DNS propagation.
  az deployment group create --name "$name" --resource-group "$rg" --subscription "$AZFLOW_SUBSCRIPTION_ID" \
    --template-file "$AZFLOW_ROOT/bicep/main.bicep" --parameters "$AZFLOW_ROOT/bicep/$stage.bicepparam" --no-wait
  wait_for_deployment "$stage" "$name"
  outputs="$(az deployment group show --name "$name" --resource-group "$rg" --subscription "$AZFLOW_SUBSCRIPTION_ID" \
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

# Poll the deployment started by cmd_apply until it reaches a terminal state. While it runs, write the custom
# domain's TXT record the moment its validation token becomes readable (before that the hostname lookup fails
# because the customDomains resource does not exist yet, which is expected). Poll interval: AZFLOW_POLL_SECONDS.
wait_for_deployment() { # <stage> <deployment name>
  local stage="$1" name="$2" rg state token written=""
  rg="$(stage_get "$stage" .resourceGroup)"
  log "Deployment $name started; waiting for it (and writing the custom-domain TXT record once its token appears)."
  while :; do
    state="$(az deployment group show --name "$name" --resource-group "$rg" --subscription "$AZFLOW_SUBSCRIPTION_ID" \
      --query properties.provisioningState -o tsv)"
    if [ -z "$written" ]; then
      token="$(validation_token "$stage" 2>/dev/null || true)"
      if [ -n "$token" ] && [ "$token" != "null" ]; then
        write_dns_auth_record "$stage" "$token"
        written=1
      fi
    fi
    case "$state" in
      Succeeded) return 0 ;;
      Failed | Canceled)
        warn "deployment $name ended $state:"
        az deployment group show --name "$name" --resource-group "$rg" --subscription "$AZFLOW_SUBSCRIPTION_ID" \
          --query properties.error -o json >&2 || true
        return 1
        ;;
    esac
    sleep "${AZFLOW_POLL_SECONDS:-20}"
  done
}

validation_token() { # <stage>: the pending dns-txt-token, empty or "null" once the domain is validated
  az staticwebapp hostname show --name "$(stage_get "$1" .staticWebApp)" --resource-group "$(stage_get "$1" .resourceGroup)" \
    --hostname "$(stage_get "$1" .webHost)" --subscription "$AZFLOW_SUBSCRIPTION_ID" --query validationToken -o tsv
}

host_record() { # <stage> <webHost|apiHost>: that host's record-set name in the shared zone
  local host zone
  host="$(stage_get "$1" ".$2")"
  zone="$(stage_get "$1" .shared.dnsZone)"
  record_name "$host" "$zone" || die "$2 $host is not a subdomain of zone $zone; this script only handles subdomain hosts."
}

write_dns_auth_record() { # <stage> <token>: publish `_dnsauth.<host>` in the shared zone (add-record is idempotent)
  local stage="$1" token="$2" host zone subdomain record
  host="$(stage_get "$stage" .webHost)"
  zone="$(stage_get "$stage" .shared.dnsZone)"
  subdomain="$(host_record "$stage" webHost)"
  record="_dnsauth.$subdomain"
  az network dns record-set txt add-record --resource-group "$(stage_get "$stage" .shared.resourceGroup)" --zone-name "$zone" \
    --subscription "$(shared_subscription "$stage")" --record-set-name "$record" --value "$token" >/dev/null
  log "Wrote domain-ownership TXT record $record.$zone for $host."
  summary "- \`$stage\`: wrote domain-ownership TXT record \`$record.$zone\` for \`$host\`."
}

# The Static Web App custom domain (bicep/modules/static-web-app.bicep) uses dns-txt-token validation: Azure
# generates a token that must be published as `_dnsauth.<host>` in the shared zone before it proves ownership and
# issues the managed certificate. `apply` already writes it while the deployment runs; this standalone command
# re-checks afterwards. Idempotent: once the domain is validated, Azure stops returning a token and this is a no-op.
cmd_dns_auth() {
  local stage="$1" host token
  need_stage "$stage"
  need_subscription
  host="$(stage_get "$stage" .webHost)"
  token="$(validation_token "$stage")"
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    log "Custom domain $host is already validated; no TXT record needed."
    summary "- \`$stage\`: \`$host\` already validated, no domain-ownership TXT record needed."
    return 0
  fi
  write_dns_auth_record "$stage" "$token"
}

# The API's ingress is AKS's application-routing add-on (managed NGINX). Its public IP is assigned by the cluster's
# load balancer to the add-on's `nginx` Service in the `app-routing-system` namespace and is not an ARM output of the
# cluster, so Bicep cannot write this record. Microsoft documents reading it with kubectl:
#   kubectl get service -n app-routing-system nginx -o jsonpath="{.status.loadBalancer.ingress[0].ip}"
# (https://learn.microsoft.com/azure/aks/app-routing). The cluster uses Azure RBAC for Kubernetes and the infra
# identity holds no Kubernetes role by default, so this first grants it Azure Kubernetes Service RBAC Reader on that
# one namespace (read-only, no Secrets), the narrowest built-in grant that can read the Service. README, "Access model".
INGRESS_NAMESPACE=app-routing-system
INGRESS_SERVICE=nginx

cluster_id() { # <stage>
  az aks show --resource-group "$(stage_get "$1" .resourceGroup)" --name "$(stage_get "$1" .cluster)" \
    --subscription "$AZFLOW_SUBSCRIPTION_ID" --query id -o tsv
}

ensure_ingress_reader() { # <stage>: namespace-scoped AKS RBAC Reader for the infra identity (idempotent)
  local stage="$1" scope n
  scope="$(cluster_id "$stage")/namespaces/$INGRESS_NAMESPACE"
  # Filtered by principal here rather than with --assignee, which can make az look the principal up in Microsoft
  # Graph; the pipeline identity has no Graph permission.
  n="$(az role assignment list --role "$ROLE_AKS_RBAC_READER" --scope "$scope" --subscription "$AZFLOW_SUBSCRIPTION_ID" \
    --fill-principal-name false -o json |
    jq --arg p "$AZFLOW_INFRA_PRINCIPAL_ID" --arg s "$scope" \
      '[.[] | select(.principalId == $p and (.scope | ascii_downcase) == ($s | ascii_downcase))] | length')"
  if [ "$n" -gt 0 ]; then
    log "The infra identity can already read namespace $INGRESS_NAMESPACE."
    return 0
  fi
  az role assignment create --assignee-object-id "$AZFLOW_INFRA_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
    --role "$ROLE_AKS_RBAC_READER" --scope "$scope" --subscription "$AZFLOW_SUBSCRIPTION_ID" -o none
  log "Granted the infra identity Azure Kubernetes Service RBAC Reader on namespace $INGRESS_NAMESPACE (takes up to five minutes to apply)."
  summary "- \`$stage\`: granted the infra identity read-only access to namespace \`$INGRESS_NAMESPACE\` (to read the ingress IP)."
}

# ingress_ip <kubeconfig>: the ingress Service's public IPv4. Retries while the load balancer has not assigned one
# yet and while a fresh role assignment is still propagating (kubectl then answers Forbidden).
ingress_ip() {
  local kubeconfig="$1" n=1 max="${AZFLOW_INGRESS_ATTEMPTS:-30}" ip err
  while :; do
    ip="$(kubectl --kubeconfig "$kubeconfig" get service "$INGRESS_SERVICE" --namespace "$INGRESS_NAMESPACE" \
      -o 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>"$kubeconfig.err")" || ip=""
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
    err="$(cat "$kubeconfig.err")"
    if [ "$n" -ge "$max" ]; then
      warn "no public IP on service $INGRESS_NAMESPACE/$INGRESS_SERVICE after $max attempts${err:+ (last error: $err)}"
      return 1
    fi
    log "Ingress IP not readable yet (attempt $n/$max)${err:+: $err}" >&2
    sleep "${AZFLOW_POLL_SECONDS:-20}"
    n=$((n + 1))
  done
}

write_api_record() { # <stage> <ip>: make the apiHost A record hold exactly <ip>, touching it only when it differs
  local stage="$1" ip="$2" host zone record shared_rg shared_sub current old
  host="$(stage_get "$stage" .apiHost)"
  zone="$(stage_get "$stage" .shared.dnsZone)"
  record="$(host_record "$stage" apiHost)"
  shared_rg="$(stage_get "$stage" .shared.resourceGroup)"
  shared_sub="$(shared_subscription "$stage")"
  # Newer az versions print the record list as ARecords, older ones as arecords; a missing record set reads as empty.
  current="$(az network dns record-set a show --resource-group "$shared_rg" --zone-name "$zone" --subscription "$shared_sub" \
    --name "$record" --query "(ARecords || aRecords || arecords)[].ipv4Address" -o tsv 2>/dev/null || true)"
  if [ "$current" = "$ip" ]; then
    log "A record $host already points at the ingress IP $ip."
    summary "- \`$stage\`: \`$host\` already points at the ingress IP \`$ip\`."
    return 0
  fi
  # Add the new address before removing any old one, so the name never resolves to nothing in between.
  az network dns record-set a add-record --resource-group "$shared_rg" --zone-name "$zone" --subscription "$shared_sub" \
    --record-set-name "$record" --ipv4-address "$ip" >/dev/null
  for old in $current; do
    [ "$old" = "$ip" ] && continue
    az network dns record-set a remove-record --resource-group "$shared_rg" --zone-name "$zone" --subscription "$shared_sub" \
      --record-set-name "$record" --ipv4-address "$old" --keep-empty-record-set >/dev/null
  done
  log "A record $host now points at the ingress IP $ip${current:+ (was: $(printf '%s' "$current" | tr '\n' ' '))}."
  summary "- \`$stage\`: A record \`$host\` now points at the ingress IP \`$ip\`."
}

cmd_api_dns() {
  local stage="$1" cluster state kubeconfig ip
  need_stage "$stage"
  need_subscription
  [ -n "${AZFLOW_INFRA_PRINCIPAL_ID:-}" ] ||
    die "AZFLOW_INFRA_PRINCIPAL_ID is empty. Re-run bootstrap/seed.sh: it writes AZFLOW_<STAGE>_INFRA_PRINCIPAL_ID (README, \"First-run order\")."
  require_cmd kubectl "Run: az aks install-cli"
  require_cmd kubelogin "Run: az aks install-cli"
  host_record "$stage" apiHost >/dev/null
  cluster="$(stage_get "$stage" .cluster)"
  state="$(cluster_state "$stage")"
  [ -n "$state" ] || die "cluster $cluster does not exist. Run the apply workflow first."
  [ "$state" = Running ] || die "cluster $cluster is $state, so its ingress IP cannot be read. Run the 'cluster-start' workflow for $stage first."
  ensure_ingress_reader "$stage"
  kubeconfig="$(mktemp)"
  # shellcheck disable=SC2064  # expand now: the local is gone when the trap fires
  trap "rm -f '$kubeconfig' '$kubeconfig.err'" EXIT
  # Entra-only cluster: the user kubeconfig carries no credential; kubelogin fetches a token from the az sign-in.
  az aks get-credentials --resource-group "$(stage_get "$stage" .resourceGroup)" --name "$cluster" \
    --subscription "$AZFLOW_SUBSCRIPTION_ID" --file "$kubeconfig" --overwrite-existing >/dev/null
  kubelogin convert-kubeconfig --login azurecli --kubeconfig "$kubeconfig"
  ip="$(ingress_ip "$kubeconfig")" || die "could not read the ingress IP of cluster $cluster; the A record for $(stage_get "$stage" .apiHost) was not changed."
  write_api_record "$stage" "$ip"
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
    what-if | apply | dns-auth | api-dns | destroy)
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
