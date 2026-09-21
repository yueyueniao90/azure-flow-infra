// Static Web App on the Free plan. Content is deployed by the web pipeline, not linked to a repo.

param name string

@description('Static Web Apps are only offered in a few regions; this is metadata location, independent of the cluster region.')
param location string

@description('Object ID of the identity that deploys site content. Empty skips the assignment.')
param deployPrincipalId string = ''

var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

resource site 'Microsoft.Web/staticSites@2023-12-01' = {
  name: name
  location: location
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    provider: 'None'
    stagingEnvironmentPolicy: 'Disabled'
    allowConfigFileUpdates: true
  }
}

resource deployer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployPrincipalId)) {
  scope: site
  name: guid(site.id, deployPrincipalId, contributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalId: deployPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output name string = site.name
output defaultHostname string = site.properties.defaultHostname
