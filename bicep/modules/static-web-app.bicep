// Static Web App on the Free plan. Content is deployed by the web pipeline, not linked to a repo.

param name string

@description('Static Web Apps are only offered in a few regions; this is metadata location, independent of the cluster region.')
param location string

@description('Object ID of the identity that deploys site content. Empty skips the assignment.')
param deployPrincipalId string = ''

var staticWebAppContributorRoleId = 'de139f84-1756-47ae-9be6-808fbbe84772'

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
  name: guid(site.id, deployPrincipalId, staticWebAppContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', staticWebAppContributorRoleId)
    principalId: deployPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output name string = site.name
output defaultHostname string = site.properties.defaultHostname
