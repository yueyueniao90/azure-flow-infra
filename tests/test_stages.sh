#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail` is intended; single quotes hold literal $VARS
# Stage settings files: schema, naming, and the rules for a public repository.
set -euo pipefail
# shellcheck source=tests/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
# shellcheck source=bootstrap/lib.sh
. "$REPO_ROOT/bootstrap/lib.sh"

section "stage files"
for st in staging production; do
  out="$(validate_stage "$st" 2>&1 || true)"
  assert_eq "$st validates" "" "$out"
  assert_eq "$st stage key" "$st" "$(stage_get "$st" .stage)"
done
out="$(validate_distinct 2>&1 || true)"
assert_eq "stages use distinct names" "" "$out"

assert_eq "staging rg" "rg-azflow-staging" "$(stage_get staging .resourceGroup)"
assert_eq "production rg" "rg-azflow-prod" "$(stage_get production .resourceGroup)"
assert_eq "staging cluster" "aks-azflow-staging" "$(stage_get staging .cluster)"
assert_eq "production cluster" "aks-azflow-prod" "$(stage_get production .cluster)"
assert_eq "staging registry" "acrazflowstaging" "$(stage_get staging .registry)"
assert_eq "production registry" "acrazflowprod" "$(stage_get production .registry)"
assert_eq "staging swa" "swa-azflow-staging" "$(stage_get staging .staticWebApp)"
assert_eq "production swa" "swa-azflow-prod" "$(stage_get production .staticWebApp)"
assert_eq "staging web host" "staging.demo.zzll.de" "$(stage_get staging .webHost)"
assert_eq "staging api host" "api-staging.demo.zzll.de" "$(stage_get staging .apiHost)"
assert_eq "production web host" "app.demo.zzll.de" "$(stage_get production .webHost)"
assert_eq "production api host" "api.demo.zzll.de" "$(stage_get production .apiHost)"
assert_eq "staging region" "westeurope" "$(stage_get staging .location)"
assert_eq "production region" "germanywestcentral" "$(stage_get production .location)"
[ "$(stage_get staging .location)" != "$(stage_get production .location)" ] && pass || fail "stages must be in different regions (4 vCPU per region on the trial)"

section "subscription is an environment reference, never a value"
for st in staging production; do
  assert_eq "$st subscriptionId is a reference" '$AZFLOW_SUBSCRIPTION_ID' "$(stage_get "$st" .subscriptionId)"
  assert_eq "$st shared subscriptionId is a reference" '$AZFLOW_SUBSCRIPTION_ID' "$(stage_get "$st" .shared.subscriptionId)"
done
unset AZFLOW_SUBSCRIPTION_ID || true
if resolve_ref '$AZFLOW_SUBSCRIPTION_ID' >/dev/null; then fail "unset reference must not resolve"; else pass; fi
assert_eq "reference resolves at run time" "sub-1234" "$(AZFLOW_SUBSCRIPTION_ID=sub-1234 resolve_ref '$AZFLOW_SUBSCRIPTION_ID')"
assert_eq "braced reference resolves" "sub-1234" "$(AZFLOW_SUBSCRIPTION_ID=sub-1234 resolve_ref '${AZFLOW_SUBSCRIPTION_ID}')"
assert_eq "plain value passes through" "plain" "$(resolve_ref plain)"

section "registry name suffix"
assert_eq "no suffix" "acrazflowstaging" "$(registry_name staging)"
assert_eq "suffix appended" "acrazflowprodxy7" "$(AZFLOW_NAME_SUFFIX=xy7 registry_name production)"
out="$(AZFLOW_NAME_SUFFIX='Bad_Suffix' validate_stage staging 2>&1 || true)"
assert_contains "invalid suffix rejected" "$out" "registry name"

section "validation catches broken files"
tmp="$(mktemp -d)"
cp "$REPO_ROOT"/stages/*.json "$tmp/"
jq '.resourceGroup = "rg-azflow-staging"' "$tmp/production.json" >"$tmp/p.json" && mv "$tmp/p.json" "$tmp/production.json"
out="$(AZFLOW_STAGES_DIR="$tmp" bash -c ". '$REPO_ROOT/bootstrap/lib.sh'; validate_distinct" 2>&1 || true)"
assert_contains "duplicate names rejected" "$out" "resourceGroup"
jq 'del(.cluster)' "$REPO_ROOT/stages/staging.json" >"$tmp/staging.json"
out="$(AZFLOW_STAGES_DIR="$tmp" bash -c ". '$REPO_ROOT/bootstrap/lib.sh'; validate_stage staging" 2>&1 || true)"
assert_contains "missing key rejected" "$out" 'missing "cluster"'
rm -rf "$tmp"

section "public repository hygiene"
cd "$REPO_ROOT"
guid='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
# Built-in Azure role definition ids are public constants; anything else shaped like a GUID is suspect.
allowed="$(grep -hoE "\"[0-9a-f-]{36}\"" bootstrap/lib.sh | tr -d '"' | sort -u)"
found="$(git ls-files -co --exclude-standard | grep -vE '^tests/' | xargs grep -hoEi "$guid" 2>/dev/null | tr 'A-F' 'a-f' | sort -u || true)"
unexpected=""
for g in $found; do
  printf '%s\n' "$allowed" | grep -qx "$g" || unexpected="$unexpected $g"
done
for g in $unexpected; do fail "unexpected GUID outside the built-in role constants: $g"; done
pass
if git ls-files -co --exclude-standard | grep -vE '^tests/' | xargs grep -nEi '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}' 2>/dev/null; then
  fail "email address found in tracked files"
else pass; fi

finish "stages"
