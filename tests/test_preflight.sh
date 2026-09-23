#!/usr/bin/env bash
# bootstrap/preflight.sh against a fake `az`: pass/fail reporting, size recommendation, read-only.
set -euo pipefail
# shellcheck source=tests/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=bootstrap/lib.sh
. "$REPO_ROOT/bootstrap/lib.sh"

PREFLIGHT="$REPO_ROOT/bootstrap/preflight.sh"
export AZFLOW_SUBSCRIPTION_ID="sub-test"
unset AZFLOW_NAME_SUFFIX || true

run_preflight() { # sets OUT and RC
  set +e
  OUT="$(with_fakes "$PREFLIGHT" "$@" 2>&1)"
  RC=$?
  set -e
}

section "healthy subscription: everything passes"
new_state
healthy_region swedencentral
healthy_region germanywestcentral
run_preflight
assert_eq "exit code" 0 "$RC"
assert_contains "result line" "$OUT" "RESULT: OK"
assert_contains "quota row" "$OUT" "[PASS]"
assert_contains "size usable" "$OUT" "staging VM size Standard_B2s"
assert_not_contains "no failures" "$OUT" "[FAIL]"
assert_contains "provider table" "$OUT" "Microsoft.ContainerService"
assert_contains "size table lists candidates" "$OUT" "Standard_B2s_v2"

section "read-only: only query verbs reach az"
bad="$(grep -E '(^| )(create|register|delete|update|set|assign|install|login)( |$)' "$FAKE_AZ_STATE/calls.log" | grep -vE '^account show' || true)"
assert_eq "no mutating az calls" "" "$bad"
bad="$(grep -vE '^(account show|provider show|vm list-usage|vm list-skus|acr check-name|acr show|staticwebapp show|rest --method post)' "$FAKE_AZ_STATE/calls.log" || true)"
assert_eq "only whitelisted az commands" "" "$bad"
assert_file_contains "uses --all so restricted sizes are visible" "$FAKE_AZ_STATE/calls.log" "--all"

section "captain's case: B2*_v2 restricted in swedencentral, configured size is one of them"
new_state
region_fixture swedencentral 4 "standardBSFamily:4 standardBSv2Family:4 standardBASv2Family:4 standardDASv5Family:4" \
  Standard_B2s:2:4:standardBSFamily:NotAvailableForSubscription \
  Standard_B2s_v2:2:8:standardBSv2Family:NotAvailableForSubscription \
  Standard_B2as_v2:2:8:standardBASv2Family:NotAvailableForSubscription \
  Standard_D2as_v5:2:8:standardDASv5Family:none
