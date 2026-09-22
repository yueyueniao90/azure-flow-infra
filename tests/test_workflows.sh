#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail` is intended; single quotes hold literal $VARS
# GitHub Actions workflows: actionlint, plus the rules for a public repository that actionlint does not know
# (pinned actions, least privilege, no untrusted text in shell, no identifiers or secrets in the files).
set -euo pipefail
# shellcheck source=tests/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

cd "$REPO_ROOT"
WF=.github/workflows
files="$(ls $WF/*.yml)"

section "actionlint"
if command -v actionlint >/dev/null 2>&1; then
  out="$(actionlint 2>&1 || true)"
  assert_eq "actionlint is clean" "" "$out"
elif [ "${AZFLOW_SKIP_ACTIONLINT:-0}" = 1 ]; then
  echo "SKIPPED: actionlint not available (AZFLOW_SKIP_ACTIONLINT=1)"
else
  fail "actionlint not found (https://github.com/rhysd/actionlint, or brew install actionlint); set AZFLOW_SKIP_ACTIONLINT=1 to skip"
fi

# triggers <file>: the event names under `on:`
triggers() { awk '/^on:/ {t=1; next} /^[a-z]/ {t=0} t && /^  [a-z_]+:/ {sub(/:.*/, ""); gsub(/ /, ""); printf "%s ", $0}' "$1"; }

# job_body <file> <job>: the lines belonging to one job (its own `if:`, `environment:`, `needs:`, `env:` and
# `steps:`), stopping at the next top-level job. Lets assertions below check a field or command is set on the
# right job, not merely present somewhere in the file.
job_body() { awk -v job="  $2:" '$0 == job {in_job = 1; next} in_job && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {in_job = 0} in_job' "$1"; }

section "the expected workflows exist"
for f in checks preview apply cluster-stop cluster-start destroy; do
  [ -f "$WF/$f.yml" ] && pass || fail "missing $WF/$f.yml"
done

section "third-party actions are pinned to a full commit SHA"
for f in $files; do
  # every `uses:` value must be owner/repo@<40 hex characters>
  bad="$(grep -E '^\s*(-\s+)?uses:' "$f" | grep -vE 'uses:\s+[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}(\s|$)' || true)"
  assert_eq "$f: unpinned actions" "" "$bad"
done

