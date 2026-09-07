$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module "$script:RepositoryRoot/bootstrap/modules/Common.psm1" -Force
Import-Module "$script:RepositoryRoot/bootstrap/modules/Experience.psm1" -Force
Import-Module "$script:RepositoryRoot/bootstrap/modules/Azure.psm1" -Force
Import-Module "$script:RepositoryRoot/bootstrap/modules/Entra.psm1" -Force
Import-Module "$script:RepositoryRoot/bootstrap/modules/PurviewPackage.psm1" -Force
Import-Module "$script:RepositoryRoot/bootstrap/modules/PurviewExecutor.psm1" -Force -ErrorAction Stop
BeforeAll { $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')) }

Describe 'Dedicated executor API identity integration' {
    InModuleScope PurviewExecutor {
        BeforeEach {
            $script:ctx = @{
                deploymentOwnershipId = '11111111-1111-4111-8111-111111111111'
                sourceFingerprint = 'sha256:' + ('a' * 64)
                tenantId = '22222222-2222-4222-8222-222222222222'
                workerPrincipalId = '33333333-3333-4333-8333-333333333333'
                workerApplicationId = '44444444-4444-4444-8444-444444444444'
            }
            $script:ops = [ordered]@{}
            $script:app = $null
            $script:principal = $null
            $script:assignments = @()
            $script:saved = 0
            $script:posts = 0
            $script:fixtureApp = [pscustomobject]@{
                id = '55555555-5555-4555-8555-555555555555'
                appId = '66666666-6666-4666-8666-666666666666'
                displayName = "A365 Gateway Purview Executor - $($script:ctx.deploymentOwnershipId)"
                signInAudience = 'AzureADMyOrg'
                tags = @(Get-BootstrapApplicationTags -DeploymentOwnershipId $script:ctx.deploymentOwnershipId) +
                    @("A365GatewaySource:$($script:ctx.sourceFingerprint)", 'A365GatewayPurviewExecutor')
                identifierUris = @(); appRoles = @((Get-PurviewExecutorRole))
                requiredResourceAccess = @(); passwordCredentials = @(); keyCredentials = @()
                isFallbackPublicClient = $false
                api = [pscustomobject]@{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @(); acceptMappedClaims = $false }
                web = [pscustomobject]@{ redirectUris = @() }; spa = [pscustomobject]@{ redirectUris = @() }
                publicClient = [pscustomobject]@{ redirectUris = @() }
            }
            Mock Get-ExactApplicationByDisplayName { $script:app }
            Mock Get-ServicePrincipalByAppId { $script:principal }
            Mock Get-BoundedGraphCollection {
                if ($InitialUrl -match '/appRoleAssignedTo$') { return $script:assignments }
                if ($InitialUrl -match '/(federatedIdentityCredentials|appRoleAssignments|transitiveMemberOf)$') { return @() }
                throw 'Unexpected Graph collection'
            }
            Mock Invoke-AzJson {
                return [pscustomobject]@{ id = $script:ctx.workerPrincipalId; appId = $script:ctx.workerApplicationId; servicePrincipalType = 'ManagedIdentity' }
            }
            Mock Invoke-GraphJsonBody {
                $script:saved | Should -BeGreaterThan 0
                $script:posts++
                if ($Url -ceq 'https://graph.microsoft.com/v1.0/applications') {
                    $script:ops.application.status | Should -Be 'Started'
                    $Body.api.requestedAccessTokenVersion | Should -Be 2
                    $Body.requiredResourceAccess.Count | Should -Be 0
                    $Body.appRoles[0].value | Should -Be 'Purview.Executor.Invoke'
                    $script:app = $script:fixtureApp
                }
                elseif ($Method -ceq 'PATCH') {
                    $script:ops.audience.status | Should -Be 'Started'
                    $script:app.identifierUris = @($Body.identifierUris)
                }
                elseif ($Url -ceq 'https://graph.microsoft.com/v1.0/servicePrincipals') {
                    $script:ops.principal.status | Should -Be 'Started'
                    $Body.appRoleAssignmentRequired | Should -BeTrue
                    $script:principal = [pscustomobject]@{
                        id = '77777777-7777-4777-8777-777777777777'; appId = $script:app.appId
                        servicePrincipalType = 'Application'; accountEnabled = $true; appRoleAssignmentRequired = $true
                        tags = @($Body.tags); servicePrincipalNames = @($script:app.appId, "api://$($script:app.appId)")
                        appRoles = @((Get-PurviewExecutorRole)); passwordCredentials = @(); keyCredentials = @()
                        oauth2PermissionScopes = @(); alternativeNames = @()
                    }
                }
                elseif ($Url -match '/appRoleAssignedTo$') {
                    $script:ops.invokeRole.status | Should -Be 'Started'
                    $Body.principalId | Should -Be $script:ctx.workerPrincipalId
                    $script:assignments = @([pscustomobject]@{
                        id = 'safe-assignment'; principalId = $Body.principalId
                        resourceId = $Body.resourceId; appRoleId = $Body.appRoleId; principalType = 'ServicePrincipal'
                    })
                }
                else { throw 'Unexpected Graph mutation' }
            }
        }

        It 'creates the dedicated API/SP/audience and grants only the worker once; redelivery is read-only' {
            $identity = Ensure-PurviewExecutorIdentity -Context $script:ctx -Operations $script:ops -Checkpoint { $script:saved++ }
            $identity.applicationId | Should -Be $script:fixtureApp.appId
            $script:posts | Should -Be 4
            $null = Ensure-PurviewExecutorIdentity -Context $script:ctx -Operations $script:ops -Checkpoint { $script:saved++ }
            $script:posts | Should -Be 4
        }

        It 'does not adopt an application without a durable creation intent' {
            $script:app = $script:fixtureApp
            { Ensure-PurviewExecutorIdentity -Context $script:ctx -Operations $script:ops -Checkpoint { $script:saved++ } } | Should -Throw '*unowned*'
            $script:posts | Should -Be 0
        }

        It 'refuses extra caller grants without deleting or regranting anything' {
            $null = Ensure-PurviewExecutorIdentity -Context $script:ctx -Operations $script:ops -Checkpoint { $script:saved++ }
            $script:assignments += $script:assignments[0]
            { Ensure-PurviewExecutorIdentity -Context $script:ctx -Operations $script:ops -Checkpoint { $script:saved++ } } | Should -Throw '*only*exact worker*'
            $script:posts | Should -Be 4
        }

        It 'fails closed for a caller that is not the exact system managed identity' {
            Mock Invoke-AzJson { [pscustomobject]@{ id = $script:ctx.workerPrincipalId; appId = $script:ctx.workerApplicationId; servicePrincipalType = 'Application' } }
            { Ensure-PurviewExecutorIdentity -Context $script:ctx -Operations $script:ops -Checkpoint { $script:saved++ } } | Should -Throw '*accepted worker*'
            $script:posts | Should -Be 3
        }

        It 'rejects application credentials, delegated scopes and unapproved roles after creation' {
            $null = Ensure-PurviewExecutorIdentity -Context $script:ctx -Operations $script:ops -Checkpoint { $script:saved++ }
            $script:app.passwordCredentials = @(@{ keyId = '88888888-8888-4888-8888-888888888888' })
            { Ensure-PurviewExecutorIdentity -Context $script:ctx -Operations $script:ops -Checkpoint { $script:saved++ } } | Should -Throw '*empty collection*'
            $script:app.passwordCredentials = @()
            $script:app.api.oauth2PermissionScopes = @(@{ value = 'unapproved' })
            { Ensure-PurviewExecutorIdentity -Context $script:ctx -Operations $script:ops -Checkpoint { $script:saved++ } } | Should -Throw '*empty collection*'
            $script:posts | Should -Be 4
        }

        It 'performs no writes while verifying a completed identity' {
            $null = Ensure-PurviewExecutorIdentity -Context $script:ctx -Operations $script:ops -Checkpoint { $script:saved++ }
            $saved = $script:saved
            $null = Ensure-PurviewExecutorIdentity -Context $script:ctx -Operations $script:ops -Checkpoint { throw 'No writes in verification' } -ReadOnly
            $script:saved | Should -Be $saved
            $script:posts | Should -Be 4
        }
    }
}

Describe 'Fresh Purview executor durable dispatch' {
    BeforeEach {
        $script:operations = [ordered]@{}
        $script:saves = 0
        $script:calls = 0
        $script:present = $false
        $script:save = { $script:saves++ }
        $script:discover = {
            if ($script:present) { return @{ id = 'exact-resource' } }
            return $null
        }

        $script:mutate = {
            $script:saves | Should -BeGreaterThan 0
            $script:operations.create.status | Should -Be 'Started'
            $script:calls++
            $script:present = $true
        }
    }

    It 'persists intent before a single mutation and independently reads the result' {
        $result = Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint $script:save -Discover $script:discover -Mutate $script:mutate
        $result.id | Should -Be 'exact-resource'
        $script:calls | Should -Be 1
        $script:operations.create.status | Should -Be 'Completed'
        $null = Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint $script:save -Discover $script:discover -Mutate $script:mutate
        $script:calls | Should -Be 1
    }

    It 'never resubmits after a lost mutation result even when discovery is absent' {
        { Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint $script:save -Discover $script:discover -Mutate { $script:calls++; throw 'Synthetic transport failure' } } | Should -Throw
        { Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint $script:save -Discover $script:discover -Mutate $script:mutate } | Should -Throw '*ambiguous*'
        $script:calls | Should -Be 1
    }

    It 'recovers a started mutation by independent exact readback only' {
        { Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint $script:save -Discover $script:discover -Mutate { $script:present = $true; throw 'Synthetic lost response' } } | Should -Throw
        $result = Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint $script:save -Discover $script:discover -Mutate { throw 'Must not dispatch' }
        $result.id | Should -Be 'exact-resource'
    }

    It 'refuses adoption without its own prior intent' {
        $script:present = $true
        { Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint $script:save -Discover $script:discover -Mutate $script:mutate } | Should -Throw '*unowned*'
        $script:calls | Should -Be 0
    }

    It 'does not mutate after unknown discovery or a failed durable checkpoint' {
        { Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint $script:save -Discover { throw 'Unknown discovery' } -Mutate $script:mutate } | Should -Throw
        $script:operations.Count | Should -Be 0
        { Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint { throw 'Disk failure' } -Discover $script:discover -Mutate $script:mutate } | Should -Throw
        $script:calls | Should -Be 0
    }

    It 'rejects a changed target before even discovering it' {
        $null = Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint $script:save -Discover $script:discover -Mutate $script:mutate
        { Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'other' } `
            -Checkpoint $script:save -Discover { throw 'Must not read changed target' } -Mutate $script:mutate } | Should -Throw '*intent*'
    }

    It 'fails closed on missing or changed completed evidence' {
        $null = Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint $script:save -Discover $script:discover -Mutate $script:mutate
        { Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint $script:save -Discover { @{ id = 'different' } } -Mutate $script:mutate } | Should -Throw '*readback*'
        $script:present = $false
        { Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint $script:save -Discover $script:discover -Mutate $script:mutate } | Should -Throw
        $script:calls | Should -Be 1
    }

    It 'never creates in verification mode' {
        { Invoke-PurviewBootstrapOnce -Operations $script:operations -Name create -Intent @{ target = 'exact' } `
            -Checkpoint $script:save -Discover $script:discover -Mutate $script:mutate -ReadOnly } | Should -Throw
        $script:saves | Should -Be 0
        $script:calls | Should -Be 0
    }
}

