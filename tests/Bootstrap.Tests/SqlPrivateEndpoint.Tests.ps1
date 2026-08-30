$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Azure.psm1') -Force
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
            $script:nicId = "$script:resourceGroupScope/providers/Microsoft.Network/networkInterfaces/pe-$script:serverName.nic.33333333-3333-4333-8333-333333333333".ToLowerInvariant()
            $script:recordSetId = "$script:zoneId/A/$script:serverName".ToLowerInvariant()
            $script:privateEndpointIpv4Address = '10.42.1.4'
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
                privateEndpointNetworkInterfaceId = $script:nicId
                privateEndpointIpv4Address = $script:privateEndpointIpv4Address
                privateDnsARecordSetId = $script:recordSetId
                privateDnsARecordName = $script:serverName
                privateDnsARecordIpv4Address = $script:privateEndpointIpv4Address
            }
            $script:privateEndpointSubnetId = $script:foundation.privateEndpointSubnetId
            $script:serverConnections = @([pscustomobject]@{
                id = "$script:serverId/privateEndpointConnections/connection"
                privateEndpointId = $script:privateEndpointId
                status = 'Approved'
            })
            Mock Invoke-AzJsonArray { return @($script:serverConnections) }
            Mock Get-GatewaySqlPrivateEndpointReadyAddressEvidence {
                return [ordered]@{
                    privateEndpointNetworkInterfaceId = $script:nicId
                    privateEndpointIpv4Address = $script:privateEndpointIpv4Address
                    privateDnsARecordSetId = $script:recordSetId
                    privateDnsARecordName = $script:serverName
                    privateDnsARecordIpv4Address = $script:privateEndpointIpv4Address
                }
            }
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

        It 'rejects persisted address evidence that differs from the exact live NIC and A-record tuple' {
            $script:evidence.privateDnsARecordIpv4Address = '10.42.1.5'

            { Test-GatewaySqlPrivateEndpointEvidence `
                -Config $script:config -Foundation $script:foundation `
                -SqlServerFqdn "$script:serverName.database.windows.net" `
                -Evidence $script:evidence -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint } |
                Should -Throw '*private endpoint, approval, subnet*'
        }
    }
}

Describe 'Bounded SQL private endpoint NIC and A-record readiness' {
    InModuleScope Azure {
        BeforeEach {
            $script:subscriptionId = '11111111-1111-4111-8111-111111111111'
            $script:resourceGroupScope = "/subscriptions/$script:subscriptionId/resourceGroups/rg-safe-dev"
            $script:serverName = 'sql-safe-dev'
            $script:privateEndpointId = "$script:resourceGroupScope/providers/Microsoft.Network/privateEndpoints/pe-$script:serverName"
            $script:nicId = "$script:resourceGroupScope/providers/Microsoft.Network/networkInterfaces/pe-$script:serverName.nic.33333333-3333-4333-8333-333333333333".ToLowerInvariant()
            $script:recordSetId = "$script:resourceGroupScope/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net/A/$script:serverName"
            $script:privateEndpointIpv4Address = '10.42.1.4'
            $script:config = [pscustomobject]@{
                subscriptionId = $script:subscriptionId
                resourceGroupName = 'rg-safe-dev'
                projectName = 'safe'
                environment = 'dev'
                location = 'koreacentral'
            }
            $script:foundation = [pscustomobject]@{
                privateEndpointSubnetId = "$script:resourceGroupScope/providers/Microsoft.Network/virtualNetworks/vnet-safe-dev/subnets/snet-private-endpoints"
            }
            $script:recordReadCount = 0
            $script:recordMode = 'exact'
            Mock Start-Sleep { }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                if ($Arguments[0] -ceq 'network' -and $Arguments[1] -ceq 'private-endpoint') {
                    return [pscustomobject]@{
                        id = $script:privateEndpointId
                        name = "pe-$script:serverName"
                        location = 'koreacentral'
                        provisioningState = 'Succeeded'
                        subnet = [pscustomobject]@{ id = $script:foundation.privateEndpointSubnetId }
                        networkInterfaces = @([pscustomobject]@{ id = $script:nicId })
                    }
                }
                if ($Arguments[0] -ceq 'resource') {
                    return [pscustomobject]@{
                        id = $script:nicId
                        type = 'Microsoft.Network/networkInterfaces'
                        name = "pe-$script:serverName.nic.33333333-3333-4333-8333-333333333333"
                        location = 'koreacentral'
                        properties = [pscustomobject]@{
                            provisioningState = 'Succeeded'
                            privateEndpoint = [pscustomobject]@{ id = $script:privateEndpointId }
                            ipConfigurations = @([pscustomobject]@{ properties = [pscustomobject]@{
                                subnet = [pscustomobject]@{ id = $script:foundation.privateEndpointSubnetId }
                                privateIPAddress = $script:privateEndpointIpv4Address
                            } })
                        }
                    }
                }
                if ($Arguments[0] -ceq 'network' -and $Arguments[1] -ceq 'private-dns') {
                    $script:recordReadCount++
                    $records = switch ($script:recordMode) {
                        'delayed' { if ($script:recordReadCount -eq 1) { @() } else { @([pscustomobject]@{ ipv4Address = $script:privateEndpointIpv4Address }) } }
                        'extra' { @([pscustomobject]@{ ipv4Address = $script:privateEndpointIpv4Address }, [pscustomobject]@{ ipv4Address = '10.42.1.5' }) }
                        'mismatch' { @([pscustomobject]@{ ipv4Address = '10.42.1.5' }) }
                        default { @([pscustomobject]@{ ipv4Address = $script:privateEndpointIpv4Address }) }
                    }
                    return [pscustomobject]@{
                        id = $script:recordSetId
                        name = $script:serverName
                        fqdn = "$script:serverName.privatelink.database.windows.net."
                        aRecords = $records
                    }
                }
                throw 'Unexpected SQL private-endpoint address readback.'
            }
        }

        It 'derives one exact NIC IPv4 and requires the sole A-record to equal it' {
            $result = Get-GatewaySqlPrivateEndpointReadyAddressEvidence `
                -Config $script:config -Foundation $script:foundation `
                -SqlServerFqdn "$script:serverName.database.windows.net" `
                -MaximumAttempts 1 -PollIntervalSeconds 0

            [string]$result.privateEndpointNetworkInterfaceId | Should -BeExactly $script:nicId
            [string]$result.privateEndpointIpv4Address | Should -BeExactly $script:privateEndpointIpv4Address
            [string]$result.privateDnsARecordSetId | Should -BeExactly $script:recordSetId.ToLowerInvariant()
            [string]$result.privateDnsARecordName | Should -BeExactly $script:serverName
            [string]$result.privateDnsARecordIpv4Address | Should -BeExactly $script:privateEndpointIpv4Address
        }

        It 'uses injectable polling bounds and converges without a real sleep in tests' {
            $script:recordMode = 'delayed'

            $result = Get-GatewaySqlPrivateEndpointReadyAddressEvidence `
                -Config $script:config -Foundation $script:foundation `
                -SqlServerFqdn "$script:serverName.database.windows.net" `
                -MaximumAttempts 2 -PollIntervalSeconds 0

            [string]$result.privateEndpointIpv4Address | Should -BeExactly $script:privateEndpointIpv4Address
            $script:recordReadCount | Should -Be 2
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It 'fails closed on an extra or mismatched A-record set' {
            foreach ($mode in @('extra', 'mismatch')) {
                $script:recordMode = $mode
                { Get-GatewaySqlPrivateEndpointReadyAddressEvidence `
                    -Config $script:config -Foundation $script:foundation `
                    -SqlServerFqdn "$script:serverName.database.windows.net" `
                    -MaximumAttempts 1 -PollIntervalSeconds 0 } |
                    Should -Throw '*did not converge within the bounded management-plane readiness window*'
            }
        }
    }
}
