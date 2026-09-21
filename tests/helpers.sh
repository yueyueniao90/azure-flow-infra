#!/usr/bin/env bash
# shellcheck disable=SC2034  # REPO_ROOT and friends are used by the sourcing test files
# Tiny assertion helpers and fixture builders shared by the test files. Source it.
# Every test runs the scripts with tests/fake-bin first on PATH, so no real `az` or `gh` is reachable.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
FAKE_BIN="$TESTS_DIR/fake-bin"

T_PASS=0
T_FAIL=0

pass() { T_PASS=$((T_PASS + 1)); }
fail() {
  T_FAIL=$((T_FAIL + 1))
  printf '  FAIL: %s\n' "$*"
}
section() { printf '\n== %s\n' "$*"; }

assert_eq() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass; else fail "$1: expected '$2', got '$3'"; fi
}
assert_contains() { # <name> <haystack> <needle>
  case "$2" in *"$3"*) pass ;; *) fail "$1: output does not contain '$3'" ;; esac
}
assert_not_contains() { # <name> <haystack> <needle>
  case "$2" in *"$3"*) fail "$1: output unexpectedly contains '$3'" ;; *) pass ;; esac
}
assert_file_contains() { # <name> <file> <needle>
  if grep -qF -- "$3" "$2" 2>/dev/null; then pass; else fail "$1: $2 does not contain '$3'"; fi
}
assert_count() { # <name> <expected count> <file> <fixed pattern>
  local n
  n="$(grep -cF -- "$4" "$3" 2>/dev/null || true)"
  assert_eq "$1" "$2" "${n:-0}"
}

finish() {
  printf '\n%s: %d passed, %d failed\n' "${1:-tests}" "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}

# ---- fake Azure state ---------------------------------------------------------------------------

# new_state: fresh state directory with every provider registered; exports FAKE_AZ_STATE.
new_state() {
  FAKE_AZ_STATE="$(mktemp -d)"
  export FAKE_AZ_STATE
  local ns
  for ns in $REQUIRED_PROVIDERS; do printf Registered >"$FAKE_AZ_STATE/provider.$ns"; done
}

# usage_json <regional free vCPU limit> <family:limit> ...
usage_json() {
  local limit="$1" fam out="" f l
  shift
  out="{\"name\":{\"value\":\"cores\"},\"currentValue\":0,\"limit\":$limit}"
  for fam in "$@"; do
    f="${fam%%:*}"
    l="${fam##*:}"
    out="$out,{\"name\":{\"value\":\"$f\"},\"currentValue\":0,\"limit\":$l}"
  done
  printf '[%s]' "$out"
}

# skus_json <region> <name:vcpu:mem:family:restriction|none> ...  (plus one unrelated size)
skus_json() {
  local region="$1" spec out="" n v m f r
  shift
  for spec in "$@"; do
    IFS=: read -r n v m f r <<<"$spec"
    local restr="[]"
    [ "$r" = none ] || restr="[{\"type\":\"Location\",\"reasonCode\":\"$r\",\"values\":[\"$region\"]}]"
    out="$out{\"resourceType\":\"virtualMachines\",\"name\":\"$n\",\"family\":\"$f\",\"capabilities\":[{\"name\":\"vCPUs\",\"value\":\"$v\"},{\"name\":\"MemoryGB\",\"value\":\"$m\"}],\"restrictions\":$restr},"
  done
  out="$out{\"resourceType\":\"virtualMachines\",\"name\":\"Standard_M128s\",\"family\":\"standardMSFamily\",\"capabilities\":[{\"name\":\"vCPUs\",\"value\":\"128\"},{\"name\":\"MemoryGB\",\"value\":\"2048\"}],\"restrictions\":[]},{\"resourceType\":\"disks\",\"name\":\"Premium_LRS\",\"restrictions\":[]}"
  printf '[%s]' "$out"
}

# region_fixture <region> <regional limit> <family:limit,...> <sku specs...>
region_fixture() {
  local region="$1" limit="$2" fams="$3"
  shift 3
  # shellcheck disable=SC2086  # fams is a space-separated list
  usage_json "$limit" $fams >"$FAKE_AZ_STATE/usage.$region.json"
  skus_json "$region" "$@" >"$FAKE_AZ_STATE/skus.$region.json"
}

# A region where the cheap burstable sizes work.
healthy_region() { # <region> [regional limit]
  region_fixture "$1" "${2:-4}" "standardBSFamily:4 standardBSv2Family:4 standardDASv5Family:4" \
    Standard_B2s:2:4:standardBSFamily:none \
    Standard_B2s_v2:2:8:standardBSv2Family:none \
    Standard_D2as_v5:2:8:standardDASv5Family:none
}

with_fakes() { PATH="$FAKE_BIN:$PATH" "$@"; }
