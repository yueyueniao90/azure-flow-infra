# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Public repo: commit no subscription/tenant ID, email, token or secret. Stage files hold `"$AZFLOW_SUBSCRIPTION_ID"`, resolved at run time (see README, "Stage settings").
- Never run `az` for real from a worker: the captain's login is off limits. Validate offline only with `tests/run.sh` (shellcheck, Bicep build/lint, fake `az`/`gh` in `tests/fake-bin`).
- Scripts must stay bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`, no empty-array expansion under `set -u`.
- Cost rules: Free/Basic tiers, one AKS node, no monitoring, Key Vault or autoscaler. Role IDs live in `bootstrap/lib.sh` and `bicep/modules/`; `tests/test_bicep.sh` keeps them in sync with the seed's RBAC condition.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
