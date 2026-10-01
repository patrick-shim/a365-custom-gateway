BeforeAll {
    $identityModule = $null
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $definitions = foreach ($source in @(
        @{ Path = 'operations\GatewayUpgrade.psm1'; Names = @(
            'Test-GatewayUpgradeResourceId', 'ConvertTo-GatewayUpgradeCanonical',
            'ConvertTo-GatewayUpgradeCanonicalJson', 'Get-GatewayUpgradeFingerprint'
        ) }
        @{ Path = 'operations\GatewayUpgradeExecution.psm1'; Names = @(
            'Get-GatewayUpgradeWorkloadSnapshot', 'Get-GatewayUpgradeMutableEnvironmentPattern',
            'Assert-GatewayUpgradeCutoverReaderRoles', 'Assert-GatewayUpgradeDatabaseJobFields'
        ) }
        @{ Path = 'operations\GatewayUpgradeCutover.psm1'; Names = @(
            'Get-GatewayUpgradeCutoverRevisions', 'Close-GatewayUpgradeCutover'
        ) }
    )) {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $root $source.Path), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw 'The actual ARM identity consumers must parse.' }
        foreach ($name in $source.Names) {
            $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $false)
            if ($null -eq $definition) { throw "Missing actual ARM identity consumer: $name" }
            $definition.Extent.Text
        }
    }
    $identityModule = New-Module -Name "UpgradeArmIdentityFixture_$([guid]::NewGuid().ToString('N'))" `
        -ArgumentList ($definitions -join "`n") -ScriptBlock {
        param($definitions)
        Set-StrictMode -Version Latest
        function Invoke-GatewayUpgradeArm {
            param($Context, $Method, $ResourceId, $ApiVersion)
            throw 'Unscripted ARM access is forbidden.'
        }
        function Invoke-GatewayUpgradeCutoverArm {
            param($Context, $Method, $Id, $Version)
            throw 'Unscripted cutover ARM access is forbidden.'
        }
        function ConvertTo-GatewayUpgradeCutoverNormalizedConfiguration {
            param($Context, $Component, $Configuration)
            throw 'Unscripted configuration normalization is forbidden.'
        }
        function Get-GatewayUpgradeCutoverExecutionModule {
            param($Context)
            throw 'Unscripted execution-module access is forbidden.'
        }
        function Assert-GatewayUpgradeCutoverAuthority {
            param($Context)
            throw 'Unscripted cutover authority is forbidden.'
        }
        function Get-GatewayUpgradeCutoverInventory {
            param($Context)
            throw 'Unscripted inventory access is forbidden.'
        }
        function Set-GatewayUpgradeCutoverAppHold {
            param($Context, $Component, [switch]$EmergencyDeny)
            throw 'Unscripted application mutation is forbidden.'
        }
        function Set-GatewayUpgradeCutoverQueueHold {
            param($Context, $Id)
            throw 'Unscripted queue mutation is forbidden.'
        }
        function Assert-GatewayUpgradeCutoverHeld {
            param($Context, [switch]$ZeroWriters, [switch]$AllowAbsentProtectionQueue)
            throw 'Unscripted closure assertion is forbidden.'
        }
        . ([scriptblock]::Create($definitions))
        Export-ModuleMember -Function Test-GatewayUpgradeResourceId, Get-GatewayUpgradeFingerprint,
            Get-GatewayUpgradeWorkloadSnapshot, Get-GatewayUpgradeCutoverRevisions,
            Assert-GatewayUpgradeCutoverReaderRoles, Close-GatewayUpgradeCutover
    }
    $identityModule | Import-Module -NoClobber -DisableNameChecking
    $matchesId = $identityModule.ExportedCommands['Test-GatewayUpgradeResourceId']
    $fingerprint = $identityModule.ExportedCommands['Get-GatewayUpgradeFingerprint']
    $snapshotCommand = $identityModule.ExportedCommands['Get-GatewayUpgradeWorkloadSnapshot']
    $revisionsCommand = $identityModule.ExportedCommands['Get-GatewayUpgradeCutoverRevisions']
    $readerRolesCommand = $identityModule.ExportedCommands['Assert-GatewayUpgradeCutoverReaderRoles']
    $closeCommand = $identityModule.ExportedCommands['Close-GatewayUpgradeCutover']
    $armScope = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-arm-fixture'
    $appId = "$armScope/providers/Microsoft.App/containerApps/ca-gateway-api-dev"
}

