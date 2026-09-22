# azure-flow-infra

Infrastructure as code and the one-time bootstrap for a small Azure CI/CD demo. The apps are tiny on purpose;
the delivery flow (staging stage, end-to-end tests that gate releases, promotion to production, a dedicated
domain) is the point. Part of a three-repository set: this repo (public), `azure-flow-web` and `azure-flow-api`
(both private).

This repository holds step 1 (per-stage settings, the Bicep for a staging and a production stage, a read-only
preflight check, the seed script) and step 2: the GitHub Actions pipeline that previews and applies the Bicep, plus
the manual workflows that stop, start and destroy the demo so it does not run up credit.

```
stages/            per-stage settings (staging.json, production.json)
bicep/             main.bicep (stage entry point), staging/production .bicepparam, modules/ (one per resource kind)
bootstrap/         preflight.sh (read-only checks), seed.sh (one-time setup), github-environments.sh, lib.sh (shared),
                   cert-manager/ (manual TLS bootstrap for AKS, see "HTTPS")
ci/                stage.sh: the logic the workflows call, testable offline against the fake `az`
.github/workflows/ checks, preview, apply, cluster-stop, cluster-start, destroy (see "The pipeline" below)
tests/             offline test suite: tests/run.sh
```

## Prerequisites

| Tool | Needed for |
| --- | --- |
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az`) | preflight and seed |
| [GitHub CLI](https://cli.github.com/) (`gh`), authenticated | seed writes repository variables (optional: otherwise it prints them); `bootstrap/github-environments.sh` needs admin rights on the repository |
| `jq` | preflight, seed, github-environments, tests |
| `shellcheck`, the Bicep CLI (standalone [`bicep`](https://aka.ms/bicep-install) or `az bicep`), [`actionlint`](https://github.com/rhysd/actionlint) | tests only |
| [Helm](https://helm.sh/docs/intro/install/), `kubectl` | the captain's manual cert-manager bootstrap only (`bootstrap/cert-manager/README.md`, see "HTTPS"); no pipeline or test needs them |

You need to be able to create app registrations in your Entra tenant and to assign roles on the subscription
(Owner of the subscription is enough). The scripts also run on the macOS default bash (3.2).

## First-run order

Everything below runs from the captain's own machine, signed in with the captain's own `az login` and `gh auth
login`; no worker or pipeline ever uses that login (see "The pipeline"). Four steps, in this order:

```bash
az login
export AZFLOW_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"   # see "Stage settings" for why

