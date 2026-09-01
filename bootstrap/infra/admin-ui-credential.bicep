targetScope = 'resourceGroup'

@minLength(3)
@maxLength(24)
param keyVaultName string

@minLength(36)
@maxLength(36)
param credentialKeyId string

@minLength(36)
@maxLength(36)
param deploymentOwnershipId string

@minLength(71)
@maxLength(71)
param bootstrapSourceFingerprint string

@secure()
@minLength(1)
param secretValue string

var secretName = 'admin-ui-entra-client-secret'
var secretContentType = 'application/vnd.a365-gateway.admin-ui-entra-client-secret'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource adminUiCredential 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: secretName
  tags: {
    managedBy: 'a365gw-bootstrap'
    credentialKeyId: credentialKeyId
    bootstrapOwnershipId: deploymentOwnershipId
    bootstrapSourceFingerprint: bootstrapSourceFingerprint
  }
  properties: {
    value: secretValue
    contentType: secretContentType
    attributes: {
      enabled: true
    }
  }
}

output secretResourceId string = adminUiCredential.id
output versionlessSecretUri string = '${keyVault.properties.vaultUri}secrets/${secretName}'
output credentialKeyId string = credentialKeyId
output deploymentOwnershipId string = deploymentOwnershipId
output bootstrapSourceFingerprint string = bootstrapSourceFingerprint
output contentType string = secretContentType
output enabled bool = true
