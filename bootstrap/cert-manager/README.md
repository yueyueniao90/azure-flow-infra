# cert-manager bootstrap (manual, one time per cluster)

Installing cert-manager needs `Azure Kubernetes Service RBAC Cluster Admin` on the cluster: it creates
CRDs, ClusterRoles and ClusterRoleBindings, privileges comparable to cluster-admin. No pipeline
identity in this repo holds that role and none ever should (see `AGENTS.md` and the "Access model"
section of the main README) — granting it would let an automated identity touch anything in the
cluster, unlike every other grant here, which is scoped to one resource kind. So this is run by the
captain, by hand, using the subscription-Owner access he already has (Owner already implies
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
- [Helm](https://helm.sh/docs/intro/install/) and `kubectl` on your machine, signed in with your own
  `az login` (never a pipeline identity).

## Procedure (repeat once per stage: `staging`, then `production`)

1. **Self-assign Cluster Admin on that stage's cluster.** As subscription Owner you can already do
   this; nothing needs to be granted first.
   ```bash
   MY_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv)"
   CLUSTER_ID="$(az aks show --resource-group rg-azflow-<stage> --name aks-azflow-<stage> --query id -o tsv)"
   az role assignment create --role "Azure Kubernetes Service RBAC Cluster Admin" \
     --assignee "$MY_OBJECT_ID" --scope "$CLUSTER_ID"
   ```
2. **Get cluster credentials.**
   ```bash
   az aks get-credentials --resource-group rg-azflow-<stage> --name aks-azflow-<stage>
   ```
3. **Install cert-manager with Helm** (idempotent; `helm upgrade --install` is safe to re-run).
   ```bash
   helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
     --namespace cert-manager --create-namespace --set crds.enabled=true
   ```
4. **Apply the staging ClusterIssuer first.** Let's Encrypt's production server has tight rate limits
   (5 failed validations per hostname per hour; see "Rate limits" below) — a misconfigured issuer
   retried in a loop can burn through them during setup. The staging server has much looser limits and
   issues certificates browsers don't trust, which is fine for this one check. Edit
   `cluster-issuer-staging.yaml`'s `spec.acme.email` to your own address first (it ships with a
   placeholder and is never committed with a real one); then:
   ```bash
   kubectl apply -f bootstrap/cert-manager/cluster-issuer-staging.yaml
   ```
5. **Confirm a certificate issues.** Once the API repo's Ingress carries the
   `cert-manager.io/cluster-issuer: letsencrypt-staging` annotation and a `tls:` block for that stage's
   host (a separate, small change in `azure-flow-api`, out of scope here), check:
   ```bash
   kubectl get certificate -A
   kubectl describe certificate <name> -n <namespace>   # Ready: True once issued
   ```
6. **Switch to the production ClusterIssuer.** Edit `cluster-issuer-prod.yaml`'s `spec.acme.email` the
   same way, apply it, then change the Ingress annotation from `letsencrypt-staging` to
   `letsencrypt-prod` (in the API repo) and confirm a real certificate issues the same way as step 5.
   ```bash
   kubectl apply -f bootstrap/cert-manager/cluster-issuer-prod.yaml
   ```

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
is exactly what step 4's staging-first ordering protects against.

## Node capacity

cert-manager's three components (controller, webhook, cainjector) are lightweight (roughly 200-300 MiB
combined at defaults) and should fit alongside the API's pod on the single `Standard_B2s` node, but
there is no autoscaler and no second node to fail over to — worth confirming after the first real
install.
