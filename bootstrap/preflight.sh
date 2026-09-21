#!/usr/bin/env bash
# Read-only checks to run BEFORE bootstrap/seed.sh. Creates and changes nothing in Azure.
#
#   az login
#   export AZFLOW_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
#   bootstrap/preflight.sh [--stage staging|production] [--alt-regions "r1 r2 ..."]
#
# Reports PASS / FAIL / UNKNOWN / WARN per check and exits non-zero on any FAIL or UNKNOWN:
#   1. required resource providers are registered
#   2. each stage region's regional vCPU quota covers the cluster node
#   3. which candidate VM sizes (>= 2 vCPU, >= 4 GiB) are really usable for THIS subscription in each
#      stage region (not restricted, family quota free); recommends a size or an alternative region
#   4. registry name and Static Web App name availability
# Sizes and quota need Microsoft.Compute registered; on a fresh subscription run
# `bootstrap/seed.sh --providers-only` (free, idempotent) and then this script again.

set -euo pipefail
# shellcheck source=bootstrap/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

only_stage=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stage)
      [ $# -ge 2 ] || die "--stage needs a value"
      only_stage="$2"
      shift 2
      ;;
    --alt-regions)
      [ $# -ge 2 ] || die "--alt-regions needs a value"
      ALT_REGIONS="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

require_cmd az "Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli"
require_cmd jq "Install jq (brew install jq)."

STAGES="$ALL_STAGES"
if [ -n "$only_stage" ]; then
  case " $ALL_STAGES " in
    *" $only_stage "*) STAGES="$only_stage" ;;
    *) die "unknown stage '$only_stage' (expected one of: $ALL_STAGES)" ;;
  esac
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

n_pass=0
n_fail=0
n_unknown=0
n_warn=0

row() { # <PASS|FAIL|UNKNOWN|WARN> <label> <detail>
  case "$1" in
    PASS) n_pass=$((n_pass + 1)) ;;
    FAIL) n_fail=$((n_fail + 1)) ;;
    UNKNOWN) n_unknown=$((n_unknown + 1)) ;;
    WARN) n_warn=$((n_warn + 1)) ;;
  esac
  printf '  %-9s %-42s %s\n' "[$1]" "$2" "$3"
}

# ---- load and validate stage files --------------------------------------------------------------

S_NAME=()
S_SUB=()
S_LOC=()
S_SIZE=()
S_RG=()
S_REG=()
S_SWA=()
problems=0
for st in $STAGES; do
  if ! out="$(validate_stage "$st")"; then
    printf '%s\n' "$out" >&2
    problems=1
    continue
  fi
  if ! sub="$(resolve_ref "$(stage_get "$st" .subscriptionId)")"; then
    die "stage '$st': subscriptionId is $(stage_get "$st" .subscriptionId) but that environment variable is not set. Try: export AZFLOW_SUBSCRIPTION_ID=\"\$(az account show --query id -o tsv)\""
  fi
  S_NAME+=("$st")
  S_SUB+=("$sub")
  S_LOC+=("$(stage_get "$st" .location)")
  S_SIZE+=("$(stage_get "$st" .nodeSize)")
  S_RG+=("$(stage_get "$st" .resourceGroup)")
  S_REG+=("$(registry_name "$st")")
  S_SWA+=("$(stage_get "$st" .staticWebApp)")
done
[ "$problems" -eq 0 ] || die "stage file problems above"
n_stages=${#S_NAME[@]}

az account show >/dev/null 2>&1 || die "not signed in to Azure. Run: az login"

SUBS=""
for ((i = 0; i < n_stages; i++)); do
  case " $SUBS " in *" ${S_SUB[$i]} "*) ;; *) SUBS="$SUBS ${S_SUB[$i]}" ;; esac
done

# ---- 1. resource providers ----------------------------------------------------------------------

log "1. Resource providers"
for sub in $SUBS; do
  for ns in $REQUIRED_PROVIDERS; do
    state="$(az provider show --namespace "$ns" --subscription "$sub" --query registrationState -o tsv 2>/dev/null || true)"
    [ -n "$state" ] || state="Unknown"
    printf '%s' "$state" >"$WORK/prov.$sub.$ns"
    if [ "$state" = "Registered" ]; then
      row PASS "$ns" "registered"
    else
      row FAIL "$ns" "$state (bootstrap/seed.sh --providers-only registers it)"
    fi
  done
done

is_registered() { [ "$(cat "$WORK/prov.$1.$2" 2>/dev/null || true)" = "Registered" ]; }

# ---- 2 and 3. quota and VM sizes ----------------------------------------------------------------