Describe 'Executor exact readback shape guards' {
    It 'accepts only complete ARM arrays including proven empty results' {
        { Assert-PurviewExecutorCompleteArmCollection -Collection ([pscustomobject]@{ value = @() }) } | Should -Not -Throw
        { Assert-PurviewExecutorCompleteArmCollection -Collection ([pscustomobject]@{ value = @(@{ id = 'safe' }); nextLink = $null }) } | Should -Not -Throw
        { Assert-PurviewExecutorCompleteArmCollection -Collection ([pscustomobject]@{ value = @(); nextLink = 'https://management.azure.com/next-page' }) } | Should -Throw '*truncated*'
        { Assert-PurviewExecutorCompleteArmCollection -Collection ([pscustomobject]@{ value = $null }) } | Should -Throw '*unknown*'
    }

    It 'rejects a nonaccepted plan before source or infrastructure access' {
        { Get-PurviewExecutorFreshContext -Config @{} -State @{} -Foundation @{} -Runtime @{} -Automation @{} -Database @{} } |
            Should -Throw '*accepted bootstrap plan*'
    }

    It 'rejects empty or malformed application-role contracts' {
        { Assert-PurviewExecutorRole -Object ([pscustomobject]@{ appRoles = @() }) } | Should -Throw
        $role = Get-PurviewExecutorRole
        $role.allowedMemberTypes = @('Application', 'User')
        { Assert-PurviewExecutorRole -Object ([pscustomobject]@{ appRoles = @($role) }) } | Should -Throw
    }
}