section "safe triggers and no untrusted text in shell"
for f in $files; do
  assert_eq "$f: no pull_request_target" 0 "$(grep -c 'pull_request_target' "$f" || true)"
  assert_eq "$f: no secrets" 0 "$(grep -cE 'secrets\.|client-secret|creds:' "$f" || true)"
  # No `${{ ... }}` expression may appear inside a run: block; inputs reach scripts through env: only.
  exprs="$(awk '
    /^[[:space:]]*(-[[:space:]]+)?run:/ {
      match($0, /^[[:space:]]*(-[[:space:]]+)?/); ind = RLENGTH; inrun = 1
      if ($0 ~ /\$\{\{/) print FILENAME ":" NR ": " $0
      next
    }
    inrun {
      match($0, /^[[:space:]]*/)
      if ($0 !~ /^[[:space:]]*$/ && RLENGTH <= ind) { inrun = 0 } else if ($0 ~ /\$\{\{/) print FILENAME ":" NR ": " $0
    }' "$f")"
  assert_eq "$f: expressions inside run blocks" "" "$exprs"
done

section "least privilege"
for f in $files; do
  assert_eq "$f: top-level permissions are empty" 1 "$(grep -cE '^permissions: \{\}$' "$f" || true)"
  # every job declares its own permissions
  jobs="$(awk '/^jobs:/ {j=1; next} j && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {n++} END {print n+0}' "$f")"
  perms="$(awk '/^jobs:/ {j=1; next} j && /^    permissions:/ {n++} END {print n+0}' "$f")"
  assert_eq "$f: every job has permissions" "$jobs" "$perms"
  # id-token: write only where a job logs in to Azure
  assert_eq "$f: id-token only with azure/login" "$(grep -c 'uses: azure/login@' "$f" || true)" "$(grep -c 'id-token: write' "$f" || true)"
done
assert_eq "checks.yml never logs in" 0 "$(grep -c 'azure/login' $WF/checks.yml || true)"
assert_eq "checks.yml has no id-token" 0 "$(grep -c 'id-token' $WF/checks.yml || true)"

section "public repository: no identifiers"
guid='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
assert_eq "no GUIDs in workflows or ci scripts" "" "$(grep -rEn "$guid" .github ci || true)"
assert_eq "no email addresses in workflows or ci scripts" "" "$(grep -rEn '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' .github ci | grep -vE '@[0-9a-f]{40}' || true)"

section "preview.yml"
p="$WF/preview.yml"
assert_file_contains "runs on pull requests" "$p" "pull_request:"
assert_file_contains "only for bicep and stages" "$p" '- "bicep/**"'
assert_file_contains "only for bicep and stages" "$p" '- "stages/**"'
wi="$(job_body "$p" what-if)"
assert_contains "same-repo pull requests only" "$wi" "github.event.pull_request.head.repo.full_name == github.repository"
assert_contains "read-only preview identity" "$wi" "vars.AZFLOW_PREVIEW_CLIENT_ID"
assert_contains "what-if staging" "$wi" "ci/stage.sh what-if staging"
assert_contains "what-if production" "$wi" "ci/stage.sh what-if production"
assert_contains "updates one comment" "$wi" "updateComment"
assert_contains "job summary" "$wi" 'GITHUB_STEP_SUMMARY'
assert_eq "preview trigger" "pull_request " "$(triggers "$p")"
assert_eq "preview uses no environment" 0 "$(grep -c 'environment:' "$p" || true)"

section "apply.yml"
a="$WF/apply.yml"
assert_eq "apply triggers" "push workflow_dispatch " "$(triggers "$a")"
assert_file_contains "push to main" "$a" "branches: [main]"
assert_file_contains "manual dispatch" "$a" "workflow_dispatch:"
assert_file_contains "serialized" "$a" "group: azflow-infra"
assert_file_contains "never cancels a running run" "$a" "cancel-in-progress: false"
as="$(job_body "$a" apply-staging)"
ap="$(job_body "$a" apply-production)"
assert_contains "staging environment" "$as" "environment: staging"
assert_contains "production environment" "$ap" "environment: production"
assert_contains "production waits for staging" "$ap" "needs: apply-staging"
assert_contains "applies staging" "$as" "ci/stage.sh apply staging"
assert_contains "applies production" "$ap" "ci/stage.sh apply production"
assert_contains "staging domain-ownership TXT record" "$as" "ci/stage.sh dns-auth staging"
assert_contains "production domain-ownership TXT record" "$ap" "ci/stage.sh dns-auth production"
for v in AZFLOW_NAME_SUFFIX AZFLOW_API_PRINCIPAL_ID AZFLOW_WEB_PRINCIPAL_ID AZFLOW_SUBSCRIPTION_ID; do
  assert_contains "$v passed to staging" "$as" "      $v:"
  assert_contains "$v passed to production" "$ap" "      $v:"
done
assert_contains "staging identity" "$as" "vars.AZFLOW_STAGING_CLIENT_ID"
assert_contains "production identity" "$ap" "vars.AZFLOW_PRODUCTION_CLIENT_ID"

section "cluster-stop.yml and cluster-start.yml"
for w in stop start; do
  c="$WF/cluster-$w.yml"
  assert_file_contains "$w: manual only" "$c" "workflow_dispatch:"
  assert_eq "$w: no other trigger" "workflow_dispatch " "$(triggers "$c")"
  assert_file_contains "$w: stage input" "$c" "- both"
  stg="$(job_body "$c" "$w-staging")"
  prod="$(job_body "$c" "$w-production")"
  assert_contains "$w: staging environment" "$stg" "environment: staging"
  assert_contains "$w: production environment" "$prod" "environment: production"
  assert_contains "$w: staging" "$stg" "ci/stage.sh aks $w staging"
  assert_contains "$w: production" "$prod" "ci/stage.sh aks $w production"
  assert_file_contains "$w: never cancels" "$c" "cancel-in-progress: false"
done

section "destroy.yml"
d="$WF/destroy.yml"
assert_file_contains "manual only" "$d" "workflow_dispatch:"
assert_eq "no other trigger" "workflow_dispatch " "$(triggers "$d")"
assert_file_contains "include_shared input" "$d" "include_shared:"
assert_file_contains "include_shared is off by default" "$d" "default: false"
cf="$(job_body "$d" confirm)"
ds="$(job_body "$d" destroy-staging)"
dp="$(job_body "$d" destroy-production)"
assert_contains "confirmation text" "$cf" '"destroy azflow"'
assert_contains "staging environment" "$ds" "environment: staging"
assert_contains "production is approval gated" "$dp" "environment: production"
assert_contains "shared only on request" "$dp" "ci/stage.sh destroy production --shared"
assert_contains "production job waits for staging" "$dp" "needs: destroy-staging"
assert_contains "azure jobs wait for the confirmation" "$ds" "needs: confirm"
assert_contains "Route 53 reminder" "$dp" "Route 53"

finish "workflows"
