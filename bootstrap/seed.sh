#!/usr/bin/env bash
# One-time seed, run by the captain after `az login` (and after bootstrap/preflight.sh).
#
#   export AZFLOW_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
#   bootstrap/seed.sh --dry-run          # prints every planned action, touches nothing
#   bootstrap/seed.sh                    # does it
#   bootstrap/seed.sh --providers-only   # only registers resource providers (free), then stops
#
# Options: --dry-run, --providers-only, --no-gh (print the IDs instead of writing GitHub variables).
#
# What it does, per stage file in stages/ (idempotent: every step looks first, so re-running is safe):
#   1. registers the resource providers
#   2. creates the stage resource groups and the shared resource group (DNS zone lives there)
#   3. creates Entra app registrations + service principals: infra, web, api for each stage (six) and
#      one read-only infra identity for pull-request previews
#   4. adds federated credentials (OIDC); no secrets or passwords are ever created
#   5. assigns each identity rights on ITS OWN stage's resource group only (see README, "Access model")
#   6. writes client / tenant / subscription / principal IDs to GitHub repo variables with gh when
#      authenticated, otherwise prints them

set -euo pipefail
# shellcheck source=bootstrap/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

DRY=0
PROVIDERS_ONLY=0
USE_GH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --providers-only) PROVIDERS_ONLY=1 ;;
    --no-gh) USE_GH=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd jq "Install jq (brew install jq)."
if [ "$DRY" -eq 0 ]; then
  require_cmd az "Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli"
fi

RETRY_SLEEP="${AZFLOW_RETRY_SLEEP:-10}"
ISSUER="https://token.actions.githubusercontent.com"
AUDIENCE="api://AzureADTokenExchange"
WHATIF_ROLE="azflow-deployment-whatif"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
: >"$WORK/vars"

# ---- output helpers -----------------------------------------------------------------------------

plan() { printf '  [dry-run] %s\n' "$*"; }
did() { printf '  + %s\n' "$*"; }
have() { printf '  = %s (already there)\n' "$*"; }

# retry <description> <command...>: role and credential writes can lag behind a new service principal.
retry() {
  local what="$1" n=1 max=6
  shift
  until "$@"; do
    if [ "$n" -ge "$max" ]; then
      die "$what failed after $max attempts"
    fi
    warn "$what failed (attempt $n/$max), waiting for Entra to catch up..."
    sleep "$RETRY_SLEEP"
    n=$((n + 1))
  done
}

# ---- load stages --------------------------------------------------------------------------------

problems=0
for st in $ALL_STAGES; do
  if ! out="$(validate_stage "$st")"; then
    printf '%s\n' "$out" >&2
    problems=1
  fi
done
[ "$problems" -eq 0 ] || die "stage file problems above"
if ! out="$(validate_distinct)"; then
  printf '%s\n' "$out" >&2
  die "stage files problems above"
fi

# Subscriptions come from the environment at run time. A dry run needs no sign-in, so it shows a
# placeholder for anything unset.
resolve_sub() { # <stage> <jq path>
  local raw
  raw="$(stage_get "$1" "$2")"
  if resolve_ref "$raw"; then return 0; fi
  if [ "$DRY" -eq 1 ]; then
    printf '<%s>' "${raw#\$}"
    return 0
  fi
  die "stage '$1': $2 is $raw but that environment variable is not set. Try: export AZFLOW_SUBSCRIPTION_ID=\"\$(az account show --query id -o tsv)\""
}

ST_SUB=()
ST_SHARED_SUB=()
ST_LOC=()
ST_RG=()
ST_CLUSTER=()
ST_SWA=()
ST_REGISTRY=()
ST_WEB_HOST=()
ST_API_HOST=()
i=0
for st in $ALL_STAGES; do
  sub="$(resolve_sub "$st" .subscriptionId)" || exit 2
  shared_sub="$(resolve_sub "$st" .shared.subscriptionId)" || exit 2
  ST_SUB+=("$sub")
  ST_SHARED_SUB+=("$shared_sub")
  ST_LOC+=("$(stage_get "$st" .location)")
  ST_RG+=("$(stage_get "$st" .resourceGroup)")
  ST_CLUSTER+=("$(stage_get "$st" .cluster)")
  ST_SWA+=("$(stage_get "$st" .staticWebApp)")
  ST_REGISTRY+=("$(registry_name "$st")")
  ST_WEB_HOST+=("$(stage_get "$st" .webHost)")
  ST_API_HOST+=("$(stage_get "$st" .apiHost)")
  i=$((i + 1))