AfterAll {
    if ($null -ne $identityModule) { Remove-Module -ModuleInfo $identityModule -Force }
}

Describe 'ARM identity comparison does not normalize signed bindings' {
    It 'accepts only casing differences, including finite allowlist membership' {
        & $matchesId $appId.ToLowerInvariant() $appId | Should -BeTrue
        & $matchesId $appId.ToUpperInvariant() @("$appId-unrelated", $appId) | Should -BeTrue
    }

    It 'rejects <Label>' -ForEach @(
        @{ Label = 'another subscription'; Change = { $appId.Replace('11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222') } }
        @{ Label = 'another group'; Change = { $appId.Replace('rg-arm-fixture', 'rg-other') } }
        @{ Label = 'another resource'; Change = { "$appId-other" } }
        @{ Label = 'a parent resource'; Change = { $armScope } }
        @{ Label = 'a child resource'; Change = { "$appId/revisions/unreviewed" } }
        @{ Label = 'an appended slash'; Change = { "$appId/" } }
        @{ Label = 'an encoded separator'; Change = { $appId.Replace('/containerApps/', '/containerApps%2F') } }
        @{ Label = 'a traversal alias'; Change = { "$appId/../ca-gateway-api-dev" } }
        @{ Label = 'a null value'; Change = { $null } }
        @{ Label = 'a non-string value'; Change = { 42 } }
    ) {
        & $matchesId (& $Change) $appId | Should -BeFalse
    }

    It 'retains exact canonical fingerprints and rejects an empty allowlist' {
        & $fingerprint @{ id = $appId } | Should -Not -Be (& $fingerprint @{ id = $appId.ToLowerInvariant() })
        & $matchesId $appId @() | Should -BeFalse
        & $matchesId $null $null | Should -BeFalse
    }
}

