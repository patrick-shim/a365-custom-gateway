// ============================================================================
// Module: Azure Blob Storage private endpoint
// Purpose: Private interaction-content access from the Gateway VNet
// ============================================================================

@description('Name of the private endpoint.')
@minLength(2)
param privateEndpointName string

@description('Azure region for the private endpoint.')
param location string

@description('Name of the existing Storage Account.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Resource ID of the subnet dedicated to private endpoints.')
@minLength(1)
param subnetId string

@description('Resource ID of the virtual network used by the Container Apps environment.')
@minLength(1)
param virtualNetworkId string

@description('Name of the Blob private DNS zone.')
param privateDnsZoneName string = 'privatelink.blob.${environment().suffixes.storage}'

@description('Name of the virtual network link for the private DNS zone.')
@minLength(1)
param virtualNetworkLinkName string

@description('Tags to apply to the private endpoint.')
param tags object = {}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
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
        name: 'peconn-${storageAccountName}-blob'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
          requestMessage: 'Private Blob access for encrypted Gateway interaction content.'
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'storageBlobDnsGroup'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

@description('Resource ID of the Blob private endpoint.')
output privateEndpointId string = privateEndpoint.id

@description('Resource ID of the Blob private DNS zone.')
output privateDnsZoneId string = privateDnsZone.id

@description('Resource ID of the VNet link used for Blob private DNS resolution.')
output privateDnsZoneVirtualNetworkLinkId string = privateDnsZoneVirtualNetworkLink.id