bootstrap/preflight.sh                 # 1. read-only; PASS/FAIL table, non-zero exit on any blocker
bootstrap/seed.sh --dry-run            # 2. prints every planned action, changes nothing
bootstrap/seed.sh                      #    the real thing; safe to re-run. Writes the repository variables below.
bootstrap/github-environments.sh       # 3. creates the `staging` and `production` GitHub environments (--dry-run first)
git push                               # 4. merge the pipeline to main: apply.yml runs, staging then production
```

Step 4 is the first real deployment. `apply.yml` deploys staging automatically, then pauses `apply-production` for
the captain's approval (see "Approving a production apply" below). Until the seed (step 2) has run, `preview.yml`
and `apply.yml` report a clear "run the seed first" message instead of failing; see "The pipeline".

On a fresh subscription the preflight can not read quota or VM sizes because `Microsoft.Compute` is not registered
yet. It then reports FAIL/UNKNOWN rows. Register the providers first (free, idempotent), then run the preflight again:

```bash
bootstrap/seed.sh --providers-only
bootstrap/preflight.sh
```

What the preflight tells you:

1. whether the resource providers (Compute, ContainerService, ContainerRegistry, Web, Network, Authorization) are registered;
2. each stage region's regional vCPU quota against what its cluster node needs;
3. which candidate VM sizes with at least 2 vCPU and 4 GiB are really usable for **this** subscription in each stage
   region (a size can exist in a region and still be `NotAvailableForSubscription`), and it recommends a size, or
   another region when nothing fits. Candidates are listed cheapest plausible first in `bootstrap/lib.sh`;
4. whether the registry name (globally unique) and Static Web App name are free.

Act on the recommendation by editing `nodeSize` (or `location`) in the stage file. If the registry name is taken,
export `AZFLOW_NAME_SUFFIX=<short unique text>` before the preflight, the seed and every Bicep deployment.

`seed.sh` never creates secrets or passwords. Sign-in from GitHub Actions uses OIDC federated credentials only.
It needs `AZFLOW_SUBSCRIPTION_ID` set (a dry run shows a placeholder instead).

## Stage settings

`stages/<stage>.json` is the single description of a stage. Scripts and Bicep read the same file.

| Key | Meaning |
| --- | --- |
| `stage` | `staging` or `production`; must match the file name |
| `subscriptionId` | environment reference such as `"$AZFLOW_SUBSCRIPTION_ID"`, resolved when a script runs |
| `location` | region of the resource group, cluster and registry (per stage, see below) |
| `resourceGroup`, `cluster`, `registry`, `staticWebApp` | resource names; every stage uses its own |
| `webHost`, `apiHost` | public hostnames of the stage; `webHost` is bound to the Static Web App as a custom domain (see "HTTPS" below), `apiHost` is used by the AKS Ingress set up in the `azure-flow-api` repo (see "HTTPS") |
| `nodeSize` | VM size of the single cluster node (extra key; the preflight recommends a value) |
| `staticWebAppLocation` | Static Web Apps exist in only a few regions (`westeurope`, `centralus`, `eastus2`, `eastasia`, `westus2`), so this is separate from `location` (extra key) |
| `shared` | `subscriptionId`, `resourceGroup`, `location`, `dnsZone` of the shared group that holds the DNS zone (extra key; must resolve to the same value in both files) |

**The repository is public, so no subscription ID is committed.** The value is an environment-variable reference
(`"subscriptionId": "$AZFLOW_SUBSCRIPTION_ID"`) that `preflight.sh` and `seed.sh` expand at run time. Each stage
carries its own reference so the code already treats every stage as if it could live in its own subscription: to
split them later, point production at another variable (for example `"$AZFLOW_PROD_SUBSCRIPTION_ID"`), set it, and
run the seed again. The `.bicepparam` files read the shared group's subscription from the variable that the stage file's
`shared.subscriptionId` names; both stage files must resolve it to the same value (preflight and the seed check this).
The deployment itself targets whichever subscription the pipeline (or `az --subscription`) selects.

`location` is a per-stage setting on purpose: it lets staging and production use different regions if a
subscription's per-region quota or VM-size availability requires it. Both stages currently use `westeurope` with
`nodeSize` `Standard_B2s_v2`; together their two 2-vCPU nodes consume this account's full 4-vCPU free allowance for
that VM family in that region, leaving no headroom for a third node there.

### Naming scheme

| | staging | production |
| --- | --- | --- |
| resource group | `rg-azflow-staging` | `rg-azflow-prod` |
| AKS cluster | `aks-azflow-staging` | `aks-azflow-prod` |
| container registry | `acrazflowstaging` | `acrazflowprod` (+ optional `AZFLOW_NAME_SUFFIX`) |
| Static Web App | `swa-azflow-staging` | `swa-azflow-prod` |
| web host | `staging.demo.zzll.de` | `app.demo.zzll.de` |
| api host | `api-staging.demo.zzll.de` | `api.demo.zzll.de` |
| region | `westeurope` | `westeurope` |

Shared by both stages: resource group `rg-azflow-shared` holding the Azure DNS zone `demo.zzll.de`.

## Bicep

`bicep/main.bicep` is the stage entry point (resource-group scope). `bicep/staging.bicepparam` and
`bicep/production.bicepparam` load `stages/<stage>.json`, so a stage is deployed with:

```bash
az deployment group create --resource-group rg-azflow-staging \
  --template-file bicep/main.bicep --parameters bicep/staging.bicepparam
