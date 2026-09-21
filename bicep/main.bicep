// Stage entry point: one deployment per stage, at resource-group scope.
//   az deployment group create -g <stage resource group> -f main.bicep -p staging.bicepparam
// The .bicepparam files read the stage settings from ../stages/<stage>.json.

targetScope = 'resourceGroup'

param location string
param clusterName string
param registryName string
param staticWebAppName string
param staticWebAppLocation string

@description('VM size of the cluster node.')
param nodeSize string

@description('Subscription of the shared resource group; empty means the deployment subscription.')
param sharedSubscriptionId string = ''
param sharedResourceGroup string
param dnsZoneName string

@description('Object ID of this stage\'s api pipeline identity. Empty skips its role assignments.')
param apiPrincipalId string = ''

@description('Object ID of this stage\'s web pipeline identity. Empty skips its role assignment.')
param webPrincipalId string = ''

var sharedSubscription = empty(sharedSubscriptionId) ? subscription().subscriptionId : sharedSubscriptionId

module registry 'modules/registry.bicep' = {
  name: 'registry'
  params: {
    name: registryName
    location: location
    pushPrincipalId: apiPrincipalId
  }
}

module cluster 'modules/aks.bicep' = {
  name: 'cluster'
  params: {
    name: clusterName
    location: location
    nodeSize: nodeSize
    deployPrincipalId: apiPrincipalId
  }
}

module registryPull 'modules/registry-pull.bicep' = {
  name: 'registry-pull'
  params: {
    registryName: registry.outputs.name
    kubeletPrincipalId: cluster.outputs.kubeletPrincipalId
  }
}

module staticWebApp 'modules/static-web-app.bicep' = {
  name: 'static-web-app'
  params: {
    name: staticWebAppName
    location: staticWebAppLocation
    deployPrincipalId: webPrincipalId
  }
}

// The zone lives in the shared resource group. The api identity writes its own A record there.
module dnsZone 'modules/dns-zone.bicep' = {
  name: 'dns-zone'
  scope: resourceGroup(sharedSubscription, sharedResourceGroup)
  params: {
    zoneName: dnsZoneName
    recordWriterPrincipalId: apiPrincipalId
  }
}

output registryLoginServer string = registry.outputs.loginServer
output staticWebAppDefaultHostname string = staticWebApp.outputs.defaultHostname
output dnsNameServers array = dnsZone.outputs.nameServers
