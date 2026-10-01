BeforeAll {
    $tokens = $null
    $errors = $null
    $path = Join-Path $PSScriptRoot '..\..\operations\upgrade-bootstrap-admin-ui.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'Admin UI upgrade source must parse before validation tests.' }
    $readback = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '..\..\operations\GatewayAdminUiReadback.psm1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'Shared Admin UI readback source must parse before validation tests.' }
    $functions = @(
        'Test-UpgradedAdminUi', 'Read-AdminUiUpgradeReceipt',
        'Get-AdminUiUpgradeIntent', 'Get-AdminUiUpgradeSourceMetadata', 'Assert-AdminUiUpgradeReceipt', 'Assert-AdminUiUpgradeCurrentImage',
        'Get-AdminUiUpgradePriorEvidence', 'Get-AdminUiUpgradeParameters', 'Assert-AdminDeploymentResult',
        'Get-AdminUiLiveBoundary', 'Get-ExactAdminRoleAssignment'
    )
    $common = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '..\..\bootstrap\modules\Common.psm1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'Common source must parse before validation tests.' }
    $commonFunctions = @(
        'Get-BootstrapSha256', 'ConvertTo-BootstrapCanonicalValue', 'Get-BootstrapObjectFingerprint',
        'Get-BootstrapDeterministicGuid', 'Get-BootstrapImageBuildIntentTag',
        'Assert-BootstrapFingerprintValue', 'Assert-BootstrapSourcePathIsRegular',
        'Test-GatewayContainerAppRevisionRunning'
    )
    $azure = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '..\..\bootstrap\modules\Azure.psm1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'ACR source must parse before validation tests.' }
    $definitions = foreach ($source in @(
        @{ Ast = $ast; Names = @('Invoke-AdminUiUpgradeWhatIf') }
        @{ Ast = $readback; Names = $functions }
        @{ Ast = $common; Names = $commonFunctions }
        @{ Ast = $azure; Names = @('Assert-GatewayAcrCompletedBuildContract') }
    )) {
        foreach ($name in $source.Names) {
            $definition = $source.Ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $false)
            if ($null -eq $definition) { throw "The real '$name' helper is required." }
            $definition.Extent.Text
        }
    }
    # Only the actual admission block runs: bootstrap authentication, build, and
    # deployment entry points are never evaluated by this synthetic driver.
    $main = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[0]
    $admission = @()
    $capturing = $false
    foreach ($statement in $main.Body.Statements) {
        if ($statement.Extent.Text.StartsWith('$receipt = Read-AdminUiUpgradeReceipt')) { $capturing = $true }
        if ($capturing) { $admission += $statement.Extent.Text }
        if ($statement.Extent.Text.StartsWith('Assert-AdminUiUpgradeCurrentImage')) { break }
    }
    if ($admission.Count -lt 5 -or $admission[-1] -notlike 'Assert-AdminUiUpgradeCurrentImage*') {
        throw 'The exact driver admission and recovery-image boundary are required.'
    }
    $module = New-Module -Name "AdminUiWhatIfFixture_$([guid]::NewGuid().ToString('N'))" -ArgumentList ($definitions -join "`n"), $TestDrive, ($admission -join "`n") -ScriptBlock {
        param($definition, $root, $admission)
        Set-StrictMode -Version Latest
        $script:repositoryRoot = $root
        $script:admission = [scriptblock]::Create($admission)
        function Invoke-AzJson { param([string[]]$Arguments) throw 'Unscripted Azure access is forbidden.' }
        function New-ArmParameterFile { param([System.Collections.IDictionary]$Parameters) throw 'Unscripted parameter output is forbidden.' }
        function Test-AdminUiHttpBoundary {
            param($Fqdn, $TenantId, $ClientId)
            throw 'Unscripted HTTP access is forbidden.'
        }
        function Get-GatewayAcrExactRunById { param($Registry, $Repository, $Tag, $RunId) throw 'Unscripted ACR run access is forbidden.' }
        function Get-GatewayAcrExactTagDigest { param($Registry, $Repository, $Tag) throw 'Unscripted ACR tag access is forbidden.' }
        function Get-GatewayAcrExactImageRuns { param($Registry, $Repository, $Tag) throw 'Unscripted ACR discovery is forbidden.' }
        function Get-BootstrapSourceFingerprint { param($Root) return ('sha256:' + ('1' * 64)) }
        function Save-AdminUiUpgradeReceipt { param($Receipt, $Path) throw 'Unscripted receipt mutation is forbidden.' }
        function Resolve-AdminUiBuild { throw 'Build mutations are forbidden.' }
        function Deploy-AdminUiUpgrade { throw 'Deployment mutations are forbidden.' }
        . ([scriptblock]::Create($definition))
        function Invoke-FixtureAdmission {
            param($Configuration, $State, $Completion, $SourceMetadata, $AdminBefore, $BootstrapSourceFingerprint)
            $ownershipId = [string]$Completion.deploymentOwnershipId
            $foundation = $State.steps['Azure foundation'].evidence
            $buildSourceFingerprint = [string]$SourceMetadata.buildSourceFingerprint
            $upgradeSourceFingerprint = [string]$SourceMetadata.upgradeSourceFingerprint
            $intent = Get-AdminUiUpgradeIntent -Configuration $Configuration -Completion $Completion -ConfigurationFingerprint $State.configurationFingerprint -UpgradeSourceFingerprint $upgradeSourceFingerprint
            $intentId = $intent.intentId
            $tag = $intent.tag
            $deploymentName = $intent.deploymentName
            $locatorFingerprint = $intent.locatorFingerprint
            $receiptPath = Join-Path $repositoryRoot ".bootstrap\evidence\$($Configuration.resourceGroupName)\admin-ui-upgrade\$($locatorFingerprint.Substring(7)).json"
            $apiBefore = @{ image = $State.steps['Gateway runtime deployment'].evidence.apiImage }
            $workerBefore = @{ image = $State.steps['Gateway runtime deployment'].evidence.workerImage }
            $queuesBefore = @()
            $prospectiveWhatIf = @(@{ resourceId = $AdminBefore.appId; changeType = 'Deploy' })
            . $script:admission
            return @{ receipt = $receipt; created = $createdReceipt; path = $receiptPath }
        }
        Export-ModuleMember -Function Invoke-AdminUiUpgradeWhatIf, Test-UpgradedAdminUi,
            Read-AdminUiUpgradeReceipt, Get-AdminUiUpgradeIntent, Get-AdminUiUpgradePriorEvidence,
            Get-AdminUiUpgradeSourceMetadata, Get-AdminUiUpgradeParameters, Get-BootstrapObjectFingerprint, Assert-AdminUiUpgradeReceipt,
            Assert-AdminUiUpgradeCurrentImage, Invoke-FixtureAdmission
    }
    $module | Import-Module -NoClobber -DisableNameChecking
    $invoke = $module.ExportedCommands['Invoke-AdminUiUpgradeWhatIf']
    $verify = $module.ExportedCommands['Test-UpgradedAdminUi']
    $priorEvidence = $module.ExportedCommands['Get-AdminUiUpgradePriorEvidence']
    $intentFor = $module.ExportedCommands['Get-AdminUiUpgradeIntent']
    $fingerprintFor = $module.ExportedCommands['Get-BootstrapObjectFingerprint']
    $parametersFor = $module.ExportedCommands['Get-AdminUiUpgradeParameters']
    $readReceipt = $module.ExportedCommands['Read-AdminUiUpgradeReceipt']
    $currentImageGuard = $module.ExportedCommands['Assert-AdminUiUpgradeCurrentImage']
    $driverAdmission = $module.ExportedCommands['Invoke-FixtureAdmission']
    $configuration = [pscustomobject]@{ resourceGroupName = 'synthetic-ui-group' }
    $appId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/synthetic-ui-group/providers/Microsoft.App/containerApps/synthetic-ui'
}