done
n_stages=$i

# The shared group holds the DNS zone; validate_distinct has checked that every stage file describes it identically.
first_stage="$(printf '%s' "$ALL_STAGES" | cut -d' ' -f1)"
SHARED_SUB="${ST_SHARED_SUB[0]}"
SHARED_RG="$(stage_get "$first_stage" .shared.resourceGroup)"
SHARED_LOC="$(stage_get "$first_stage" .shared.location)"

# Distinct subscriptions across all groups.
SUBS=""
for ((i = 0; i < n_stages; i++)); do
  case " $SUBS " in *" ${ST_SUB[$i]} "*) ;; *) SUBS="$SUBS ${ST_SUB[$i]}" ;; esac
done
case " $SUBS " in *" $SHARED_SUB "*) ;; *) SUBS="$SUBS $SHARED_SUB" ;; esac

# ---- sign-in and tenant -------------------------------------------------------------------------

TENANT_ID="<tenant-id>"
if [ "$DRY" -eq 0 ]; then
  az account show >/dev/null 2>&1 || die "not signed in to Azure. Run: az login"
  for sub in $SUBS; do
    t="$(az account show --subscription "$sub" --query tenantId -o tsv 2>/dev/null)" ||
      die "subscription $sub is not visible to this login"
    if [ "$TENANT_ID" = "<tenant-id>" ]; then
      TENANT_ID="$t"
    elif [ "$TENANT_ID" != "$t" ]; then
      die "the stage subscriptions are in different tenants; one seed run covers one tenant"
    fi
  done
fi

# ---- 1. providers -------------------------------------------------------------------------------

ensure_provider() { # <sub> <namespace>
  local state
  if [ "$DRY" -eq 1 ]; then
    plan "register resource provider $2 in subscription $1 (if not registered)"
    return
  fi
  state="$(az provider show --namespace "$2" --subscription "$1" --query registrationState -o tsv 2>/dev/null || true)"
  if [ "$state" = "Registered" ]; then
    have "provider $2"
  else
    az provider register --namespace "$2" --subscription "$1" --wait -o none
    did "registered provider $2"
  fi
}

log "1. Resource providers"
for sub in $SUBS; do
  for ns in $REQUIRED_PROVIDERS; do ensure_provider "$sub" "$ns"; done
done
if [ "$PROVIDERS_ONLY" -eq 1 ]; then
  log
  log "Providers done. Re-run bootstrap/preflight.sh, then bootstrap/seed.sh."
  exit 0
fi

# ---- 2. resource groups -------------------------------------------------------------------------

ensure_rg() { # <sub> <name> <location>
  if [ "$DRY" -eq 1 ]; then
    plan "create resource group $2 ($3) in subscription $1 (if missing)"
    return
  fi
  if [ "$(az group exists --name "$2" --subscription "$1" 2>/dev/null)" = "true" ]; then
    have "resource group $2"
  else
    az group create --name "$2" --location "$3" --subscription "$1" -o none
    did "created resource group $2"
  fi
}

rg_id() { printf '/subscriptions/%s/resourceGroups/%s' "$1" "$2"; }

log
log "2. Resource groups"
for ((i = 0; i < n_stages; i++)); do ensure_rg "${ST_SUB[$i]}" "${ST_RG[$i]}" "${ST_LOC[$i]}"; done
ensure_rg "$SHARED_SUB" "$SHARED_RG" "$SHARED_LOC"

# ---- 3. identities and 4. federated credentials -------------------------------------------------

ID_APP=""
ID_OBJ=""

# ensure_identity <display name>: sets ID_APP (client id) and ID_OBJ (service principal object id).
ensure_identity() {
  local name="$1" app obj
  if [ "$DRY" -eq 1 ]; then
    plan "create Entra app registration + service principal '$name' (if missing)"
    ID_APP="<$name-client-id>"
    ID_OBJ="<$name-principal-id>"
    return
  fi
  app="$(az ad app list --filter "displayName eq '$name'" --query "[0].appId" -o tsv 2>/dev/null || true)"
  if [ -n "$app" ]; then
    have "app registration $name"
  else
    app="$(az ad app create --display-name "$name" --query appId -o tsv)"
    did "created app registration $name"
  fi
  obj="$(az ad sp list --filter "appId eq '$app'" --query "[0].id" -o tsv 2>/dev/null || true)"
  if [ -n "$obj" ]; then
    have "service principal $name"
  else
    obj="$(az ad sp create --id "$app" --query id -o tsv)"
    did "created service principal $name"
  fi
  ID_APP="$app"
  ID_OBJ="$obj"
}

