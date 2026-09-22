// Static Web App on the Free plan. Content is deployed by the web pipeline, not linked to a repo.

param name string

@description('Static Web Apps are only offered in a few regions; this is metadata location, independent of the cluster region.')
param location string

@description('Object ID of the identity that deploys site content. Empty skips the assignment.')
param deployPrincipalId string = ''

@description('Custom hostname to bind to this Static Web App, e.g. "staging.demo.zzll.de". Empty skips the binding.')
param customDomain string = ''

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

// Ownership is proven with a `_dnsauth.<host>` TXT record (dns-txt-token), not a CNAME swap, so the
// binding can be created before DNS points at this app. The infra pipeline reads the generated
// validation token back after this deploys and writes that TXT record (see ci/stage.sh dns-auth);
// the managed TLS certificate that follows is free and automatic, no cert-manager involvement.
resource customDomainBinding 'Microsoft.Web/staticSites/customDomains@2023-12-01' = if (!empty(customDomain)) {
  parent: site
  name: customDomain
  properties: {
    validationMethod: 'dns-txt-token'
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
