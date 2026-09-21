using 'main.bicep'

var stage = loadJsonContent('../stages/production.json')

param location = stage.location
param clusterName = stage.cluster
// Registry names are globally unique: AZFLOW_NAME_SUFFIX (optional) is appended to the stage's name.
param registryName = '${stage.registry}${readEnvironmentVariable('AZFLOW_NAME_SUFFIX', '')}'
param staticWebAppName = stage.staticWebApp
param staticWebAppLocation = stage.staticWebAppLocation
param nodeSize = stage.nodeSize
param sharedSubscriptionId = readEnvironmentVariable('AZFLOW_SUBSCRIPTION_ID', '') // see README: stage files hold $AZFLOW_SUBSCRIPTION_ID
param sharedResourceGroup = stage.shared.resourceGroup
param dnsZoneName = stage.shared.dnsZone
param apiPrincipalId = readEnvironmentVariable('AZFLOW_API_PRINCIPAL_ID', '')
param webPrincipalId = readEnvironmentVariable('AZFLOW_WEB_PRINCIPAL_ID', '')
