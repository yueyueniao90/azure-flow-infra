#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail` is intended; single quotes hold literal $VARS
# bootstrap/seed.sh against a fake `az` and `gh`: dry run, first run, idempotent re-run, least privilege.
set -euo pipefail
# shellcheck source=tests/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=bootstrap/lib.sh
. "$REPO_ROOT/bootstrap/lib.sh"

SEED="$REPO_ROOT/bootstrap/seed.sh"
export AZFLOW_SUBSCRIPTION_ID="sub-test"
export AZFLOW_RETRY_SLEEP=0
unset AZFLOW_NAME_SUFFIX || true

run_seed() { # sets OUT and RC
  set +e
  OUT="$(with_fakes "$SEED" "$@" 2>&1)"
  RC=$?
  set -e
}

section "--dry-run: prints every action, never calls az or gh"
new_state
run_seed --dry-run
assert_eq "exit code" 0 "$RC"
[ ! -e "$FAKE_AZ_STATE/calls.log" ] && pass || fail "dry run called az"
[ ! -e "$FAKE_AZ_STATE/gh-calls.log" ] && pass || fail "dry run called gh"
for want in "resource provider Microsoft.Compute" "resource group rg-azflow-staging" "resource group rg-azflow-prod" \
  "resource group rg-azflow-shared" "azflow-infra-staging" "azflow-infra-production" "azflow-web-staging" "azflow-web-production" \
  "azflow-api-staging" "azflow-api-production" "azflow-infra-preview" \
  "environment:staging" "environment:production" "repo:yueyueniao90/azure-flow-infra:pull_request" \
  "repo:yueyueniao90/azure-flow-web:ref:refs/heads/main" "repo:yueyueniao90/azure-flow-api:ref:refs/heads/main" \
  "Role Based Access Control Administrator" "azflow-deployment-whatif" "AZFLOW_STAGING_CLIENT_ID"; do
  assert_contains "dry run mentions $want" "$OUT" "$want"
done
assert_contains "dry run says nothing changed" "$OUT" "nothing was changed"
new_state
unset AZFLOW_SUBSCRIPTION_ID
run_seed --dry-run
assert_eq "dry run works without the subscription variable" 0 "$RC"
run_seed
assert_eq "real run without the subscription variable" 2 "$RC"
assert_contains "real run explains the variable" "$OUT" "AZFLOW_SUBSCRIPTION_ID"
export AZFLOW_SUBSCRIPTION_ID="sub-test"

section "--providers-only"
new_state
rm -f "$FAKE_AZ_STATE"/provider.*
run_seed --providers-only
assert_eq "exit code" 0 "$RC"
for ns in $REQUIRED_PROVIDERS; do assert_eq "$ns registered" Registered "$(cat "$FAKE_AZ_STATE/provider.$ns")"; done
assert_count "no groups created" 0 "$FAKE_AZ_STATE/calls.log" "group create"

section "first run"
new_state
rm -f "$FAKE_AZ_STATE"/provider.*
run_seed
assert_eq "exit code" 0 "$RC"
calls="$FAKE_AZ_STATE/calls.log"
assert_contains "finished" "$OUT" "Seed complete"
for rg in rg-azflow-staging rg-azflow-prod rg-azflow-shared; do
  [ -e "$FAKE_AZ_STATE/rg.$rg" ] && pass || fail "resource group $rg not created"
done
assert_count "seven app registrations (six stage identities + preview)" 7 "$calls" "ad app create"
assert_count "seven service principals" 7 "$calls" "ad sp create"
assert_count "seven federated credentials" 7 "$calls" "federated-credential create"
assert_eq "infra staging subject" "repo:yueyueniao90/azure-flow-infra:environment:staging" "$(cat "$FAKE_AZ_STATE/fedcred.app-azflow-infra-staging.github-environment-staging")"
assert_eq "infra production subject" "repo:yueyueniao90/azure-flow-infra:environment:production" "$(cat "$FAKE_AZ_STATE/fedcred.app-azflow-infra-production.github-environment-production")"
assert_eq "preview subject" "repo:yueyueniao90/azure-flow-infra:pull_request" "$(cat "$FAKE_AZ_STATE/fedcred.app-azflow-infra-preview.github-pull-request")"
for st in staging production; do
  assert_eq "web $st subject" "repo:yueyueniao90/azure-flow-web:ref:refs/heads/main" "$(cat "$FAKE_AZ_STATE/fedcred.app-azflow-web-$st.github-main")"
  assert_eq "api $st subject" "repo:yueyueniao90/azure-flow-api:ref:refs/heads/main" "$(cat "$FAKE_AZ_STATE/fedcred.app-azflow-api-$st.github-main")"
