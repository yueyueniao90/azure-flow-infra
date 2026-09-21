#!/usr/bin/env bash
# Shared helpers for bootstrap/preflight.sh and bootstrap/seed.sh. Source it; do not run it.
# Written for bash 3.2 (the macOS default): no associative arrays, no mapfile.

# shellcheck disable=SC2034  # constants are used by the scripts that source this file

AZFLOW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGES_DIR="${AZFLOW_STAGES_DIR:-$AZFLOW_ROOT/stages}"
ALL_STAGES="staging production"

GH_OWNER="${AZFLOW_GH_OWNER:-yueyueniao90}"
INFRA_REPO="$GH_OWNER/azure-flow-infra"
WEB_REPO="$GH_OWNER/azure-flow-web"
API_REPO="$GH_OWNER/azure-flow-api"

# Resource providers the stages need (all free to register).
REQUIRED_PROVIDERS="Microsoft.Compute Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.Web Microsoft.Network Microsoft.Authorization"

# One node per cluster, fixed in bicep/modules/aks.bicep.
NODE_COUNT=1
MIN_VCPUS=2
MIN_MEM_GIB=4

# VM sizes with >= 2 vCPU and >= 4 GiB, cheapest plausible first. Override with AZFLOW_CANDIDATE_SIZES.
CANDIDATE_SIZES="${AZFLOW_CANDIDATE_SIZES:-Standard_B2s Standard_B2s_v2 Standard_B2as_v2 Standard_B2ls_v2 Standard_B2als_v2 Standard_D2as_v5 Standard_D2ads_v5 Standard_D2s_v3 Standard_D2s_v5 Standard_D2ds_v5}"

# Regions to suggest when a stage region has no usable size.
ALT_REGIONS="${AZFLOW_ALT_REGIONS:-northeurope swedencentral francecentral germanywestcentral uksouth westeurope italynorth polandcentral}"

# Built-in role definition IDs. bicep/modules/*.bicep hold their own copies of the ones they assign;
# tests/test_bicep.sh checks that every role Bicep assigns is allowed by the seed's condition below.
ROLE_CONTRIBUTOR="b24988ac-6180-42a0-ab88-20f7382dd24c"
ROLE_READER="acdd72a7-3385-48ef-bd42-f606fba81ae7"
ROLE_RBAC_ADMIN="f58310d9-a9f6-47eb-a7ab-d5d5a8c0a5dc"
ROLE_ACR_PUSH="8311e382-0749-4cb8-b61a-304f252e45ec"
ROLE_ACR_PULL="7f951dda-4ed3-4680-a7ca-43fe172d538d"
ROLE_AKS_CLUSTER_USER="4abbcc35-e782-43d8-92c5-2d3f1bd2253f"
ROLE_AKS_RBAC_WRITER="a7ffa36f-339b-4b5c-8bdf-e2c188b2c8ac"
ROLE_SWA_CONTRIBUTOR="de139f84-1756-47ae-9be6-808fbbe84772"
ROLE_DNS_ZONE_CONTRIBUTOR="befefa01-2a29-4197-83a8-272ff33ce314"

log() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not on PATH. $2"
}

stage_file() { printf '%s/%s.json' "$STAGES_DIR" "$1"; }

# stage_get <stage> <jq path, e.g. .location>; prints the value or nothing.
stage_get() {
  jq -r "$2 // empty" "$(stage_file "$1")"
}

# resolve_ref <value>: expands a whole-value environment reference ($NAME or ${NAME}) at run time.
# Plain values pass through. Prints nothing and returns 1 when the variable is unset or empty.
resolve_ref() {
  local v="$1" name
  if [[ "$v" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
    name="${BASH_REMATCH[1]}"
    v="${!name:-}"
    [ -n "$v" ] || return 1
  fi
  printf '%s' "$v"
}

# The registry name is globally unique in Azure: an optional suffix keeps it collision-free.
registry_name() {
  printf '%s%s' "$(stage_get "$1" .registry)" "${AZFLOW_NAME_SUFFIX:-}"
}

# validate_stage <stage>: schema and naming checks; prints problems and returns 1 if any.
validate_stage() {
  local stage="$1" f key val bad=0
  f="$(stage_file "$stage")"
  [ -f "$f" ] || {
    printf '%s: missing\n' "$f"
    return 1
  }
  jq -e . "$f" >/dev/null 2>&1 || {
    printf '%s: not valid JSON\n' "$f"
    return 1
  }
  for key in stage subscriptionId location resourceGroup cluster registry staticWebApp staticWebAppLocation nodeSize webHost apiHost \
    shared.subscriptionId shared.resourceGroup shared.location shared.dnsZone; do
    val="$(jq -r ".${key} // empty" "$f")"
    if [ -z "$val" ]; then
      printf '%s: missing "%s"\n' "$f" "$key"
      bad=1
    fi
  done
  [ "$(stage_get "$stage" .stage)" = "$stage" ] || {
    printf '%s: "stage" must be "%s"\n' "$f" "$stage"
    bad=1
  }
  [[ "$(registry_name "$stage")" =~ ^[a-z0-9]{5,50}$ ]] || {
    printf '%s: registry name "%s" must be 5-50 lowercase letters and digits\n' "$f" "$(registry_name "$stage")"
    bad=1
  }
  [[ "$(stage_get "$stage" .cluster)" =~ ^[a-zA-Z0-9]([a-zA-Z0-9_-]{0,61}[a-zA-Z0-9])?$ ]] || {
    printf '%s: cluster name is not a valid AKS name\n' "$f"
    bad=1
  }
  [ "$bad" -eq 0 ]
}

# Registered Entra app display name for a role ("infra", "web", "api") in a stage, or "infra-preview".
identity_name() { printf 'azflow-%s-%s' "$1" "$2"; }

# validate_distinct: the stages must not share resource names, and must agree on the shared group.
validate_distinct() {
  local key a b bad=0 stage_a stage_b
  stage_a="$(printf '%s' "$ALL_STAGES" | cut -d' ' -f1)"
  stage_b="$(printf '%s' "$ALL_STAGES" | cut -d' ' -f2)"
  for key in resourceGroup cluster registry staticWebApp webHost apiHost; do
    a="$(stage_get "$stage_a" ".$key")"
    b="$(stage_get "$stage_b" ".$key")"
    if [ "$a" = "$b" ]; then
      printf '"%s" is "%s" in both stages; stages must use different names\n' "$key" "$a"
      bad=1
    fi
  done
  for key in shared.resourceGroup shared.location shared.dnsZone; do
    a="$(stage_get "$stage_a" ".$key")"
    b="$(stage_get "$stage_b" ".$key")"
    if [ "$a" != "$b" ]; then
      printf '"%s" differs between stages ("%s" vs "%s"); the shared group is one place\n' "$key" "$a" "$b"
      bad=1
    fi
  done
  # Compare the resolved subscriptions (two references may name the same one); an unset reference compares as written.
  a="$(stage_get "$stage_a" .shared.subscriptionId)"
  b="$(stage_get "$stage_b" .shared.subscriptionId)"
  a="$(resolve_ref "$a" || printf '%s' "$a")"
  b="$(resolve_ref "$b" || printf '%s' "$b")"
  if [ "$a" != "$b" ]; then
    printf '"shared.subscriptionId" differs between stages ("%s" vs "%s"); the shared group is one place\n' "$a" "$b"
    bad=1
  fi
  [ "$bad" -eq 0 ]
}