Describe 'Executor independent private storage network readback' {
    InModuleScope PurviewExecutor {
        BeforeEach {
            $script:scope = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe'
            $script:storageId = "$script:scope/providers/Microsoft.Storage/storageAccounts/safe"
            $script:peId = "$script:scope/providers/Microsoft.Network/privateEndpoints/pe-safe"
            $script:vnetId = "$script:scope/providers/Microsoft.Network/virtualNetworks/vnet-safe"
            $script:subnetId = "$script:vnetId/subnets/snet-private-endpoints"
            $script:zoneId = "$script:scope/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
            $script:envId = "$script:scope/providers/Microsoft.App/managedEnvironments/safe"
            $script:ctxNetwork = @{ deploymentOwnershipId = '22222222-2222-4222-8222-222222222222'; sourceFingerprint = 'sha256:' + ('a' * 64) }
            $script:tags = @{ bootstrapOwnershipId = $script:ctxNetwork.deploymentOwnershipId; bootstrapSourceFingerprint = $script:ctxNetwork.sourceFingerprint }
            $script:resources = @{}
            $script:resources[$script:storageId] = @{
                id = $script:storageId; name = 'safe'; tags = $script:tags
                properties = @{
                    publicNetworkAccess = 'Disabled'; allowBlobPublicAccess = $false; allowSharedKeyAccess = $false
                    privateEndpointConnections = @(@{ properties = @{ privateLinkServiceConnectionState = @{ status = 'Approved' }; privateEndpoint = @{ id = $script:peId } } })
                }
            }
            $script:resources[$script:peId] = @{
                id = $script:peId; tags = $script:tags
                properties = @{
                    subnet = @{ id = $script:subnetId }; networkInterfaces = @(@{ id = 'safe-nic' })
                    privateLinkServiceConnections = @(@{ properties = @{ privateLinkServiceId = $script:storageId; groupIds = @('blob'); privateLinkServiceConnectionState = @{ status = 'Approved' } } })
                }
            }
            $script:resources['safe-nic'] = @{ properties = @{ ipConfigurations = @(@{ properties = @{ privateIPAddress = '10.42.2.5'; subnet = @{ id = $script:subnetId } } }) } }
            $script:resources["$script:peId/privateDnsZoneGroups"] = @{
                value = @(@{ properties = @{ privateDnsZoneConfigs = @(@{ properties = @{ privateDnsZoneId = $script:zoneId } }) } })
            }
            $script:resources["$script:zoneId/virtualNetworkLinks"] = @{
                value = @(@{ properties = @{ virtualNetwork = @{ id = $script:vnetId }; registrationEnabled = $false; virtualNetworkLinkState = 'Completed' } })
            }
            $script:resources["$script:zoneId/A/safe"] = @{ properties = @{ aRecords = @(@{ ipv4Address = '10.42.2.5' }) } }
            $script:resources[$script:vnetId] = @{ id = $script:vnetId; tags = $script:tags; properties = @{ addressSpace = @{ addressPrefixes = @('10.42.0.0/16') } } }
            $script:resources[$script:envId] = @{ id = $script:envId; tags = $script:tags; properties = @{ vnetConfiguration = @{ infrastructureSubnetId = "$script:vnetId/subnets/snet-container-apps" } } }
            $script:networkArgs = @{
                Config = @{ subscriptionId = '11111111-1111-4111-8111-111111111111'; resourceGroupName = 'rg-safe' }
                Foundation = @{ privateEndpointSubnetId = $script:subnetId; virtualNetworkName = 'vnet-safe'; containerAppsEnvironmentId = $script:envId }
                Runtime = @{ storageAccountId = $script:storageId }; Context = $script:ctxNetwork
            }
            Mock Get-PurviewExecutorArmResource {
                if (-not $script:resources.Contains($Id)) { throw 'Unexpected metadata target' }
                return $script:resources[$Id]
            }
        }

        It 'proves the exact owned storage, NIC, private DNS and Container Apps network independently' {
            $network = Get-PurviewExecutorStorageNetwork @script:networkArgs
            $network.privateEndpointIp | Should -Be '10.42.2.5'
            $network.storageAccountName | Should -Be 'safe'
        }

        It 'rejects public or shared-key-enabled storage before publication' {
            $script:resources[$script:storageId].properties.publicNetworkAccess = 'Enabled'
            { Get-PurviewExecutorStorageNetwork @script:networkArgs } | Should -Throw '*private*'
            $script:resources[$script:storageId].properties.publicNetworkAccess = 'Disabled'
            $script:resources[$script:storageId].properties.allowSharedKeyAccess = $true
            { Get-PurviewExecutorStorageNetwork @script:networkArgs } | Should -Throw '*Entra-only*'
        }

        It 'rejects a different endpoint target and DNS address instead of accepting private-looking IPs' {
            $script:resources[$script:peId].properties.privateLinkServiceConnections[0].properties.privateLinkServiceId = 'other-storage'
            { Get-PurviewExecutorStorageNetwork @script:networkArgs } | Should -Throw '*identity*'
            $script:resources[$script:peId].properties.privateLinkServiceConnections[0].properties.privateLinkServiceId = $script:storageId
            $script:resources["$script:zoneId/A/safe"].properties.aRecords[0].ipv4Address = '10.42.2.6'
            { Get-PurviewExecutorStorageNetwork @script:networkArgs } | Should -Throw '*DNS address*'
        }

        It 'rejects an unowned private endpoint and a publisher environment in another subnet' {
            $script:resources[$script:peId].tags = @{ bootstrapOwnershipId = 'other'; bootstrapSourceFingerprint = $script:ctxNetwork.sourceFingerprint }
            { Get-PurviewExecutorStorageNetwork @script:networkArgs } | Should -Throw '*ownership*'
            $script:resources[$script:peId].tags = $script:tags
            $script:resources[$script:envId].properties.vnetConfiguration.infrastructureSubnetId = "$script:vnetId/subnets/other"
            { Get-PurviewExecutorStorageNetwork @script:networkArgs } | Should -Throw '*outside*'
        }
    }
}

