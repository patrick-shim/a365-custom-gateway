@description('Azure region that supports Prompt Shields / Content Safety.')
param location string

@description('Globally unique Azure AI Content Safety account name.')
param accountName string

@allowed([
  'F0'
  'S0'
])
param skuName string = 'F0'

@description('Bootstrap ownership tag value.')
param deploymentOwnershipId string

@description('Bootstrap source fingerprint tag value.')
param sourceFingerprint string

module contentSafety './modules/content-safety.bicep' = {
  name: 'runtimeContentSafety'
  params: {
    accountName: accountName
    location: location
    skuName: skuName
    tags: {
      bootstrapOwnershipId: deploymentOwnershipId
      bootstrapSourceFingerprint: sourceFingerprint
      workload: 'prompt-protection'
      deployProfile: 'runtime'
    }
  }
}

output accountId string = contentSafety.outputs.accountId
output accountName string = contentSafety.outputs.accountName
output endpoint string = contentSafety.outputs.endpoint