done

section "no secrets, no passwords, no long-lived credentials"
assert_not_contains "no credential reset" "$(cat "$calls")" "credential reset"
assert_not_contains "no --create-password" "$(cat "$calls")" "password"
assert_not_contains "no secret" "$(cat "$calls")" "secret"
assert_not_contains "no --years" "$(cat "$calls")" "--years"

section "least privilege: each identity only on its own stage's group"
roles="$FAKE_AZ_STATE/roles.jsonl"
S="/subscriptions/sub-test/resourceGroups"
has_role() { # <who> <role> <scope> -> count
  jq -s --arg o "obj-azflow-$1" --arg r "$2" --arg s "$3" '[.[] | select(.principalId == $o and .roleDefinitionName == $r and .scope == $s)] | length' "$roles"
}
scopes_of() { jq -s -r --arg o "obj-azflow-$1" '[.[] | select(.principalId == $o) | .scope] | unique | .[]' "$roles"; }
assert_eq "infra-staging Contributor on staging rg" 1 "$(has_role infra-staging Contributor "$S/rg-azflow-staging")"
assert_eq "infra-staging RBAC admin on staging rg" 1 "$(has_role infra-staging 'Role Based Access Control Administrator' "$S/rg-azflow-staging")"
assert_eq "infra-staging Contributor on shared rg" 1 "$(has_role infra-staging Contributor "$S/rg-azflow-shared")"
assert_eq "infra-production Contributor on prod rg" 1 "$(has_role infra-production Contributor "$S/rg-azflow-prod")"
assert_eq "infra-staging scopes" "$(printf '%s\n%s' "$S/rg-azflow-shared" "$S/rg-azflow-staging")" "$(scopes_of infra-staging)"
assert_eq "infra-production scopes" "$(printf '%s\n%s' "$S/rg-azflow-prod" "$S/rg-azflow-shared")" "$(scopes_of infra-production)"
for kind in web api; do
  assert_eq "$kind-staging only on staging rg" "$S/rg-azflow-staging" "$(scopes_of "$kind-staging")"
  assert_eq "$kind-production only on prod rg" "$S/rg-azflow-prod" "$(scopes_of "$kind-production")"
  assert_eq "$kind-staging is Reader" 1 "$(has_role "$kind-staging" Reader "$S/rg-azflow-staging")"
done
assert_eq "preview Reader on staging" 1 "$(has_role infra-preview Reader "$S/rg-azflow-staging")"
assert_eq "preview what-if on prod" 1 "$(has_role infra-preview azflow-deployment-whatif "$S/rg-azflow-prod")"
assert_eq "preview has no write role" 0 "$(jq -s '[.[] | select(.principalId == "obj-azflow-infra-preview" and (.roleDefinitionName == "Contributor" or .roleDefinitionName == "Owner"))] | length' "$roles")"
assert_eq "nobody is Owner" 0 "$(jq -s '[.[] | select(.roleDefinitionName == "Owner" or .roleDefinitionName == "User Access Administrator")] | length' "$roles")"
assert_eq "no assignment at subscription scope" 0 "$(jq -s '[.[] | select(.scope | test("^/subscriptions/[^/]+$"))] | length' "$roles")"
assert_file_contains "what-if role defined" "$FAKE_AZ_STATE/roledef.azflow-deployment-whatif" "Microsoft.Resources/deployments/whatIf/action"
assert_eq "what-if role has no write actions" 0 "$(jq '[.Actions[] | select(test("write|delete"))] | length' "$FAKE_AZ_STATE/roledef.azflow-deployment-whatif")"

