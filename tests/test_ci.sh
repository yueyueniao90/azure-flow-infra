#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail` is intended; single quotes hold literal $VARS
# ci/stage.sh (what the workflows run) against the fake `az`: preview, apply, cluster stop/start, destroy.
set -euo pipefail
# shellcheck source=tests/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=bootstrap/lib.sh
. "$REPO_ROOT/bootstrap/lib.sh"

CI="$REPO_ROOT/ci/stage.sh"
unset AZFLOW_NAME_SUFFIX AZFLOW_API_PRINCIPAL_ID AZFLOW_WEB_PRINCIPAL_ID GITHUB_STEP_SUMMARY || true
export AZFLOW_SUBSCRIPTION_ID="sub-test"

# run_ci <args...>: sets OUT (stdout and stderr) and RC. The job summary lands in $SUMMARY_FILE.
run_ci() {
  SUMMARY_FILE="$FAKE_AZ_STATE/summary.md"
  set +e
  OUT="$(GITHUB_STEP_SUMMARY="$SUMMARY_FILE" with_fakes "$CI" "$@" 2>&1)"
  RC=$?
  set -e
}
# run_ci_stdout <args...>: sets OUT to stdout only (the markdown the preview job posts).
run_ci_stdout() {
  set +e
  OUT="$(with_fakes "$CI" "$@" 2>/dev/null)"
  RC=$?
  set -e
}
seed_groups() { : >"$FAKE_AZ_STATE/rg.rg-azflow-staging" && : >"$FAKE_AZ_STATE/rg.rg-azflow-prod" && : >"$FAKE_AZ_STATE/rg.rg-azflow-shared"; }

section "missing-vars"
new_state
OUT="$(A=1 B='' with_fakes "$CI" missing-vars A B C)"
assert_eq "lists only the unset ones" "B
C" "$OUT"
OUT="$(A=1 with_fakes "$CI" missing-vars A)"
assert_eq "nothing missing" "" "$OUT"

section "argument and stage validation"
new_state
run_ci frobnicate
assert_eq "unknown command" 2 "$RC"
run_ci apply nowhere
assert_eq "unknown stage" 2 "$RC"
assert_contains "names the stages" "$OUT" "staging production"
run_ci apply
assert_eq "missing stage" 2 "$RC"
AZFLOW_SUBSCRIPTION_ID="" run_ci apply staging
assert_eq "no subscription" 2 "$RC"
assert_contains "explains the variable" "$OUT" "AZFLOW_SUBSCRIPTION_ID"
[ ! -e "$FAKE_AZ_STATE/calls.log" ] && pass || fail "called az without a subscription"

section "what-if: resource group does not exist yet (before the seed)"
new_state
run_ci_stdout what-if staging
assert_eq "exit code is success" 0 "$RC"
assert_contains "clear message" "$OUT" "does not exist yet"
assert_contains "points at the seed" "$OUT" "bootstrap/seed.sh"
assert_not_contains "no what-if call" "$(cat "$FAKE_AZ_STATE/calls.log")" "what-if"
: >"$FAKE_AZ_STATE/rg.rg-azflow-staging"
run_ci_stdout what-if staging
assert_eq "shared group missing: success" 0 "$RC"
assert_contains "names the shared group" "$OUT" "rg-azflow-shared"

section "what-if: healthy"
new_state
seed_groups
AZFLOW_NAME_SUFFIX=sfx AZFLOW_API_PRINCIPAL_ID=api-1 AZFLOW_WEB_PRINCIPAL_ID=web-1 run_ci_stdout what-if staging
assert_eq "exit code" 0 "$RC"
assert_contains "heading" "$OUT" "### staging"
assert_contains "result in a code block" "$OUT" '```text'
assert_contains "the what-if text" "$OUT" "Resource changes: 1 to create."
case "$OUT" in *$'\033'*) fail "ANSI colour codes leaked into the markdown" ;; *) pass ;; esac
assert_file_contains "what-if targets the stage group" "$FAKE_AZ_STATE/calls.log" "deployment group what-if --resource-group rg-azflow-staging --subscription sub-test"
assert_file_contains "what-if skips RBAC write checks (preview identity is read-only)" "$FAKE_AZ_STATE/calls.log" "--validation-level ProviderNoRbac"
assert_file_contains "parameters passed through" "$FAKE_AZ_STATE/deploy-env.log" "sub=sub-test suffix=sfx api=api-1 web=web-1"
assert_not_contains "never deploys" "$(cat "$FAKE_AZ_STATE/calls.log")" "deployment group create"

section "what-if: failure is reported and fails the step"
touch "$FAKE_AZ_STATE/deploy-fails"
run_ci_stdout what-if production
assert_eq "exit code" 1 "$RC"
assert_contains "failure in the comment" "$OUT" "What-if failed"
assert_contains "the error text" "$OUT" "deployment failed"
rm -f "$FAKE_AZ_STATE/deploy-fails"

