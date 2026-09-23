#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail` is intended; single quotes hold literal $VARS
# Bicep: build, lint, and invariants that keep the demo free, keyless and least-privilege.
# Needs the `bicep` CLI (or `az bicep`); neither talks to a subscription.
set -euo pipefail
# shellcheck source=tests/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=bootstrap/lib.sh
. "$REPO_ROOT/bootstrap/lib.sh"

# bicep_cli <build|build-params|lint> <file> [extra flags, e.g. --stdout]
# The standalone CLI takes the file positionally; `az bicep` requires --file.
if command -v bicep >/dev/null 2>&1; then
  bicep_cli() {
    local cmd="$1" file="$2"
    shift 2
    bicep "$cmd" "$file" "$@"
  }
elif command -v az >/dev/null 2>&1 && az bicep version >/dev/null 2>&1; then
  bicep_cli() {
    local cmd="$1" file="$2"
    shift 2
    az bicep "$cmd" --file "$file" "$@"
  }
else
  if [ "${AZFLOW_SKIP_BICEP:-0}" = 1 ]; then
    echo "SKIPPED: bicep not available (AZFLOW_SKIP_BICEP=1)"
    exit 0
  fi
  echo "bicep CLI not found. Install it (https://aka.ms/bicep-install, or: az bicep install) or set AZFLOW_SKIP_BICEP=1." >&2
  exit 1
fi

cd "$REPO_ROOT/bicep"
unset AZFLOW_NAME_SUFFIX AZFLOW_SUBSCRIPTION_ID AZFLOW_API_PRINCIPAL_ID AZFLOW_WEB_PRINCIPAL_ID || true