section "RBAC Administrator is conditioned to the roles Bicep assigns"
cond="$(jq -s -r '[.[] | select(.principalId == "obj-azflow-infra-staging" and .roleDefinitionName == "Role Based Access Control Administrator" and .scope == "'"$S"'/rg-azflow-staging")][0].condition' "$roles")"
for id in "$ROLE_ACR_PUSH" "$ROLE_ACR_PULL" "$ROLE_AKS_CLUSTER_USER" "$ROLE_AKS_RBAC_WRITER" "$ROLE_CONTRIBUTOR" "$ROLE_DNS_ZONE_CONTRIBUTOR"; do
  assert_contains "condition allows $id" "$cond" "$id"
done
for id in "$ROLE_RBAC_ADMIN" "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9" "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"; do
  assert_not_contains "condition does not allow $id" "$cond" "$id"
done
assert_contains "condition guards writes" "$cond" "roleAssignments/write"
assert_contains "condition guards deletes" "$cond" "roleAssignments/delete"
# Azure ABAC requires the ActionMatches{...} action name to be a single-quoted string literal
# (learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-examples); an
# unquoted action name is what actually broke the captain's real seed.sh run.
assert_contains "condition quotes the write ActionMatches action" "$cond" "ActionMatches{'Microsoft.Authorization/roleAssignments/write'}"
assert_contains "condition quotes the delete ActionMatches action" "$cond" "ActionMatches{'Microsoft.Authorization/roleAssignments/delete'}"
shared_cond="$(jq -s -r '[.[] | select(.principalId == "obj-azflow-infra-staging" and .roleDefinitionName == "Role Based Access Control Administrator" and .scope == "'"$S"'/rg-azflow-shared")][0].condition' "$roles")"
assert_contains "shared rg allows DNS Zone Contributor" "$shared_cond" "$ROLE_DNS_ZONE_CONTRIBUTOR"
assert_not_contains "shared rg does not allow AcrPush" "$shared_cond" "$ROLE_ACR_PUSH"
assert_not_contains "shared rg does not allow Contributor" "$shared_cond" "$ROLE_CONTRIBUTOR"
assert_contains "shared rg condition also quotes ActionMatches" "$shared_cond" "ActionMatches{'Microsoft.Authorization/roleAssignments/write'}"

section "GitHub variables"
vars="$FAKE_AZ_STATE/gh-vars.log"
assert_file_contains "infra tenant" "$vars" "yueyueniao90/azure-flow-infra	AZFLOW_TENANT_ID	tenant-fake"
assert_file_contains "infra staging client" "$vars" "yueyueniao90/azure-flow-infra	AZFLOW_STAGING_CLIENT_ID	app-azflow-infra-staging"
assert_file_contains "infra staging api principal" "$vars" "yueyueniao90/azure-flow-infra	AZFLOW_STAGING_API_PRINCIPAL_ID	obj-azflow-api-staging"
assert_file_contains "infra production web principal" "$vars" "yueyueniao90/azure-flow-infra	AZFLOW_PRODUCTION_WEB_PRINCIPAL_ID	obj-azflow-web-production"
assert_file_contains "preview client" "$vars" "yueyueniao90/azure-flow-infra	AZFLOW_PREVIEW_CLIENT_ID	app-azflow-infra-preview"
assert_file_contains "web client" "$vars" "yueyueniao90/azure-flow-web	AZFLOW_STAGING_CLIENT_ID	app-azflow-web-staging"
assert_file_contains "api client" "$vars" "yueyueniao90/azure-flow-api	AZFLOW_PRODUCTION_CLIENT_ID	app-azflow-api-production"
assert_file_contains "api registry" "$vars" "yueyueniao90/azure-flow-api	AZFLOW_PRODUCTION_REGISTRY	acrazflowprod"
assert_file_contains "subscription id" "$vars" "AZFLOW_STAGING_SUBSCRIPTION_ID	sub-test"
assert_not_contains "no gh secret calls" "$(cat "$FAKE_AZ_STATE/gh-calls.log")" "secret"

section "second run changes nothing"
: >"$calls"
: >"$FAKE_AZ_STATE/gh-calls.log"
run_seed
assert_eq "exit code" 0 "$RC"
for verb in "provider register" "group create" "ad app create" "ad sp create" "federated-credential create" "federated-credential update" \
  "role assignment create" "role assignment delete"; do
  assert_count "second run: no '$verb'" 0 "$calls" "$verb"
done
assert_contains "reports existing" "$OUT" "already there"