ensure_fedcred() { # <identity name> <app id> <credential name> <subject>
  local existing params
  params="$(jq -cn --arg n "$3" --arg i "$ISSUER" --arg s "$4" --arg a "$AUDIENCE" \
    '{name: $n, issuer: $i, subject: $s, audiences: [$a]}')"
  if [ "$DRY" -eq 1 ]; then
    plan "federated credential '$3' on $1: subject $4"
    return
  fi
  existing="$(az ad app federated-credential list --id "$2" --query "[?name=='$3'].subject | [0]" -o tsv 2>/dev/null || true)"
  if [ "$existing" = "$4" ]; then
    have "federated credential $3 on $1"
  elif [ -n "$existing" ]; then
    retry "update federated credential $3" az ad app federated-credential update --id "$2" --federated-credential-id "$3" --parameters "$params"
    did "updated federated credential $3 on $1 (subject was $existing)"
  else
    retry "create federated credential $3" az ad app federated-credential create --id "$2" --parameters "$params" -o none
    did "created federated credential $3 on $1"
  fi
}

# ---- 5. role assignments ------------------------------------------------------------------------

# Role Based Access Control Administrator, limited to assigning/removing only the listed roles.
rbac_condition() { # <role id>...
  local ids="" id
  for id in "$@"; do ids="$ids$id, "; done
  ids="${ids%, }"
  printf '((!(ActionMatches{Microsoft.Authorization/roleAssignments/write})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {%s})) AND ((!(ActionMatches{Microsoft.Authorization/roleAssignments/delete})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {%s}))' "$ids" "$ids"
}

stage_rbac_condition() {
  rbac_condition "$ROLE_ACR_PUSH" "$ROLE_ACR_PULL" "$ROLE_AKS_CLUSTER_USER" "$ROLE_AKS_RBAC_WRITER" "$ROLE_CONTRIBUTOR" "$ROLE_DNS_ZONE_CONTRIBUTOR"
}

squash() { tr -d ' \n\t'; }

# ensure_role <sub> <scope> <principal object id> <role name> <who, for messages> [condition]
ensure_role() {
  local sub="$1" scope="$2" obj="$3" role="$4" who="$5" cond="${6:-}" existing exact stale id
  if [ "$DRY" -eq 1 ]; then
    if [ -n "$cond" ]; then
      plan "role '$role' for $who on $scope, limited by condition to assigning: $(printf '%s' "$cond" | grep -o '{[^}]*}' | tail -n 1)"
    else
      plan "role '$role' for $who on $scope"
    fi
    return
  fi
  existing="$(az role assignment list --assignee "$obj" --role "$role" --scope "$scope" --subscription "$sub" -o json 2>/dev/null || echo '[]')"
  exact=0
  stale=""
  while IFS=$'\t' read -r id c; do
    [ -n "$id" ] || continue
    if [ "$(printf '%s' "$c" | squash)" = "$(printf '%s' "$cond" | squash)" ]; then
      exact=1
    else
      stale="$stale $id"
    fi
  done < <(printf '%s' "$existing" | jq -r --arg s "$scope" '.[] | select((.scope | ascii_downcase) == ($s | ascii_downcase)) | [.id, (.condition // "")] | @tsv')
  if [ "$exact" -eq 1 ]; then
    have "role $role for $who on $scope"
    return
  fi
  for id in $stale; do
    az role assignment delete --ids "$id" --subscription "$sub" -o none
    did "removed outdated $role assignment for $who (condition changed)"
  done
  if [ -n "$cond" ]; then
    retry "assign $role to $who" az role assignment create --assignee-object-id "$obj" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$scope" --subscription "$sub" --condition "$cond" --condition-version 2.0 -o none
  else
    retry "assign $role to $who" az role assignment create --assignee-object-id "$obj" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$scope" --subscription "$sub" -o none
  fi
  did "assigned $role to $who on $scope"
}

