@description('Globally unique Azure AI Content Safety account name.')
param accountName string

@description('Azure region that supports Prompt Shields.')
param location string

@allowed([
  'F0'
  'S0'
])
@description('Azure AI Content Safety SKU.')
param skuName string = 'S0'

@description('Tags to apply to the resource.')
param tags object = {}

resource account 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: accountName
  location: location
  kind: 'ContentSafety'
  sku: {
    name: skuName
  }
  tags: tags
  properties: {
    customSubDomainName: accountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

output accountId string = account.id
output accountName string = account.name
output endpoint string = 'https://${accountName}.cognitiveservices.azure.com/'