section "changed RBAC condition is replaced, not duplicated"
new_state
run_seed
jq -c 'if .roleDefinitionName == "Role Based Access Control Administrator" then .condition = "old-condition" else . end' "$FAKE_AZ_STATE/roles.jsonl" >"$FAKE_AZ_STATE/r.tmp"
mv "$FAKE_AZ_STATE/r.tmp" "$FAKE_AZ_STATE/roles.jsonl"
run_seed
assert_eq "exit code" 0 "$RC"
assert_eq "no stale condition left" 0 "$(jq -s '[.[] | select(.condition == "old-condition")] | length' "$FAKE_AZ_STATE/roles.jsonl")"
assert_eq "assignment count unchanged" 1 "$(jq -s '[.[] | select(.principalId == "obj-azflow-infra-staging" and .roleDefinitionName == "Role Based Access Control Administrator" and (.scope | endswith("staging")))] | length' "$FAKE_AZ_STATE/roles.jsonl")"

section "federated credential with a wrong subject is corrected"
printf 'repo:someone/else:ref:refs/heads/main' >"$FAKE_AZ_STATE/fedcred.app-azflow-api-staging.github-main"
run_seed
assert_eq "subject fixed" "repo:yueyueniao90/azure-flow-api:ref:refs/heads/main" "$(cat "$FAKE_AZ_STATE/fedcred.app-azflow-api-staging.github-main")"
assert_contains "reports the update" "$OUT" "updated federated credential github-main"

section "role assignment retries while Entra catches up"
new_state
echo 3 >"$FAKE_AZ_STATE/role-create-fail-first"
run_seed
assert_eq "exit code after transient failures" 0 "$RC"
assert_contains "warned about retry" "$OUT" "waiting for Entra"

section "an invalid role condition is a permanent failure, not retried like a propagation delay"
new_state
touch "$FAKE_AZ_STATE/role-create-always-invalid-condition"
run_seed
assert_eq "exit code" 2 "$RC"
assert_contains "reports the real Azure error" "$OUT" "InvalidCreateOrUpdateRoleAssignmentRequest"
assert_contains "explains it is not retrying" "$OUT" "not retrying"
assert_not_contains "never treated as Entra propagation lag" "$OUT" "waiting for Entra"
assert_count "only one create attempt, not six" 1 "$FAKE_AZ_STATE/calls.log" \
  "role assignment create --assignee-object-id obj-azflow-infra-staging --assignee-principal-type ServicePrincipal --role Role Based Access Control Administrator --scope $S/rg-azflow-staging"

section "gh unavailable: variables are printed, nothing fails"
new_state
: >"$FAKE_AZ_STATE/gh-not-authenticated"
run_seed
assert_eq "exit code" 0 "$RC"
assert_contains "printed" "$OUT" "AZFLOW_STAGING_CLIENT_ID=app-azflow-infra-staging"
[ ! -e "$FAKE_AZ_STATE/gh-vars.log" ] && pass || fail "gh variables written without authentication"
new_state
run_seed --no-gh
assert_contains "--no-gh prints" "$OUT" "AZFLOW_TENANT_ID=tenant-fake"
[ ! -e "$FAKE_AZ_STATE/gh-vars.log" ] && pass || fail "--no-gh wrote variables"
new_state
echo "yueyueniao90/azure-flow-web" >"$FAKE_AZ_STATE/gh-fail-repo"
run_seed
assert_eq "one repo failing is not fatal" 0 "$RC"
assert_contains "asks to set by hand" "$OUT" "Set these by hand"
assert_file_contains "other repos still written" "$FAKE_AZ_STATE/gh-vars.log" "yueyueniao90/azure-flow-api"

section "name suffix reaches the api repo variables"
new_state
AZFLOW_NAME_SUFFIX=ab1 run_seed
assert_file_contains "suffixed registry variable" "$FAKE_AZ_STATE/gh-vars.log" "AZFLOW_STAGING_REGISTRY	acrazflowstagingab1"

section "not signed in"
new_state
: >"$FAKE_AZ_STATE/not-logged-in"
run_seed
assert_eq "exit code" 2 "$RC"
assert_contains "login hint" "$OUT" "az login"