Describe 'Actual workload snapshots accept Azure ID spelling, not identity drift' {
    BeforeEach {
        $context = @{
            config = @{ environment = 'dev' }
            plan = @{ scope = @{ resourceGroupId = $armScope } }
            foundation = @{
                containerAppsEnvironmentId = "$armScope/providers/Microsoft.App/managedEnvironments/cae-fixture"
                runtimeImagePullIdentityId = "$armScope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-runtime-fixture"
            }
            runtime = @{
                apiPrincipalId = '22222222-2222-4222-8222-222222222222'
                workerPrincipalId = '33333333-3333-4333-8333-333333333333'
                apiFqdn = 'api.synthetic.invalid'
            }
            state = @{
                deploymentOwnershipId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
                acceptedPlan = @{ sourceFingerprint = 'sha256:' + ('a' * 64) }
                steps = @{ 'Admin UI deployment' = @{ evidence = @{
                    adminUiPrincipalId = '44444444-4444-4444-8444-444444444444'
                    adminUiUrl = 'https://admin.synthetic.invalid'
                } } }
            }
        }
        $apps = @{}
        foreach ($workload in @('api', 'worker', 'adminUi')) {
            $name = switch ($workload) {
                api { 'ca-gateway-api-dev' }
                worker { 'ca-gateway-worker-dev-v3' }
                adminUi { 'ca-gateway-admin-dev' }
            }
            $id = "$armScope/providers/Microsoft.App/containerApps/$name"
            $identityId = if ($workload -ceq 'adminUi') {
                "$armScope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-admin-dev"
            } else { $context.foundation.runtimeImagePullIdentityId }
            $apps[$id] = @{
                id = $id.ToLowerInvariant()
                tags = @{
                    bootstrapOwnershipId = $context.state.deploymentOwnershipId
                    bootstrapSourceFingerprint = $context.state.acceptedPlan.sourceFingerprint
                }
                identity = @{
                    type = if ($workload -ceq 'adminUi') { 'UserAssigned' } else { 'SystemAssigned, UserAssigned' }
                    principalId = if ($workload -ceq 'api') { $context.runtime.apiPrincipalId } else { $context.runtime.workerPrincipalId }
                    userAssignedIdentities = @{ $identityId.ToLowerInvariant() = @{} }
                }
                properties = @{
                    environmentId = $context.foundation.containerAppsEnvironmentId.ToLowerInvariant()
                    latestReadyRevisionName = "$name--original"
                    configuration = @{
                        activeRevisionsMode = 'Single'; secrets = @()
                        ingress = @{ fqdn = if ($workload -ceq 'api') { 'api.synthetic.invalid' } else { 'admin.synthetic.invalid' } }
                    }
                    template = @{ containers = @(@{ image = "fixture.invalid/$workload@sha256:" + ('b' * 64); env = @() }) }
                }
            }
        }
        Mock Invoke-GatewayUpgradeArm -ModuleName $identityModule.Name {
            $Method | Should -BeExactly 'GET'
            if ($ResourceId -ceq "$armScope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-admin-dev") {
                $ApiVersion | Should -BeExactly '2023-01-31'
                return @{ properties = @{ principalId = $context.state.steps['Admin UI deployment'].evidence.adminUiPrincipalId } }
            }
            $apps.Contains($ResourceId) | Should -BeTrue
            $ApiVersion | Should -BeExactly $(if ($ResourceId.EndsWith('worker-dev-v3')) { '2025-01-01' } else { '2024-03-01' })
            $apps[$ResourceId]
        }
        Mock ConvertTo-GatewayUpgradeCutoverNormalizedConfiguration -ModuleName $identityModule.Name { $Configuration }
    }

    It 'accepts the actual lowercased <Component> resource and preserves raw observation bytes' -ForEach @(
        @{ Component = 'api' }, @{ Component = 'worker' }, @{ Component = 'adminUi' }
    ) {
        $snapshot = & $snapshotCommand $context $Component
        $snapshot.id | Should -BeExactly "$armScope/providers/Microsoft.App/containerApps/$($snapshot.name)"
        $snapshot.raw.id | Should -BeExactly $snapshot.id.ToLowerInvariant()
        $snapshot.image | Should -Match '@sha256:[0-9a-f]{64}$'
        Should -Invoke Invoke-GatewayUpgradeArm -ModuleName $identityModule.Name -Exactly -Times $(if ($Component -ceq 'adminUi') { 2 } else { 1 })
    }

    It 'still rejects <Label> independently of ID casing' -ForEach @(
        @{ Label = 'another application'; Change = { $apps[$appId].id += '-other' } }
        @{ Label = 'another environment'; Change = { $apps[$appId].properties.environmentId += '-other' } }
        @{ Label = 'another image-pull identity'; Change = { $apps[$appId].identity.userAssignedIdentities = @{ "$armScope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/other" = @{} } } }
        @{ Label = 'another principal'; Change = { $apps[$appId].identity.principalId = '55555555-5555-4555-8555-555555555555' } }
        @{ Label = 'changed ownership spelling'; Change = { $apps[$appId].tags.bootstrapOwnershipId = $context.state.deploymentOwnershipId.ToUpperInvariant() } }
        @{ Label = 'changed source spelling'; Change = { $apps[$appId].tags.bootstrapSourceFingerprint = $context.state.acceptedPlan.sourceFingerprint.ToUpperInvariant() } }
        @{ Label = 'a mutable image tag'; Change = { $apps[$appId].properties.template.containers[0].image = 'fixture.invalid/api:latest' } }
        @{ Label = 'another endpoint'; Change = { $apps[$appId].properties.configuration.ingress.fqdn = 'other.synthetic.invalid' } }
        @{ Label = 'a second container'; Change = { $apps[$appId].properties.template.containers += $apps[$appId].properties.template.containers[0] } }
    ) {
        . $Change
        { & $snapshotCommand $context api } | Should -Throw 'UpgradeExecution:*'
    }
}

