// Container registry (Basic: the smallest tier). No admin user (anonymous pull is off by default).
// The api pipeline identity may push images; nothing else is granted here.

@description('Registry name: 5-50 lowercase letters and digits, globally unique.')
@minLength(5)
@maxLength(50)
param name string

param location string

@description('Object ID of the identity allowed to push images (AcrPush). Empty skips the assignment.')
param pushPrincipalId string = ''

var acrPushRoleId = '8311e382-0749-4cb8-b61a-304f252e45ec'

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource acrPush 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(pushPrincipalId)) {
  scope: registry
  name: guid(registry.id, pushPrincipalId, acrPushRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPushRoleId)
    principalId: pushPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output name string = registry.name
output loginServer string = registry.properties.loginServer
