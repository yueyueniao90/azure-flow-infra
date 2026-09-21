# azure-flow-infra

Infrastructure as code and the one-time bootstrap for a small Azure CI/CD demo. The apps are tiny on purpose;
the delivery flow (staging stage, end-to-end tests that gate releases, promotion to production, a dedicated
domain) is the point. Part of a three-repository set: this repo (public), `azure-flow-web` and `azure-flow-api`
(both private).

This repository currently holds step 1 of the build: per-stage settings, the Bicep for a staging and a production
stage, a read-only preflight check, and the seed script. The infra pipeline (GitHub Actions) comes next.

```
stages/            per-stage settings (staging.json, production.json)
bicep/             main.bicep (stage entry point), staging/production .bicepparam, modules/ (one per resource kind)
bootstrap/         preflight.sh (read-only checks), seed.sh (one-time setup), lib.sh (shared)
tests/             offline test suite: tests/run.sh
```

## Prerequisites

| Tool | Needed for |
| --- | --- |
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az`) | preflight and seed |
| [GitHub CLI](https://cli.github.com/) (`gh`), authenticated | seed writes repository variables (optional: otherwise it prints them) |
| `jq` | preflight, seed, tests |
| `shellcheck`, [`bicep`](https://aka.ms/bicep-install) | tests only |

You need to be able to create app registrations in your Entra tenant and to assign roles on the subscription
(Owner of the subscription is enough). The scripts also run on the macOS default bash (3.2).

## First-time setup

```bash
az login
export AZFLOW_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"   # see "Stage settings" for why