section "build and lint (warnings count as failures)"
for f in main.bicep modules/*.bicep; do
  out="$(bicep_cli lint "$f" 2>&1 || true)"
  assert_eq "lint $f" "" "$out"
done
template="$(bicep_cli build main.bicep --stdout 2>&1)" && pass || fail "main.bicep does not build: $template"
for st in staging production; do
  out="$(bicep_cli build-params "$st.bicepparam" --stdout 2>&1)" && pass || fail "$st.bicepparam does not build: $out"
done

section "stage entry points read the stage files"
params() { bicep_cli build-params "$1.bicepparam" --stdout | jq -r '.parametersJson | fromjson | .parameters'; }
for st in staging production; do
  p="$(params "$st")"
  assert_eq "$st cluster" "$(stage_get "$st" .cluster)" "$(printf '%s' "$p" | jq -r .clusterName.value)"
  assert_eq "$st registry" "$(stage_get "$st" .registry)" "$(printf '%s' "$p" | jq -r .registryName.value)"
  assert_eq "$st swa" "$(stage_get "$st" .staticWebApp)" "$(printf '%s' "$p" | jq -r .staticWebAppName.value)"
  assert_eq "$st location" "$(stage_get "$st" .location)" "$(printf '%s' "$p" | jq -r .location.value)"
  assert_eq "$st node size" "$(stage_get "$st" .nodeSize)" "$(printf '%s' "$p" | jq -r .nodeSize.value)"
  assert_eq "$st dns zone" "$(stage_get "$st" .shared.dnsZone)" "$(printf '%s' "$p" | jq -r .dnsZoneName.value)"
  assert_eq "$st shared rg" "$(stage_get "$st" .shared.resourceGroup)" "$(printf '%s' "$p" | jq -r .sharedResourceGroup.value)"
  assert_eq "$st web host" "$(stage_get "$st" .webHost)" "$(printf '%s' "$p" | jq -r .webHost.value)"
  case "$(stage_get "$st" .staticWebAppLocation)" in
    westeurope | centralus | eastus2 | eastasia | westus2) pass ;;
    *) fail "$st staticWebAppLocation is not a Static Web Apps region" ;;
  esac
done
assert_eq "registry suffix applied" "acrazflowstagingxy7" "$(AZFLOW_NAME_SUFFIX=xy7 bicep_cli build-params staging.bicepparam --stdout | jq -r '.parametersJson | fromjson | .parameters.registryName.value')"
sub_of() { bicep_cli build-params "$1" --stdout | jq -r '.parametersJson | fromjson | .parameters.sharedSubscriptionId.value'; }
assert_eq "shared subscription comes from the stage file reference" "sub-shared" "$(AZFLOW_SUBSCRIPTION_ID=sub-shared sub_of staging.bicepparam)"
assert_eq "unset shared subscription reference stays empty" "" "$(sub_of staging.bicepparam)"
split="$(mktemp -d)"
cp -R "$REPO_ROOT/bicep" "$REPO_ROOT/stages" "$split/"
jq '.subscriptionId = "$AZFLOW_PROD_SUBSCRIPTION_ID" | .shared.subscriptionId = "${AZFLOW_SHARED_SUBSCRIPTION_ID}"' "$split/stages/production.json" >"$split/p.json" && mv "$split/p.json" "$split/stages/production.json"
assert_eq "split subscriptions: shared value follows the stage file" "sub-shared" \
  "$(cd "$split/bicep" && AZFLOW_SUBSCRIPTION_ID=sub-prod AZFLOW_PROD_SUBSCRIPTION_ID=sub-prod AZFLOW_SHARED_SUBSCRIPTION_ID=sub-shared sub_of production.bicepparam)"
jq '.shared.subscriptionId = "00000000-plain"' "$split/stages/production.json" >"$split/p.json" && mv "$split/p.json" "$split/stages/production.json"
assert_eq "a plain shared subscription value passes through" "00000000-plain" "$(cd "$split/bicep" && AZFLOW_SUBSCRIPTION_ID=sub-prod sub_of production.bicepparam)"
rm -rf "$split"
assert_eq "principal ids come from the environment" "11111111-1111-1111-1111-111111111111" \
  "$(AZFLOW_API_PRINCIPAL_ID=11111111-1111-1111-1111-111111111111 bicep_cli build-params staging.bicepparam --stdout | jq -r '.parametersJson | fromjson | .parameters.apiPrincipalId.value')"

section "cost and security invariants of the compiled template"
# Nested module templates are inlined; flatten every resource declaration.
res="$(printf '%s' "$template" | jq -c '[.. | objects | select(has("type") and has("apiVersion")) | select(.type != "Microsoft.Resources/deployments")]')"
q() { printf '%s' "$res" | jq -r "$1"; }
types="$(q '[.[].type] | unique | .[]')"
for t in Microsoft.ContainerRegistry/registries Microsoft.ContainerService/managedClusters Microsoft.Web/staticSites Microsoft.Web/staticSites/customDomains Microsoft.Network/dnsZones Microsoft.Authorization/roleAssignments; do
  assert_contains "declares $t" "$types" "$t"
done
for t in Microsoft.KeyVault Microsoft.OperationalInsights Microsoft.Insights Microsoft.Monitor Microsoft.Compute Microsoft.Network/publicIPAddresses Microsoft.Network/loadBalancers Microsoft.Authorization/roleDefinitions; do
  assert_not_contains "does not declare $t" "$types" "$t"
done
assert_eq "AKS free control plane" "Free" "$(q '.[] | select(.type == "Microsoft.ContainerService/managedClusters") | .sku.tier')"
assert_eq "AKS has exactly one pool" 1 "$(q '.[] | select(.type == "Microsoft.ContainerService/managedClusters") | .properties.agentPoolProfiles | length')"
assert_eq "AKS single node" 1 "$(grep -c '^var nodeCount = 1$' modules/aks.bicep)"
assert_eq "AKS no autoscaler" false "$(q '.[] | select(.type == "Microsoft.ContainerService/managedClusters") | .properties.agentPoolProfiles[0].enableAutoScaling')"
assert_eq "AKS no add-ons (no monitoring)" null "$(q '.[] | select(.type == "Microsoft.ContainerService/managedClusters") | .properties.addonProfiles')"
assert_eq "AKS app routing add-on" true "$(q '.[] | select(.type == "Microsoft.ContainerService/managedClusters") | .properties.ingressProfile.webAppRouting.enabled')"
assert_eq "AKS local accounts disabled" true "$(q '.[] | select(.type == "Microsoft.ContainerService/managedClusters") | .properties.disableLocalAccounts')"
assert_eq "AKS Azure RBAC" true "$(q '.[] | select(.type == "Microsoft.ContainerService/managedClusters") | .properties.aadProfile.enableAzureRBAC')"
assert_eq "AKS node size is a parameter" "[parameters('nodeSize')]" "$(q '.[] | select(.type == "Microsoft.ContainerService/managedClusters") | .properties.agentPoolProfiles[0].vmSize')"
assert_eq "registry is Basic" Basic "$(q '.[] | select(.type == "Microsoft.ContainerRegistry/registries") | .sku.name')"
assert_eq "registry admin user off" false "$(q '.[] | select(.type == "Microsoft.ContainerRegistry/registries") | .properties.adminUserEnabled')"
assert_eq "static web app is Free" Free "$(q '.[] | select(.type == "Microsoft.Web/staticSites") | .sku.name')"
assert_eq "custom domain binding uses dns-txt-token (no CNAME cutover required)" "dns-txt-token" \
  "$(q '.[] | select(.type == "Microsoft.Web/staticSites/customDomains") | .properties.validationMethod')"
assert_eq "custom domain name comes from the webHost parameter" "[format('{0}/{1}', parameters('name'), parameters('customDomain'))]" \
  "$(q '.[] | select(.type == "Microsoft.Web/staticSites/customDomains") | .name')"

section "role ids are the exact Azure built-in GUIDs"
# A shape check cannot catch a typo: a well-formed but wrong GUID fails deployment with RoleDefinitionDoesNotExist.
# Values from `az role definition list --name "<role name>"`.
assert_eq "AcrPush" "8311e382-0749-4cb8-b61a-304f252e45ec" "$ROLE_ACR_PUSH"
assert_eq "AcrPull" "7f951dda-4ed3-4680-a7ca-43fe172d538d" "$ROLE_ACR_PULL"
assert_eq "Azure Kubernetes Service Cluster User Role" "4abbcc35-e782-43d8-92c5-2d3f1bd2253f" "$ROLE_AKS_CLUSTER_USER"
assert_eq "Azure Kubernetes Service RBAC Writer" "a7ffa36f-339b-4b5c-8bdf-e2c188b2c0eb" "$ROLE_AKS_RBAC_WRITER"
assert_eq "Contributor" "b24988ac-6180-42a0-ab88-20f7382dd24c" "$ROLE_CONTRIBUTOR"
assert_eq "DNS Zone Contributor" "befefa01-2a29-4197-83a8-272ff33ce314" "$ROLE_DNS_ZONE_CONTRIBUTOR"
for v in acrPushRoleId:ROLE_ACR_PUSH acrPullRoleId:ROLE_ACR_PULL clusterUserRoleId:ROLE_AKS_CLUSTER_USER \
  rbacWriterRoleId:ROLE_AKS_RBAC_WRITER contributorRoleId:ROLE_CONTRIBUTOR dnsZoneContributorRoleId:ROLE_DNS_ZONE_CONTRIBUTOR; do
  bicep_id="$(grep -hoE "var ${v%%:*} = '[0-9a-f-]{36}'" modules/*.bicep | grep -oE "[0-9a-f-]{36}")"
  lib_var="${v#*:}"
  lib_id="${!lib_var}"
  assert_eq "bicep ${v%%:*} matches lib.sh ${v#*:}" "$lib_id" "$bicep_id"
done

section "role assignments are narrow and covered by the seed's RBAC condition"
assigned="$(grep -hoE "RoleId = '[0-9a-f-]{36}'" modules/*.bicep | grep -oE "[0-9a-f-]{36}" | sort -u)"
[ -n "$assigned" ] && pass || fail "no role ids found in modules"
for id in $assigned; do
  case "$id" in
    "$ROLE_ACR_PUSH" | "$ROLE_ACR_PULL" | "$ROLE_AKS_CLUSTER_USER" | "$ROLE_AKS_RBAC_WRITER" | "$ROLE_CONTRIBUTOR" | "$ROLE_DNS_ZONE_CONTRIBUTOR") pass ;;
    *) fail "Bicep assigns role $id that the seed's RBAC condition does not allow" ;;
  esac
done
assert_eq "no Owner/RBAC admin assigned by Bicep" 0 \
  "$(printf '%s\n' "$assigned" | grep -cE "$ROLE_RBAC_ADMIN|8e3af657-a8ff-443c-a75c-2fe8c4bcb635" || true)"
contributor_scopes="$(printf '%s' "$template" | jq -r --arg id "$ROLE_CONTRIBUTOR" '
  ([.. | objects | select(has("variables")) | .variables | select(type == "object")] | add // {}) as $vars
  | [$vars | to_entries[] | select(.value == $id) | "variables('"'"'" + .key + "'"'"')"] as $refs
  | [.. | objects | select(.type? == "Microsoft.Authorization/roleAssignments")
      | select(.properties.roleDefinitionId as $r | ($r | contains($id)) or ($refs | any(. as $x | $r | contains($x))))
      | .scope] | .[]')"
assert_eq "Contributor is assigned exactly once" 1 "$(printf '%s\n' "$contributor_scopes" | grep -c .)"
assert_contains "Contributor is scoped to the Static Web App resource" "$contributor_scopes" "Microsoft.Web/staticSites'"
assert_eq "role assignments all target service principals" 0 \
  "$(q '[.[] | select(.type == "Microsoft.Authorization/roleAssignments") | select(.properties.principalType != "ServicePrincipal")] | length')"
assert_eq "role assignments are scoped to a resource" 0 \
  "$(q '[.[] | select(.type == "Microsoft.Authorization/roleAssignments") | select((.scope // "") == "")] | length')"
condition_ids="$(AZFLOW_SUBSCRIPTION_ID=s "$REPO_ROOT/bootstrap/seed.sh" --dry-run | grep 'azflow-infra-staging on .*rg-azflow-staging, limited')"
for id in $assigned; do assert_contains "seed condition for stage rg allows $id" "$condition_ids" "$id"; done

finish "bicep"