Describe 'Healthy Admin UI revision readback' {
    BeforeEach {
        $image = 'synthetic.invalid/admin@sha256:' + ('b' * 64)
        $fingerprint = 'sha256:' + ('a' * 64)
        $boundary = @{
            image = $image
            app = @{
                tags = @{ adminUiUpgradeSourceFingerprint = $fingerprint }
                properties = @{ latestReadyRevisionName = 'synthetic-ui--1' }
            }
            appName = 'synthetic-ui'; fqdn = 'synthetic.invalid'
            principalId = '11111111-1111-4111-8111-111111111111'
            secretResourceId = '/synthetic/secret'
            localRegistryAuthenticationDisabled = $true
            keyVaultRbacOnly = $true
            keyVaultPublicNetworkDisabled = $true
        }
        $state = @{ steps = @{ 'Admin UI identity' = @{ evidence = @{ adminUiClientId = 'synthetic-client' } } } }
        $verifyConfiguration = [pscustomobject]@{ resourceGroupName = 'synthetic-ui-group'; tenantId = 'synthetic-tenant' }
        Mock Get-AdminUiLiveBoundary -ModuleName $module.Name { $boundary }
        Mock Test-AdminUiHttpBoundary -ModuleName $module.Name { @{ healthStatus = 200; signInStatus = 302 } }
        Mock Invoke-AzJson -ModuleName $module.Name { throw 'Unscripted revision read is forbidden.' }
    }

    It 'accepts a healthy ready replica in <_> state' -ForEach @('Running', 'RunningAtMaxScale') {
        $running = $_
        Mock Invoke-AzJson -ModuleName $module.Name {
            @(@{ name = 'synthetic-ui--1'; healthState = 'Healthy'; runningState = $running; replicas = 1 })
        }
        $result = & $verify -Configuration $verifyConfiguration -State $state -OwnershipId 'synthetic-owner' `
            -BootstrapSourceFingerprint $fingerprint -UpgradeSourceFingerprint $fingerprint -Image $image
        $result.runningState | Should -BeExactly $running
        Should -Invoke Test-AdminUiHttpBoundary -ModuleName $module.Name -Times 1 -Exactly
    }

    It 'rejects <_> even when other fields look healthy' -ForEach @('Stopped', 'Degraded', 'Failed', 'Processing', 'Unknown') {
        $running = $_
        Mock Invoke-AzJson -ModuleName $module.Name {
            @(@{ name = 'synthetic-ui--1'; healthState = 'Healthy'; runningState = $running; replicas = 1 })
        }
        { & $verify -Configuration $verifyConfiguration -State $state -OwnershipId 'synthetic-owner' `
            -BootstrapSourceFingerprint $fingerprint -UpgradeSourceFingerprint $fingerprint -Image $image } | Should -Throw
        Should -Invoke Test-AdminUiHttpBoundary -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'rejects an unhealthy or empty ready revision' -ForEach @(
        @{ Health = 'Unhealthy'; Replicas = 1 }
        @{ Health = 'Healthy'; Replicas = 0 }
    ) {
        Mock Invoke-AzJson -ModuleName $module.Name {
            @(@{ name = 'synthetic-ui--1'; healthState = $Health; runningState = 'RunningAtMaxScale'; replicas = $Replicas })
        }
        { & $verify -Configuration $verifyConfiguration -State $state -OwnershipId 'synthetic-owner' `
            -BootstrapSourceFingerprint $fingerprint -UpgradeSourceFingerprint $fingerprint -Image $image } | Should -Throw
        Should -Invoke Test-AdminUiHttpBoundary -ModuleName $module.Name -Times 0 -Exactly
    }
}

AfterAll {
    if ($null -ne $module) { Remove-Module -Name $module.Name -Force }
}

Describe 'Bounded Admin UI resource What-If' {
    BeforeEach {
        $parameterPath = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).json"
        [IO.File]::WriteAllText($parameterPath, '{}')
        Mock New-ArmParameterFile -ModuleName $module.Name { $parameterPath }
        Mock Invoke-AzJson -ModuleName $module.Name { throw 'Unexpected provider arguments.' }
    }

    It 'requests JSON resource changes without unrelated ignored resources' {
        Mock Invoke-AzJson -ModuleName $module.Name {
            @{ status = 'Succeeded'; changes = @(@{ resourceId = $appId; changeType = 'Deploy' }) }
        } -ParameterFilter {
            '--no-pretty-print' -cin $Arguments -and
            $Arguments[[Array]::IndexOf($Arguments, '--exclude-change-types') + 1] -ceq 'Ignore' -and
            $Arguments[[Array]::IndexOf($Arguments, '--result-format') + 1] -ceq 'ResourceIdOnly'
        }
        $result = @(& $invoke -Configuration $configuration -Parameters @{ environment = 'dev' } `
            -AllowedResourceIds @($appId) -AdminAppId $appId)
        $result.Count | Should -Be 1
        $result[0].resourceId | Should -BeExactly $appId.ToLowerInvariant()
        Should -Invoke Invoke-AzJson -ModuleName $module.Name -Times 1 -Exactly
        Test-Path -LiteralPath $parameterPath | Should -BeFalse
    }

    It 'still rejects unsafe or outside-allowlist changes' -ForEach @(
        @{ Kind = 'Create'; Outside = $false }
        @{ Kind = 'Delete'; Outside = $false }
        @{ Kind = 'Modify'; Outside = $true }
        @{ Kind = 'Deploy'; Outside = $true }
        @{ Kind = 'Ignore'; Outside = $true }
        @{ Kind = 'Unsupported'; Outside = $false }
    ) {
        $resource = if ($Outside) { "$appId-unapproved" } else { $appId }
        Mock Invoke-AzJson -ModuleName $module.Name {
            @{ status = 'Succeeded'; changes = @(@{ resourceId = $resource; changeType = $Kind }) }
        }
        { & $invoke -Configuration $configuration -Parameters @{ environment = 'dev' } `
            -AllowedResourceIds @($appId) -AdminAppId $appId } | Should -Throw
        Test-Path -LiteralPath $parameterPath | Should -BeFalse
    }

    It 'rejects a response with no exact UI change' {
        Mock Invoke-AzJson -ModuleName $module.Name { @{ status = 'Succeeded'; changes = @() } }
        { & $invoke -Configuration $configuration -Parameters @{ environment = 'dev' } `
            -AllowedResourceIds @($appId) -AdminAppId $appId } | Should -Throw
    }
}

