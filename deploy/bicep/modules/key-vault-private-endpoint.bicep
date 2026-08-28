// ============================================================================
// Module: Key Vault private endpoint
// Purpose: Private Key Vault access for a VNet-integrated Container Apps env
// ============================================================================

@description('Name of the private endpoint.')
@minLength(2)
param privateEndpointName string

@description('Azure region for the private endpoint.')
param location string

@description('Name of the existing Key Vault.')
@minLength(1)
param keyVaultName string

@description('Resource ID of the subnet dedicated to private endpoints.')
@minLength(1)
param subnetId string

@description('Resource ID of the virtual network used by the Container Apps environment.')
@minLength(1)
param virtualNetworkId string

@description('Name of the Key Vault private DNS zone.')
param privateDnsZoneName string = 'privatelink.vaultcore.azure.net'

@description('Name of the virtual network link for the private DNS zone.')
@minLength(1)
param virtualNetworkLinkName string

@description('Tags to apply to the private endpoint.')
param tags object = {}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

resource privateDnsZoneVirtualNetworkLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: virtualNetworkLinkName
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetworkId
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: privateEndpointName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${privateEndpointName}-connection'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [
            'vault'
          ]
          requestMessage: 'Private access for the A365 Gateway Admin UI.'
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'key-vault'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'key-vault'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

@description('Resource ID of the Key Vault private endpoint.')
output privateEndpointId string = privateEndpoint.id

@description('Resource ID of the Key Vault private DNS zone.')
output privateDnsZoneId string = privateDnsZone.id