section "apply"
new_state
run_ci apply staging
assert_eq "resource group missing" 2 "$RC"
assert_contains "points at the seed" "$OUT" "bootstrap/seed.sh"
seed_groups
echo Running >"$FAKE_AZ_STATE/aks.aks-azflow-staging"
AZFLOW_NAME_SUFFIX=sfx AZFLOW_API_PRINCIPAL_ID=api-1 AZFLOW_WEB_PRINCIPAL_ID=web-1 GITHUB_RUN_ID=77 run_ci apply staging
assert_eq "exit code" 0 "$RC"
assert_file_contains "deployment named per run" "$FAKE_AZ_STATE/calls.log" "deployment group create --name azflow-staging-77 --resource-group rg-azflow-staging --subscription sub-test"
assert_file_contains "parameters passed through" "$FAKE_AZ_STATE/deploy-env.log" "sub=sub-test suffix=sfx api=api-1 web=web-1"
summary="$(cat "$SUMMARY_FILE")"
for ns in ns1-01.azure-dns.com. ns2-01.azure-dns.net. ns3-01.azure-dns.org. ns4-01.azure-dns.info.; do
  assert_contains "summary lists $ns" "$summary" "\`$ns\`"
done
assert_contains "summary names the zone" "$summary" "demo.zzll.de"
assert_contains "summary names the record" "$summary" "Route 53"
assert_contains "summary shows the registry" "$summary" "acrfake.azurecr.io"
run_ci apply production
assert_eq "production apply" 0 "$RC"
assert_file_contains "production group" "$FAKE_AZ_STATE/calls.log" "--resource-group rg-azflow-prod"
assert_file_contains "production parameter file" "$FAKE_AZ_STATE/calls.log" "bicep/production.bicepparam"
run_ci apply staging
assert_contains "warns when principals are empty" "$OUT" "role assignments for that identity are skipped"

section "apply refuses a stopped cluster, with the remedy"
echo Stopped >"$FAKE_AZ_STATE/aks.aks-azflow-staging"
before="$(grep -c "deployment group create" "$FAKE_AZ_STATE/calls.log")"
run_ci apply staging
assert_eq "exit code" 2 "$RC"
assert_contains "names the workflow" "$OUT" "cluster-start"
assert_eq "no deployment attempted" "$before" "$(grep -c "deployment group create" "$FAKE_AZ_STATE/calls.log")"
echo Stopped >"$FAKE_AZ_STATE/aks.aks-azflow-prod"
touch "$FAKE_AZ_STATE/deploy-fails"
echo Running >"$FAKE_AZ_STATE/aks.aks-azflow-staging"
run_ci apply staging
assert_eq "a failed deployment fails the job" 1 "$(printf '%s' "$RC")"
rm -f "$FAKE_AZ_STATE/deploy-fails"

section "cluster stop and start"
new_state
run_ci aks stop staging
assert_eq "stop without resource group is fine" 0 "$RC"
assert_contains "says so" "$OUT" "nothing to stop"
run_ci aks start staging
assert_eq "start without resource group fails" 2 "$RC"
seed_groups
run_ci aks stop staging
assert_eq "stop without cluster is fine" 0 "$RC"
run_ci aks start staging
assert_eq "start without cluster fails" 2 "$RC"
echo Running >"$FAKE_AZ_STATE/aks.aks-azflow-staging"
run_ci aks start staging
assert_eq "start when running" 0 "$RC"
assert_contains "idempotent" "$OUT" "already Running"
assert_not_contains "no az aks start call" "$(cat "$FAKE_AZ_STATE/calls.log")" "aks start"
run_ci aks stop staging
assert_eq "stop" 0 "$RC"
assert_file_contains "stop call" "$FAKE_AZ_STATE/calls.log" "aks stop --resource-group rg-azflow-staging --name aks-azflow-staging --subscription sub-test"
assert_eq "state is Stopped" Stopped "$(cat "$FAKE_AZ_STATE/aks.aks-azflow-staging")"
assert_contains "summary" "$(cat "$SUMMARY_FILE")" "now Stopped"
run_ci aks stop staging
assert_contains "stop is idempotent" "$OUT" "already Stopped"
run_ci aks start staging
assert_eq "start" 0 "$RC"
assert_file_contains "start call" "$FAKE_AZ_STATE/calls.log" "aks start --resource-group rg-azflow-staging --name aks-azflow-staging"
assert_eq "state is Running" Running "$(cat "$FAKE_AZ_STATE/aks.aks-azflow-staging")"
echo Running >"$FAKE_AZ_STATE/aks.aks-azflow-prod"
run_ci aks stop production
assert_file_contains "production cluster" "$FAKE_AZ_STATE/calls.log" "aks stop --resource-group rg-azflow-prod --name aks-azflow-prod"
run_ci aks pause staging
assert_eq "bad action" 2 "$RC"