bootstrap/preflight.sh            # read-only; PASS/FAIL table, non-zero exit on any blocker
bootstrap/seed.sh --dry-run       # prints every planned action, changes nothing
bootstrap/seed.sh                 # the real thing; safe to re-run
```

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
| `webHost`, `apiHost` | public hostnames of the stage (used from step 7 on) |
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

`location` is a per-stage setting on purpose: the free trial allows 4 vCPU per region, so one 2-vCPU node per
cluster only fits when the two stages are in different regions (staging `westeurope`, production `germanywestcentral`).

### Naming scheme

| | staging | production |
| --- | --- | --- |
| resource group | `rg-azflow-staging` | `rg-azflow-prod` |
| AKS cluster | `aks-azflow-staging` | `aks-azflow-prod` |
| container registry | `acrazflowstaging` | `acrazflowprod` (+ optional `AZFLOW_NAME_SUFFIX`) |
| Static Web App | `swa-azflow-staging` | `swa-azflow-prod` |
| web host | `staging.demo.zzll.de` | `app.demo.zzll.de` |
| api host | `api-staging.demo.zzll.de` | `api.demo.zzll.de` |
| region | `westeurope` | `germanywestcentral` |

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
| `static-web-app.bicep` | Static Web App, Free plan | Static Web App Contributor for the web identity |
| `dns-zone.bicep` | Azure DNS zone in the shared group (both stages declare it identically) | DNS Zone Contributor for the api identity (it writes its own A record) |

The cluster has local accounts disabled and uses Azure RBAC for Kubernetes, so there is no static kubeconfig to leak.
To use `kubectl` yourself, give your user a role such as *Azure Kubernetes Service RBAC Cluster Admin* on the cluster.

## Access model (least privilege)

| Identity (Entra app) | Token subject | Rights |
| --- | --- | --- |
| `azflow-infra-<stage>` | infra repo, environment `<stage>` | On its own stage group: Contributor, plus Role Based Access Control Administrator **limited by an ABAC condition** to assigning and removing only AcrPush, AcrPull, AKS Cluster User, AKS RBAC Writer, Static Web App Contributor and DNS Zone Contributor. On the shared group (only the DNS zone lives there): Contributor, plus RBAC Administrator limited to DNS Zone Contributor. |
| `azflow-web-<stage>` | `azure-flow-web`, branch `main` | Reader on its own stage group; Static Web App Contributor on its Static Web App (from Bicep) |
| `azflow-api-<stage>` | `azure-flow-api`, branch `main` | Reader on its own stage group; AcrPush, AKS Cluster User and RBAC Writer, DNS Zone Contributor on single resources (from Bicep) |
| `azflow-infra-preview` | infra repo, `pull_request` | Reader plus the custom role `azflow-deployment-whatif` (only `deployments/whatIf/action` and deployment reads) on the stage groups and the shared group |

Why this is the least that works: the infra deployment writes a registry, a cluster, a Static Web App, a DNS zone
and role assignments. Contributor on one resource group covers the writes but cannot grant access; the
conditioned RBAC Administrator adds exactly the grants Bicep makes and nothing else, so a hijacked pipeline cannot
hand itself Owner. A hand-written custom role could be narrower than Contributor, but it needs one entry per
resource-provider action and can only be verified against a real deployment; it is listed under follow-ups.
Nothing is assigned at subscription scope, nobody is Owner, and there are no secrets: tokens are minted per run
for a specific repository and branch or environment. Fork pull requests get no OIDC token. The production infra
environment is protected by a required reviewer (configured with the pipeline in step 2), and only an approved
job receives the `environment:production` token.

The web and api repos are private and have no environment protection on the free plan, so their credentials are
tied to the `main` branch instead.

### GitHub repository variables written by the seed

Identifiers only, no secrets. `<S>` is `STAGING` or `PRODUCTION`.

| Repo | Variables |
| --- | --- |
| infra | `AZFLOW_TENANT_ID`, `AZFLOW_PREVIEW_CLIENT_ID`, `AZFLOW_NAME_SUFFIX` (if set), and per stage `AZFLOW_<S>_SUBSCRIPTION_ID`, `AZFLOW_<S>_CLIENT_ID`, `AZFLOW_<S>_API_PRINCIPAL_ID`, `AZFLOW_<S>_WEB_PRINCIPAL_ID` |
| web | `AZFLOW_TENANT_ID` and per stage `AZFLOW_<S>_SUBSCRIPTION_ID`, `_CLIENT_ID`, `_RESOURCE_GROUP`, `_STATIC_WEB_APP`, `_WEB_HOST`, `_API_HOST` |
| api | `AZFLOW_TENANT_ID`, `AZFLOW_NAME_SUFFIX` (if set) and per stage `AZFLOW_<S>_SUBSCRIPTION_ID`, `_CLIENT_ID`, `_RESOURCE_GROUP`, `_CLUSTER`, `_REGISTRY`, `_API_HOST` |

If `gh` is missing, unauthenticated (or you pass `--no-gh`) or a repository is not reachable yet, the seed prints
the values for you to set by hand.

## What costs credit and what is free

| Free | Costs credit |
| --- | --- |
| Static Web Apps, Free plan | The cluster VM (`nodeSize`), one per cluster: the bulk of the cost |
| AKS control plane, free tier | Two Container Registries, Basic tier (small daily fee each) |
| Resource groups, role assignments, app registrations, federated credentials | Public IP and load balancer the cluster creates for ingress, and the node's OS disk (32 GB, set small) |
| Resource provider registration | The Azure DNS zone (small monthly fee plus per-query cost) |

Deliberately not used: monitoring or Log Analytics, Key Vault, autoscaling, extra nodes, premium tiers. Stopping the
clusters and destroying the stages come with the infra pipeline (step 2).

## The free trial and its spending limit

A free-trial subscription comes with a starter credit for about 30 days and has a spending limit switched on by
default. While it is on, you are never billed: when the credit or the time runs out, Azure disables the resources
instead of charging, and keeps the data for a grace period before deleting it. Charges only start if you remove
the spending limit or upgrade to pay-as-you-go, so do not. Both stages share the one subscription, so they share
its credit and its spending limit. Check the exact terms and remaining credit in the portal (Cost Management).

## DNS: delegating `demo.zzll.de` from Route 53 to Azure

`zzll.de` stays in AWS Route 53; only the subdomain `demo.zzll.de` is delegated to the Azure DNS zone.

1. Let the infra pipeline create the stages (the zone is created by the stage deployments). Then read the zone's
   four name servers:
   ```bash
   az network dns zone show --resource-group rg-azflow-shared --name demo.zzll.de --query nameServers -o tsv
   ```
   (They are also the `dnsNameServers` output of the stage deployments.)
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

Hostname binding and HTTPS certificates are set up in step 7; until then the zone is empty.

## Tests

```bash
tests/run.sh
```

One command, offline. It runs shellcheck over all scripts, builds and lints all Bicep files (warnings fail), checks
cost and security invariants of the compiled template (free tiers, one node, no monitoring or Key Vault, role
assignments limited to what the seed's RBAC condition allows), and runs the preflight and the seed against a fake
`az` and `gh` on `PATH`: dry run, first run, idempotent second run, least-privilege scopes, retries, separate
subscriptions per stage. Nothing talks to Azure; the tests never touch a real login.

## Known limits and follow-ups

- Verified offline only (Bicep build/lint, shellcheck, fake `az`). Built-in role IDs, the Static Web App name check
  (`Microsoft.Web/checkNameAvailability`, reported as a warning if it cannot be queried) and the what-if custom role
  are not yet proven against Azure; the first real run of the pipeline confirms them.
- Promoting an image from the staging registry to the production registry needs the production api identity to read
  the staging registry. That is a cross-stage grant this repo does not make; decide it in the api CD step.
- `RBAC Writer` cannot create Kubernetes namespaces; the api deploys into an existing namespace (for example `default`).
- DNS Zone Contributor for the api identity is zone-wide; it could be narrowed to record-set scope once the records exist.
- A custom role for the infra identities could replace Contributor with an exact action list.
- A production stage in its own subscription needs the seed run once more; cross-subscription paths are untested.