Describe 'Canonical Admin UI successor admission without provider mutations' {
    BeforeAll {
        function New-SyntheticUpgradeSource {
            param([string]$Build = '6', [string]$Tool = '7')
            $value = @{ buildSourceFingerprint = "sha256:$($Build * 64)"; toolFingerprint = "sha256:$($Tool * 64)" }
            $value['upgradeSourceFingerprint'] = & $fingerprintFor -InputObject $value
            return $value
        }

        function New-SyntheticUpgradeReceipt {
            param($Source = $priorSource, [string]$Status = 'Accepted', [string]$Digest = $upgradedDigest)
            $intent = & $intentFor -Configuration $admissionConfiguration -Completion $completion `
                -ConfigurationFingerprint $admissionState.configurationFingerprint -UpgradeSourceFingerprint $Source.upgradeSourceFingerprint
            $plan = @{
                schemaVersion = 1; operation = 'BootstrapAdminUiOnlyUpgrade'
                subscriptionId = $admissionConfiguration.subscriptionId; tenantId = $admissionConfiguration.tenantId
                resourceGroupName = $admissionConfiguration.resourceGroupName; projectName = $admissionConfiguration.projectName
                environment = $admissionConfiguration.environment; deploymentOwnershipId = $ownership
                configurationFingerprint = $admissionState.configurationFingerprint
                acceptedBootstrapPlanFingerprint = $completion.acceptedPlanFingerprint
                acceptedBootstrapPlanRecordFingerprint = $completion.acceptedPlanRecordFingerprint
                baselineVerifiedAtUtc = $completion.verifiedAtUtc; baselineBootstrapSourceFingerprint = $bootstrapFingerprint
                buildSourceFingerprint = $Source.buildSourceFingerprint; upgradeToolFingerprint = $Source.toolFingerprint
                upgradeSourceFingerprint = $Source.upgradeSourceFingerprint
                baseline = @{
                    foundation = @{ acrName = 'syntheticregistry'; acrLoginServer = 'synthetic.invalid' }
                    api = @{ image = $admissionState.steps['Gateway runtime deployment'].evidence.apiImage }
                    worker = @{ image = $admissionState.steps['Gateway runtime deployment'].evidence.workerImage }
                    queues = @()
                    adminUi = @{ image = $originalImage; principalId = $principal; secretResourceId = $secretId }
                }
                build = @{
                    component = 'adminUi'; repository = 'gateway-admin'; dockerfile = 'src/Gateway.AdminUi/Dockerfile'
                    intentId = $intent.intentId; tag = $intent.tag
                }
                prospectiveWhatIf = @(@{ resourceId = $adminId; changeType = 'Deploy' })
                deployment = @{ name = $intent.deploymentName; mode = 'Incremental'; deployKeyVaultPrivateEndpoint = $false }
            }
            $receipt = @{
                schemaVersion = 1; operation = 'BootstrapAdminUiOnlyUpgrade'; status = $Status
                acceptedAtUtc = '2026-09-22T10:00:00.0000000+00:00'; updatedAtUtc = '2026-09-22T10:05:00.0000000+00:00'
                acceptedPlan = $plan; planFingerprint = & $fingerprintFor -InputObject $plan
                locatorFingerprint = $intent.locatorFingerprint
                build = @{
                    intentId = $intent.intentId; tag = $intent.tag; state = 'DigestCheckpointed'; runId = 'synthetic-run'
                    digest = $Digest; image = "synthetic.invalid/gateway-admin@$Digest"
                }
                deployment = @{
                    name = $intent.deploymentName; mode = 'Incremental'; deployKeyVaultPrivateEndpoint = $false
                    state = 'Succeeded'; completedAtUtc = '2026-09-22T10:04:00.0000000+00:00'
                }
            }
            if ($Status -ceq 'Verified') {
                $receipt['verifiedAtUtc'] = '2026-09-22T10:05:00.0000000+00:00'
                $receipt['result'] = @{
                    acceptedBootstrapPlanUnchanged = $true
                    adminUi = @{
                        image = $receipt.build.image; digest = $Digest
                        principalId = $principal; secretResourceId = $secretId
                    }
                }
            }
            return $receipt
        }

        function Save-SyntheticUpgradeReceipt {
            param($Receipt = $prior, [switch]$RehashPlan, [string]$Name)
            if ($RehashPlan) { $Receipt.planFingerprint = & $fingerprintFor -InputObject $Receipt.acceptedPlan }
            if (-not $Name) { $Name = "$($Receipt.locatorFingerprint.Substring(7)).json" }
            $path = Join-Path $receiptDirectory $Name
            [IO.File]::WriteAllText($path, ($Receipt | ConvertTo-Json -Depth 100))
            $preservedReceipts[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            return $path
        }
    }

    BeforeEach {
        $admissionConfiguration = [pscustomobject]@{
            subscriptionId = '22222222-2222-4222-8222-222222222222'
            tenantId = '11111111-1111-4111-8111-111111111111'
            resourceGroupName = 'synthetic-ui-group'; projectName = 'synthetic'; environment = 'dev'
        }
        $ownership = '33333333-3333-4333-8333-333333333333'
        $principal = '44444444-4444-4444-8444-444444444444'
        $clientId = '55555555-5555-4555-8555-555555555555'
        $bootstrapFingerprint = 'sha256:' + ('1' * 64)
        $originalImage = 'synthetic.invalid/gateway-admin@sha256:' + ('4' * 64)
        $upgradedDigest = 'sha256:' + ('5' * 64)
        $upgradedImage = "synthetic.invalid/gateway-admin@$upgradedDigest"
        $groupId = "/subscriptions/$($admissionConfiguration.subscriptionId)/resourceGroups/$($admissionConfiguration.resourceGroupName)"
        $adminId = "$groupId/providers/Microsoft.App/containerApps/ca-gateway-admin-dev"
        $identityId = "$groupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-admin-dev"
        $registryId = "$groupId/providers/Microsoft.ContainerRegistry/registries/syntheticregistry"
        $secretId = "$groupId/providers/Microsoft.KeyVault/vaults/kv-synthetic-dev/secrets/admin-ui-entra-client-secret"
        $secretUri = 'https://kv-synthetic-dev.vault.azure.net/secrets/admin-ui-entra-client-secret'
        $roleIds = @(
            "$registryId/providers/Microsoft.Authorization/roleAssignments/66666666-6666-4666-8666-666666666666"
            "$secretId/providers/Microsoft.Authorization/roleAssignments/77777777-7777-4777-8777-777777777777"
        )
        $completion = @{
            deploymentOwnershipId = $ownership; acceptedPlanFingerprint = 'sha256:' + ('a' * 64)
            acceptedPlanRecordFingerprint = 'sha256:' + ('b' * 64); verifiedAtUtc = '2026-09-22T09:00:00.0000000+00:00'
        }
        $admissionState = @{
            configurationFingerprint = 'sha256:' + ('2' * 64)
            steps = @{
                'Azure foundation' = @{ evidence = @{
                    acrName = 'syntheticregistry'; acrLoginServer = 'synthetic.invalid'
                    containerAppsEnvironmentName = 'synthetic-environment'
                } }
                'Gateway API identity' = @{ evidence = @{ gatewayApiScopeBaseUri = "api://$clientId" } }
                'Gateway runtime deployment' = @{ evidence = @{
                    apiImage = 'synthetic.invalid/gateway-api@sha256:' + ('a' * 64)
                    workerImage = 'synthetic.invalid/gateway-worker@sha256:' + ('b' * 64)
                } }
                'Admin UI identity' = @{ evidence = @{ adminUiClientId = $clientId } }
                'Admin UI Key Vault credential' = @{ evidence = @{ secretUri = $secretUri } }
                'Admin UI deployment' = @{ evidence = @{
                    adminUiImage = $originalImage; adminUiPrincipalId = $principal; sourceFingerprint = $bootstrapFingerprint
                } }
            }
        }
        $priorSource = New-SyntheticUpgradeSource
        $currentSource = New-SyntheticUpgradeSource -Build '8' -Tool '9'
        $currentIntent = & $intentFor -Configuration $admissionConfiguration -Completion $completion `
            -ConfigurationFingerprint $admissionState.configurationFingerprint -UpgradeSourceFingerprint $currentSource.upgradeSourceFingerprint
        $receiptDirectory = Join-Path $TestDrive '.bootstrap\evidence\synthetic-ui-group\admin-ui-upgrade'
        if (Test-Path -LiteralPath $receiptDirectory) { Remove-Item -LiteralPath $receiptDirectory -Recurse -Force }
        [IO.Directory]::CreateDirectory($receiptDirectory) | Out-Null
        $currentReceiptPath = Join-Path $receiptDirectory "$($currentIntent.locatorFingerprint.Substring(7)).json"
        $prior = New-SyntheticUpgradeReceipt
        $preservedReceipts = @{}
        $checkPreservedBytes = $true
        $expectedSaves = 0
        $identityReadback = [pscustomobject]@{
            name = 'id-gateway-admin-dev'; id = $identityId; principalId = $principal
            tags = @{ bootstrapOwnershipId = $ownership; bootstrapSourceFingerprint = $bootstrapFingerprint }
        }
        $appReadback = @{
            name = 'ca-gateway-admin-dev'; id = $adminId
            tags = @{
                bootstrapOwnershipId = $ownership; bootstrapSourceFingerprint = $bootstrapFingerprint
                adminUiUpgradeSourceFingerprint = $priorSource.upgradeSourceFingerprint
            }
            identity = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $identityId = @{} } }
            properties = @{
                provisioningState = 'Succeeded'; latestReadyRevisionName = 'synthetic-ui--1'
                template = @{ containers = @(@{ image = $upgradedImage }) }
                configuration = @{
                    activeRevisionsMode = 'Single'; ingress = @{ fqdn = 'synthetic.invalid' }
                    registries = @(@{ server = 'synthetic.invalid'; identity = $identityId })
                    secrets = @(@{ name = 'admin-ui-entra-client-secret'; keyVaultUrl = $secretUri; identity = $identityId })
                }
            }
        } | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $adminBoundary = @{
            image = $upgradedImage; principalId = $principal; secretResourceId = $secretId; fqdn = 'synthetic.invalid'
            appId = $adminId; identityId = $identityId; allowedRoleAssignmentIds = $roleIds
            app = $appReadback | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        }
        $runReadback = [pscustomobject]@{
            runId = 'synthetic-run'; runType = 'QuickRun'; status = 'Succeeded'
            outputImages = @([pscustomobject]@{ repository = 'gateway-admin'; tag = $prior.build.tag; digest = $upgradedDigest })
        }
        $tagReadback = [pscustomobject]@{ tag = $prior.build.tag; digest = $upgradedDigest }
        $expectedParameters = & $parametersFor -Configuration $admissionConfiguration -State $admissionState `
            -OwnershipId $ownership -BootstrapSourceFingerprint $bootstrapFingerprint `
            -UpgradeSourceFingerprint $priorSource.upgradeSourceFingerprint -Image $upgradedImage
        $deploymentParameters = @{}
        foreach ($entry in $expectedParameters.GetEnumerator()) { $deploymentParameters[$entry.Key] = @{ value = $entry.Value } }
        $deploymentReadback = [pscustomobject]@{
            name = $prior.deployment.name
            id = "$groupId/providers/Microsoft.Resources/deployments/$($prior.deployment.name)"
            properties = @{
                mode = 'Incremental'; provisioningState = 'Succeeded'; parameters = $deploymentParameters
                outputs = @{
                    deploymentOwnershipId = @{ value = $ownership }; bootstrapSourceFingerprint = @{ value = $bootstrapFingerprint }
                    adminUiUpgradeSourceFingerprint = @{ value = $priorSource.upgradeSourceFingerprint }
                    adminUiContainerImage = @{ value = $upgradedImage }
                }
            }
        }
        $revisionReadback = [pscustomobject]@{ name = 'synthetic-ui--1'; healthState = 'Healthy'; runningState = 'RunningAtMaxScale'; replicas = 1 }
        $readResponses = @{}
        $readResponses[(@('deployment', 'group', 'show', '--subscription', $admissionConfiguration.subscriptionId, '--resource-group', 'synthetic-ui-group', '--name', $prior.deployment.name) -join '|')] = $deploymentReadback
        $readResponses['identity|show|--resource-group|synthetic-ui-group|--name|id-gateway-admin-dev'] = $identityReadback
        $readResponses['containerapp|show|--resource-group|synthetic-ui-group|--name|ca-gateway-admin-dev'] = $appReadback
        $readResponses["resource|show|--ids|$registryId|--api-version|2023-11-01-preview"] = @{
            properties = @{ adminUserEnabled = $false; policies = @{ azureADAuthenticationAsArmPolicy = @{ status = 'enabled' } } }
        }
        $readResponses['keyvault|show|--resource-group|synthetic-ui-group|--name|kv-synthetic-dev'] = @{
            properties = @{ enableRbacAuthorization = $true; publicNetworkAccess = 'Disabled' }
        }
        $roleQuery = '[].{id:id,principalId:principalId,scope:scope,roleDefinitionId:roleDefinitionId}'
        $readResponses["role|assignment|list|--assignee-object-id|$principal|--scope|$registryId|--include-inherited|--query|$roleQuery"] = @(
            @{ id = $roleIds[0]; principalId = $principal; scope = $registryId; roleDefinitionId = '/roles/7f951dda-4ed3-4680-a7ca-43fe172d538d' }
        )
        $readResponses["role|assignment|list|--assignee-object-id|$principal|--scope|$secretId|--include-inherited|--query|$roleQuery"] = @(
            @{ id = $roleIds[1]; principalId = $principal; scope = $secretId; roleDefinitionId = '/roles/4633458b-17de-408a-b874-0445c86b69e6' }
        )
        $revisionKey = 'containerapp|revision|list|--resource-group|synthetic-ui-group|--name|ca-gateway-admin-dev|--query|[?properties.active==`true`].{name:name,healthState:properties.healthState,runningState:properties.runningState,replicas:properties.replicas}'
        $readResponses[$revisionKey] = @($revisionReadback)
        Mock Invoke-AzJson -ModuleName $module.Name {
            $key = $Arguments -join '|'
            if (-not $readResponses.ContainsKey($key)) { throw 'Unscripted Azure transport is forbidden.' }
            return $readResponses[$key]
        }
        Mock Test-AdminUiHttpBoundary -ModuleName $module.Name { throw 'Unscripted HTTP transport is forbidden.' }
        Mock Test-AdminUiHttpBoundary -ModuleName $module.Name {
            @{ healthStatus = 200; signInStatus = 302; authorityHost = 'login.microsoftonline.com' }
        } -ParameterFilter { $Fqdn -ceq 'synthetic.invalid' -and $TenantId -ceq $admissionConfiguration.tenantId -and $ClientId -ceq $clientId }
        Mock Get-GatewayAcrExactRunById -ModuleName $module.Name { throw 'Unscripted ACR run is forbidden.' }
        Mock Get-GatewayAcrExactRunById -ModuleName $module.Name { $runReadback } -ParameterFilter {
            $Registry -ceq 'syntheticregistry' -and $Repository -ceq 'gateway-admin' -and $Tag -ceq $prior.build.tag -and $RunId -ceq $prior.build.runId
        }
        Mock Get-GatewayAcrExactTagDigest -ModuleName $module.Name { throw 'Unscripted ACR tag is forbidden.' }
        Mock Get-GatewayAcrExactTagDigest -ModuleName $module.Name { $tagReadback } -ParameterFilter {
            $Registry -ceq 'syntheticregistry' -and $Repository -ceq 'gateway-admin' -and $Tag -ceq $prior.build.tag
        }
        Mock Get-GatewayAcrExactTagDigest -ModuleName $module.Name { $null } -ParameterFilter {
            $Registry -ceq 'syntheticregistry' -and $Repository -ceq 'gateway-admin' -and $Tag -ceq $currentIntent.tag
        }
        Mock Get-GatewayAcrExactImageRuns -ModuleName $module.Name { throw 'Unscripted ACR discovery is forbidden.' }
        Mock Get-GatewayAcrExactImageRuns -ModuleName $module.Name { @() } -ParameterFilter {
            $Registry -ceq 'syntheticregistry' -and $Repository -ceq 'gateway-admin' -and $Tag -ceq $currentIntent.tag
        }
        Mock Save-AdminUiUpgradeReceipt -ModuleName $module.Name { throw 'Unscripted receipt mutation is forbidden.' }
        Mock Resolve-AdminUiBuild -ModuleName $module.Name { throw 'Build mutation is forbidden.' }
        Mock Deploy-AdminUiUpgrade -ModuleName $module.Name { throw 'Deployment mutation is forbidden.' }
        $admissionArguments = @{
            Configuration = $admissionConfiguration; State = $admissionState; Completion = $completion
            SourceMetadata = $currentSource; BootstrapSourceFingerprint = $bootstrapFingerprint
            AdminUiBoundary = $adminBoundary; ReceiptPath = $currentReceiptPath
        }
        $driverArguments = @{
            Configuration = $admissionConfiguration; State = $admissionState; Completion = $completion
            SourceMetadata = $currentSource; BootstrapSourceFingerprint = $bootstrapFingerprint; AdminBefore = $adminBoundary
        }
    }

    AfterEach {
        if ($checkPreservedBytes) {
            foreach ($path in $preservedReceipts.Keys) {
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -BeExactly $preservedReceipts[$path]
            }
        }
        Should -Invoke Save-AdminUiUpgradeReceipt -ModuleName $module.Name -Times $expectedSaves -Exactly
        Should -Invoke Resolve-AdminUiBuild -ModuleName $module.Name -Times 0 -Exactly
        Should -Invoke Deploy-AdminUiUpgrade -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'admits the original bootstrap image without discovering or trusting any provider upgrade' {
        $adminBoundary.image = $originalImage
        $adminBoundary.app.tags.adminUiUpgradeSourceFingerprint = ''
        & $priorEvidence @admissionArguments | Should -BeNullOrEmpty
        Should -Invoke Get-GatewayAcrExactRunById -ModuleName $module.Name -Times 0 -Exactly
        Should -Invoke Invoke-AzJson -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'reverifies a <Label> receipt without relabeling or rewriting it' -ForEach @(
        @{ Label = 'completed (canonical Verified)'; Status = 'Verified' }
        @{ Label = 'post-check-failed Accepted + Succeeded'; Status = 'Accepted' }
    ) {
        $prior = New-SyntheticUpgradeReceipt -Status $Status
        $path = Save-SyntheticUpgradeReceipt
        $proof = & $priorEvidence @admissionArguments
        $proof.recordedStatus | Should -BeExactly $Status
        $proof.planFingerprint | Should -BeExactly $prior.planFingerprint
        $proof.receiptFileName | Should -BeExactly ([IO.Path]::GetFileName($path))
        $proof.receiptByteFingerprint | Should -BeExactly "sha256:$($preservedReceipts[$path].ToLowerInvariant())"
        $proof.upgradeSourceFingerprint | Should -BeExactly $priorSource.upgradeSourceFingerprint
        $proof.buildSourceFingerprint | Should -BeExactly $priorSource.buildSourceFingerprint
        $proof.upgradeToolFingerprint | Should -BeExactly $priorSource.toolFingerprint
        $proof.verification.kind | Should -BeExactly 'ReadOnlyPredecessorReverification'
        $proof.verification.verifierToolFingerprint | Should -BeExactly $currentSource.toolFingerprint
        $proof.verification.verifierUpgradeSourceFingerprint | Should -BeExactly $currentSource.upgradeSourceFingerprint
        $proof.verification.adminUi.image | Should -BeExactly $upgradedImage
        $proof.verification.adminUi.runningState | Should -BeExactly 'RunningAtMaxScale'
        $proof.verification.adminUi.http.healthStatus | Should -Be 200
        $proof.verification.acrRunFingerprint | Should -BeExactly (& $fingerprintFor -InputObject $runReadback)
        $proof.deployment.recordFingerprint | Should -BeExactly (& $fingerprintFor -InputObject $deploymentReadback)
        [DateTimeOffset]::Parse($proof.verification.verifiedAtUtc) | Should -BeGreaterThan ([DateTimeOffset]'2026-09-22T10:05:00Z')
        Should -Invoke Get-GatewayAcrExactRunById -ModuleName $module.Name -Times 1 -Exactly
        Should -Invoke Get-GatewayAcrExactTagDigest -ModuleName $module.Name -Times 1 -Exactly
        Should -Invoke Test-AdminUiHttpBoundary -ModuleName $module.Name -Times 1 -Exactly
        (& $readReceipt -Path $path).status | Should -BeExactly $Status
    }

    It 'binds prior bytes and fresh verification into the new immutable driver Plan only' {
        $priorPath = Save-SyntheticUpgradeReceipt
        $expectedSaves = 1
        Mock Save-AdminUiUpgradeReceipt -ModuleName $module.Name {
            [IO.File]::WriteAllText($Path, ($Receipt | ConvertTo-Json -Depth 100))
        } -ParameterFilter { $Path -ceq $currentReceiptPath }
        $result = & $driverAdmission @driverArguments
        $result.created | Should -BeTrue
        $stored = & $readReceipt -Path $result.path
        $stored.status | Should -BeExactly 'Accepted'
        $stored.build.state | Should -BeExactly 'IntentRecorded'
        $stored.deployment.state | Should -BeExactly 'Planned'
        $stored.acceptedPlan.baseline.adminUi.image | Should -BeExactly $upgradedImage
        $stored.acceptedPlan.priorUpgrade.receiptByteFingerprint | Should -BeExactly "sha256:$($preservedReceipts[$priorPath].ToLowerInvariant())"
        $stored.planFingerprint | Should -BeExactly (& $fingerprintFor -InputObject $stored.acceptedPlan)
        $stored.acceptedPlan.priorUpgrade.recordedStatus = 'Verified'
        (& $fingerprintFor -InputObject $stored.acceptedPlan) | Should -Not -BeExactly $stored.planFingerprint
        Should -Invoke Save-AdminUiUpgradeReceipt -ModuleName $module.Name -Times 0 -Exactly -ParameterFilter { $Path -ceq $priorPath }
    }

    It 'reverifies a <Status> predecessor for Full maintenance without a successor intent' -ForEach @(
        @{ Status = 'Verified' }
        @{ Status = 'Accepted' }
    ) {
        $prior = New-SyntheticUpgradeReceipt -Status $Status
        $path = Save-SyntheticUpgradeReceipt
        $arguments = $admissionArguments.Clone()
        $arguments.Remove('ReceiptPath')
        $arguments.ForFullMaintenance = $true
        $proof = & $priorEvidence @arguments
        $proof.recordedStatus | Should -BeExactly $Status
        $proof.context.resourceGroupName | Should -BeExactly $admissionConfiguration.resourceGroupName
        $proof.context.deploymentOwnershipId | Should -BeExactly $completion.deploymentOwnershipId
        $proof.context.bootstrapPlanFingerprint | Should -BeExactly $completion.acceptedPlanFingerprint
        $proof.context.configurationFingerprint | Should -BeExactly $admissionState.configurationFingerprint
        $proof.receiptSetFingerprint | Should -BeExactly (& $fingerprintFor -InputObject @{
            ([IO.Path]::GetFileName($path)) = "sha256:$($preservedReceipts[$path].ToLowerInvariant())"
        })
        (& $readReceipt -Path $path).status | Should -BeExactly $Status
        Should -Invoke Get-GatewayAcrExactRunById -ModuleName $module.Name -Times 1 -Exactly
        Should -Invoke Save-AdminUiUpgradeReceipt -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'allows same-source completed readback only for Full maintenance, not a new UI attempt' {
        $prior = New-SyntheticUpgradeReceipt -Source $currentSource
        $priorSource = $currentSource
        $path = Save-SyntheticUpgradeReceipt
        $adminBoundary.app.tags.adminUiUpgradeSourceFingerprint = $currentSource.upgradeSourceFingerprint
        $appReadback.tags.adminUiUpgradeSourceFingerprint = $currentSource.upgradeSourceFingerprint
        $runReadback.outputImages[0].tag = $prior.build.tag
        $tagReadback.tag = $prior.build.tag
        Mock Get-GatewayAcrExactTagDigest -ModuleName $module.Name { $tagReadback } -ParameterFilter {
            $Registry -ceq 'syntheticregistry' -and $Repository -ceq 'gateway-admin' -and $Tag -ceq $currentIntent.tag
        }
        $deploymentReadback.id = "$groupId/providers/Microsoft.Resources/deployments/$($prior.deployment.name)"
        $deploymentReadback.name = $prior.deployment.name
        $parameters = & $parametersFor -Configuration $admissionConfiguration -State $admissionState `
            -OwnershipId $completion.deploymentOwnershipId -BootstrapSourceFingerprint $bootstrapFingerprint `
            -UpgradeSourceFingerprint $currentSource.upgradeSourceFingerprint -Image $upgradedImage
        foreach ($key in $parameters.Keys) { $deploymentReadback.properties.parameters[$key].value = $parameters[$key] }
        $deploymentReadback.properties.outputs.adminUiUpgradeSourceFingerprint.value = $currentSource.upgradeSourceFingerprint
        $readResponses[(@('deployment', 'group', 'show', '--subscription', $admissionConfiguration.subscriptionId,
            '--resource-group', 'synthetic-ui-group', '--name', $prior.deployment.name) -join '|')] = $deploymentReadback
        { & $priorEvidence @admissionArguments } | Should -Throw '*current-source receipt*'
        $arguments = $admissionArguments.Clone()
        $arguments.Remove('ReceiptPath')
        $arguments.ForFullMaintenance = $true
        $proof = & $priorEvidence @arguments
        $proof.receiptFileName | Should -BeExactly ([IO.Path]::GetFileName($path))
        $proof.upgradeSourceFingerprint | Should -BeExactly $currentSource.upgradeSourceFingerprint
        Should -Invoke Save-AdminUiUpgradeReceipt -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'rejects incomplete <Build>/<Deployment> during Full baseline readback' -ForEach @(
        @{ Build = 'IntentRecorded'; Deployment = 'Planned' }
        @{ Build = 'RunQueued'; Deployment = 'Planned' }
        @{ Build = 'DigestCheckpointed'; Deployment = 'IntentRecorded' }
        @{ Build = 'DigestCheckpointed'; Deployment = 'Unknown' }
    ) {
        $prior.status = 'Accepted'
        $prior.build.state = $Build
        $prior.deployment.state = $Deployment
        $null = Save-SyntheticUpgradeReceipt
        $arguments = $admissionArguments.Clone()
        $arguments.Remove('ReceiptPath')
        $arguments.ForFullMaintenance = $true
        { & $priorEvidence @arguments } | Should -Throw '*Admin UI*'
        Should -Invoke Get-GatewayAcrExactRunById -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'rejects a malformed current-source receipt during Full readback instead of skipping it' {
        $null = Save-SyntheticUpgradeReceipt
        [IO.File]::WriteAllText($currentReceiptPath, 'null')
        $arguments = $admissionArguments.Clone()
        $arguments.Remove('ReceiptPath')
        $arguments.ForFullMaintenance = $true
        { & $priorEvidence @arguments } | Should -Throw '*receipt*'
        Should -Invoke Get-GatewayAcrExactRunById -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'binds both the entry driver and shared readback implementation into tool provenance' {
        $directory = Join-Path $TestDrive 'operations'
        $null = New-Item -ItemType Directory -Path $directory -Force
        $driverPath = Join-Path $directory 'upgrade-bootstrap-admin-ui.ps1'
        $readbackPath = Join-Path $directory 'GatewayAdminUiReadback.psm1'
        [IO.File]::WriteAllText($driverPath, 'synthetic driver')
        [IO.File]::WriteAllText($readbackPath, 'synthetic readback')
        $getMetadata = $module.ExportedCommands['Get-AdminUiUpgradeSourceMetadata']
        $first = & $getMetadata
        [IO.File]::WriteAllText($readbackPath, 'changed synthetic readback')
        $second = & $getMetadata
        $second.toolFingerprint | Should -Not -BeExactly $first.toolFingerprint
        $second.upgradeSourceFingerprint | Should -Not -BeExactly $first.upgradeSourceFingerprint
        $second.buildSourceFingerprint | Should -BeExactly $first.buildSourceFingerprint
        [IO.File]::WriteAllText($driverPath, 'changed synthetic driver')
        (& $getMetadata).toolFingerprint | Should -Not -BeExactly $second.toolFingerprint
        Should -Invoke Invoke-AzJson -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'rejects <Label> receipt bindings even with a recomputed Plan fingerprint' -ForEach @(
        @{ Label = 'different tenant'; Change = { param($r) $r.acceptedPlan.tenantId = '99999999-9999-4999-8999-999999999999' } }
        @{ Label = 'different subscription'; Change = { param($r) $r.acceptedPlan.subscriptionId = '99999999-9999-4999-8999-999999999999' } }
        @{ Label = 'different resource group'; Change = { param($r) $r.acceptedPlan.resourceGroupName = 'foreign-group' } }
        @{ Label = 'different project'; Change = { param($r) $r.acceptedPlan.projectName = 'foreign-project' } }
        @{ Label = 'different environment'; Change = { param($r) $r.acceptedPlan.environment = 'prod' } }
        @{ Label = 'different ownership'; Change = { param($r) $r.acceptedPlan.deploymentOwnershipId = '99999999-9999-4999-8999-999999999999' } }
        @{ Label = 'different configuration'; Change = { param($r) $r.acceptedPlan.configurationFingerprint = 'sha256:' + ('f' * 64) } }
        @{ Label = 'different bootstrap Plan'; Change = { param($r) $r.acceptedPlan.acceptedBootstrapPlanFingerprint = 'sha256:' + ('f' * 64) } }
        @{ Label = 'different bootstrap Plan record'; Change = { param($r) $r.acceptedPlan.acceptedBootstrapPlanRecordFingerprint = 'sha256:' + ('f' * 64) } }
        @{ Label = 'stale bootstrap verification'; Change = { param($r) $r.acceptedPlan.baselineVerifiedAtUtc = '2026-09-21T09:00:00.0000000+00:00' } }
        @{ Label = 'stale bootstrap source'; Change = { param($r) $r.acceptedPlan.baselineBootstrapSourceFingerprint = 'sha256:' + ('f' * 64) } }
        @{ Label = 'altered build source'; Change = { param($r) $r.acceptedPlan.buildSourceFingerprint = 'sha256:' + ('f' * 64) } }
        @{ Label = 'altered tool source'; Change = { param($r) $r.acceptedPlan.upgradeToolFingerprint = 'sha256:' + ('f' * 64) } }
        @{ Label = 'altered combined source'; Change = { param($r) $r.acceptedPlan.upgradeSourceFingerprint = 'sha256:' + ('f' * 64) } }
        @{ Label = 'malformed source'; Change = { param($r) $r.acceptedPlan.buildSourceFingerprint = 'not-a-fingerprint' } }
        @{ Label = 'different registry'; Change = { param($r) $r.acceptedPlan.baseline.foundation.acrName = 'foreignregistry' } }
        @{ Label = 'different registry authority'; Change = { param($r) $r.acceptedPlan.baseline.foundation.acrLoginServer = 'foreign.invalid' } }
        @{ Label = 'different API image'; Change = { param($r) $r.acceptedPlan.baseline.api.image = 'foreign.invalid/api@sha256:' + ('f' * 64) } }
        @{ Label = 'different worker image'; Change = { param($r) $r.acceptedPlan.baseline.worker.image = 'foreign.invalid/worker@sha256:' + ('f' * 64) } }
        @{ Label = 'different Admin identity'; Change = { param($r) $r.acceptedPlan.baseline.adminUi.principalId = '99999999-9999-4999-8999-999999999999' } }
        @{ Label = 'different secret scope'; Change = { param($r) $r.acceptedPlan.baseline.adminUi.secretResourceId += '-foreign' } }
        @{ Label = 'unbounded baseline image'; Change = { param($r) $r.acceptedPlan.baseline.adminUi.image = 'synthetic.invalid/admin:latest' } }
        @{ Label = 'unsupported Plan schema'; Change = { param($r) $r.acceptedPlan.schemaVersion = 2 } }
        @{ Label = 'different build intent'; Change = { param($r) $r.build.intentId = '99999999-9999-4999-8999-999999999999' } }
        @{ Label = 'different build tag'; Change = { param($r) $r.build.tag += '-other' } }
        @{ Label = 'different build repository'; Change = { param($r) $r.acceptedPlan.build.repository = 'gateway-api' } }
        @{ Label = 'different Dockerfile'; Change = { param($r) $r.acceptedPlan.build.dockerfile = 'src/Gateway.Api/Dockerfile' } }
        @{ Label = 'different deployment name'; Change = { param($r) $r.deployment.name += '-other' } }
        @{ Label = 'complete deployment mode'; Change = { param($r) $r.acceptedPlan.deployment.mode = 'Complete' } }
        @{ Label = 'private endpoint redeployment'; Change = { param($r) $r.acceptedPlan.deployment.deployKeyVaultPrivateEndpoint = $true } }
        @{ Label = 'altered locator'; Change = { param($r) $r.locatorFingerprint = 'sha256:' + ('f' * 64) } }
        @{ Label = 'missing checkpoint'; Change = { param($r) $r.Remove('build') } }
        @{ Label = 'mismatched digest'; Change = { param($r) $r.build.digest = 'sha256:' + ('f' * 64) } }
        @{ Label = 'tag rather than digest'; Change = { param($r) $r.build.image = 'synthetic.invalid/gateway-admin:latest' } }
        @{ Label = 'malformed run ID'; Change = { param($r) $r.build.runId = '../unknown' } }
        @{ Label = 'unsupported status'; Change = { param($r) $r.status = 'Unknown' } }
        @{ Label = 'noncanonical accepted status'; Change = { param($r) $r.status = 'accepted' } }
        @{ Label = 'noncanonical verified status'; Change = { param($r) $r.status = 'verified' } }
        @{ Label = 'unsupported receipt schema'; Change = { param($r) $r.schemaVersion = 2 } }
        @{ Label = 'unsupported operation'; Change = { param($r) $r.operation = 'SomeOtherUpgrade' } }
    ) {
        & $Change $prior
        $null = Save-SyntheticUpgradeReceipt -RehashPlan
        { & $priorEvidence @admissionArguments } | Should -Throw
        Should -Invoke Get-GatewayAcrExactRunById -ModuleName $module.Name -Times 0 -Exactly
        Should -Invoke Invoke-AzJson -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'rejects a Plan whose bytes no longer match its accepted fingerprint' {
        $prior.acceptedPlan.projectName = 'changed-without-acceptance'
        $null = Save-SyntheticUpgradeReceipt
        { & $priorEvidence @admissionArguments } | Should -Throw '*immutable accepted*'
        Should -Invoke Invoke-AzJson -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'rejects an incomplete or unknown <Build>/<Deployment> checkpoint even if the bootstrap image is live' -ForEach @(
        @{ Build = 'IntentRecorded'; Deployment = 'Planned' }
        @{ Build = 'RunQueued'; Deployment = 'Planned' }
        @{ Build = 'DigestCheckpointed'; Deployment = 'Planned' }
        @{ Build = 'DigestCheckpointed'; Deployment = 'IntentRecorded' }
        @{ Build = 'DigestCheckpointed'; Deployment = 'Unknown' }
        @{ Build = 'DigestCheckpointed'; Deployment = 'Failed' }
        @{ Build = 'IntentRecorded'; Deployment = 'Succeeded' }
    ) {
        $prior.build.state = $Build
        $prior.deployment.state = $Deployment
        $null = Save-SyntheticUpgradeReceipt
        $adminBoundary.image = $originalImage
        $adminBoundary.app.tags.adminUiUpgradeSourceFingerprint = ''
        { & $priorEvidence @admissionArguments } | Should -Throw
        Should -Invoke Get-GatewayAcrExactRunById -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'rejects malformed prior JSON <Json> rather than silently skipping it' -ForEach @(
        @{ Json = 'null' }
        @{ Json = 'false' }
        @{ Json = '[]' }
        @{ Json = '{}' }
        @{ Json = '{ invalid' }
        @{ Json = '{"status":"Accepted","status":"Verified"}' }
        @{ Json = '{"status":"Accepted","STATUS":"Verified"}' }
        @{ Json = '{"acceptedPlan":{"build":{"tag":"one","tag":"two"}}}' }
    ) {
        $path = Join-Path $receiptDirectory "$('f' * 64).json"
        [IO.File]::WriteAllText($path, $Json)
        $preservedReceipts[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        { & $priorEvidence @admissionArguments } | Should -Throw
        Should -Invoke Invoke-AzJson -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'rejects a prior receipt stored at a different deterministic filename' {
        $null = Save-SyntheticUpgradeReceipt -Name "$('f' * 64).json"
        { & $priorEvidence @admissionArguments } | Should -Throw '*locator*'
    }

    It 'rejects duplicate image receipts without guessing which source owns the live image' {
        $null = Save-SyntheticUpgradeReceipt
        $other = New-SyntheticUpgradeReceipt -Source (New-SyntheticUpgradeSource -Tool 'a')
        $null = Save-SyntheticUpgradeReceipt -Receipt $other
        { & $priorEvidence @admissionArguments } | Should -Throw '*ambiguity*'
        Should -Invoke Get-GatewayAcrExactRunById -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'allows older completed history with a different image but never uses it as current proof' {
        $priorPath = Save-SyntheticUpgradeReceipt
        $older = New-SyntheticUpgradeReceipt -Source (New-SyntheticUpgradeSource -Tool 'a') -Status 'Verified' -Digest ('sha256:' + ('c' * 64))
        $null = Save-SyntheticUpgradeReceipt -Receipt $older
        $proof = & $priorEvidence @admissionArguments
        $proof.receiptFileName | Should -BeExactly ([IO.Path]::GetFileName($priorPath))
        Should -Invoke Get-GatewayAcrExactRunById -ModuleName $module.Name -Times 1 -Exactly
    }

    It 'does not ignore malformed or incomplete nonmatching history' -ForEach @(
        @{ Label = 'malformed'; Json = '[]' }
        @{ Label = 'incomplete'; Json = $null }
    ) {
        $null = Save-SyntheticUpgradeReceipt
        if ($Json) {
            [IO.File]::WriteAllText((Join-Path $receiptDirectory "$('f' * 64).json"), $Json)
        }
        else {
            $other = New-SyntheticUpgradeReceipt -Source (New-SyntheticUpgradeSource -Tool 'a') -Digest ('sha256:' + ('c' * 64))
            $other.deployment.state = 'IntentRecorded'
            $null = Save-SyntheticUpgradeReceipt -Receipt $other
        }
        { & $priorEvidence @admissionArguments } | Should -Throw
        Should -Invoke Get-GatewayAcrExactRunById -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'rejects an arbitrary current image or missing and stale current source tags' -ForEach @(
        @{ Label = 'arbitrary image'; Change = { $adminBoundary.image = 'synthetic.invalid/gateway-admin@sha256:' + ('f' * 64) } }
        @{ Label = 'missing tag'; Change = { $adminBoundary.app.tags.PSObject.Properties.Remove('adminUiUpgradeSourceFingerprint') } }
        @{ Label = 'stale tag'; Change = { $adminBoundary.app.tags.adminUiUpgradeSourceFingerprint = 'sha256:' + ('f' * 64) } }
    ) {
        $null = Save-SyntheticUpgradeReceipt
        . $Change
        { & $priorEvidence @admissionArguments } | Should -Throw
        Should -Invoke Get-GatewayAcrExactRunById -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'does not discover receipts outside the owned directory or in its descendants' -ForEach @(
        @{ Relative = 'nested' }
        @{ Relative = '..\other-upgrades' }
    ) {
        $elsewhere = Join-Path $receiptDirectory $Relative
        [IO.Directory]::CreateDirectory($elsewhere) | Out-Null
        [IO.File]::WriteAllText((Join-Path $elsewhere "$($prior.locatorFingerprint.Substring(7)).json"), ($prior | ConvertTo-Json -Depth 100))
        { & $priorEvidence @admissionArguments } | Should -Throw '*exactly one*'
        Should -Invoke Invoke-AzJson -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'rejects inconsistent historical successful verification instead of trusting the status' -ForEach @(
        @{ Label = 'missing result'; Change = { param($r) $r.Remove('result') } }
        @{ Label = 'different image'; Change = { param($r) $r.result.adminUi.image += '-other' } }
        @{ Label = 'different digest'; Change = { param($r) $r.result.adminUi.digest = 'sha256:' + ('f' * 64) } }
        @{ Label = 'different identity'; Change = { param($r) $r.result.adminUi.principalId = '99999999-9999-4999-8999-999999999999' } }
        @{ Label = 'different secret'; Change = { param($r) $r.result.adminUi.secretResourceId += '-other' } }
        @{ Label = 'changed bootstrap'; Change = { param($r) $r.result.acceptedBootstrapPlanUnchanged = $false } }
    ) {
        $prior = New-SyntheticUpgradeReceipt -Status 'Verified'
        & $Change $prior
        $null = Save-SyntheticUpgradeReceipt
        { & $priorEvidence @admissionArguments } | Should -Throw
        Should -Invoke Get-GatewayAcrExactRunById -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'independently rejects <Label> ACR evidence' -ForEach @(
        @{ Label = 'pending run'; Change = { $runReadback.status = 'Running' } }
        @{ Label = 'failed run'; Change = { $runReadback.status = 'Failed' } }
        @{ Label = 'different run'; Change = { $runReadback.runId = 'other-run' } }
        @{ Label = 'different run type'; Change = { $runReadback.runType = 'AutoRun' } }
        @{ Label = 'missing output'; Change = { $runReadback.outputImages = @() } }
        @{ Label = 'multiple outputs'; Change = { $runReadback.outputImages += $runReadback.outputImages[0] } }
        @{ Label = 'different output repository'; Change = { $runReadback.outputImages[0].repository = 'gateway-api' } }
        @{ Label = 'different output tag'; Change = { $runReadback.outputImages[0].tag += '-other' } }
        @{ Label = 'different run digest'; Change = { $runReadback.outputImages[0].digest = 'sha256:' + ('f' * 64) } }
        @{ Label = 'missing tag'; Change = { $tagReadback = $null } }
        @{ Label = 'different tag'; Change = { $tagReadback.tag += '-other' } }
        @{ Label = 'retagged digest'; Change = { $tagReadback.digest = 'sha256:' + ('f' * 64) } }
    ) {
        $null = Save-SyntheticUpgradeReceipt
        . $Change
        { & $priorEvidence @admissionArguments } | Should -Throw
        Should -Invoke Invoke-AzJson -ModuleName $module.Name -Times 0 -Exactly
        Should -Invoke Test-AdminUiHttpBoundary -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'independently rejects <Label> deployment evidence' -ForEach @(
        @{ Label = 'missing ARM deployment'; Change = {
            $key = @($readResponses.Keys | Where-Object { $_ -like 'deployment|*' })[0]
            $readResponses[$key] = $null
        } }
        @{ Label = 'unknown deployment'; Change = { $deploymentReadback.properties.provisioningState = 'Running' } }
        @{ Label = 'failed deployment'; Change = { $deploymentReadback.properties.provisioningState = 'Failed' } }
        @{ Label = 'different ID'; Change = { $deploymentReadback.id += '-foreign' } }
        @{ Label = 'different name'; Change = { $deploymentReadback.name += '-foreign' } }
        @{ Label = 'complete mode'; Change = { $deploymentReadback.properties.mode = 'Complete' } }
        @{ Label = 'different parameter tenant'; Change = { $deploymentParameters.entraIdTenantId.value = '99999999-9999-4999-8999-999999999999' } }
        @{ Label = 'different parameter Admin client'; Change = { $deploymentParameters.adminUiEntraClientId.value = '99999999-9999-4999-8999-999999999999' } }
        @{ Label = 'different API scope'; Change = { $deploymentParameters.adminUiGatewayApiScope.value = 'foreign-scope' } }
        @{ Label = 'different parameter source'; Change = { $deploymentParameters.adminUiUpgradeSourceFingerprint.value = 'sha256:' + ('f' * 64) } }
        @{ Label = 'different parameter bootstrap'; Change = { $deploymentParameters.bootstrapSourceFingerprint.value = 'sha256:' + ('f' * 64) } }
        @{ Label = 'different parameter ownership'; Change = { $deploymentParameters.deploymentOwnershipId.value = '99999999-9999-4999-8999-999999999999' } }
        @{ Label = 'different parameter image'; Change = { $deploymentParameters.adminUiContainerImage.value = $originalImage } }
        @{ Label = 'private endpoint enabled'; Change = { $deploymentParameters.deployKeyVaultPrivateEndpoint.value = $true } }
        @{ Label = 'different output image'; Change = { $deploymentReadback.properties.outputs.adminUiContainerImage.value = $originalImage } }
        @{ Label = 'different output source'; Change = { $deploymentReadback.properties.outputs.adminUiUpgradeSourceFingerprint.value = 'sha256:' + ('f' * 64) } }
        @{ Label = 'different output bootstrap'; Change = { $deploymentReadback.properties.outputs.bootstrapSourceFingerprint.value = 'sha256:' + ('f' * 64) } }
        @{ Label = 'different output ownership'; Change = { $deploymentReadback.properties.outputs.deploymentOwnershipId.value = '99999999-9999-4999-8999-999999999999' } }
    ) {
        $null = Save-SyntheticUpgradeReceipt
        . $Change
        { & $priorEvidence @admissionArguments } | Should -Throw
        Should -Invoke Test-AdminUiHttpBoundary -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'independently rejects <Label> live identity, image and readiness evidence' -ForEach @(
        @{ Label = 'different managed principal'; Change = { $identityReadback.principalId = '99999999-9999-4999-8999-999999999999' } }
        @{ Label = 'different managed identity owner'; Change = { $identityReadback.tags.bootstrapOwnershipId = '99999999-9999-4999-8999-999999999999' } }
        @{ Label = 'different managed identity source'; Change = { $identityReadback.tags.bootstrapSourceFingerprint = 'sha256:' + ('f' * 64) } }
        @{ Label = 'different app ownership'; Change = { $appReadback.tags.bootstrapOwnershipId = '99999999-9999-4999-8999-999999999999' } }
        @{ Label = 'different app bootstrap source'; Change = { $appReadback.tags.bootstrapSourceFingerprint = 'sha256:' + ('f' * 64) } }
        @{ Label = 'different app upgrade source'; Change = { $appReadback.tags.adminUiUpgradeSourceFingerprint = 'sha256:' + ('f' * 64) } }
        @{ Label = 'different live image'; Change = { $appReadback.properties.template.containers[0].image = $originalImage } }
        @{ Label = 'different identity type'; Change = { $appReadback.identity.type = 'SystemAssigned' } }
        @{ Label = 'different pull identity'; Change = { $appReadback.properties.configuration.registries[0].identity += '-foreign' } }
        @{ Label = 'different pull registry'; Change = { $appReadback.properties.configuration.registries[0].server = 'foreign.invalid' } }
        @{ Label = 'different secret identity'; Change = { $appReadback.properties.configuration.secrets[0].identity += '-foreign' } }
        @{ Label = 'different secret URI'; Change = { $appReadback.properties.configuration.secrets[0].keyVaultUrl += '/version' } }
        @{ Label = 'unhealthy revision'; Change = { $revisionReadback.healthState = 'Unhealthy' } }
        @{ Label = 'stopped revision'; Change = { $revisionReadback.runningState = 'Stopped' } }
        @{ Label = 'no replicas'; Change = { $revisionReadback.replicas = 0 } }
        @{ Label = 'wrong ready revision'; Change = { $revisionReadback.name = 'other-revision' } }
        @{ Label = 'multiple active revisions'; Change = { $readResponses[$revisionKey] += $revisionReadback } }
        @{ Label = 'missing active revision'; Change = { $readResponses[$revisionKey] = @() } }
        @{ Label = 'wrong role principal'; Change = {
            $key = @($readResponses.Keys | Where-Object { $_ -like 'role|assignment|list*' })[0]
            $readResponses[$key][0].principalId = '99999999-9999-4999-8999-999999999999'
        } }
        @{ Label = 'inherited broad role'; Change = {
            $key = @($readResponses.Keys | Where-Object { $_ -like 'role|assignment|list*' })[0]
            $readResponses[$key][0].scope = $groupId
        } }
        @{ Label = 'extra role'; Change = {
            $key = @($readResponses.Keys | Where-Object { $_ -like 'role|assignment|list*' })[0]
            $readResponses[$key] += $readResponses[$key][0]
        } }
        @{ Label = 'enabled ACR admin'; Change = {
            $readResponses["resource|show|--ids|$registryId|--api-version|2023-11-01-preview"].properties.adminUserEnabled = $true
        } }
        @{ Label = 'public Key Vault'; Change = {
            $readResponses['keyvault|show|--resource-group|synthetic-ui-group|--name|kv-synthetic-dev'].properties.publicNetworkAccess = 'Enabled'
        } }
    ) {
        $null = Save-SyntheticUpgradeReceipt
        . $Change
        { & $priorEvidence @admissionArguments } | Should -Throw
        Should -Invoke Test-AdminUiHttpBoundary -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'requires fresh HTTP proof even for a historically Verified receipt' {
        $prior = New-SyntheticUpgradeReceipt -Status 'Verified'
        $null = Save-SyntheticUpgradeReceipt
        Mock Test-AdminUiHttpBoundary -ModuleName $module.Name { throw 'Synthetic HTTP or sign-in failure.' } -ParameterFilter { $true }
        { & $priorEvidence @admissionArguments } | Should -Throw '*HTTP or sign-in failure*'
        Should -Invoke Test-AdminUiHttpBoundary -ModuleName $module.Name -Times 1 -Exactly
    }

    It 'rejects a receipt edited by another writer during read-only verification' {
        $path = Save-SyntheticUpgradeReceipt
        $checkPreservedBytes = $false
        Mock Test-AdminUiHttpBoundary -ModuleName $module.Name {
            [IO.File]::AppendAllText($path, ' ')
            @{ healthStatus = 200; signInStatus = 302 }
        } -ParameterFilter { $true }
        { & $priorEvidence @admissionArguments } | Should -Throw '*bytes changed*'
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Not -BeExactly $preservedReceipts[$path]
    }

    It 'rejects another receipt appearing during read-only verification' {
        $null = Save-SyntheticUpgradeReceipt
        Mock Test-AdminUiHttpBoundary -ModuleName $module.Name {
            [IO.File]::WriteAllText((Join-Path $receiptDirectory "$('f' * 64).json"), '{}')
            @{ healthStatus = 200; signInStatus = 302 }
        } -ParameterFilter { $true }
        { & $priorEvidence @admissionArguments } | Should -Throw '*set changed*'
    }

    It 'refuses predecessor discovery whenever the current receipt path already exists' {
        [IO.File]::WriteAllText($currentReceiptPath, 'null')
        { & $priorEvidence @admissionArguments } | Should -Throw '*current-source receipt*'
        Should -Invoke Invoke-AzJson -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'does not scan or replace a malformed current attempt (<_>) in the real driver' -ForEach @('null', '[]', '{}', '{ invalid') {
        $Json = $_
        $null = Save-SyntheticUpgradeReceipt
        [IO.File]::WriteAllText($currentReceiptPath, $Json)
        Mock Get-AdminUiUpgradePriorEvidence -ModuleName $module.Name { throw 'Current attempt must not enter adoption.' }
        { & $driverAdmission @driverArguments } | Should -Throw
        Should -Invoke Get-AdminUiUpgradePriorEvidence -ModuleName $module.Name -Times 0 -Exactly
        [IO.File]::ReadAllText($currentReceiptPath) | Should -BeExactly $Json
    }

    It 'preserves a same-source unknown build attempt without scanning or creating another intent' {
        $current = New-SyntheticUpgradeReceipt -Source $currentSource
        $current.acceptedPlan.baseline.adminUi.image = $upgradedImage
        $current.build.state = 'IntentRecorded'
        $current.deployment.state = 'Planned'
        foreach ($key in @('image', 'digest', 'runId')) { $current.build.Remove($key) }
        $null = Save-SyntheticUpgradeReceipt -Receipt $current -RehashPlan
        [IO.File]::WriteAllText((Join-Path $receiptDirectory "$('f' * 64).json"), '{ unrelated malformed receipt')
        Mock Get-AdminUiUpgradePriorEvidence -ModuleName $module.Name { throw 'Current attempt must not enter adoption.' }
        $result = & $driverAdmission @driverArguments
        $result.created | Should -BeFalse
        $result.receipt.build.state | Should -BeExactly 'IntentRecorded'
        Should -Invoke Get-AdminUiUpgradePriorEvidence -ModuleName $module.Name -Times 0 -Exactly
        Should -Invoke Get-GatewayAcrExactTagDigest -ModuleName $module.Name -Times 0 -Exactly
        Should -Invoke Get-GatewayAcrExactImageRuns -ModuleName $module.Name -Times 0 -Exactly
    }

    It 'keeps the exact current-attempt image recovery boundary for <Deployment>/<Choice>' -ForEach @(
        @{ Deployment = 'Planned'; Choice = 'baseline'; Allowed = $true }
        @{ Deployment = 'Planned'; Choice = 'target'; Allowed = $false }
        @{ Deployment = 'IntentRecorded'; Choice = 'baseline'; Allowed = $true }
        @{ Deployment = 'IntentRecorded'; Choice = 'target'; Allowed = $true }
        @{ Deployment = 'Succeeded'; Choice = 'baseline'; Allowed = $false }
        @{ Deployment = 'Succeeded'; Choice = 'target'; Allowed = $true }
        @{ Deployment = 'IntentRecorded'; Choice = 'foreign'; Allowed = $false }
        @{ Deployment = 'Succeeded'; Choice = 'foreign'; Allowed = $false }
    ) {
        $prior.deployment.state = $Deployment
        $image = switch ($Choice) { baseline { $originalImage } target { $upgradedImage } foreign { 'synthetic.invalid/foreign@sha256:' + ('f' * 64) } }
        if ($Allowed) { { & $currentImageGuard -Receipt $prior -Image $image } | Should -Not -Throw }
        else { { & $currentImageGuard -Receipt $prior -Image $image } | Should -Throw '*recovery boundary*' }
    }

    It 'still rejects a fresh current build collision before inspecting prior receipts' -ForEach @('tag', 'run') {
        $kind = $_
        $null = Save-SyntheticUpgradeReceipt
        if ($kind -ceq 'tag') {
            Mock Get-GatewayAcrExactTagDigest -ModuleName $module.Name { @{ digest = $upgradedDigest } } -ParameterFilter { $Tag -ceq $currentIntent.tag }
        }
        else {
            Mock Get-GatewayAcrExactImageRuns -ModuleName $module.Name { @(@{ runId = 'unknown-current-run' }) } -ParameterFilter { $Tag -ceq $currentIntent.tag }
        }
        Mock Get-AdminUiUpgradePriorEvidence -ModuleName $module.Name { throw 'Collision must not enter adoption.' }
        { & $driverAdmission @driverArguments } | Should -Throw '*collides*'
        Should -Invoke Get-AdminUiUpgradePriorEvidence -ModuleName $module.Name -Times 0 -Exactly
    }
}