# Custom role for PR previews: what-if needs an action the Reader role lacks. Read-only, no writes.
ensure_whatif_role() { # <sub> <assignable scope>...
  local sub="$1" scopes existing def
  shift
  scopes="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  def="$(jq -cn --arg n "$WHATIF_ROLE" --argjson s "$scopes" '{
    Name: $n, IsCustom: true,
    Description: "Run deployment what-if previews. Read-only: no resource changes.",
    Actions: ["Microsoft.Resources/deployments/whatIf/action", "Microsoft.Resources/deployments/read", "Microsoft.Resources/deployments/operations/read"],
    NotActions: [], AssignableScopes: $s}')"
  if [ "$DRY" -eq 1 ]; then
    plan "custom role '$WHATIF_ROLE' (what-if only) in subscription $sub, assignable to: $*"
    return
  fi
  existing="$(az role definition list --name "$WHATIF_ROLE" --custom-role-only true --subscription "$sub" --query "[0].name" -o tsv 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    az role definition update --role-definition "$def" --subscription "$sub" -o none
    did "updated custom role $WHATIF_ROLE in $sub"
  else
    az role definition create --role-definition "$def" --subscription "$sub" -o none
    did "created custom role $WHATIF_ROLE in $sub"
  fi
}

# ---- run: identities, credentials, rights -------------------------------------------------------

INFRA_APP=()
API_APP=()
WEB_APP=()
API_OBJ=()
WEB_OBJ=()

log
log "3-5. Identities, federated credentials and role assignments"
i=0
for st in $ALL_STAGES; do
  sub="${ST_SUB[$i]}"
  rg_scope="$(rg_id "$sub" "${ST_RG[$i]}")"
  shared_sub="${ST_SHARED_SUB[$i]}"
  shared_scope="$(rg_id "$shared_sub" "$SHARED_RG")"
  log
  log "Stage $st"

  # infra: environment-scoped token of the infra repo. Contributor deploys the stage's Bicep; the
  # conditioned RBAC Administrator lets that deployment grant only the narrow roles Bicep assigns.
  name="$(identity_name infra "$st")"
  ensure_identity "$name"
  INFRA_APP+=("$ID_APP")
  infra_obj="$ID_OBJ"
  ensure_fedcred "$name" "$ID_APP" "github-environment-$st" "repo:$INFRA_REPO:environment:$st"
  ensure_role "$sub" "$rg_scope" "$infra_obj" "Contributor" "$name"
  ensure_role "$sub" "$rg_scope" "$infra_obj" "Role Based Access Control Administrator" "$name" "$(stage_rbac_condition)"
  # The shared group holds only the DNS zone. Contributor there lets the stage deployment create the
  # zone; the RBAC condition allows only the DNS Zone Contributor role.
  ensure_role "$shared_sub" "$shared_scope" "$infra_obj" "Contributor" "$name"
  ensure_role "$shared_sub" "$shared_scope" "$infra_obj" "Role Based Access Control Administrator" "$name" "$(rbac_condition "$ROLE_DNS_ZONE_CONTRIBUTOR")"

  # web and api: main branch of their private repos. Reader on the stage group to look resources up;
  # the write-type rights are granted per resource by Bicep (bicep/modules).
  for kind in web api; do
    name="$(identity_name "$kind" "$st")"
    ensure_identity "$name"
    if [ "$kind" = web ]; then
      WEB_APP+=("$ID_APP")
      WEB_OBJ+=("$ID_OBJ")
      repo="$WEB_REPO"
    else
      API_APP+=("$ID_APP")
      API_OBJ+=("$ID_OBJ")
      repo="$API_REPO"
    fi
    ensure_fedcred "$name" "$ID_APP" "github-main" "repo:$repo:ref:refs/heads/main"
    ensure_role "$sub" "$rg_scope" "$ID_OBJ" "Reader" "$name"
  done
  i=$((i + 1))
done

# Preview identity: pull_request token of the infra repo; read-only plus what-if, on every group.
log
log "Preview identity"
name="$(identity_name infra preview)"
ensure_identity "$name"
PREVIEW_APP="$ID_APP"
preview_obj="$ID_OBJ"
ensure_fedcred "$name" "$ID_APP" "github-pull-request" "repo:$INFRA_REPO:pull_request"
for sub in $SUBS; do
  scopes=""
  for ((i = 0; i < n_stages; i++)); do
    [ "${ST_SUB[$i]}" != "$sub" ] || scopes="$scopes $(rg_id "$sub" "${ST_RG[$i]}")"
  done
  [ "$SHARED_SUB" != "$sub" ] || scopes="$scopes $(rg_id "$SHARED_SUB" "$SHARED_RG")"
  # shellcheck disable=SC2086  # scopes is a space-separated list of resource ids
  ensure_whatif_role "$sub" $scopes
  for scope in $scopes; do
    ensure_role "$sub" "$scope" "$preview_obj" "Reader" "$name"
    ensure_role "$sub" "$scope" "$preview_obj" "$WHATIF_ROLE" "$name"
  done
