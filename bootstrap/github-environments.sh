#!/usr/bin/env bash
# One-time setup of the GitHub environments the infra pipeline uses, run by the captain after the seed
# (the seed's OIDC subjects are `environment:staging` and `environment:production`).
#
#   gh auth login                            # once; the token needs admin rights on the repository
#   bootstrap/github-environments.sh --dry-run   # prints every gh api call, changes nothing
#   bootstrap/github-environments.sh             # does it; safe to re-run
#
# Result, in yueyueniao90/azure-flow-infra:
#   staging      deployments only from the main branch
#   production   deployments only from the main branch, one required reviewer (yueyueniao90), and the reviewer may
#                approve their own run (the repository has a single developer)
# Override the reviewer with AZFLOW_APPROVER=<github login>. Uses `gh api` only; no secrets are read or written.
set -euo pipefail
# shellcheck source=bootstrap/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd jq "Install jq (brew install jq)."
if [ "$DRY" -eq 0 ]; then
  require_cmd gh "Install the GitHub CLI: https://cli.github.com/"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"
fi

REPO="$INFRA_REPO"
APPROVER="${AZFLOW_APPROVER:-$GH_OWNER}"
BRANCH="main"

plan() { printf '  [dry-run] %s\n' "$*"; }
did() { printf '  + %s\n' "$*"; }
have() { printf '  = %s (already there)\n' "$*"; }

# environment_body <reviewer id, or empty for none>
environment_body() {
  jq -cn --arg id "$1" '{
    wait_timer: 0,
    prevent_self_review: false,
    reviewers: (if $id == "" then [] else [{type: "User", id: (if ($id | test("^[0-9]+$")) then ($id | tonumber) else $id end)}] end),
    deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}
  }'
}

# ensure_environment <name> <reviewer id, or empty>
ensure_environment() {
  local env="$1" reviewer="$2" body path policies id name type found=0
  path="repos/$REPO/environments/$env"
  body="$(environment_body "$reviewer")"
  if [ "$DRY" -eq 1 ]; then
    plan "PUT $path $body"
    plan "GET $path/deployment-branch-policies, then ensure only branch '$BRANCH' is allowed (POST it if missing, DELETE any other)"
    return
  fi
  printf '%s' "$body" | gh api --method PUT "$path" --input - >/dev/null
  if [ -n "$reviewer" ]; then
    did "environment $env: deployments only from $BRANCH, required reviewer $APPROVER (self-review allowed)"
  else
    did "environment $env: deployments only from $BRANCH, no reviewers"
  fi
  policies="$(gh api "$path/deployment-branch-policies" --jq '.branch_policies[] | [.id, .name, .type] | @tsv')"
  while IFS=$'\t' read -r id name type; do
    [ -n "$id" ] || continue
    if [ "$name" = "$BRANCH" ] && [ "$type" = branch ]; then
      found=1
    else
      gh api --method DELETE "$path/deployment-branch-policies/$id" >/dev/null
      did "environment $env: removed deployment policy '$name' ($type)"
    fi
  done <<EOP
$policies
EOP
  if [ "$found" -eq 1 ]; then
    have "environment $env: deployment policy for branch $BRANCH"
  else
    jq -cn --arg n "$BRANCH" '{name: $n, type: "branch"}' | gh api --method POST "$path/deployment-branch-policies" --input - >/dev/null
    did "environment $env: allowed deployments from branch $BRANCH"
  fi
}

log "GitHub environments for $REPO"
approver_id=""
if [ "$DRY" -eq 1 ]; then
  approver_id="<id of $APPROVER>"
  plan "GET users/$APPROVER (to read the reviewer's numeric id)"
else
  approver_id="$(gh api "users/$APPROVER" --jq .id)"
  [[ "$approver_id" =~ ^[0-9]+$ ]] || die "could not read the numeric id of GitHub user '$APPROVER'"
fi

ensure_environment staging ""
ensure_environment production "$approver_id"

log
if [ "$DRY" -eq 1 ]; then
  log "Dry run complete: nothing was changed."
else
  log "Done. Safe to re-run. Check Settings > Environments in $REPO."
fi
