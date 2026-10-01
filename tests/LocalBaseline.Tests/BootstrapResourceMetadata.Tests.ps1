BeforeAll {
    $metadataModule = $null
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $loops = @{}
    foreach ($source in @(
        @{ surface = 'Foundation'; file = 'Experience.psm1'; function = 'Test-GatewaySubscriptionDeploymentEvidence'; marker = 'Microsoft.App/managedEnvironments' },
        @{ surface = 'Roles'; file = 'Verification.psm1'; function = 'Assert-GatewayExactAzureRoleAssignments'; marker = 'Microsoft.Storage/storageAccounts' }
    )) {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $root "bootstrap\modules\$($source.file)"), [ref]$tokens, [ref]$errors)
        if ($errors.Count -ne 0) { throw 'The actual metadata verifier must parse.' }
        $function = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $source.function
        }, $false)
        if ($null -eq $function) { throw 'The actual metadata verifier function is missing.' }
        $matches = @($function.Body.FindAll({
            param($node)
            $node -is [Management.Automation.Language.ForEachStatementAst] -and
                $node.Variable.VariablePath.UserPath -ceq 'resource' -and
                $node.Condition.Extent.Text.Contains($source.marker, [StringComparison]::Ordinal)
        }, $false))
        if ($matches.Count -ne 1) { throw "The exact $($source.surface) metadata loop is not unique." }
        $loops[$source.surface] = [scriptblock]::Create($matches[0].Extent.Text)
    }

    $metadataModule = New-Module -Name "BootstrapMetadataFixture_$([guid]::NewGuid().ToString('N'))" `
        -ArgumentList $loops -ScriptBlock {
        param($loops)
        Set-StrictMode -Version Latest
        $script:Loops = $loops
        $script:Calls = [Collections.Generic.List[object]]::new()
        $script:Expected = @{}
        $script:Fault = ''
        $script:FaultIndex = 0

        function Invoke-AzJson {
            param([string[]]$Arguments)
            if ($Arguments.Count -lt 6 -or $Arguments[0] -cne 'resource' -or $Arguments[1] -cne 'show') {
                throw 'Unscripted Azure access is forbidden.'
            }
            $options = @{}
            for ($index = 2; $index -lt $Arguments.Count; $index += 2) {
                if ($index + 1 -ge $Arguments.Count -or
                    $Arguments[$index] -cnotin @('--ids', '--query', '--api-version') -or
                    $options.ContainsKey($Arguments[$index])) {
                    throw 'The exact read arguments are not accepted by this finite transport.'
                }
                $options[$Arguments[$index]] = $Arguments[$index + 1]
            }
            if (-not $options.ContainsKey('--ids') -or -not $script:Expected.ContainsKey($options['--ids'])) {
                throw 'The resource is outside the synthetic metadata allowlist.'
            }
            $expected = $script:Expected[$options['--ids']]
            if (-not $options.ContainsKey('--api-version') -or $options['--api-version'] -cne $expected.apiVersion) {
                throw 'NoRegisteredProviderFound: the unpinned or unexpected API version is unsupported.'
            }
            if (-not $options.ContainsKey('--query') -or $options['--query'] -cne $script:ExpectedQuery) {
                throw 'The metadata projection changed.'
            }
            $callIndex = $script:Calls.Count
            $script:Calls.Add(@{ id = $expected.id; apiVersion = $options['--api-version'] })
            $actual = @{
                id = $expected.id; type = $expected.type; name = $expected.name
                ownershipId = '11111111-1111-4111-8111-111111111111'
                sourceFingerprint = 'sha256:' + ('a' * 64)
            }
            if ($callIndex -eq $script:FaultIndex) {
                switch -CaseSensitive ($script:Fault) {
                    'ProviderFailure' { throw 'NoRegisteredProviderFound: synthetic provider failure.' }
                    'MissingMetadata' { return $null }
                    'WrongId' { $actual.id += '-different' }
                    'WrongType' { $actual.type = 'Microsoft.Storage/storageAccounts' }
                    'WrongName' { $actual.name = 'different' }
                    'WrongOwnership' { $actual.ownershipId = '22222222-2222-4222-8222-222222222222' }
                    'WrongSource' { $actual.sourceFingerprint = 'sha256:' + ('b' * 64) }
                }
            }
            return $actual
        }

        function New-BootstrapValidationMismatchException {
            param([string]$PropertyName)
            return [InvalidOperationException]::new("Synthetic metadata mismatch: $PropertyName")
        }

        function Invoke-BootstrapMetadataFixture {
            param(
                [ValidateSet('Foundation', 'Roles')][string]$Surface,
                [bool]$PurviewEnabled = $true,
                [string]$Fault = '',
                [int]$FaultIndex = 0
            )
            $script:Calls.Clear()
            $script:Expected.Clear()
            $script:Fault = $Fault
            $script:FaultIndex = $FaultIndex
            $scope = '/subscriptions/33333333-3333-4333-8333-333333333333/resourceGroups/rg-synthetic/providers'
            $canonicalOwnershipId = '11111111-1111-4111-8111-111111111111'
            $SourceFingerprint = 'sha256:' + ('a' * 64)
            $Runtime = @{ deploymentOwnershipId = $canonicalOwnershipId; sourceFingerprint = $SourceFingerprint }
            $Evidence = @{
                containerAppsEnvironmentId = "$scope/Microsoft.App/managedEnvironments/environment"
                containerAppsEnvironmentName = 'environment'
                virtualNetworkId = "$scope/Microsoft.Network/virtualNetworks/network"
                virtualNetworkName = 'network'
                privateEndpointSubnetId = "$scope/Microsoft.Network/virtualNetworks/network/subnets/private"
                privateEndpointSubnetName = 'private'
            }
            $storageId = "$scope/Microsoft.Storage/storageAccounts/storage"
            $expectedRegistryId = "$scope/Microsoft.ContainerRegistry/registries/registry"
            $expectedVaultId = "$scope/Microsoft.KeyVault/vaults/vault"
            $expectedQueueId = "$scope/Microsoft.ServiceBus/namespaces/bus/queues/provisioning"
            $expectedProtectionQueueId = "$scope/Microsoft.ServiceBus/namespaces/bus/queues/protection"
            $purviewCapabilityEnabled = $PurviewEnabled
            $resources = if ($Surface -ceq 'Foundation') {
                $script:ExpectedQuery = '{id:id,type:type,name:name,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
                @(
                    @{ id = $Evidence.containerAppsEnvironmentId; type = 'Microsoft.App/managedEnvironments'; name = 'environment'; apiVersion = '2024-03-01' },
                    @{ id = $Evidence.virtualNetworkId; type = 'Microsoft.Network/virtualNetworks'; name = 'network'; apiVersion = '2023-11-01' },
                    @{ id = $Evidence.privateEndpointSubnetId; type = 'Microsoft.Network/virtualNetworks/subnets'; name = 'network/private'; apiVersion = '2023-11-01' }
                )
            }
            else {
                $script:ExpectedQuery = '{id:id,type:type,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}'
                @(
                    @{ id = $storageId; type = 'Microsoft.Storage/storageAccounts'; name = 'storage'; apiVersion = '2023-05-01' },
                    @{ id = $expectedRegistryId; type = 'Microsoft.ContainerRegistry/registries'; name = 'registry'; apiVersion = '2023-11-01-preview' },
                    @{ id = $expectedVaultId; type = 'Microsoft.KeyVault/vaults'; name = 'vault'; apiVersion = '2023-07-01' },
                    @{ id = $expectedQueueId; type = 'Microsoft.ServiceBus/namespaces/queues'; name = 'bus/provisioning'; apiVersion = '2024-01-01' }
                    if ($PurviewEnabled) {
                        @{ id = $expectedProtectionQueueId; type = 'Microsoft.ServiceBus/namespaces/queues'; name = 'bus/protection'; apiVersion = '2024-01-01' }
                    }
                )
            }
            foreach ($resource in $resources) { $script:Expected[$resource.id] = $resource }
            . $script:Loops[$Surface]
            return @($script:Calls)
        }

        function Get-BootstrapMetadataFixtureCallCount { return $script:Calls.Count }
        Export-ModuleMember -Function Invoke-BootstrapMetadataFixture, Get-BootstrapMetadataFixtureCallCount
    }
    $metadataModule | Import-Module -NoClobber -DisableNameChecking
    $invokeMetadata = $metadataModule.ExportedCommands['Invoke-BootstrapMetadataFixture']
    $metadataCallCount = $metadataModule.ExportedCommands['Get-BootstrapMetadataFixtureCallCount']
}

AfterAll {
    if ($metadataModule) { Remove-Module $metadataModule -Force }
}

Describe 'Canonical resource metadata uses reviewed explicit API versions' {
    It 'reads all three foundation metadata resources with their template versions' {
        $calls = @(& $invokeMetadata -Surface Foundation)
        $calls.Count | Should -Be 3
        ($calls.apiVersion -join '|') | Should -Be '2024-03-01|2023-11-01|2023-11-01'
    }

    It 'reads every enabled RBAC target using an explicit reviewed version' {
        $calls = @(& $invokeMetadata -Surface Roles)
        $calls.Count | Should -Be 5
        ($calls.apiVersion -join '|') | Should -Be '2023-05-01|2023-11-01-preview|2023-07-01|2024-01-01|2024-01-01'
    }

    It 'does not invent a protection queue when Purview is disabled' {
        $calls = @(& $invokeMetadata -Surface Roles -PurviewEnabled $false)
        $calls.Count | Should -Be 4
        @($calls | Where-Object id -Like '*/queues/protection').Count | Should -Be 0
    }

    It 'still rejects foundation metadata mismatch: <_>' -ForEach @(
        'WrongId', 'WrongType', 'WrongName', 'WrongOwnership', 'WrongSource', 'MissingMetadata'
    ) {
        { & $invokeMetadata -Surface Foundation -Fault $_ } | Should -Throw
        (& $metadataCallCount) | Should -Be 1
    }

    It 'still rejects RBAC metadata mismatch: <_>' -ForEach @(
        'WrongId', 'WrongType', 'WrongOwnership', 'WrongSource', 'MissingMetadata'
    ) {
        { & $invokeMetadata -Surface Roles -Fault $_ -FaultIndex 1 } | Should -Throw
        (& $metadataCallCount) | Should -Be 2
    }

    It 'preserves the untagged subnet contract' {
        @(& $invokeMetadata -Surface Foundation -Fault WrongOwnership -FaultIndex 2).Count | Should -Be 3
    }

    It 'preserves the untagged queue contract' {
        @(& $invokeMetadata -Surface Roles -Fault WrongSource -FaultIndex 3).Count | Should -Be 5
    }

    It 'does not retry, default or treat provider failure as absence on <_>' -ForEach @('Foundation', 'Roles') {
        { & $invokeMetadata -Surface $_ -Fault ProviderFailure } |
            Should -Throw '*NoRegisteredProviderFound*'
        (& $metadataCallCount) | Should -Be 1
    }
}
