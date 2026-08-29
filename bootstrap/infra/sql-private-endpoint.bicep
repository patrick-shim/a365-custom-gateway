targetScope = 'resourceGroup'

param location string
param sqlServerName string
param privateEndpointSubnetId string
param virtualNetworkId string
param projectName string = 'a365gw'
param environment string
@minLength(36)
@maxLength(36)
param deploymentOwnershipId string
@minLength(71)
@maxLength(71)
param bootstrapSourceFingerprint string

var tags = {
  application: 'a365-custom-gateway'
  environment: environment
  managedBy: 'bootstrap'
  projectName: projectName
  deploymentId: '${projectName}-${environment}'
  bootstrapOwnershipId: deploymentOwnershipId
  bootstrapSourceFingerprint: bootstrapSourceFingerprint
}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' existing = {
  name: sqlServerName
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink${az.environment().suffixes.sqlServerHostname}'
  location: 'global'
  tags: tags
}

resource virtualNetworkLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: 'link-${projectName}-${environment}-sql'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetworkId
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${sqlServerName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'peconn-${sqlServerName}'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
          requestMessage: 'Private SQL access for the A365 Gateway runtime.'
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'sqlDnsGroup'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sql'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output privateEndpointId string = privateEndpoint.id
output privateDnsZoneId string = privateDnsZone.id
output virtualNetworkLinkId string = virtualNetworkLink.id
output privateDnsZoneGroupId string = privateDnsZoneGroup.id
output sqlServerId string = sqlServer.id
output privateEndpointSubnetId string = privateEndpointSubnetId
output virtualNetworkId string = virtualNetworkId
output deploymentOwnershipId string = deploymentOwnershipId
output bootstrapSourceFingerprint string = bootstrapSourceFingerprint
