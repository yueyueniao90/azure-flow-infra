// AKS cluster sized for a demo: free control-plane tier, exactly one node, no autoscaler,
// no monitoring add-on. Ingress comes from the managed application-routing add-on.
// Access is Microsoft Entra only (local accounts disabled, Azure RBAC for Kubernetes),
// so there are no long-lived kubeconfig credentials.
//
// One public IP per stage: the static IP declared here is the cluster's only outbound IP (AKS then creates none of
// its own) and, once bootstrap/ingress-ip/bind.sh has pointed the add-on's nginx controller at it, also the ingress IP
// (README, "One public IP per stage"). The subscription's regional public-IP quota is 3, shared by both stages.

param name string
param location string

@description('VM size of the single node; needs at least 2 vCPU and 4 GiB. bootstrap/preflight.sh recommends one.')
param nodeSize string

@description('Object ID of the identity that deploys workloads to the cluster. Empty skips the assignments.')
param deployPrincipalId string = ''

var nodeCount = 1
var clusterUserRoleId = '4abbcc35-e782-43d8-92c5-2d3f1bd2253f'
var rbacWriterRoleId = 'a7ffa36f-339b-4b5c-8bdf-e2c188b2c0eb'
var networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${name}'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

// Control-plane identity. User-assigned (not system-assigned) so its role below exists before the cluster is
// created: AKS needs it to attach the static IP, which lives outside the node resource group.
resource controlPlane 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${name}'
  location: location
}

// Network Contributor on this stage group, the scope Microsoft documents for a static IP outside the node resource
// group: the Kubernetes cloud provider lists the group's public IPs to find the one the ingress names. The group holds
// no other network resource.
resource controlPlaneNetwork 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, controlPlane.id, networkContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalId: controlPlane.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource cluster 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: name
  location: location
  dependsOn: [
    controlPlaneNetwork
  ]
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${controlPlane.id}': {}
    }
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
      loadBalancerProfile: {
        outboundIPs: {
          publicIPs: [
            {
              id: publicIp.id
            }
          ]
        }
      }
    }
    ingressProfile: {
      webAppRouting: {
        // Default controller type AnnotationControlled (the default; settable only from API 2025-02-01): AKS keeps
        // the load-balancer annotations bootstrap/ingress-ip/bind.sh sets on the default controller.
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
output publicIpName string = publicIp.name
output publicIpAddress string = publicIp.properties.ipAddress