section "separate subscription per stage"
new_state
tmp="$(mktemp -d)"
cp "$REPO_ROOT"/stages/*.json "$tmp/"
jq '.subscriptionId = "$AZFLOW_PROD_SUBSCRIPTION_ID"' "$tmp/production.json" >"$tmp/p.json" && mv "$tmp/p.json" "$tmp/production.json"
AZFLOW_STAGES_DIR="$tmp" AZFLOW_PROD_SUBSCRIPTION_ID="sub-prod" run_seed
assert_eq "exit code" 0 "$RC"
assert_file_contains "prod group in prod subscription" "$FAKE_AZ_STATE/calls.log" "group create --name rg-azflow-prod --location westeurope --subscription sub-prod"
assert_file_contains "staging group in staging subscription" "$FAKE_AZ_STATE/calls.log" "group create --name rg-azflow-staging --location westeurope --subscription sub-test"
assert_file_contains "prod scope uses prod subscription" "$FAKE_AZ_STATE/roles.jsonl" '"scope":"/subscriptions/sub-prod/resourceGroups/rg-azflow-prod"'
assert_file_contains "prod variable" "$FAKE_AZ_STATE/gh-vars.log" "AZFLOW_PRODUCTION_SUBSCRIPTION_ID	sub-prod"
rm -rf "$tmp"

section "shared group in its own subscription"
new_state
tmp="$(mktemp -d)"
cp "$REPO_ROOT"/stages/*.json "$tmp/"
for st in staging production; do
  jq '.shared.subscriptionId = "$AZFLOW_SHARED_SUBSCRIPTION_ID"' "$tmp/$st.json" >"$tmp/x.json" && mv "$tmp/x.json" "$tmp/$st.json"
done
AZFLOW_STAGES_DIR="$tmp" AZFLOW_SHARED_SUBSCRIPTION_ID="sub-shared" run_seed
assert_eq "exit code" 0 "$RC"
assert_file_contains "shared group in shared subscription" "$FAKE_AZ_STATE/calls.log" "group create --name rg-azflow-shared --location westeurope --subscription sub-shared"
assert_file_contains "shared scope uses the shared subscription" "$FAKE_AZ_STATE/roles.jsonl" '"scope":"/subscriptions/sub-shared/resourceGroups/rg-azflow-shared"'
assert_not_contains "no role on the shared group in the stage subscription" "$(cat "$FAKE_AZ_STATE/roles.jsonl")" '/subscriptions/sub-test/resourceGroups/rg-azflow-shared'
assert_count "what-if role is defined once for the tenant" 1 "$FAKE_AZ_STATE/calls.log" "role definition create"
assert_eq "what-if role is assignable in both subscriptions" "sub-shared sub-test" \
  "$(jq -r '[.AssignableScopes[] | split("/")[2]] | unique | join(" ")' "$FAKE_AZ_STATE/roledef.azflow-deployment-whatif")"
assert_eq "preview what-if on the shared group" 1 \
  "$(jq -s '[.[] | select(.principalId == "obj-azflow-infra-preview" and .roleDefinitionName == "azflow-deployment-whatif" and .scope == "/subscriptions/sub-shared/resourceGroups/rg-azflow-shared")] | length' "$FAKE_AZ_STATE/roles.jsonl")"
AZFLOW_STAGES_DIR="$tmp" AZFLOW_SHARED_SUBSCRIPTION_ID="sub-shared" run_seed
assert_eq "second run exit code" 0 "$RC"
assert_count "second run does not create the what-if role again" 1 "$FAKE_AZ_STATE/calls.log" "role definition create"
rm -rf "$tmp"

section "stage files that disagree on the shared subscription"
new_state
tmp="$(mktemp -d)"
cp "$REPO_ROOT"/stages/*.json "$tmp/"
jq '.shared.subscriptionId = "$AZFLOW_SHARED_SUBSCRIPTION_ID"' "$tmp/production.json" >"$tmp/x.json" && mv "$tmp/x.json" "$tmp/production.json"
AZFLOW_STAGES_DIR="$tmp" AZFLOW_SHARED_SUBSCRIPTION_ID="sub-shared" run_seed
assert_eq "exit code" 2 "$RC"
assert_contains "names the key" "$OUT" "shared.subscriptionId"
assert_count "nothing was created" 0 "$FAKE_AZ_STATE/calls.log" "group create"
rm -rf "$tmp"

finish "seed"