Describe 'Actual revision inventory has one identity per ARM resource' {
    BeforeEach {
        $revisionId = "$appId/revisions/api--original"
        $response = @{ value = @(@{ id = $revisionId.ToLowerInvariant(); properties = @{ active = $false; replicas = 0 } }) }
        Mock Invoke-GatewayUpgradeCutoverArm -ModuleName $identityModule.Name {
            $Method | Should -BeExactly 'GET'
            $Id | Should -BeExactly "$appId/revisions"
            $Version | Should -BeExactly '2025-01-01'
            $response
        }
    }

    It 'retains an original revision whose ARM prefix uses different casing' {
        $result = & $revisionsCommand @{} $appId
        @($result).Count | Should -Be 1
        $result[0].id | Should -BeExactly $revisionId.ToLowerInvariant()
    }

    It 'rejects <Label>' -ForEach @(
        @{ Label = 'duplicate casing aliases'; Change = { $response.value += @{ id = $revisionId; properties = @{ active = $false; replicas = 0 } } } }
        @{ Label = 'a foreign parent'; Change = { $response.value[0].id = "$appId-other/revisions/api--original" } }
        @{ Label = 'a traversal tail'; Change = { $response.value[0].id = "$appId/revisions/../api--original" } }
        @{ Label = 'an encoded tail'; Change = { $response.value[0].id = "$appId/revisions/api%2D%2Doriginal" } }
        @{ Label = 'a noncanonical revision name'; Change = { $response.value[0].id = "$appId/revisions/API--original" } }
        @{ Label = 'a final newline'; Change = { $response.value[0].id = "$revisionId`n" } }
        @{ Label = 'a truncated page'; Change = { $response.nextLink = 'https://unfollowed.synthetic.invalid' } }
        @{ Label = 'an empty inventory'; Change = { $response.value = @() } }
        @{ Label = 'an unknown active state'; Change = { $response.value[0].properties.active = 'false' } }
        @{ Label = 'an invalid replica count'; Change = { $response.value[0].properties.replicas = -1 } }
    ) {
        . $Change
        { & $revisionsCommand @{} $appId } | Should -Throw 'UpgradeCutoverUnknown:*'
    }
}