```

Optional environment inputs read by the parameter files: `AZFLOW_NAME_SUFFIX`, `AZFLOW_API_PRINCIPAL_ID`,
`AZFLOW_WEB_PRINCIPAL_ID` (object IDs of that stage's api and web identities, written by the seed as repository
variables). Empty means the corresponding role assignments are skipped.

| Module | Creates | Role assignments made there |
| --- | --- | --- |
| `registry.bicep` | Container Registry, Basic tier, admin user off | AcrPush for the api identity |
| `aks.bicep` | AKS, free control plane, one node, no autoscaler, no add-ons except managed application routing (ingress), Entra-only access | Cluster User Role and RBAC Writer for the api identity |
| `registry-pull.bicep` | | AcrPull for the cluster's kubelet identity on the stage registry |
| `static-web-app.bicep` | Static Web App, Free plan, plus a `customDomains` child resource binding `webHost` (`dns-txt-token` validation; see "HTTPS" below) | Contributor on the Static Web App resource only, for the web identity |
| `dns-zone.bicep` | Azure DNS zone in the shared group (both stages declare it identically) | DNS Zone Contributor for the api identity (it writes its own A record) |

The cluster has local accounts disabled and uses Azure RBAC for Kubernetes, so there is no static kubeconfig to leak.
To use `kubectl` yourself, give your user a role such as *Azure Kubernetes Service RBAC Cluster Admin* on the cluster.

## Access model (least privilege)

| Identity (Entra app) | Token subject | Rights |
| --- | --- | --- |
| `azflow-infra-<stage>` | infra repo, environment `<stage>` | On its own stage group: Contributor, plus Role Based Access Control Administrator **limited by an ABAC condition** to assigning and removing only AcrPush, AcrPull, AKS Cluster User, AKS RBAC Writer, Contributor and DNS Zone Contributor. On the shared group (only the DNS zone lives there): Contributor, plus RBAC Administrator limited to DNS Zone Contributor. |
| `azflow-web-<stage>` | `azure-flow-web`, branch `main` | Reader on its own stage group; Contributor on its own Static Web App resource only (from Bicep) |
| `azflow-api-<stage>` | `azure-flow-api`, branch `main` | Reader on its own stage group; AcrPush, AKS Cluster User and RBAC Writer, DNS Zone Contributor on single resources (from Bicep) |
| `azflow-infra-preview` | infra repo, `pull_request` | Reader plus the custom role `azflow-deployment-whatif` (only `deployments/whatIf/action` and deployment reads) on the stage groups and the shared group; role names are unique per tenant, so it is defined once, assignable to every group in every subscription |

Why this is the least that works: the infra deployment writes a registry, a cluster, a Static Web App, a DNS zone
and role assignments. Contributor on one resource group covers the writes but cannot grant access; the
conditioned RBAC Administrator adds exactly the grants Bicep makes and nothing else, so a hijacked pipeline cannot
hand itself Owner. A hand-written custom role could be narrower than Contributor, but it needs one entry per
resource-provider action and can only be verified against a real deployment; it is listed under follow-ups.
The web identity gets the built-in Contributor role, but only on its own Static Web App resource (no Static Web Apps
role ID could be verified offline). Because Bicep assigns it, Contributor is in the stage-group ABAC condition: an
infra identity can hand Contributor to another principal within its own stage group, which is no more than it already
holds there. The shared group's condition still allows DNS Zone Contributor only.
The ABAC condition string (built by `bootstrap/seed.sh`'s `rbac_condition()`) quotes the action name inside
`ActionMatches{...}` as a single-quoted string literal, e.g. `ActionMatches{'Microsoft.Authorization/roleAssignments/write'}`;
Azure rejects an unquoted action name with `InvalidCreateOrUpdateRoleAssignmentRequest`. The `GuidEquals {...}`
role IDs are bare, comma-separated GUIDs (no quotes). See Microsoft's
[delegate-role-assignments-examples](https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-examples)
for the reference grammar if this condition ever needs to change.
Nothing is assigned at subscription scope, nobody is Owner, and there are no secrets: tokens are minted per run
for a specific repository and branch or environment. Fork pull requests get no OIDC token. The production infra
environment is protected by a required reviewer (configured with the pipeline in step 2), and only an approved
job receives the `environment:production` token.

The web and api repos are private and have no environment protection on the free plan, so their credentials are
tied to the `main` branch instead.

**Known exception: staging can change production DNS.** Both stages share one DNS zone (`demo.zzll.de`), by design.
The staging infra identity (its `environment:staging` token is not protected by a required reviewer) has Contributor on
the shared group, and the staging api identity (a `main` branch push of a private repo without environment protection)
has DNS Zone Contributor on the whole zone. Either can therefore create, change or delete the production records
`app.demo.zzll.de` and `api.demo.zzll.de`, so a staging pipeline can bypass the production approval for DNS. This
was accepted for the demo; narrowing it would take record-set-scoped grants or one zone per stage.

### GitHub repository variables written by the seed

Identifiers only, no secrets. `<S>` is `STAGING` or `PRODUCTION`.

| Repo | Variables |
| --- | --- |
| infra | `AZFLOW_TENANT_ID`, `AZFLOW_PREVIEW_CLIENT_ID`, `AZFLOW_NAME_SUFFIX` (if set), and per stage `AZFLOW_<S>_SUBSCRIPTION_ID`, `AZFLOW_<S>_CLIENT_ID`, `AZFLOW_<S>_API_PRINCIPAL_ID`, `AZFLOW_<S>_WEB_PRINCIPAL_ID` |
| web | `AZFLOW_TENANT_ID` and per stage `AZFLOW_<S>_SUBSCRIPTION_ID`, `_CLIENT_ID`, `_RESOURCE_GROUP`, `_STATIC_WEB_APP`, `_WEB_HOST`, `_API_HOST` |
| api | `AZFLOW_TENANT_ID`, `AZFLOW_NAME_SUFFIX` (if set) and per stage `AZFLOW_<S>_SUBSCRIPTION_ID`, `_CLIENT_ID`, `_RESOURCE_GROUP`, `_CLUSTER`, `_REGISTRY`, `_API_HOST` |

If `gh` is missing, unauthenticated (or you pass `--no-gh`) or a repository is not reachable yet, the seed prints
the values for you to set by hand.

## The pipeline

All of it is GitHub Actions, in `.github/workflows/`. Nothing in it ever uses the captain's own Azure or GitHub
login: every job that talks to Azure signs in with one of the OIDC identities the seed created (see "Access
model"), scoped to one stage's resource group. `ci/stage.sh` holds the logic every job calls, so it can be tested
offline against a fake `az` (`tests/test_ci.sh`) instead of only being provable by running the real workflow.

| Workflow | Runs on | What it does |
| --- | --- | --- |
| `checks.yml` | every pull request, every push to `main` | `tests/run.sh` (shellcheck, Bicep build/lint, the bash suites) plus `actionlint`. No Azure login. |
| `preview.yml` | pull requests that touch `bicep/**` or `stages/**`, same-repository only | `az deployment group what-if` for each stage with the read-only preview identity (`AZFLOW_PREVIEW_CLIENT_ID`); posts the result to the job summary and to one pull-request comment it updates on every push. A fork pull request gets no Azure token, so the job skips cleanly. Before the seed has run (no resource group yet) it says so instead of failing. |
| `apply.yml` | pushes to `main` touching `bicep/**` or `stages/**`, and manual dispatch | `apply-staging` deploys staging, then `apply-production` (needs `apply-staging`) deploys production. Each job uses the matching GitHub environment and identity. After the Bicep deploy, each job also runs `ci/stage.sh dns-auth <stage>` (see "HTTPS" below). The job summary lists the DNS zone's name servers (for the Route 53 delegation, see below). |
| `cluster-stop.yml` / `cluster-start.yml` | manual only | `az aks stop` / `az aks start` on one stage or both, so the cluster VM (the bulk of the cost) is not paying for idle time. |
| `destroy.yml` | manual only | Deletes a stage's resources, and with `include_shared` the shared group (the DNS zone) too. See "Destroying the demo". |

`apply.yml`, `cluster-stop.yml`, `cluster-start.yml` and `destroy.yml` all share one concurrency group
(`azflow-infra`): only one of them runs at a time, a run already in progress (including one paused on the
production approval) is never cancelled, and a newer queued run replaces an older queued one.

### Approving a production apply

`apply-production` (in `apply.yml`, and the production job of `cluster-stop`/`cluster-start`/`destroy`) targets the
GitHub environment `production`, which `bootstrap/github-environments.sh` configures with the captain
(`yueyueniao90`) as its one required reviewer. When such a run reaches that job, GitHub pauses it and shows it
under the repository's **Actions** tab as *Waiting*; open the run and use **Review deployments** to approve or
reject. The captain may approve their own run (there is one developer); nobody else can approve it, and nobody
without write access to the repository can trigger the run in the first place.

### Stopping and starting the clusters

Run **cluster-stop** from the Actions tab (or `gh workflow run cluster-stop.yml -f stage=both`) whenever the demo
is not being watched; the AKS node VM is what actually costs credit (see "What costs credit" below), and stopping
it is free while it is off. Run **cluster-start** the same way before a demo. Both take `stage: staging`,
`production` or `both`; a stopped cluster also blocks `apply.yml` for that stage until it is started again (Azure
rejects updates to a stopped cluster), and the error names this workflow.

### Destroying the demo

**`destroy.yml` deletes real resources and cannot be undone.** Run it from the Actions tab with the confirmation
input typed exactly as `destroy azflow`; anything else is rejected before anything is touched. It deletes the
staging and production resource groups; tick `include_shared` to also delete the shared group that holds the DNS
zone (off by default, since the two stages can be recreated without losing the zone). The production deletion
waits for the same `production` environment approval as a normal apply. **When the shared group is deleted, delete
the Route 53 `NS` record for `demo.zzll.de` too** (the workflow summary repeats this): the Azure zone is gone, and
a dangling delegation lets anyone who creates a zone with that name in their own Azure account claim the subdomain.
See "DNS" below for the exact record.

## What costs credit and what is free

| Free | Costs credit |
| --- | --- |
| Static Web Apps, Free plan | The cluster VM (`nodeSize`), one per cluster: the bulk of the cost |
| AKS control plane, free tier | Two Container Registries, Basic tier (small daily fee each) |
| Resource groups, role assignments, app registrations, federated credentials | Public IP and load balancer the cluster creates for ingress, and the node's OS disk (32 GB, set small) |
| Resource provider registration | The Azure DNS zone (small monthly fee plus per-query cost) |

Deliberately not used: monitoring or Log Analytics, Key Vault, autoscaling, extra nodes, premium tiers. Use the
**cluster-stop** workflow when the demo is not being watched, and **destroy** when it is done for good (see "The
pipeline" above); both are manual so nothing is torn down without asking.

## The free trial and its spending limit

A free-trial subscription comes with a starter credit for about 30 days and has a spending limit switched on by
default. While it is on, you are never billed: when the credit or the time runs out, Azure disables the resources
instead of charging, and keeps the data for a grace period before deleting it. Charges only start if you remove
the spending limit or upgrade to pay-as-you-go, so do not. Both stages share the one subscription, so they share
its credit and its spending limit. Check the exact terms and remaining credit in the portal (Cost Management).

## DNS: delegating `demo.zzll.de` from Route 53 to Azure

`zzll.de` stays in AWS Route 53; only the subdomain `demo.zzll.de` is delegated to the Azure DNS zone.

1. Let `apply.yml` create the stages (the zone is created by the stage deployments; see "The pipeline"). Its job
   summary already lists the four name servers; to read them again later:
   ```bash
   az network dns zone show --resource-group rg-azflow-shared --name demo.zzll.de --query nameServers -o tsv
   ```
2. In the AWS console open **Route 53 > Hosted zones > `zzll.de` > Create record** and enter:
   - Record name: `demo`
   - Record type: `NS`
   - Value: the four name servers from step 1, one per line (for example `ns1-01.azure-dns.com.`)
   - TTL: `300`
3. Verify from any machine (a few minutes at most):
   ```bash
   dig NS demo.zzll.de +short
   ```
   It must print the same four Azure name servers.
4. **When the demo is destroyed, delete that NS record in Route 53.** After the Azure zone is gone the delegation
   would dangle, and anybody who creates a zone named `demo.zzll.de` in their own Azure account could then
   claim the subdomain and serve content under your domain (subdomain takeover).

## HTTPS

Two independent certificate stories, one per surface, chosen so that neither one needs a new Azure role
or identity (see "Access model"). Both need the DNS delegation above to have propagated first.

**Web (Static Web Apps): fully automatic.** `bicep/modules/static-web-app.bicep` declares a
`Microsoft.Web/staticSites/customDomains` child resource for that stage's `webHost`, using
`dns-txt-token` validation (proves ownership with a TXT record instead of pointing DNS at the app
first). After each stage's Bicep deploy, `apply.yml` runs `ci/stage.sh dns-auth <stage>`, which reads
the generated validation token back with `az staticwebapp hostname show ... --query validationToken`
and writes it as `_dnsauth.<subdomain>.demo.zzll.de` in the shared zone, using the infra identity's
existing DNS Zone Contributor grant there — no new role assignment. It is idempotent: once Azure has
validated the domain the token comes back empty and the step is a no-op, so re-running `apply.yml`
never writes a stale or duplicate record. Once validated, Static Web Apps issues and renews a free
managed TLS certificate for the custom domain automatically; nothing further to do.

**API (AKS): the certificate tool is installed by hand, once per cluster.** The API's Ingress uses
cert-manager with Let's Encrypt's **HTTP-01** challenge (not DNS-01), because HTTP-01 needs no Azure
credential at all — the ACME server just fetches a token over the ingress's already-public port 80.
DNS-01 was ruled out here because it would need Azure Workload Identity (new cluster flags, a new Entra
identity, and a widened RBAC condition) purely to enable wildcard certificates this project doesn't
need. cert-manager's Helm chart installs cluster-scoped CRDs and ClusterRoles — comparable to
cluster-admin — so no pipeline identity installs it: it is a **manual, one-time-per-cluster step the
captain runs**, the same way `bootstrap/seed.sh` itself is captain-run, using the subscription-Owner
access he already has. The full procedure, and the two checked-in `ClusterIssuer` YAMLs (Let's Encrypt
staging server first, then production, for the rate-limit reasons explained there), live in
[`bootstrap/cert-manager/README.md`](bootstrap/cert-manager/README.md) — this is the one place that
procedure is documented; **must be re-run if a stage's cluster is ever destroyed and recreated.** The
Ingress annotation itself (`cert-manager.io/cluster-issuer`, the `tls:` block) is a small change in the
`azure-flow-api` repo, out of scope here.

## Tests

```bash
tests/run.sh
```

One command, offline. It runs shellcheck over all scripts (including `ci/stage.sh` and the fakes), builds and lints
all Bicep files (warnings fail), checks cost and security invariants of the compiled template (free tiers, one
node, no monitoring or Key Vault, role assignments limited to what the seed's RBAC condition allows), runs the
preflight, the seed, `bootstrap/github-environments.sh` and `ci/stage.sh` against a fake `az` and `gh` on `PATH`
(dry run, first run, idempotent second run, least-privilege scopes, retries, separate subscriptions per stage), and
checks the workflow files themselves with `actionlint` plus repository-specific rules (every third-party action
pinned to a full commit SHA, least-privilege `permissions` per job, `id-token: write` only where a job logs in, no
`pull_request_target`, no event text interpolated into `run:` shell, no identifiers or secrets committed). Nothing
talks to Azure or GitHub; the tests never touch a real login.

The Bicep suite uses the standalone `bicep` CLI when it is on `PATH` and otherwise falls back to `az bicep`
(called as `az bicep <build|build-params|lint> --file <file>`). That fallback only compiles local files; it never
signs in or touches a subscription. Without either tool the suite fails with install instructions, unless you set
`AZFLOW_SKIP_BICEP=1`; similarly `AZFLOW_SKIP_ACTIONLINT=1` skips the workflow linter if it cannot be installed.

## Known limits and follow-ups

- Verified offline only (Bicep build/lint, shellcheck, fake `az`). Built-in role IDs, the Static Web App name check
  (`Microsoft.Web/checkNameAvailability`, reported as a warning if it cannot be queried) and the what-if custom role
  are not yet proven against Azure; the first real run of the pipeline confirms them.
- Promoting an image from the staging registry to the production registry needs the production api identity to read
  the staging registry. That is a cross-stage grant this repo does not make; decide it in the api CD step.
- `RBAC Writer` cannot create Kubernetes namespaces; the api deploys into an existing namespace (for example `default`).
- The `customDomains` resource's `dns-txt-token` validation flow, and the exact time Azure takes to issue the managed
  certificate after validation, are unproven against Azure; also unproven is whether `az staticwebapp hostname show`
  really returns an empty `validationToken` once validated (the assumption `ci/stage.sh dns-auth`'s idempotence relies
  on). The `webapprouting.kubernetes.azure.com` ingress class name in `bootstrap/cert-manager/*.yaml` is Microsoft's
  documented name for the application-routing add-on; confirm it against the real add-on before the first
  cert-manager bootstrap (see `bootstrap/cert-manager/README.md`).
- DNS Zone Contributor for the api identity is zone-wide; it could be narrowed to record-set scope once the records exist.
- A custom role for the infra identities could replace Contributor with an exact action list.
- A production stage in its own subscription needs the seed run once more; cross-subscription paths are only exercised against the fake `az`, not a real second subscription.
- The pipeline (step 2) is also verified offline only (`actionlint`, the fake `az`/`gh`, and the repository-specific
  checks in `tests/test_workflows.sh` and `tests/test_ci.sh`): the OIDC logins, the environment approval gate and
  the preview comment are unproven against real GitHub Actions and Azure until the first run after the seed.
- `preview.yml`'s read-only identity needs the custom `azflow-deployment-whatif` role (see "Access model") already
  assigned to the stage and shared groups; until the seed has run once, the preview step reports that plainly
  instead of failing.
