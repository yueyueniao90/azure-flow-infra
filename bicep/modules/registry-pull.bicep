// Lets the cluster's kubelet identity pull images from the stage registry (AcrPull).

param registryName string

@description('Object ID of the AKS kubelet identity.')
param kubeletPrincipalId string

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: registryName
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, kubeletPrincipalId, acrPullRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: kubeletPrincipalId
    principalType: 'ServicePrincipal'
  }
}