Describe 'Fresh Full Core Custom executor integration source contract' {
    It 'keeps optional-off independent of package tooling, source and provider calls' {
        Install-BootstrapPurviewExecutor -Config @{ purview = @{ enabled = $false } } `
            -State @{} -StatePath 'unused' -Foundation @{} -Runtime @{} -Automation @{} -Database @{} |
            Should -BeNullOrEmpty
    }

    Describe 'Fresh installation orchestration ordering and failure closure' {
        InModuleScope PurviewExecutor {
            BeforeEach {
                $script:config = @{ projectName = 'safe'; environment = 'dev'; location = 'koreacentral'; subscriptionId = '11111111-1111-4111-8111-111111111111'; resourceGroupName = 'rg-safe'; purview = @{ enabled = $true } }
                $script:state = [ordered]@{}
                $script:order = [Collections.Generic.List[string]]::new()
                $script:source = 'sha256:' + ('a' * 64)
                $script:context = @{
                    deploymentOwnershipId = '22222222-2222-4222-8222-222222222222'; sourceFingerprint = $script:source
                    workerApplicationId = '33333333-3333-4333-8333-333333333333'; workerPrincipalId = '44444444-4444-4444-8444-444444444444'
                    automationApplicationId = '55555555-5555-4555-8555-555555555555'; automationServicePrincipalId = '66666666-6666-4666-8666-666666666666'
                    apiPrincipalId = '77777777-7777-4777-8777-777777777777'; runtimeClientId = '88888888-8888-4888-8888-888888888888'
                    runtimePrincipalId = '99999999-9999-4999-8999-999999999999'; certificateName = 'purview-automation-certificate'; organization = 'safe.onmicrosoft.com'
                }
                $script:foundation = @{
                    acrLoginServer = 'acrsafe.azurecr.io'; virtualNetworkName = 'vnet-safe-dev'
                    privateEndpointSubnetId = 'safe-private-subnet'; containerAppsEnvironmentId = 'safe-private-environment'
                    runtimeImagePullIdentityId = 'safe-pull-identity'
                }
                $script:hostOutput = @{
                    executorId = @{ value = 'safe-host' }; executorPrincipalId = @{ value = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }
                    executorEndpoint = @{ value = 'https://safe.azurewebsites.net' }; executorBinding = @{ value = @{ PackageDigest = 'sha256:' + ('b' * 64) } }
                    packageContainerUri = @{ value = 'https://safe.blob.core.windows.net/purview-executor-packages' }
                }
                Mock Get-PurviewExecutorFreshContext { $script:context }
                Mock Get-BootstrapExecutionSourceRoot { 'C:/synthetic-source' }
                Mock Save-BootstrapState {}
                Mock Invoke-AzTsv { 'Registered' }
                Mock Invoke-BootstrapCommand {
                    $FilePath | Should -Be 'pwsh'
                    $ArgumentList | Should -Contain '-ExpectedSourceFingerprint'
                    $script:order.Add('package')
                }
                Mock Read-PurviewExecutorPackage {
                    @{ receipt = @{ packageDigest = 'sha256:' + ('b' * 64); runtimeManifestDigest = 'sha256:' + ('c' * 64); packageBytes = 512 }; receiptFingerprint = 'sha256:' + ('d' * 64) }
                }
                Mock Ensure-PurviewExecutorIdentity {
                    $script:order.Add('identity')
                    @{ applicationId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; servicePrincipalId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
                }
                Mock Build-PurviewExecutorPublisher { $script:order.Add('image'); @{ digest = 'sha256:' + ('e' * 64) } }
                Mock Get-PurviewExecutorStorageNetwork { $script:order.Add('network'); @{ storageAccountName = 'safe'; privateEndpointIp = '10.42.2.5' } }
                Mock Invoke-AzJsonArray { @() }
                Mock Get-PurviewExecutorArmResource { [pscustomobject]@{ properties = @{ subnets = @() }; value = @() } }
                Mock Invoke-PurviewExecutorDeployment {
                    $Operations[$Name] = @{ status = 'Completed' }
                    if ($Name -match 'executor-publisher') {
                        $script:order.Add('publisher')
                        return @{ jobId = @{ value = 'safe-job' }; jobName = @{ value = 'safe-job' }; jobPrincipalId = @{ value = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd' } }
                    }
                    $script:order.Add($(if ($Parameters.enableRuntime) { 'enable' } else { 'host' }))
                    return $script:hostOutput
                }
                Mock Assert-PurviewExecutorHost { $script:order.Add($(if ($Enabled) { 'verify-enabled' } else { 'verify-disabled' })) }
                Mock Assert-PurviewPublisherJob { $script:order.Add('verify-publisher'); @{ containers = @() } }
                Mock Start-PurviewPublisherOnce { $script:order.Add('publish'); @{ name = 'safe-execution' } }
            }

            It 'installs selected <preset> through package, identity, private publisher, then enabled host' -ForEach @(
                @{ preset = 'FullEvaluation' }, @{ preset = 'Custom' }
            ) {
                $script:config.capabilityPreset = $preset
                $result = Install-BootstrapPurviewExecutor -Config $script:config -State $script:state -StatePath 'safe-state' `
                    -Foundation $script:foundation -Runtime @{ storageAccountId = 'safe-storage' } -Automation @{} -Database @{}
                $result.enabled | Should -BeTrue
                $result.runtimeReadiness | Should -Be 'NotClaimedByBootstrap'
                $script:state.freshPurviewExecutor.status | Should -Be 'Installed'
                ($script:order -join '|') | Should -Be 'package|identity|image|network|host|verify-disabled|publisher|verify-publisher|publish|enable|verify-enabled'
            }

            It 'does not enable the host after uncertain publication' {
                Mock Start-PurviewPublisherOnce { throw 'Synthetic unknown job outcome' }
                { Install-BootstrapPurviewExecutor -Config $script:config -State $script:state -StatePath 'safe-state' `
                    -Foundation $script:foundation -Runtime @{ storageAccountId = 'safe-storage' } -Automation @{} -Database @{} } | Should -Throw
                $script:order | Should -Not -Contain 'enable'
                $script:state.freshPurviewExecutor.status | Should -Be 'Installing'
            }

            It 'verifies installed evidence without rebuilding, saving state or needing local package bytes' {
                $null = Install-BootstrapPurviewExecutor -Config $script:config -State $script:state -StatePath 'safe-state' `
                    -Foundation $script:foundation -Runtime @{ storageAccountId = 'safe-storage' } -Automation @{} -Database @{}
                Mock Save-BootstrapState { throw 'Verification must not save state' }
                Mock Read-PurviewExecutorPackage { throw 'Verification must not read workstation package' }
                Mock Invoke-BootstrapCommand { throw 'Verification must not build' }
                $null = Install-BootstrapPurviewExecutor -Config $script:config -State $script:state -StatePath 'safe-state' `
                    -Foundation $script:foundation -Runtime @{ storageAccountId = 'safe-storage' } -Automation @{} -Database @{} -ReadOnly
                Should -Invoke Ensure-PurviewExecutorIdentity -Times 1 -Exactly -ParameterFilter { $ReadOnly }
                Should -Invoke Start-PurviewPublisherOnce -Times 1 -Exactly -ParameterFilter { $ReadOnly }
            }

            It 'does not treat an already completed old runtime as a fresh install' {
                $script:state.steps = @{ 'Gateway runtime deployment' = @{ status = 'Completed' } }
                { Install-BootstrapPurviewExecutor -Config $script:config -State $script:state -StatePath 'safe-state' `
                    -Foundation $script:foundation -Runtime @{} -Automation @{} -Database @{} } | Should -Throw '*cannot upgrade*'
                Should -Invoke Invoke-BootstrapCommand -Times 0
            }

            It 'refuses changed accepted context before package or provider work' {
                $null = Install-BootstrapPurviewExecutor -Config $script:config -State $script:state -StatePath 'safe-state' `
                    -Foundation $script:foundation -Runtime @{ storageAccountId = 'safe-storage' } -Automation @{} -Database @{}
                $script:state.freshPurviewExecutor.context = @{ sourceFingerprint = 'sha256:' + ('f' * 64) }
                $script:order.Clear()
                { Install-BootstrapPurviewExecutor -Config $script:config -State $script:state -StatePath 'safe-state' `
                    -Foundation $script:foundation -Runtime @{} -Automation @{} -Database @{} } | Should -Throw '*immutable fresh context*'
                $script:order.Count | Should -Be 0
            }
        }
    }

    It 'wires the public engine and worker without adding a bootstrap stage' {
        (Get-GatewayBootstrapStepNames).Count | Should -Be 19
        $engine = Get-Content "$root/bootstrap/bootstrap.ps1" -Raw
        $engine | Should -Match 'Install-BootstrapPurviewExecutor'
        $engine | Should -Match '\$purviewExecutorParameters.PurviewExecutor = \$purviewExecutor'
        $main = Get-Content "$root/infrastructure/bicep/main.bicep" -Raw
        $main | Should -Match 'purviewExecutorEnabled'
        $main | Should -Match 'enableWorkerKeyVaultSecretsUser:.*!purviewExecutorEnabled'
        $worker = Get-Content "$root/infrastructure/bicep/modules/container-app-worker.bicep" -Raw
        $worker | Should -Match 'PurviewExecutor__Enabled'
        $worker | Should -Match 'PurviewExecutor__Binding__'
        $worker | Should -Match 'gateway-provisioning-v3'
        $worker | Should -Match 'gateway-protection-admin-v1'
    }
}
