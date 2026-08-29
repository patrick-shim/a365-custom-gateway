$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Entra.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Experience.psm1') -Force

Describe 'Exact SQL private endpoint and DNS evidence' {
    InModuleScope Experience {
        BeforeEach {
            $script:subscriptionId = '11111111-1111-4111-8111-111111111111'
            $script:ownershipId = '22222222-2222-4222-8222-222222222222'
            $script:sourceFingerprint = "sha256:$('a' * 64)"
            $script:config = [pscustomobject]@{
                subscriptionId = $script:subscriptionId; resourceGroupName = 'rg-safe-dev'
                projectName = 'safe'; environment = 'dev'; location = 'koreacentral'
            }
            $script:resourceGroupScope = "/subscriptions/$script:subscriptionId/resourceGroups/rg-safe-dev"
            $script:serverName = 'sql-safe-dev'
            $script:serverId = "$script:resourceGroupScope/providers/Microsoft.Sql/servers/$script:serverName"
            $script:privateEndpointId = "$script:resourceGroupScope/providers/Microsoft.Network/privateEndpoints/pe-$script:serverName"
            $script:zoneId = "$script:resourceGroupScope/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net"
            $script:linkId = "$script:zoneId/virtualNetworkLinks/link-safe-dev-sql"
            $script:zoneGroupId = "$script:privateEndpointId/privateDnsZoneGroups/sqlDnsGroup"
            $script:foundation = [pscustomobject]@{
                privateEndpointSubnetId = "$script:resourceGroupScope/providers/Microsoft.Network/virtualNetworks/vnet-safe-dev/subnets/snet-private-endpoints"
                virtualNetworkId = "$script:resourceGroupScope/providers/Microsoft.Network/virtualNetworks/vnet-safe-dev"
            }
            $script:evidence = [ordered]@{
                deploymentName = 'a365gw-safe-bootstrap-sql-private-dev'
                deploymentOwnershipId = $script:ownershipId
                sourceFingerprint = $script:sourceFingerprint
                privateEndpointId = $script:privateEndpointId
                privateDnsZoneId = $script:zoneId
                virtualNetworkLinkId = $script:linkId
                privateDnsZoneGroupId = $script:zoneGroupId
                sqlServerId = $script:serverId
                privateEndpointSubnetId = $script:foundation.privateEndpointSubnetId
                virtualNetworkId = $script:foundation.virtualNetworkId
            }
            $script:privateEndpointSubnetId = $script:foundation.privateEndpointSubnetId
            $script:serverConnections = @([pscustomobject]@{
                id = "$script:serverId/privateEndpointConnections/connection"
                privateEndpointId = $script:privateEndpointId
                status = 'Approved'
            })
            Mock Invoke-AzJsonArray { return @($script:serverConnections) }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                if ($Arguments[0] -eq 'deployment') {
                    return [pscustomobject]@{
                        state = 'Succeeded'
                        parameters = [pscustomobject]@{
                            deploymentOwnershipId = [pscustomobject]@{ value = $script:ownershipId }
                            bootstrapSourceFingerprint = [pscustomobject]@{ value = $script:sourceFingerprint }
                            privateEndpointSubnetId = [pscustomobject]@{ value = $script:foundation.privateEndpointSubnetId }
                            virtualNetworkId = [pscustomobject]@{ value = $script:foundation.virtualNetworkId }
                            sqlServerName = [pscustomobject]@{ value = $script:serverName }
                        }
                        outputs = [pscustomobject]@{
                            privateEndpointId = [pscustomobject]@{ value = $script:privateEndpointId }
                            privateDnsZoneId = [pscustomobject]@{ value = $script:zoneId }
                            virtualNetworkLinkId = [pscustomobject]@{ value = $script:linkId }
                            privateDnsZoneGroupId = [pscustomobject]@{ value = $script:zoneGroupId }
                        }
                    }
                }
                if ($Arguments[1] -eq 'private-endpoint' -and $Arguments[2] -eq 'show') {
                    return [pscustomobject]@{
                        id = $script:privateEndpointId; name = "pe-$script:serverName"; location = 'koreacentral'; provisioningState = 'Succeeded'
                        tags = [pscustomobject]@{ bootstrapOwnershipId = $script:ownershipId; bootstrapSourceFingerprint = $script:sourceFingerprint }
                        subnet = [pscustomobject]@{ id = $script:privateEndpointSubnetId }
                        manualPrivateLinkServiceConnections = @()
                        privateLinkServiceConnections = @([pscustomobject]@{
                            name = "peconn-$script:serverName"; privateLinkServiceId = $script:serverId
                            groupIds = @('sqlServer'); privateLinkServiceConnectionState = [pscustomobject]@{ status = 'Approved' }
                        })
                    }
                }
                if ($Arguments[1] -eq 'private-dns' -and $Arguments[2] -eq 'zone') {
                    return [pscustomobject]@{
                        id = $script:zoneId; name = 'privatelink.database.windows.net'; location = 'global'
                        tags = [pscustomobject]@{ bootstrapOwnershipId = $script:ownershipId; bootstrapSourceFingerprint = $script:sourceFingerprint }
                    }
                }
                if ($Arguments[1] -eq 'private-dns' -and $Arguments[2] -eq 'link') {
                    return [pscustomobject]@{
                        id = $script:linkId; name = 'link-safe-dev-sql'; location = 'global'; provisioningState = 'Succeeded'
                        registrationEnabled = $false; virtualNetwork = [pscustomobject]@{ id = $script:foundation.virtualNetworkId }
                    }
                }
                if ($Arguments[1] -eq 'private-endpoint' -and $Arguments[2] -eq 'dns-zone-group') {
                    return [pscustomobject]@{
                        id = $script:zoneGroupId; name = 'sqlDnsGroup'; provisioningState = 'Succeeded'
                        privateDnsZoneConfigs = @([pscustomobject]@{ name = 'sql'; privateDnsZoneId = $script:zoneId })
                    }
                }
                throw 'Unexpected mocked SQL private-endpoint readback.'
            }
        }

        It 'accepts the exact deployment, SQL target, subnet, approval, zone group, and VNet link' {
            Test-GatewaySqlPrivateEndpointEvidence `
                -Config $script:config -Foundation $script:foundation `
                -SqlServerFqdn "$script:serverName.database.windows.net" `
                -Evidence $script:evidence -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint |
                Should -BeTrue
        }

        It 'rejects a private endpoint moved to a different subnet' {
            $script:privateEndpointSubnetId = "$script:resourceGroupScope/providers/Microsoft.Network/virtualNetworks/vnet-safe-dev/subnets/other"
            { Test-GatewaySqlPrivateEndpointEvidence `
                -Config $script:config -Foundation $script:foundation `
                -SqlServerFqdn "$script:serverName.database.windows.net" `
                -Evidence $script:evidence -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint } |
                Should -Throw '*private endpoint, approval, subnet*'
        }

        It 'rejects any extra SQL-server-side private endpoint connection' {
            $script:serverConnections += [pscustomobject]@{
                id = "$script:serverId/privateEndpointConnections/extra"
                privateEndpointId = "$script:resourceGroupScope/providers/Microsoft.Network/privateEndpoints/extra"
                status = 'Approved'
            }
            { Test-GatewaySqlPrivateEndpointEvidence `
                -Config $script:config -Foundation $script:foundation `
                -SqlServerFqdn "$script:serverName.database.windows.net" `
                -Evidence $script:evidence -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint } |
                Should -Throw '*private endpoint, approval, subnet*'
        }
    }
}