Describe 'Actual private observer role readback preserves exact permission and scope' {
    BeforeEach {
        $principal = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        $assignmentName = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        $contract = @{
            assignmentResourceId = "$appId/providers/Microsoft.Authorization/roleAssignments/$assignmentName"
            roleDefinitionId = '/subscriptions/11111111-1111-4111-8111-111111111111/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7'
        }
        $role = @{
            id = $contract.assignmentResourceId.ToLowerInvariant(); name = $assignmentName; type = 'microsoft.authorization/roleassignments'
            properties = @{
                principalId = $principal; principalType = 'ServicePrincipal'
                scope = $appId.ToLowerInvariant(); roleDefinitionId = $contract.roleDefinitionId.ToLowerInvariant()
            }
        }

        Mock Invoke-GatewayUpgradeArm -ModuleName $identityModule.Name {
            $Method | Should -BeExactly 'GET'
            $ResourceId | Should -BeExactly $contract.assignmentResourceId
            $ApiVersion | Should -BeExactly '2022-04-01'
            $role
        }
    }

    It 'accepts only the same role assignment, permission and scope under different ARM casing' {
        { & $readerRolesCommand @{} @($contract) $principal } | Should -Not -Throw
    }

    It 'rejects <Label>' -ForEach @(
        @{ Label = 'another assignment'; Change = { $role.id += '-other' } }
        @{ Label = 'another scope'; Change = { $role.properties.scope = $armScope } }
        @{ Label = 'another permission'; Change = { $role.properties.roleDefinitionId += '-other' } }
        @{ Label = 'another principal'; Change = { $role.properties.principalId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd' } }
        @{ Label = 'noncanonical principal spelling'; Change = { $role.properties.principalId = $principal.ToUpperInvariant() } }
        @{ Label = 'an added condition'; Change = { $role.properties.condition = 'unreviewed' } }
    ) {
        . $Change
        { & $readerRolesCommand @{} @($contract) $principal } | Should -Throw 'UpgradeCutover:*'
    }
}

Describe 'Actual close-only execution never deactivates its own admitted sentinel' {
    It 'excludes the exact sentinel even when its observed ARM prefix has different casing' {
        $workerId = "$armScope/providers/Microsoft.App/containerApps/ca-gateway-worker-dev-v3"
        $sentinelId = "$appId/revisions/api--reviewed-pre"
        $context = @{
            planFingerprint = 'sha256:' + ('e' * 64)
            plan = @{ cutover = @{
                TimeoutSeconds = 600
                ProvisioningQueueResourceId = "$armScope/providers/Microsoft.ServiceBus/namespaces/sb-fixture/queues/gateway-provisioning-v3"
                ProtectionQueueResourceId = "$armScope/providers/Microsoft.ServiceBus/namespaces/sb-fixture/queues/gateway-protection-admin-v1"
            } }
            cutoverInventory = @{ apps = @{ api = @{ id = $appId }; worker = @{ id = $workerId } } }
            syntheticSentinelId = $sentinelId
        }
        $execution = New-Module -Name "UpgradeArmCloseFixture_$([guid]::NewGuid().ToString('N'))" -ScriptBlock {
            function Initialize-GatewayUpgradeWorkloadBaselines { param($Context) }
            function Save-GatewayUpgradeNamedEvidence { param($Context, $Name, $Value) }
            function Invoke-GatewayUpgradePreSchemaApi { param($Context) return $Context.syntheticSentinelId }
        }
        $mutations = [Collections.Generic.List[string]]::new()
        Mock Assert-GatewayUpgradeCutoverAuthority -ModuleName $identityModule.Name {}
        Mock Get-GatewayUpgradeCutoverInventory -ModuleName $identityModule.Name { $context.cutoverInventory }
        Mock Get-GatewayUpgradeCutoverExecutionModule -ModuleName $identityModule.Name { $execution }
        Mock Set-GatewayUpgradeCutoverAppHold -ModuleName $identityModule.Name {
            param($Context, $Component, [switch]$EmergencyDeny)
            $EmergencyDeny.IsPresent | Should -BeFalse
        }
        Mock Set-GatewayUpgradeCutoverQueueHold -ModuleName $identityModule.Name {
            $Id | Should -BeIn @($context.plan.cutover.ProvisioningQueueResourceId, $context.plan.cutover.ProtectionQueueResourceId)
        }
        Mock Get-GatewayUpgradeCutoverRevisions -ModuleName $identityModule.Name {
            if ($AppId -ceq $context.cutoverInventory.apps.api.id) {
                return @(
                    @{ id = "$AppId/revisions/api--old".ToLowerInvariant(); properties = @{ active = $true } }
                    @{ id = $context.syntheticSentinelId.ToLowerInvariant(); properties = @{ active = $true } }
                )
            }
            $AppId | Should -BeExactly $context.cutoverInventory.apps.worker.id
            @(@{ id = "$AppId/revisions/worker--old".ToLowerInvariant(); properties = @{ active = $true } })
        }
        Mock Invoke-GatewayUpgradeCutoverArm -ModuleName $identityModule.Name {
            $Method | Should -BeExactly 'POST'
            $Version | Should -BeExactly '2025-01-01'
            $mutations.Add($Id)
        }
        Mock Assert-GatewayUpgradeCutoverHeld -ModuleName $identityModule.Name {
            $ZeroWriters.IsPresent | Should -BeTrue
            $AllowAbsentProtectionQueue.IsPresent | Should -BeTrue
        }
        try {
            $result = & $closeCommand $context
            $result.status | Should -BeExactly 'ClosedZeroWritersObserved'
            $mutations.Count | Should -Be 2
            $mutations | Should -Contain "$appId/revisions/api--old/deactivate".ToLowerInvariant()
            $mutations | Should -Contain "$workerId/revisions/worker--old/deactivate".ToLowerInvariant()
            $mutations | Should -Not -Contain "$sentinelId/deactivate".ToLowerInvariant()
            $context.Contains('cutoverDeadline') | Should -BeFalse
        }
        finally { Remove-Module -ModuleInfo $execution -Force }
    }
}
