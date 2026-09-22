#!/usr/bin/env bash
# One command runs everything, offline: shellcheck, Bicep build and lint, and the bash suites
# (preflight, seed, environments and the CI script against a fake `az` and `gh`) and the workflow checks.
# Needs: bash, jq, shellcheck, bicep (or az bicep), actionlint.
#   tests/run.sh
# Set AZFLOW_SKIP_SHELLCHECK=1, AZFLOW_SKIP_BICEP=1 or AZFLOW_SKIP_ACTIONLINT=1 to skip a tool you cannot install.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

command -v jq >/dev/null 2>&1 || {
  echo "jq is required (brew install jq)" >&2
  exit 1
}

failed=0
step() {
  printf '\n######## %s\n' "$1"
  shift
  "$@" || failed=1
}

# shellcheck disable=SC2329  # called through step
shellcheck_all() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    if [ "${AZFLOW_SKIP_SHELLCHECK:-0}" = 1 ]; then
      echo "SKIPPED: shellcheck not available (AZFLOW_SKIP_SHELLCHECK=1)"
      return 0
    fi
    echo "shellcheck not found (brew install shellcheck) or set AZFLOW_SKIP_SHELLCHECK=1" >&2
    return 1
  fi
  shellcheck -x bootstrap/*.sh ci/*.sh tests/*.sh tests/fake-bin/az tests/fake-bin/gh && echo "shellcheck: clean"
}

step "shellcheck" shellcheck_all
step "stage files" bash tests/test_stages.sh
step "bicep" bash tests/test_bicep.sh
step "preflight" bash tests/test_preflight.sh
step "seed" bash tests/test_seed.sh
step "github environments" bash tests/test_environments.sh
step "ci script" bash tests/test_ci.sh
step "workflows" bash tests/test_workflows.sh

printf '\n'
if [ "$failed" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "TESTS FAILED"
fi
exit "$failed"
