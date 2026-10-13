# Ingress IP binding (manual, one time per cluster)

Each stage uses one static public IP, `pip-<cluster>` in the stage resource group, for both the cluster's
outbound traffic and its ingress (main README, "One public IP per stage"). Bicep makes it the cluster's outbound
IP. This script makes it the ingress IP too, by setting two load-balancer annotations on the application-routing
add-on's default `NginxIngressController`:

```yaml
spec:
  loadBalancerAnnotations:
    service.beta.kubernetes.io/azure-pip-name: pip-<cluster>
    service.beta.kubernetes.io/azure-load-balancer-resource-group: <stage resource group>
```

That is Microsoft's documented way to give the add-on's NGINX a static IP
([application routing: NGINX configuration](https://learn.microsoft.com/azure/aks/app-routing-nginx-configuration)).
It cannot be Bicep: the `NginxIngressController` is a Kubernetes object, not an Azure resource. It is not a pipeline
step either: the object is cluster-scoped, so changing it needs a cluster-wide Kubernetes role (the script uses
`Azure Kubernetes Service RBAC Cluster Admin`, like the cert-manager bootstrap). No pipeline identity here holds or
should hold such a role (`AGENTS.md`, main README "Access model"). So the captain runs it by hand, with the
subscription-Owner access he already has.

**Must be re-run if a stage's cluster is ever destroyed and recreated.** The annotations live only inside the
cluster. The static IP itself survives, because it belongs to the stage resource group, not to the cluster.

## Prerequisites

- That stage's infra apply has run with the one-IP Bicep: the cluster and `pip-<cluster>` both exist. A cluster from
  before that change has to be deleted first (main README, "Moving an existing stage to one IP").
- `kubectl`, `kubelogin` (`az aks install-cli`) and `jq` on your machine, signed in with your own `az login` (never a
  pipeline identity).

## Procedure (once per stage)

```bash
export AZFLOW_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
bootstrap/ingress-ip/bind.sh production     # or staging
```

It is idempotent, so a re-run is safe. Against the stage's cluster from `stages/<stage>.json` it:

1. **Self-assigns `Azure Kubernetes Service RBAC Cluster Admin` on the cluster**, unless already assigned, and waits
   for a fresh assignment to reach the cluster (shared with the cert-manager bootstrap, `bootstrap/cluster-admin.sh`).
2. **Gets cluster credentials** into a temporary kubeconfig converted with `kubelogin`; `~/.kube/config` is not
   touched.
3. **Reads the static IP's address** (`az network public-ip show`).
4. **Merge-patches the `default` NginxIngressController** with the two annotations above; nothing else in it changes.
   AKS keeps the annotations because the default controller is `AnnotationControlled` (the add-on's default). The
   ingress class `webapprouting.kubernetes.azure.com` and the `app-routing-system/nginx` Service keep their names.
5. **Waits until the `nginx` Service reports the static IP.** The cloud provider moves the ingress onto the load
   balancer frontend the cluster already uses for outbound traffic. If the ingress had a temporary IP of its own,
   the cloud provider releases it. The cluster's control-plane identity holds Network Contributor on the stage group
   for this (`bicep/modules/aks.bicep`).

Then re-run `apply.yml` for the stage: its `api-dns` step points `apiHost` at the static IP. Until this script has
run, that step stops and names this script. On a new cluster, continue with `bootstrap/cert-manager/install.sh`
(`bootstrap/cert-manager/README.md`): its HTTP-01 challenge needs `apiHost` to resolve to the bound ingress.

## If the Service never reports the static IP

The script gives up after about five minutes and names the Service's current address. Look at the Service's events:

```bash
az aks get-credentials --resource-group <stage group> --name <cluster> --subscription "$AZFLOW_SUBSCRIPTION_ID"
kubectl describe service nginx -n app-routing-system
```

An authorization error there means the control-plane identity's Network Contributor grant on the stage group is
missing or still propagating. Re-run the infra apply, wait a few minutes, then run this script again.
