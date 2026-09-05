targetScope = 'resourceGroup'

@minLength(3)
@maxLength(24)
param keyVaultName string

@minLength(36)
@maxLength(36)
param keyCredentialId string

@minLength(40)
@maxLength(40)
param certificateThumbprint string

@minLength(36)
@maxLength(36)
param automationApplicationId string

@minLength(36)
@maxLength(36)
param deploymentOwnershipId string

@minLength(71)
@maxLength(71)
param bootstrapSourceFingerprint string

@secure()
@minLength(1)
param secretValue string

var secretName = 'purview-automation-certificate'
var contentType = 'application/x-pkcs12'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource automationCertificate 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: secretName
  tags: {
    managedBy: 'a365gw-bootstrap'
    keyCredentialId: keyCredentialId
    certificateThumbprint: certificateThumbprint
    automationApplicationId: automationApplicationId
    bootstrapOwnershipId: deploymentOwnershipId
    bootstrapSourceFingerprint: bootstrapSourceFingerprint
  }
  properties: {
    value: secretValue
    contentType: contentType
    attributes: {
      enabled: true
    }
  }
}

output secretResourceId string = automationCertificate.id
output versionlessSecretUri string = '${keyVault.properties.vaultUri}secrets/${secretName}'
output keyCredentialId string = keyCredentialId
output certificateThumbprint string = certificateThumbprint
output automationApplicationId string = automationApplicationId
output deploymentOwnershipId string = deploymentOwnershipId
output bootstrapSourceFingerprint string = bootstrapSourceFingerprint
output contentType string = contentType
output enabled bool = true
