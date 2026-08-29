#Requires -Version 7.0

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module (Join-Path $repoRoot 'operations' 'RuntimeImagePull.psm1') -Force

    $script:subscriptionId = '11111111-1111-4111-8111-111111111111'
    $script:resourceGroup = 'rg-gateway'
    $script:apiName = 'ca-gateway-api-dev'
    $script:workerName = 'ca-gateway-worker-dev-v3'
    $script:acrScope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ContainerRegistry/registries/acrgateway"
    $script:acrLoginServer = 'acrgateway.azurecr.io'
    $script:apiImage = "$acrLoginServer/gateway-api@sha256:$('a' * 64)"
    $script:workerImage = "$acrLoginServer/gateway-worker@sha256:$('b' * 64)"
    $script:identityId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-runtime-pull"
    $script:identityPrincipalId = '22222222-2222-4222-8222-222222222222'
    $script:acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    $script:roleDefinitionId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/$acrPullRoleId"
    $script:dedicatedAssignmentName = Get-ArmDeterministicGuid -Values @(
        $acrScope,
        $identityId,
        $acrPullRoleId)
    $script:dedicatedAssignmentId = "$acrScope/providers/Microsoft.Authorization/roleAssignments/$dedicatedAssignmentName"
}

Describe 'Runtime image-pull deployment contract' {
    It 'matches the documented ARM guid UUID-v5 algorithm' {
        Get-ArmDeterministicGuid -Values @('hello', 'world') |
            Should -Be 'a5b868f8-11fe-567a-ace0-e77cc87f104e'
    }

    It 'rejects every partial dedicated identity receipt combination' -TestCases @(
        @{ Identity = 'identity'; Principal = ''; Role = '' }
        @{ Identity = ''; Principal = 'principal'; Role = '' }
        @{ Identity = ''; Principal = ''; Role = 'role' }
        @{ Identity = 'identity'; Principal = 'principal'; Role = '' }
        @{ Identity = 'identity'; Principal = ''; Role = 'role' }
        @{ Identity = ''; Principal = 'principal'; Role = 'role' }
    ) {
        param($Identity, $Principal, $Role)

        {
            Assert-GatewayRuntimeImagePullContract `
                -SubscriptionId $subscriptionId `
                -ResourceGroup $resourceGroup `
                -ApiContainerAppName $apiName `
                -WorkerContainerAppName $workerName `
                -RuntimeImagePullIdentityId $Identity `
                -RuntimeImagePullIdentityPrincipalId $Principal `
                -RuntimeImagePullAcrPullRoleAssignmentId $Role
        } | Should -Throw '*either all empty*or all populated*'
    }

    It 'rejects empty legacy mode unless the caller explicitly authorizes existing-deployment readback' {
        {
            Assert-GatewayRuntimeImagePullContract `
                -SubscriptionId $subscriptionId `
                -ResourceGroup $resourceGroup `
                -ApiContainerAppName $apiName `
                -WorkerContainerAppName $workerName
        } | Should -Throw '*fresh private-image deployment cannot use the legacy*'
    }

    It 'rejects legacy system-registry workloads that retain any attached user-assigned identity' {
        $expectedSubscriptionId = $subscriptionId
        $expectedResourceGroup = $resourceGroup
        $expectedIdentityId = $identityId
        $invoker = {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'containerapp') {
                $name = $Arguments[[array]::IndexOf($Arguments, '--name') + 1]
                return @{
                    id = "/subscriptions/$expectedSubscriptionId/resourceGroups/$expectedResourceGroup/providers/Microsoft.App/containerApps/$name"
                    principalId = '44444444-4444-4444-8444-444444444444'
                    identityType = 'SystemAssigned, UserAssigned'
                    userAssignedIdentities = @{ $expectedIdentityId = @{} }
                    registries = @(@{ server = 'acrgateway.azurecr.io'; identity = 'system' })
                } | ConvertTo-Json -Compress -Depth 6
            }
            throw 'unexpected command'
        }.GetNewClosure()

        {
            Assert-GatewayRuntimeImagePullContract `
                -SubscriptionId $subscriptionId `
                -ResourceGroup $resourceGroup `
                -ApiContainerAppName $apiName `
                -WorkerContainerAppName $workerName `
                -AllowExistingLegacySystemAssignedImagePull `
                -AzureInvoker $invoker
        } | Should -Throw '*exactly its system identity*'
    }

    It 'accepts one exact dedicated identity and deterministic AcrPull receipt' {
        $calls = [System.Collections.Generic.List[string[]]]::new()
        $expectedIdentityId = $identityId
        $expectedPrincipalId = $identityPrincipalId
        $expectedAssignmentId = $dedicatedAssignmentId
        $expectedAssignmentName = $dedicatedAssignmentName
        $expectedAcrScope = $acrScope
        $expectedRoleDefinitionId = $roleDefinitionId
        $invoker = {
            param([string[]]$Arguments)
            $calls.Add($Arguments)
            if ($Arguments[0] -eq 'identity') {
                return @{
                    id = $expectedIdentityId
                    principalId = $expectedPrincipalId
                } | ConvertTo-Json -Compress
            }
            if ($Arguments[0] -eq 'role') {
                return @(@{
                    id = $expectedAssignmentId
                    name = $expectedAssignmentName
                    principalId = $expectedPrincipalId
                    principalType = 'ServicePrincipal'
                    scope = $expectedAcrScope
                    roleDefinitionId = $expectedRoleDefinitionId
                    condition = $null
                    conditionVersion = $null
                    delegatedManagedIdentityResourceId = $null
                }) | ConvertTo-Json -Compress
            }
            if ($Arguments[0] -eq 'acr') {
                return @{
                    id = $expectedAcrScope
                    loginServer = 'acrgateway.azurecr.io'
                } | ConvertTo-Json -Compress
            }
            if ($Arguments[0] -eq 'containerapp') {
                return ConvertTo-Json -InputObject @() -Compress
            }
            throw 'unexpected command'
        }.GetNewClosure()

        $result = Assert-GatewayRuntimeImagePullContract `
            -SubscriptionId $subscriptionId `
            -ResourceGroup $resourceGroup `
            -ApiContainerAppName $apiName `
            -WorkerContainerAppName $workerName `
            -RuntimeImagePullIdentityId $identityId `
            -RuntimeImagePullIdentityPrincipalId $identityPrincipalId `
            -RuntimeImagePullAcrPullRoleAssignmentId $dedicatedAssignmentId `
            -ExpectedAcrName 'acrgateway' `
            -ExpectedAcrLoginServer $acrLoginServer `
            -ApiContainerImage $apiImage `
            -WorkerContainerImage $workerImage `
            -AllowFreshDedicatedImagePull `
            -AzureInvoker $invoker

        $result.Mode | Should -Be 'DedicatedUserAssignedIdentity'
        $result.AllowLegacySystemAssignedImagePull | Should -BeFalse
        $calls.Count | Should -Be 4
        $roleCall = @($calls | Where-Object { $_[0] -eq 'role' })[0]
        $roleCall | Should -Not -Contain '--include-inherited'
        $roleQueryIndex = [array]::IndexOf($roleCall, '--query')
        $roleQueryIndex | Should -BeGreaterThan -1
        $roleCall[$roleQueryIndex + 1] | Should -BeLike '*principalType:principalType*condition:condition*delegatedManagedIdentityResourceId:delegatedManagedIdentityResourceId*'
        foreach ($call in $calls) {
            $call | Should -Contain '--subscription'
            $call | Should -Contain $subscriptionId
        }
    }

    It 'rejects non-exact dedicated role assignment shapes: <Case>' -TestCases @(
        @{ Case = 'conditioned' }
        @{ Case = 'delegated' }
        @{ Case = 'additional direct role' }
        @{ Case = 'wrong principal type' }
    ) {
        param($Case)

        $caseValue = $Case
        $expectedIdentityId = $identityId
        $expectedPrincipalId = $identityPrincipalId
        $expectedAssignmentId = $dedicatedAssignmentId
        $expectedAssignmentName = $dedicatedAssignmentName
        $expectedAcrScope = $acrScope
        $expectedRoleDefinitionId = $roleDefinitionId
        $expectedSubscriptionId = $subscriptionId
        $invoker = {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'identity') {
                return @{ id = $expectedIdentityId; principalId = $expectedPrincipalId } |
                    ConvertTo-Json -Compress
            }
            if ($Arguments[0] -eq 'role') {
                $assignment = @{
                    id = $expectedAssignmentId
                    name = $expectedAssignmentName
                    principalId = $expectedPrincipalId
                    principalType = 'ServicePrincipal'
                    scope = $expectedAcrScope
                    roleDefinitionId = $expectedRoleDefinitionId
                    condition = $null
                    conditionVersion = $null
                    delegatedManagedIdentityResourceId = $null
                }
                if ($caseValue -eq 'conditioned') {
                    $assignment['condition'] = "@Resource[Microsoft.ContainerRegistry/registries:name] StringEquals 'restricted'"
                    $assignment['conditionVersion'] = '2.0'
                }
                elseif ($caseValue -eq 'delegated') {
                    $assignment['delegatedManagedIdentityResourceId'] = $expectedIdentityId
                }
                elseif ($caseValue -eq 'wrong principal type') {
                    $assignment['principalType'] = 'User'
                }
                $assignments = @($assignment)
                if ($caseValue -eq 'additional direct role') {
                    $assignments += @{
                        id = "$expectedAcrScope/providers/Microsoft.Authorization/roleAssignments/66666666-6666-4666-8666-666666666666"
                        name = '66666666-6666-4666-8666-666666666666'
                        principalId = $expectedPrincipalId
                        principalType = 'ServicePrincipal'
                        scope = $expectedAcrScope
                        roleDefinitionId = "/subscriptions/$expectedSubscriptionId/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
                        condition = $null
                        conditionVersion = $null
                        delegatedManagedIdentityResourceId = $null
                    }
                }
                return ConvertTo-Json -InputObject $assignments -Compress -Depth 5
            }
            throw 'unexpected command'
        }.GetNewClosure()

        {
            Assert-GatewayRuntimeImagePullContract `
                -SubscriptionId $subscriptionId `
                -ResourceGroup $resourceGroup `
                -ApiContainerAppName $apiName `
                -WorkerContainerAppName $workerName `
                -RuntimeImagePullIdentityId $identityId `
                -RuntimeImagePullIdentityPrincipalId $identityPrincipalId `
                -RuntimeImagePullAcrPullRoleAssignmentId $dedicatedAssignmentId `
                -ExpectedAcrName 'acrgateway' `
                -ExpectedAcrLoginServer $acrLoginServer `
                -ApiContainerImage $apiImage `
                -WorkerContainerImage $workerImage `
                -AllowFreshDedicatedImagePull `
                -AzureInvoker $invoker
        } | Should -Throw '*exact deterministic direct AcrPull assignment*'
    }

    It 'rejects a dedicated role receipt whose name is not the foundation deterministic guid' {
        $wrongAssignmentId = "$acrScope/providers/Microsoft.Authorization/roleAssignments/33333333-3333-4333-8333-333333333333"
        $expectedIdentityId = $identityId
        $expectedPrincipalId = $identityPrincipalId
        $invoker = {
            param([string[]]$Arguments)
            return @{
                id = $expectedIdentityId
                principalId = $expectedPrincipalId
            } | ConvertTo-Json -Compress
        }.GetNewClosure()

        {
            Assert-GatewayRuntimeImagePullContract `
                -SubscriptionId $subscriptionId `
                -ResourceGroup $resourceGroup `
                -ApiContainerAppName $apiName `
                -WorkerContainerAppName $workerName `
                -RuntimeImagePullIdentityId $identityId `
                -RuntimeImagePullIdentityPrincipalId $identityPrincipalId `
                -RuntimeImagePullAcrPullRoleAssignmentId $wrongAssignmentId `
                -ExpectedAcrName 'acrgateway' `
                -AzureInvoker $invoker
        } | Should -Throw '*exact deterministic assignment name*'
    }

    It 'rejects non-exact ACR and immutable image bindings: <Case>' -TestCases @(
        @{ Case = 'wrong ACR scope' }
        @{ Case = 'wrong image host' }
        @{ Case = 'mutable image tag' }
    ) {
        param($Case)

        $expectedSubscriptionId = '11111111-1111-4111-8111-111111111111'
        $expectedResourceGroup = 'rg-gateway'
        $expectedAcrName = 'acrgateway'
        $expectedLoginServer = 'acrgateway.azurecr.io'
        $actualAcrScope = "/subscriptions/$expectedSubscriptionId/resourceGroups/$expectedResourceGroup/providers/Microsoft.ContainerRegistry/registries/$expectedAcrName"
        $actualLoginServer = $expectedLoginServer
        $apiContainerImage = "$expectedLoginServer/gateway-api@sha256:$('a' * 64)"
        $workerContainerImage = "$expectedLoginServer/gateway-worker@sha256:$('b' * 64)"
        $expectedError = '*immutable digest references*'
        if ($Case -eq 'wrong ACR scope') {
            $actualAcrScope = "/subscriptions/$expectedSubscriptionId/resourceGroups/$expectedResourceGroup/providers/Microsoft.ContainerRegistry/registries/otheracr"
            $expectedError = '*exact expected deployment ACR*'
        }
        elseif ($Case -eq 'wrong image host') {
            $apiContainerImage = "otheracr.azurecr.io/gateway-api@sha256:$('a' * 64)"
        }
        else {
            $workerContainerImage = "$expectedLoginServer/gateway-worker:latest"
        }
        $runtimeImagePullModule = Get-Module -Name RuntimeImagePull -ErrorAction Stop

        {
            & $runtimeImagePullModule {
                param($Arguments)
                Assert-RuntimeImageAcrBinding @Arguments
            } @{
                SubscriptionId = $expectedSubscriptionId
                ResourceGroup = $expectedResourceGroup
                ExpectedAcrName = $expectedAcrName
                ExpectedAcrLoginServer = $expectedLoginServer
                AcrScope = $actualAcrScope
                ActualAcrLoginServer = $actualLoginServer
                ApiContainerImage = $apiContainerImage
                WorkerContainerImage = $workerContainerImage
            }
        } | Should -Throw $expectedError
    }

    It 'accepts populated receipts for existing apps only after exact UAMI migration and removal of direct system AcrPull' {
        $apiSystemPrincipalId = '44444444-4444-4444-8444-444444444444'
        $workerSystemPrincipalId = '55555555-5555-4555-8555-555555555555'
        $expectedIdentityId = $identityId
        $expectedIdentityPrincipalId = $identityPrincipalId
        $expectedAssignmentId = $dedicatedAssignmentId
        $expectedAssignmentName = $dedicatedAssignmentName
        $expectedAcrScope = $acrScope
        $expectedAcrLoginServer = $acrLoginServer
        $expectedRoleDefinitionId = $roleDefinitionId
        $expectedSubscriptionId = $subscriptionId
        $expectedResourceGroup = $resourceGroup
        $expectedApiName = $apiName
        $expectedWorkerName = $workerName
        $calls = [System.Collections.Generic.List[string[]]]::new()
        $invoker = {
            param([string[]]$Arguments)
            $calls.Add($Arguments)
            if ($Arguments[0] -eq 'identity') {
                return @{ id = $expectedIdentityId; principalId = $expectedIdentityPrincipalId } |
                    ConvertTo-Json -Compress
            }
            if ($Arguments[0] -eq 'role') {
                $principalId = $Arguments[[array]::IndexOf($Arguments, '--assignee-object-id') + 1]
                if ($principalId -eq $expectedIdentityPrincipalId) {
                    return @(@{
                        id = $expectedAssignmentId
                        name = $expectedAssignmentName
                        principalId = $expectedIdentityPrincipalId
                        principalType = 'ServicePrincipal'
                        scope = $expectedAcrScope
                        roleDefinitionId = $expectedRoleDefinitionId
                        condition = $null
                        conditionVersion = $null
                        delegatedManagedIdentityResourceId = $null
                    }) | ConvertTo-Json -Compress
                }
                return ConvertTo-Json -InputObject @() -Compress
            }
            if ($Arguments[0] -eq 'acr') {
                return @{ id = $expectedAcrScope; loginServer = $expectedAcrLoginServer } |
                    ConvertTo-Json -Compress
            }
            if ($Arguments[0] -eq 'containerapp') {
                return @(
                    @{
                        name = $expectedApiName
                        id = "/subscriptions/$expectedSubscriptionId/resourceGroups/$expectedResourceGroup/providers/Microsoft.App/containerApps/$expectedApiName"
                        principalId = $apiSystemPrincipalId
                        identityType = 'SystemAssigned, UserAssigned'
                        userAssignedIdentities = @{ $expectedIdentityId = @{} }
                        registries = @(@{ server = $expectedAcrLoginServer; identity = $expectedIdentityId })
                    },
                    @{
                        name = $expectedWorkerName
                        id = "/subscriptions/$expectedSubscriptionId/resourceGroups/$expectedResourceGroup/providers/Microsoft.App/containerApps/$expectedWorkerName"
                        principalId = $workerSystemPrincipalId
                        identityType = 'SystemAssigned, UserAssigned'
                        userAssignedIdentities = @{ $expectedIdentityId = @{} }
                        registries = @(@{ server = $expectedAcrLoginServer; identity = $expectedIdentityId })
                    }) | ConvertTo-Json -Compress -Depth 7
            }
            throw 'unexpected command'
        }.GetNewClosure()

        $result = Assert-GatewayRuntimeImagePullContract `
            -SubscriptionId $subscriptionId `
            -ResourceGroup $resourceGroup `
            -ApiContainerAppName $apiName `
            -WorkerContainerAppName $workerName `
            -RuntimeImagePullIdentityId $identityId `
            -RuntimeImagePullIdentityPrincipalId $identityPrincipalId `
            -RuntimeImagePullAcrPullRoleAssignmentId $dedicatedAssignmentId `
            -ExpectedAcrName 'acrgateway' `
            -ExpectedAcrLoginServer $acrLoginServer `
            -ApiContainerImage $apiImage `
            -WorkerContainerImage $workerImage `
            -AzureInvoker $invoker

        $result.Mode | Should -Be 'DedicatedUserAssignedIdentity'
        $calls.Count | Should -Be 6
        $queriedRolePrincipals = @(
            $calls |
                Where-Object { $_[0] -eq 'role' } |
                ForEach-Object { $_[[array]::IndexOf($_, '--assignee-object-id') + 1] }
        )
        $queriedRolePrincipals | Should -Contain $identityPrincipalId
        $queriedRolePrincipals | Should -Contain $apiSystemPrincipalId
        $queriedRolePrincipals | Should -Contain $workerSystemPrincipalId
        foreach ($call in $calls) {
            $call | Should -Contain '--subscription'
            $call | Should -Contain $subscriptionId
        }
    }

    It 'rejects populated receipts that would silently migrate existing system-registry workloads' {
        $apiSystemPrincipalId = '44444444-4444-4444-8444-444444444444'
        $workerSystemPrincipalId = '55555555-5555-4555-8555-555555555555'
        $expectedIdentityId = $identityId
        $expectedIdentityPrincipalId = $identityPrincipalId
        $expectedAssignmentId = $dedicatedAssignmentId
        $expectedAssignmentName = $dedicatedAssignmentName
        $expectedAcrScope = $acrScope
        $expectedAcrLoginServer = $acrLoginServer
        $expectedRoleDefinitionId = $roleDefinitionId
        $expectedSubscriptionId = $subscriptionId
        $expectedResourceGroup = $resourceGroup
        $expectedApiName = $apiName
        $expectedWorkerName = $workerName
        $invoker = {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'identity') {
                return @{ id = $expectedIdentityId; principalId = $expectedIdentityPrincipalId } |
                    ConvertTo-Json -Compress
            }
            if ($Arguments[0] -eq 'role') {
                return @(@{
                    id = $expectedAssignmentId
                    name = $expectedAssignmentName
                    principalId = $expectedIdentityPrincipalId
                    principalType = 'ServicePrincipal'
                    scope = $expectedAcrScope
                    roleDefinitionId = $expectedRoleDefinitionId
                    condition = $null
                    conditionVersion = $null
                    delegatedManagedIdentityResourceId = $null
                }) | ConvertTo-Json -Compress
            }
            if ($Arguments[0] -eq 'acr') {
                return @{ id = $expectedAcrScope; loginServer = $expectedAcrLoginServer } |
                    ConvertTo-Json -Compress
            }
            if ($Arguments[0] -eq 'containerapp') {
                return @(
                    @{
                        name = $expectedApiName
                        id = "/subscriptions/$expectedSubscriptionId/resourceGroups/$expectedResourceGroup/providers/Microsoft.App/containerApps/$expectedApiName"
                        principalId = $apiSystemPrincipalId
                        identityType = 'SystemAssigned'
                        userAssignedIdentities = @{}
                        registries = @(@{ server = $expectedAcrLoginServer; identity = 'system' })
                    },
                    @{
                        name = $expectedWorkerName
                        id = "/subscriptions/$expectedSubscriptionId/resourceGroups/$expectedResourceGroup/providers/Microsoft.App/containerApps/$expectedWorkerName"
                        principalId = $workerSystemPrincipalId
                        identityType = 'SystemAssigned'
                        userAssignedIdentities = @{}
                        registries = @(@{ server = $expectedAcrLoginServer; identity = 'system' })
                    }) | ConvertTo-Json -Compress -Depth 7
            }
            throw 'unexpected command'
        }.GetNewClosure()

        {
            Assert-GatewayRuntimeImagePullContract `
                -SubscriptionId $subscriptionId `
                -ResourceGroup $resourceGroup `
                -ApiContainerAppName $apiName `
                -WorkerContainerAppName $workerName `
                -RuntimeImagePullIdentityId $identityId `
                -RuntimeImagePullIdentityPrincipalId $identityPrincipalId `
                -RuntimeImagePullAcrPullRoleAssignmentId $dedicatedAssignmentId `
                -ExpectedAcrName 'acrgateway' `
                -ExpectedAcrLoginServer $acrLoginServer `
                -ApiContainerImage $apiImage `
                -WorkerContainerImage $workerImage `
                -AzureInvoker $invoker
        } | Should -Throw '*not already migrated*separately reviewed migration*'
    }

    It 'rejects any remaining direct system-identity AcrPull assignment without requesting inherited roles' {
        $expectedSubscriptionId = '11111111-1111-4111-8111-111111111111'
        $expectedPrincipalId = '44444444-4444-4444-8444-444444444444'
        $expectedAcrScope = "/subscriptions/$expectedSubscriptionId/resourceGroups/rg-gateway/providers/Microsoft.ContainerRegistry/registries/acrgateway"
        $expectedRoleDefinitionId = "/subscriptions/$expectedSubscriptionId/providers/Microsoft.Authorization/roleDefinitions/7f951dda-4ed3-4680-a7ca-43fe172d538d"
        $calls = [System.Collections.Generic.List[string[]]]::new()
        $invoker = {
            param([string[]]$Arguments)
            $calls.Add($Arguments)
            return @(@{
                id = "$expectedAcrScope/providers/Microsoft.Authorization/roleAssignments/77777777-7777-4777-8777-777777777777"
                principalId = $expectedPrincipalId
                principalType = 'ServicePrincipal'
                scope = $expectedAcrScope
                roleDefinitionId = $expectedRoleDefinitionId
                condition = $null
                conditionVersion = $null
                delegatedManagedIdentityResourceId = $null
            }) | ConvertTo-Json -Compress
        }.GetNewClosure()
        $runtimeImagePullModule = Get-Module -Name RuntimeImagePull -ErrorAction Stop

        {
            & $runtimeImagePullModule {
                param($SubscriptionId, $AcrScope, $PrincipalId, $AzureInvoker)
                Assert-NoDirectSystemAcrPullAssignment `
                    -SubscriptionId $SubscriptionId `
                    -AcrScope $AcrScope `
                    -PrincipalId $PrincipalId `
                    -AzureInvoker $AzureInvoker
            } $expectedSubscriptionId $expectedAcrScope $expectedPrincipalId $invoker
        } | Should -Throw '*cannot silently migrate*direct system AcrPull remains*'
        $calls.Count | Should -Be 1
        $calls[0] | Should -Not -Contain '--include-inherited'
    }

    It 'accepts legacy mode only after both existing system identities and exact deterministic assignments read back' {
        $apiPrincipalId = '44444444-4444-4444-8444-444444444444'
        $workerPrincipalId = '55555555-5555-4555-8555-555555555555'
        $apiAssignmentName = Get-ArmDeterministicGuid -Values @(
            "/subscriptions/$subscriptionId", $apiPrincipalId, $acrScope, $acrPullRoleId)
        $workerAssignmentName = Get-ArmDeterministicGuid -Values @(
            "/subscriptions/$subscriptionId", $workerPrincipalId, $acrScope, $acrPullRoleId)
        $calls = [System.Collections.Generic.List[string[]]]::new()
        $expectedApiName = $apiName
        $expectedSubscriptionId = $subscriptionId
        $expectedResourceGroup = $resourceGroup
        $expectedAcrScope = $acrScope
        $expectedAcrLoginServer = $acrLoginServer
        $expectedRoleDefinitionId = $roleDefinitionId
        $invoker = {
            param([string[]]$Arguments)
            $calls.Add($Arguments)
            if ($Arguments[0] -eq 'containerapp') {
                $name = $Arguments[[array]::IndexOf($Arguments, '--name') + 1]
                $principalId = if ($name -eq $expectedApiName) { $apiPrincipalId } else { $workerPrincipalId }
                return @{
                    id = "/subscriptions/$expectedSubscriptionId/resourceGroups/$expectedResourceGroup/providers/Microsoft.App/containerApps/$name"
                    principalId = $principalId
                    identityType = 'SystemAssigned'
                    userAssignedIdentities = @{}
                    registries = @(@{ server = $expectedAcrLoginServer; identity = 'system' })
                } | ConvertTo-Json -Compress -Depth 5
            }
            if ($Arguments[0] -eq 'acr') {
                return @(@{ id = $expectedAcrScope; loginServer = $expectedAcrLoginServer }) |
                    ConvertTo-Json -Compress
            }
            if ($Arguments[0] -eq 'role') {
                $principalId = $Arguments[[array]::IndexOf($Arguments, '--assignee-object-id') + 1]
                $assignmentName = if ($principalId -eq $apiPrincipalId) {
                    $apiAssignmentName
                }
                else {
                    $workerAssignmentName
                }
                return @(@{
                    id = "$expectedAcrScope/providers/Microsoft.Authorization/roleAssignments/$assignmentName"
                    name = $assignmentName
                    principalId = $principalId
                    principalType = 'ServicePrincipal'
                    scope = $expectedAcrScope
                    roleDefinitionId = $expectedRoleDefinitionId
                    condition = $null
                    conditionVersion = $null
                    delegatedManagedIdentityResourceId = $null
                }) | ConvertTo-Json -Compress
            }
            throw 'unexpected command'
        }.GetNewClosure()

        $result = Assert-GatewayRuntimeImagePullContract `
            -SubscriptionId $subscriptionId `
            -ResourceGroup $resourceGroup `
            -ApiContainerAppName $apiName `
            -WorkerContainerAppName $workerName `
            -ExpectedAcrName 'acrgateway' `
            -ExpectedAcrLoginServer $acrLoginServer `
            -ApiContainerImage $apiImage `
            -WorkerContainerImage $workerImage `
            -AllowExistingLegacySystemAssignedImagePull `
            -AzureInvoker $invoker

        $result.Mode | Should -Be 'LegacySystemAssignedIdentity'
        $result.AllowLegacySystemAssignedImagePull | Should -BeTrue
        $calls.Count | Should -Be 5
        foreach ($call in $calls) {
            $call | Should -Contain '--subscription'
            $call | Should -Contain $subscriptionId
            $call[0] | Should -BeIn @('containerapp', 'acr', 'role')
        }
    }

    It 'rejects a legacy assignment whose name is not the historical deterministic guid' {
        $apiPrincipalId = '44444444-4444-4444-8444-444444444444'
        $workerPrincipalId = '55555555-5555-4555-8555-555555555555'
        $expectedApiName = $apiName
        $expectedSubscriptionId = $subscriptionId
        $expectedResourceGroup = $resourceGroup
        $expectedAcrScope = $acrScope
        $expectedAcrLoginServer = $acrLoginServer
        $expectedRoleDefinitionId = $roleDefinitionId
        $invoker = {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'containerapp') {
                $name = $Arguments[[array]::IndexOf($Arguments, '--name') + 1]
                $principalId = if ($name -eq $expectedApiName) { $apiPrincipalId } else { $workerPrincipalId }
                return @{
                    id = "/subscriptions/$expectedSubscriptionId/resourceGroups/$expectedResourceGroup/providers/Microsoft.App/containerApps/$name"
                    principalId = $principalId
                    identityType = 'SystemAssigned'
                    userAssignedIdentities = @{}
                    registries = @(@{ server = $expectedAcrLoginServer; identity = 'system' })
                } | ConvertTo-Json -Compress -Depth 5
            }
            if ($Arguments[0] -eq 'acr') {
                return @(@{ id = $expectedAcrScope; loginServer = $expectedAcrLoginServer }) |
                    ConvertTo-Json -Compress
            }
            if ($Arguments[0] -eq 'role') {
                $principalId = $Arguments[[array]::IndexOf($Arguments, '--assignee-object-id') + 1]
                $wrongName = '66666666-6666-4666-8666-666666666666'
                return @(@{
                    id = "$expectedAcrScope/providers/Microsoft.Authorization/roleAssignments/$wrongName"
                    name = $wrongName
                    principalId = $principalId
                    principalType = 'ServicePrincipal'
                    scope = $expectedAcrScope
                    roleDefinitionId = $expectedRoleDefinitionId
                    condition = $null
                    conditionVersion = $null
                    delegatedManagedIdentityResourceId = $null
                }) | ConvertTo-Json -Compress
            }
            throw 'unexpected command'
        }.GetNewClosure()

        {
            Assert-GatewayRuntimeImagePullContract `
                -SubscriptionId $subscriptionId `
                -ResourceGroup $resourceGroup `
                -ApiContainerAppName $apiName `
                -WorkerContainerAppName $workerName `
                -ExpectedAcrName 'acrgateway' `
                -ExpectedAcrLoginServer $acrLoginServer `
                -ApiContainerImage $apiImage `
                -WorkerContainerImage $workerImage `
                -AllowExistingLegacySystemAssignedImagePull `
                -AzureInvoker $invoker
        } | Should -Throw '*exact deterministic direct AcrPull assignment*'
    }
}