done

# ---- 6. GitHub variables ------------------------------------------------------------------------

addvar() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$WORK/vars"; }

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

addvar "$INFRA_REPO" AZFLOW_TENANT_ID "$TENANT_ID"
addvar "$INFRA_REPO" AZFLOW_PREVIEW_CLIENT_ID "$PREVIEW_APP"
addvar "$WEB_REPO" AZFLOW_TENANT_ID "$TENANT_ID"
addvar "$API_REPO" AZFLOW_TENANT_ID "$TENANT_ID"
if [ -n "${AZFLOW_NAME_SUFFIX:-}" ]; then
  addvar "$INFRA_REPO" AZFLOW_NAME_SUFFIX "$AZFLOW_NAME_SUFFIX"
  addvar "$API_REPO" AZFLOW_NAME_SUFFIX "$AZFLOW_NAME_SUFFIX"
fi
i=0
for st in $ALL_STAGES; do
  u="$(upper "$st")"
  addvar "$INFRA_REPO" "AZFLOW_${u}_SUBSCRIPTION_ID" "${ST_SUB[$i]}"
  addvar "$INFRA_REPO" "AZFLOW_${u}_CLIENT_ID" "${INFRA_APP[$i]}"
  addvar "$INFRA_REPO" "AZFLOW_${u}_API_PRINCIPAL_ID" "${API_OBJ[$i]}"
  addvar "$INFRA_REPO" "AZFLOW_${u}_WEB_PRINCIPAL_ID" "${WEB_OBJ[$i]}"

  addvar "$WEB_REPO" "AZFLOW_${u}_SUBSCRIPTION_ID" "${ST_SUB[$i]}"
  addvar "$WEB_REPO" "AZFLOW_${u}_CLIENT_ID" "${WEB_APP[$i]}"
  addvar "$WEB_REPO" "AZFLOW_${u}_RESOURCE_GROUP" "${ST_RG[$i]}"
  addvar "$WEB_REPO" "AZFLOW_${u}_STATIC_WEB_APP" "${ST_SWA[$i]}"
  addvar "$WEB_REPO" "AZFLOW_${u}_WEB_HOST" "${ST_WEB_HOST[$i]}"
  addvar "$WEB_REPO" "AZFLOW_${u}_API_HOST" "${ST_API_HOST[$i]}"

  addvar "$API_REPO" "AZFLOW_${u}_SUBSCRIPTION_ID" "${ST_SUB[$i]}"
  addvar "$API_REPO" "AZFLOW_${u}_CLIENT_ID" "${API_APP[$i]}"
  addvar "$API_REPO" "AZFLOW_${u}_RESOURCE_GROUP" "${ST_RG[$i]}"
  addvar "$API_REPO" "AZFLOW_${u}_CLUSTER" "${ST_CLUSTER[$i]}"
  addvar "$API_REPO" "AZFLOW_${u}_REGISTRY" "${ST_REGISTRY[$i]}"
  addvar "$API_REPO" "AZFLOW_${u}_API_HOST" "${ST_API_HOST[$i]}"
  i=$((i + 1))
done

print_vars() {
  local repo name value last=""
  while IFS=$'\t' read -r repo name value; do
    if [ "$repo" != "$last" ]; then
      log "  $repo"
      last="$repo"
    fi
    log "    $name=$value"
  done < <(sort -s -t "$(printf '\t')" -k1,1 "$WORK/vars")
}

log
log "6. GitHub repository variables (identifiers only, no secrets)"
if [ "$DRY" -eq 1 ]; then
  plan "write these variables with gh when authenticated, otherwise print them:"
  print_vars
elif [ "$USE_GH" -eq 1 ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  while IFS=$'\t' read -r repo name value; do
    if gh variable set "$name" --body "$value" --repo "$repo" >/dev/null 2>&1; then
      did "variable $name on $repo"
    else
      warn "could not set $name on $repo (does the repo exist and does your gh token allow it?)"
      printf '%s\t%s\t%s\n' "$repo" "$name" "$value" >>"$WORK/unset"
    fi
  done <"$WORK/vars"
  if [ -s "$WORK/unset" ]; then
    log "Set these by hand:"
    mv "$WORK/unset" "$WORK/vars"
    print_vars
  fi
else
  log "gh is not available or not authenticated (or --no-gh): set these variables yourself."
  print_vars
fi

log
if [ "$DRY" -eq 1 ]; then
  log "Dry run complete: nothing was changed."
else
  log "Seed complete. Safe to re-run."
fi