healthy_region germanywestcentral
tmp="$(mktemp -d)"
cp "$REPO_ROOT"/stages/*.json "$tmp/"
jq '.nodeSize = "Standard_B2s_v2"' "$tmp/staging.json" >"$tmp/s.json" && mv "$tmp/s.json" "$tmp/staging.json"
AZFLOW_STAGES_DIR="$tmp" run_preflight
assert_eq "exit code" 1 "$RC"
assert_contains "restriction shown" "$OUT" "NotAvailableForSubscription"
assert_contains "recommends first usable size" "$OUT" "set nodeSize to Standard_D2as_v5 in stages/staging.json"
assert_contains "blocked" "$OUT" "RESULT: BLOCKED"
assert_contains "production still fine" "$OUT" "[PASS]"
rm -rf "$tmp"

section "no usable size in the region: suggests an alternative region"
new_state
region_fixture swedencentral 4 "standardBSFamily:4" Standard_B2s:2:4:standardBSFamily:NotAvailableForSubscription
healthy_region germanywestcentral
healthy_region northeurope
run_preflight --stage staging --alt-regions "westeurope northeurope"
assert_eq "exit code" 1 "$RC"
assert_contains "no candidate usable" "$OUT" "no candidate size is usable in swedencentral"
assert_contains "alternative region" "$OUT" "region northeurope has Standard_B2s usable"

section "quota: family quota exhausted and regional quota too small"
new_state
region_fixture swedencentral 1 "standardBSFamily:0" Standard_B2s:2:4:standardBSFamily:none
healthy_region germanywestcentral
run_preflight --stage staging --alt-regions ""
assert_eq "exit code" 1 "$RC"
assert_contains "regional quota fail" "$OUT" "[FAIL]    staging regional vCPU quota (swedencentral)"
assert_contains "needs vs free" "$OUT" "needs 2, free 1"
assert_contains "family quota verdict" "$OUT" "family quota"

section "providers not registered: blocked, sizes unknown"
new_state
rm -f "$FAKE_AZ_STATE"/provider.*
printf Registered >"$FAKE_AZ_STATE/provider.Microsoft.Network"
run_preflight
assert_eq "exit code" 1 "$RC"
assert_contains "provider fail" "$OUT" "[FAIL]    Microsoft.Compute"
assert_contains "points at providers-only" "$OUT" "seed.sh --providers-only"
assert_contains "quota unknown" "$OUT" "[UNKNOWN]"
assert_contains "registry unknown" "$OUT" "registry name"

section "names: registry taken is a blocker, SWA query failure is only a warning"
new_state
healthy_region swedencentral
healthy_region germanywestcentral
: >"$FAKE_AZ_STATE/acr-taken.acrazflowstaging"
: >"$FAKE_AZ_STATE/rest-fails"
run_preflight
assert_eq "exit code" 1 "$RC"
assert_contains "registry taken" "$OUT" "[FAIL]    staging registry name acrazflowstaging"
assert_contains "suffix hint" "$OUT" "AZFLOW_NAME_SUFFIX"
assert_contains "swa warns" "$OUT" "[WARN]    staging static web app name swa-azflow-staging"
assert_contains "prod registry ok" "$OUT" "[PASS]    production registry name acrazflowprod"

section "name suffix is used for the registry check"
new_state
healthy_region swedencentral
healthy_region germanywestcentral
: >"$FAKE_AZ_STATE/acr-taken.acrazflowstaging"
AZFLOW_NAME_SUFFIX=zz9 run_preflight
assert_eq "exit code with suffix" 0 "$RC"
assert_contains "suffixed name checked" "$OUT" "acrazflowstagingzz9"

section "existing resources of ours are not reported as taken"
new_state
healthy_region swedencentral
healthy_region germanywestcentral
: >"$FAKE_AZ_STATE/acr-taken.acrazflowstaging"
: >"$FAKE_AZ_STATE/acr-own.acrazflowstaging"
: >"$FAKE_AZ_STATE/swa-taken.swa-azflow-staging"
: >"$FAKE_AZ_STATE/swa-own.swa-azflow-staging"
run_preflight
assert_eq "exit code" 0 "$RC"
assert_contains "ours" "$OUT" "already exists in rg-azflow-staging (ours)"

section "usage errors"
new_state
run_preflight --stage nope
assert_eq "unknown stage exit code" 2 "$RC"
: >"$FAKE_AZ_STATE/not-logged-in"
run_preflight
assert_eq "not logged in exit code" 2 "$RC"
assert_contains "login hint" "$OUT" "az login"
new_state
unset AZFLOW_SUBSCRIPTION_ID
run_preflight
assert_eq "unset subscription exit code" 2 "$RC"
assert_contains "subscription hint" "$OUT" "AZFLOW_SUBSCRIPTION_ID"

section "stage files that disagree on the shared subscription"
new_state
tmp="$(mktemp -d)"
cp "$REPO_ROOT"/stages/*.json "$tmp/"
jq '.shared.subscriptionId = "$AZFLOW_SHARED_SUBSCRIPTION_ID"' "$tmp/production.json" >"$tmp/x.json" && mv "$tmp/x.json" "$tmp/production.json"
AZFLOW_SUBSCRIPTION_ID="sub-test" AZFLOW_SHARED_SUBSCRIPTION_ID="sub-shared" AZFLOW_STAGES_DIR="$tmp" run_preflight
assert_eq "exit code" 2 "$RC"
assert_contains "names the key" "$OUT" "shared.subscriptionId"
AZFLOW_SUBSCRIPTION_ID="sub-test" AZFLOW_SHARED_SUBSCRIPTION_ID="sub-test" AZFLOW_STAGES_DIR="$tmp" run_preflight
assert_not_contains "agreeing references pass the check" "$OUT" "shared.subscriptionId"
jq '.shared.subscriptionId = "$AZFLOW_SHARED_SUBSCRIPTION_ID"' "$tmp/staging.json" >"$tmp/x.json" && mv "$tmp/x.json" "$tmp/staging.json"
: >"$FAKE_AZ_STATE/calls.log"
AZFLOW_SUBSCRIPTION_ID="sub-test" AZFLOW_SHARED_SUBSCRIPTION_ID="sub-shared" AZFLOW_STAGES_DIR="$tmp" run_preflight
assert_not_contains "agreeing split subscription passes the check" "$OUT" "shared.subscriptionId"
# shellcheck disable=SC2086  # REQUIRED_PROVIDERS is a space-separated list
assert_eq "providers are checked in the shared subscription" "$(printf '%s\n' $REQUIRED_PROVIDERS | wc -l | tr -d ' ')" \
  "$(grep -c '^provider show .*--subscription sub-shared' "$FAKE_AZ_STATE/calls.log")"
rm -rf "$tmp"

finish "preflight"
