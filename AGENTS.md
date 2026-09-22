# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Public repo: commit no subscription/tenant ID, email, token or secret. Stage files hold `"$AZFLOW_SUBSCRIPTION_ID"`, resolved at run time (see README, "Stage settings").
- Never run `az` for real from a worker: the captain's login is off limits. Validate offline only with `tests/run.sh` (shellcheck, Bicep build/lint, fake `az`/`gh` in `tests/fake-bin`).
- Scripts must stay bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`, no empty-array expansion under `set -u`.
- Cost rules: Free/Basic tiers, one AKS node, no monitoring, Key Vault or autoscaler. Role IDs live in `bootstrap/lib.sh` and `bicep/modules/`; `tests/test_bicep.sh` keeps them in sync with the seed's RBAC condition.
- Pipeline (`.github/workflows/`) never uses a stored credential: every Azure job signs in over OIDC with a repository variable client ID (README, "The pipeline"). Pin every third-party action to a full commit SHA (resolve tags to SHAs with `gh api repos/<owner>/<repo>/tags`, not `gh api .../commits/<tag>`, which 404s on a tag ref). The logic each workflow runs lives in `ci/stage.sh` so it stays testable against the fake `az` (`tests/test_ci.sh`); keep new workflow behavior there rather than inline in YAML `run:` steps. `tests/test_workflows.sh` enforces the repo's workflow rules (pinned SHAs, no `pull_request_target`, no expression interpolated into `run:` shell, permissions least-privilege) with `actionlint` and grep checks; run `tests/run.sh` after editing any workflow.
- HTTPS (README, "HTTPS"): the Static Web App custom-domain binding and its DNS TXT validation are fully automated (`bicep/modules/static-web-app.bicep`, `ci/stage.sh dns-auth`, no new role). cert-manager on AKS is never installed by a pipeline identity — it needs cluster-admin-equivalent CRDs/ClusterRoles that no identity here holds or should hold — so it stays a manual, captain-run, once-per-cluster procedure in `bootstrap/cert-manager/README.md`; the `ClusterIssuer` YAMLs there are the only reviewable artifact of it. Don't add a pipeline step that runs `helm`/`kubectl` against a cluster without revisiting that decision first.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
