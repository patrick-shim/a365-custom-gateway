targetScope = 'resourceGroup'

param accountName string
param location string
param apiPrincipalId string
param roleAssignmentName string
param deploymentOwnershipId string
param bootstrapSourceFingerprint string
param upgradeSourceFingerprint string
param upgradePlanFingerprint string

resource account 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: accountName
  location: location
  kind: 'ContentSafety'
  sku: { name: 'S0' }
  tags: {
    application: 'a365-custom-gateway'
    workload: 'prompt-protection'
    bootstrapOwnershipId: deploymentOwnershipId
    bootstrapSourceFingerprint: bootstrapSourceFingerprint
    gatewayUpgradeSourceFingerprint: upgradeSourceFingerprint
    gatewayUpgradePlanFingerprint: upgradePlanFingerprint
  }
  properties: {
    customSubDomainName: accountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: { defaultAction: 'Allow' }
  }
}

resource apiReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: roleAssignmentName
  scope: account
  properties: {
    principalId: apiPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a97b65f3-24c7-4388-baec-2e87135dc908')
  }
}

output accountId string = account.id
output endpoint string = 'https://${accountName}.cognitiveservices.azure.com/'
output apiRoleAssignmentId string = apiReader.id
