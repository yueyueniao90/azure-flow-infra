// Public Azure DNS zone shared by both stages; deployed into the shared resource group.
// Both stage deployments declare it identically, so re-deploying from either stage is a no-op.

param zoneName string

@description('Object ID of an identity allowed to write record sets in this zone (DNS Zone Contributor). Empty skips the assignment.')
param recordWriterPrincipalId string = ''

var dnsZoneContributorRoleId = 'befefa01-2a29-4197-83a8-272ff33ce314'

resource zone 'Microsoft.Network/dnsZones@2018-05-01' = {
  name: zoneName
  location: 'global'
}

resource recordWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(recordWriterPrincipalId)) {
  scope: zone
  name: guid(zone.id, recordWriterPrincipalId, dnsZoneContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dnsZoneContributorRoleId)
    principalId: recordWriterPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output name string = zone.name
output nameServers array = zone.properties.nameServers