# fetch_region <sub> <region>: caches usage and SKU listings; returns 1 if either call fails.
fetch_region() {
  local sub="$1" region="$2" u="$WORK/usage.$1.$2.json" k="$WORK/skus.$1.$2.json"
  [ -s "$u" ] || az vm list-usage --location "$region" --subscription "$sub" -o json >"$u" 2>/dev/null || {
    rm -f "$u"
    return 1
  }
  # --all includes sizes restricted for this subscription (hidden by default).
  [ -s "$k" ] || az vm list-skus --location "$region" --subscription "$sub" --resource-type virtualMachines --all -o json >"$k" 2>/dev/null || {
    rm -f "$k"
    return 1
  }
}

cands_json() {
  local c out=""
  for c in $CANDIDATE_SIZES; do out="$out\"$c\","; done
  printf '[%s]' "${out%,}"
}

# eval_sizes <sub> <region> <vCPUs already needed by other stages in the same region>
# Prints one TSV line per candidate size: size vcpus mem_gib restriction family_free region_free verdict
eval_sizes() {
  jq -r --argjson cands "$(cands_json)" --argjson other "$3" --argjson nodes "$NODE_COUNT" \
    --argjson minv "$MIN_VCPUS" --argjson minm "$MIN_MEM_GIB" \
    --slurpfile usage "$WORK/usage.$1.$2.json" '
    ($usage[0]) as $u
    | ([$u[] | select(.name.value == "cores")] | first) as $core
    | (if $core then (($core.limit | tonumber) - ($core.currentValue | tonumber)) else 0 end) as $regfree
    | . as $skus
    | $cands[] as $c
    | ([$skus[] | select(.name == $c and .resourceType == "virtualMachines")]) as $m
    | if ($m | length) == 0 then [$c, "-", "-", "not offered", "-", $regfree, "no"]
      else
        ($m[0]) as $s
        | (($s.capabilities // []) | map({(.name): .value}) | add // {}) as $cap
        | (($cap.vCPUs // "0") | tonumber) as $v
        | (($cap.MemoryGB // "0") | tonumber) as $mem
        | ([$m[].restrictions[]? | select(.type == "Location") | .reasonCode] | first // "none") as $r
        | ([$u[] | select(.name.value == $s.family)] | first) as $f
        | (if $f then (($f.limit | tonumber) - ($f.currentValue | tonumber)) else 0 end) as $famfree
        | (if $r != "none" then "restricted: " + $r
           elif $v < $minv or $mem < $minm then "too small"
           elif $famfree < ($v * $nodes) then "family quota"
           elif $regfree < ($v * $nodes + $other) then "regional quota"
           else "ok" end) as $verdict
        | [$c, ($v | tostring), ($mem | tostring), $r, ($famfree | tostring), ($regfree | tostring), $verdict]
      end
    | @tsv' "$WORK/skus.$1.$2.json"
}

# configured_vcpus <sub> <region> <size>: vCPUs of a size in a region, or empty.
configured_vcpus() {
  jq -r --arg n "$3" '[.[] | select(.name == $n and .resourceType == "virtualMachines")]
    | first | (.capabilities // []) | map(select(.name == "vCPUs")) | first | .value // empty' "$WORK/skus.$1.$2.json"
}

print_size_table() { # reads TSV on stdin
  printf '    %-20s %5s %8s  %-34s %s\n' "SIZE" "vCPU" "GiB" "AVAILABILITY" "VERDICT"
  local size v m r ff _rf verdict avail
  while IFS=$'\t' read -r size v m r ff _rf verdict; do
    if [ "$r" = "none" ]; then avail="available (family free: $ff)"; else avail="$r"; fi
    printf '    %-20s %5s %8s  %-34s %s\n' "$size" "$v" "$m" "$avail" "$verdict"
  done
}

log
log "2. Regional vCPU quota and VM sizes (one node per cluster)"
first_ok_line() { awk -F'\t' '$7 == "ok" && !done { print; done = 1 }'; }

for ((i = 0; i < n_stages; i++)); do
  st="${S_NAME[$i]}"
  sub="${S_SUB[$i]}"
  region="${S_LOC[$i]}"
  size="${S_SIZE[$i]}"
  log
  log "  Stage $st: region $region, configured nodeSize $size"

  if ! is_registered "$sub" Microsoft.Compute; then
    row UNKNOWN "$st vCPU quota ($region)" "Microsoft.Compute not registered; run bootstrap/seed.sh --providers-only, then re-run"
    row UNKNOWN "$st VM size $size" "cannot list sizes until Microsoft.Compute is registered"
    continue
  fi
  if ! fetch_region "$sub" "$region"; then
    row UNKNOWN "$st vCPU quota ($region)" "az vm list-usage / list-skus failed for region $region"
    continue
  fi

  # vCPUs the other stages sharing this subscription and region need (their configured sizes).
  other=0
  for ((j = 0; j < n_stages; j++)); do
    [ "$j" -ne "$i" ] || continue
    if [ "${S_SUB[$j]}" = "$sub" ] && [ "${S_LOC[$j]}" = "$region" ]; then
      if fetch_region "$sub" "$region"; then
        ov="$(configured_vcpus "$sub" "$region" "${S_SIZE[$j]}")"
        other=$((other + ${ov:-2} * NODE_COUNT))
      fi
    fi
  done

  table="$(eval_sizes "$sub" "$region" "$other")"
  printf '%s\n' "$table" | print_size_table

  own="$(configured_vcpus "$sub" "$region" "$size")"
  need=$((${own:-$MIN_VCPUS} * NODE_COUNT + other))
  regfree="$(printf '%s\n' "$table" | head -n 1 | cut -f6)"
  if [ "${regfree:-0}" -ge "$need" ]; then
    row PASS "$st regional vCPU quota ($region)" "needs $need, free ${regfree:-0}"
  else
    row FAIL "$st regional vCPU quota ($region)" "needs $need, free ${regfree:-0}"
  fi

  mine="$(printf '%s\n' "$table" | awk -F'\t' -v s="$size" '$1 == s && !done { print; done = 1 }')"
  best="$(printf '%s\n' "$table" | first_ok_line | cut -f1)"
  if [ -n "$mine" ] && [ "$(printf '%s' "$mine" | cut -f7)" = "ok" ]; then
    row PASS "$st VM size $size" "usable in $region"
  else
    reason="not among the candidate sizes"
    [ -z "$mine" ] || reason="$(printf '%s' "$mine" | cut -f7)"
    if [ -n "$best" ]; then
      row FAIL "$st VM size $size" "$reason; set nodeSize to $best in stages/$st.json"
    else
      row FAIL "$st VM size $size" "$reason; no candidate size is usable in $region"
      found=0
      for alt in $ALT_REGIONS; do
        [ "$alt" != "$region" ] || continue
        [ "$found" -lt 3 ] || break
        fetch_region "$sub" "$alt" || continue
        alt_best="$(eval_sizes "$sub" "$alt" 0 | first_ok_line | cut -f1)"
        if [ -n "$alt_best" ]; then
          log "    alternative: region $alt has $alt_best usable; set location to $alt in stages/$st.json"
          found=$((found + 1))
        fi
      done
      [ "$found" -gt 0 ] || log "    no alternative region from [$ALT_REGIONS] has a usable candidate size"
    fi
  fi
done

# ---- 4. names -----------------------------------------------------------------------------------

log
log "3. Name availability"
for ((i = 0; i < n_stages; i++)); do
  st="${S_NAME[$i]}"
  sub="${S_SUB[$i]}"
  rg="${S_RG[$i]}"

  reg="${S_REG[$i]}"
  if ! is_registered "$sub" Microsoft.ContainerRegistry; then
    row UNKNOWN "$st registry name $reg" "Microsoft.ContainerRegistry not registered"
  elif ! resp="$(az acr check-name --name "$reg" --subscription "$sub" -o json 2>/dev/null)"; then
    row UNKNOWN "$st registry name $reg" "az acr check-name failed"
  elif [ "$(printf '%s' "$resp" | jq -r '.nameAvailable')" = "true" ]; then
    row PASS "$st registry name $reg" "available"
  elif az acr show --name "$reg" --resource-group "$rg" --subscription "$sub" >/dev/null 2>&1; then
    row PASS "$st registry name $reg" "already exists in $rg (ours)"
  else
    row FAIL "$st registry name $reg" "taken; export AZFLOW_NAME_SUFFIX=<short unique text> and re-run"
  fi

  swa="${S_SWA[$i]}"
  if ! is_registered "$sub" Microsoft.Web; then
    row UNKNOWN "$st static web app name $swa" "Microsoft.Web not registered"
  elif ! resp="$(az rest --method post \
    --uri "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Web/checkNameAvailability?api-version=2023-12-01" \
    --body "{\"name\":\"$swa\",\"type\":\"Microsoft.Web/staticSites\"}" -o json 2>/dev/null)"; then
    # Not every subscription/API surface answers this query; do not block on the check itself.
    row WARN "$st static web app name $swa" "availability could not be queried (names only need to be unique in the resource group)"
  elif [ "$(printf '%s' "$resp" | jq -r '.nameAvailable')" = "true" ]; then
    row PASS "$st static web app name $swa" "available"
  elif az staticwebapp show --name "$swa" --resource-group "$rg" --subscription "$sub" >/dev/null 2>&1; then
    row PASS "$st static web app name $swa" "already exists in $rg (ours)"
  else
    row FAIL "$st static web app name $swa" "not available: $(printf '%s' "$resp" | jq -r '.reason // .message // "unknown reason"')"
  fi
done

# ---- summary ------------------------------------------------------------------------------------

log
log "Summary: $n_pass passed, $n_fail failed, $n_unknown unknown, $n_warn warnings"
if [ $((n_fail + n_unknown)) -gt 0 ]; then
  log "RESULT: BLOCKED - fix the FAIL/UNKNOWN rows above before running bootstrap/seed.sh (providers can be registered with --providers-only)."
  exit 1
fi
log "RESULT: OK - safe to run bootstrap/seed.sh."
