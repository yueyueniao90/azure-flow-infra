using 'main.bicep'

var stage = loadJsonContent('../stages/production.json')

param location = stage.location
param clusterName = stage.cluster
// Registry names are globally unique: AZFLOW_NAME_SUFFIX (optional) is appended to the stage's name.
param registryName = '${stage.registry}${readEnvironmentVariable('AZFLOW_NAME_SUFFIX', '')}'
param staticWebAppName = stage.staticWebApp
param staticWebAppLocation = stage.staticWebAppLocation
param nodeSize = stage.nodeSize
// The stage file holds a reference such as '$AZFLOW_SUBSCRIPTION_ID' (see README) or a plain value.
var sharedSubscriptionRef = stage.shared.subscriptionId
param sharedSubscriptionId = startsWith(sharedSubscriptionRef, '$') ? readEnvironmentVariable(replace(replace(replace(sharedSubscriptionRef, '$', ''), '{', ''), '}', ''), '') : sharedSubscriptionRef
param sharedResourceGroup = stage.shared.resourceGroup
param dnsZoneName = stage.shared.dnsZone
param apiPrincipalId = readEnvironmentVariable('AZFLOW_API_PRINCIPAL_ID', '')
param webPrincipalId = readEnvironmentVariable('AZFLOW_WEB_PRINCIPAL_ID', '')