section "dns-auth: writes the domain-ownership TXT record when a validation token is pending"
new_state
seed_groups
printf 'tok-abc123' >"$FAKE_AZ_STATE/swa-token.swa-azflow-staging.staging.demo.zzll.de"
run_ci dns-auth staging
assert_eq "exit code" 0 "$RC"
assert_file_contains "reads back the token for the right hostname" "$FAKE_AZ_STATE/calls.log" \
  "staticwebapp hostname show --name swa-azflow-staging --resource-group rg-azflow-staging --hostname staging.demo.zzll.de --subscription sub-test --query validationToken -o tsv"
assert_file_contains "writes the record into the shared zone" "$FAKE_AZ_STATE/calls.log" \
  "network dns record-set txt add-record --resource-group rg-azflow-shared --zone-name demo.zzll.de --subscription sub-test --record-set-name _dnsauth.staging --value tok-abc123"
assert_eq "TXT value recorded once" "tok-abc123" "$(cat "$FAKE_AZ_STATE/txt.rg-azflow-shared.demo.zzll.de._dnsauth.staging")"
assert_contains "summary names the record" "$(cat "$SUMMARY_FILE")" "_dnsauth.staging.demo.zzll.de"
before="$(grep -c "record-set txt add-record" "$FAKE_AZ_STATE/calls.log")"
run_ci dns-auth staging
assert_eq "re-run is idempotent: exit code" 0 "$RC"
assert_eq "re-run does not duplicate the TXT value" 1 "$(grep -c . "$FAKE_AZ_STATE/txt.rg-azflow-shared.demo.zzll.de._dnsauth.staging")"
[ "$(grep -c "record-set txt add-record" "$FAKE_AZ_STATE/calls.log")" -gt "$before" ] && pass || fail "re-run did not call add-record again"

section "dns-auth: already-validated domain needs no record"
new_state
seed_groups
run_ci dns-auth staging
assert_eq "exit code" 0 "$RC"
assert_contains "says already validated" "$OUT" "already validated"
assert_not_contains "no record write call" "$(cat "$FAKE_AZ_STATE/calls.log")" "record-set txt add-record"
assert_contains "summary explains" "$(cat "$SUMMARY_FILE")" "already validated"

section "dns-auth: production uses the production hostname and stage group"
new_state
seed_groups
printf 'tok-prod' >"$FAKE_AZ_STATE/swa-token.swa-azflow-prod.app.demo.zzll.de"
run_ci dns-auth production
assert_eq "exit code" 0 "$RC"
assert_file_contains "production record name" "$FAKE_AZ_STATE/calls.log" "--record-set-name _dnsauth.app --value tok-prod"

section "dns-auth: unknown stage"
run_ci dns-auth nowhere
assert_eq "exit code" 2 "$RC"

section "destroy"
new_state
seed_groups
run_ci destroy staging
assert_eq "exit code" 0 "$RC"
[ ! -e "$FAKE_AZ_STATE/rg.rg-azflow-staging" ] && pass || fail "staging group not deleted"
[ -e "$FAKE_AZ_STATE/rg.rg-azflow-prod" ] && pass || fail "destroy staging touched production"
[ -e "$FAKE_AZ_STATE/rg.rg-azflow-shared" ] && pass || fail "destroy staging touched the shared group"
run_ci destroy staging
assert_eq "already gone is fine" 0 "$RC"
assert_contains "says so" "$OUT" "already gone"
run_ci destroy production
assert_eq "production without --shared" 0 "$RC"
[ ! -e "$FAKE_AZ_STATE/rg.rg-azflow-prod" ] && pass || fail "production group not deleted"
[ -e "$FAKE_AZ_STATE/rg.rg-azflow-shared" ] && pass || fail "shared group deleted without --shared"
assert_not_contains "no Route 53 reminder without --shared" "$(cat "$SUMMARY_FILE")" "Route 53"
seed_groups
run_ci destroy production --shared
assert_eq "production with --shared" 0 "$RC"
[ ! -e "$FAKE_AZ_STATE/rg.rg-azflow-shared" ] && pass || fail "shared group not deleted"
assert_contains "Route 53 reminder" "$(cat "$SUMMARY_FILE")" "delete the Route 53 record"
assert_contains "names the record" "$(cat "$SUMMARY_FILE")" "demo.zzll.de"
run_ci destroy production --everything
assert_eq "unknown option" 2 "$RC"

section "destroy only ever deletes rg-azflow-* groups"
new_state
seed_groups
work="$(mktemp -d)"
mkdir -p "$work/stages"
jq '.resourceGroup = "some-other-group"' "$REPO_ROOT/stages/staging.json" >"$work/stages/staging.json"
cp "$REPO_ROOT/stages/production.json" "$work/stages/production.json"
: >"$FAKE_AZ_STATE/rg.some-other-group"
AZFLOW_STAGES_DIR="$work/stages" run_ci destroy staging
assert_eq "refuses" 2 "$RC"
assert_contains "explains" "$OUT" "rg-azflow-*"
[ -e "$FAKE_AZ_STATE/rg.some-other-group" ] && pass || fail "foreign group was deleted"
rm -rf "$work"

finish "ci"
