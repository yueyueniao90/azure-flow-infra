#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail` is intended; single quotes hold literal $VARS
# bootstrap/github-environments.sh against the fake `gh`: dry run, first run, idempotent re-run, drift repair.
set -euo pipefail
# shellcheck source=tests/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=bootstrap/lib.sh
. "$REPO_ROOT/bootstrap/lib.sh"

ENVS="$REPO_ROOT/bootstrap/github-environments.sh"

run_envs() { # sets OUT and RC
  set +e
  OUT="$(with_fakes "$ENVS" "$@" 2>&1)"
  RC=$?
  set -e
}

section "--dry-run: prints the gh api calls, never calls gh"
new_state
run_envs --dry-run
assert_eq "exit code" 0 "$RC"
[ ! -e "$FAKE_AZ_STATE/gh-calls.log" ] && pass || fail "dry run called gh"
assert_contains "staging path" "$OUT" "PUT repos/yueyueniao90/azure-flow-infra/environments/staging"
assert_contains "production path" "$OUT" "PUT repos/yueyueniao90/azure-flow-infra/environments/production"
assert_contains "names the reviewer" "$OUT" "yueyueniao90"
assert_contains "says nothing changed" "$OUT" "nothing was changed"

section "first run"
new_state
run_envs
assert_eq "exit code" 0 "$RC"
assert_contains "finished" "$OUT" "Done"
calls="$FAKE_AZ_STATE/gh-calls.log"
assert_file_contains "reads the reviewer id" "$calls" "api users/yueyueniao90"
assert_file_contains "creates staging" "$calls" "api --method PUT repos/yueyueniao90/azure-flow-infra/environments/staging"
assert_file_contains "creates production" "$calls" "api --method PUT repos/yueyueniao90/azure-flow-infra/environments/production"
prod="$(cat "$FAKE_AZ_STATE/gh-env.production.json")"
stg="$(cat "$FAKE_AZ_STATE/gh-env.staging.json")"
assert_eq "production reviewer" '[{"type":"User","id":424242}]' "$(printf '%s' "$prod" | jq -c .reviewers)"
assert_eq "production allows self review" false "$(printf '%s' "$prod" | jq .prevent_self_review)"
assert_eq "staging has no reviewers" '[]' "$(printf '%s' "$stg" | jq -c .reviewers)"
for e in "$prod" "$stg"; do
  assert_eq "custom branch policies" '{"protected_branches":false,"custom_branch_policies":true}' "$(printf '%s' "$e" | jq -c .deployment_branch_policy)"
done
for e in staging production; do
  assert_eq "$e: only main is allowed" "main	branch" "$(cut -f2,3 "$FAKE_AZ_STATE/gh-policies.$e")"
done
[ "$(grep -c . "$FAKE_AZ_STATE/gh-policies.production")" -eq 1 ] && pass || fail "production should have exactly one policy"

section "second run is idempotent"
before="$(grep -c . "$FAKE_AZ_STATE/gh-policies.production")"
run_envs
assert_eq "exit code" 0 "$RC"
assert_eq "no duplicate policies" "$before" "$(grep -c . "$FAKE_AZ_STATE/gh-policies.production")"
assert_contains "reports what is already there" "$OUT" "already there"
assert_count "policies are POSTed on the first run only" 2 "$FAKE_AZ_STATE/gh-api-bodies.log" "POST repos/"

section "drift: an extra policy is removed"
printf '999\tfeature/*\tbranch\n' >>"$FAKE_AZ_STATE/gh-policies.production"
run_envs
assert_eq "exit code" 0 "$RC"
assert_eq "only main remains" "main	branch" "$(cut -f2,3 "$FAKE_AZ_STATE/gh-policies.production")"
assert_contains "reports the removal" "$OUT" "removed deployment policy 'feature/*'"

section "AZFLOW_APPROVER"
new_state
AZFLOW_APPROVER=someone-else run_envs
assert_file_contains "reads that user" "$FAKE_AZ_STATE/gh-calls.log" "api users/someone-else"

section "errors"
new_state
touch "$FAKE_AZ_STATE/gh-not-authenticated"
run_envs
assert_eq "unauthenticated gh" 2 "$RC"
assert_contains "explains gh auth login" "$OUT" "gh auth login"
new_state
run_envs --bogus
assert_eq "unknown argument" 2 "$RC"

finish "environments"
