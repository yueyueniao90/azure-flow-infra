// AKS cluster sized for a demo: free control-plane tier, exactly one node, no autoscaler,
// no monitoring add-on. Ingress comes from the managed application-routing add-on.
// Access is Microsoft Entra only (local accounts disabled, Azure RBAC for Kubernetes),
// so there are no long-lived kubeconfig credentials.

param name string
param location string

@description('VM size of the single node; needs at least 2 vCPU and 4 GiB. bootstrap/preflight.sh recommends one.')
param nodeSize string

@description('Object ID of the identity that deploys workloads to the cluster. Empty skips the assignments.')
param deployPrincipalId string = ''

var nodeCount = 1
var clusterUserRoleId = '4abbcc35-e782-43d8-92c5-2d3f1bd2253f'
var rbacWriterRoleId = 'a7ffa36f-339b-4b5c-8bdf-e2c188b2c8ac'

resource cluster 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: name
  location: location
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: name
    disableLocalAccounts: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
    }
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        count: nodeCount
        vmSize: nodeSize
        osType: 'Linux'
        osDiskSizeGB: 32
        enableAutoScaling: false
        type: 'VirtualMachineScaleSets'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      loadBalancerSku: 'standard'
    }
    ingressProfile: {
      webAppRouting: {
        enabled: true
      }
    }
  }
}

// Fetch cluster credentials (az aks get-credentials) ...
resource clusterUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployPrincipalId)) {
  scope: cluster
  name: guid(cluster.id, deployPrincipalId, clusterUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', clusterUserRoleId)
    principalId: deployPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ... and read/write Kubernetes objects inside namespaces (no role or role-binding changes).
resource rbacWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployPrincipalId)) {
  scope: cluster
  name: guid(cluster.id, deployPrincipalId, rbacWriterRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', rbacWriterRoleId)
    principalId: deployPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output name string = cluster.name
output kubeletPrincipalId string = cluster.properties.identityProfile.kubeletidentity.objectId
