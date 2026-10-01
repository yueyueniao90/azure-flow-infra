# cert-manager bootstrap (manual, one time per cluster)

Installing cert-manager needs `Azure Kubernetes Service RBAC Cluster Admin` on the cluster: it creates
CRDs, ClusterRoles and ClusterRoleBindings, privileges comparable to cluster-admin. No pipeline
identity in this repo holds that role and none ever should (see `AGENTS.md` and the "Access model"
section of the main README) — granting it would let an automated identity touch anything in the
cluster, unlike every other grant here, which is scoped to one resource kind. So this is run by the
captain, by hand (with `install.sh`), using the subscription-Owner access he already has (Owner already implies
`Microsoft.Authorization/roleAssignments/write`, so no new grant is needed for the captain either).

This uses the **HTTP-01** challenge, not DNS-01: no Azure credential is involved in solving the ACME
challenge at all, so this procedure needs no Azure Workload Identity, no new Entra app, and no Bicep
change. The trade-off: `api(-staging).demo.zzll.de` must already resolve publicly to the cluster's
ingress before Let's Encrypt can fetch the challenge.

**Must be re-run if a stage's cluster is ever destroyed and recreated** (for example after `destroy.yml`
or a trial reset) — cert-manager and the ClusterIssuers live only inside that cluster.

## Prerequisites

- That stage's first infra apply has run (the cluster and the shared DNS zone both exist).
- The Route 53 → Azure DNS delegation for `demo.zzll.de` has propagated everywhere, not just from one
  resolver (main README, "DNS: delegating `demo.zzll.de` from Route 53 to Azure"). Verify with:
  ```bash
  dig NS demo.zzll.de +short
  ```
  Doing this bootstrap before delegation has propagated fails cleanly and can be retried; doing it
  before the cluster exists is impossible (nothing to scope the role or kubeconfig to).
- [Helm](https://helm.sh/docs/intro/install/), `kubectl` and `kubelogin` (`az aks install-cli`) and `jq` on your
  machine, signed in with your own `az login` (never a pipeline identity).

## Procedure (once per stage: `staging`, then `production`)

`install.sh` does it, signed in with your own `az login` (it never signs in for you). It is idempotent, so a
re-run (or a run after the cluster was recreated) is safe:

```bash
export AZFLOW_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
bootstrap/cert-manager/install.sh staging --email <your address>                  # Let's Encrypt staging issuer
# confirm a staging certificate issues (below), then:
bootstrap/cert-manager/install.sh staging --email <your address> --issuer prod    # Let's Encrypt production issuer
# then the same two runs for production
```

The email can also come from `AZFLOW_ACME_EMAIL`. It needs `az`, `kubectl` and `kubelogin` (`az aks install-cli`),
`helm` and `jq`. Each run, against the stage's cluster from `stages/<stage>.json`:

1. **Self-assigns `Azure Kubernetes Service RBAC Cluster Admin` on the cluster** to the signed-in user, unless
   already assigned. As subscription Owner you can already do this; nothing needs to be granted first. A fresh
   assignment takes a few minutes to reach the cluster; the script waits for it.
2. **Gets cluster credentials** (`az aks get-credentials`) into a temporary kubeconfig, converted with `kubelogin`
   to use your `az` sign-in; your `~/.kube/config` is not touched.
3. **Installs cert-manager with Helm** (`helm upgrade --install`, chart `oci://quay.io/jetstack/charts/cert-manager`,
   CRDs enabled).
4. **Applies the ClusterIssuer**, `cluster-issuer-staging.yaml` by default or `cluster-issuer-prod.yaml` with
   `--issuer prod`, with your email substituted into a temporary copy. The checked-in YAMLs keep their
   placeholder and are never committed with a real address.

Always apply the staging issuer first: Let's Encrypt's production server has tight rate limits (5 failed
validations per hostname per hour; see "Rate limits" below), and a misconfigured issuer retried in a loop can burn
through them during setup. The staging server has much looser limits and issues certificates browsers don't trust,
which is fine for this one check. `--issuer prod` refuses to run until `letsencrypt-staging` exists on the cluster.

**Confirm a certificate issues** before switching issuers. Once the API repo's Ingress carries the
`cert-manager.io/cluster-issuer: letsencrypt-staging` annotation and a `tls:` block for that stage's host (a
separate, small change in `azure-flow-api`, out of scope here), check with your own kubeconfig:

```bash
az aks get-credentials --resource-group rg-azflow-<stage> --name aks-azflow-<stage>
kubectl get certificate -A
kubectl describe certificate <name> -n <namespace>   # Ready: True once issued
```

After `--issuer prod`, change the Ingress annotation from `letsencrypt-staging` to `letsencrypt-prod` (in the API
repo) and confirm a real certificate issues the same way.

## Renewal

Fully automatic once cert-manager is running: it tracks each `Certificate`'s expiry and renews well
before it expires, using the same in-cluster ClusterIssuer and no further Azure calls. Let's Encrypt
certificates are valid 90 days. No captain action needed after the one-time bootstrap above, as long as
the cluster and its single node keep running.

## Rate limits

Let's Encrypt allows 50 certificates per registered domain (`zzll.de`) per 7 days, but only 5 duplicate
certificates for the exact same hostname set per 7 days, and 5 failed validations per hostname per
hour. Two stable hostnames renewed roughly every ~60 days are nowhere near these limits in steady
state; the real risk is first-time setup or debugging a misconfigured issuer retried in a loop, which
is exactly what the staging-first ordering above protects against.

## Node capacity

cert-manager's three components (controller, webhook, cainjector) are lightweight (roughly 200-300 MiB
combined at defaults) and should fit alongside the API's pod on the single `Standard_B2s_v2` node, but
there is no autoscaler and no second node to fail over to — worth confirming after the first real
install.
