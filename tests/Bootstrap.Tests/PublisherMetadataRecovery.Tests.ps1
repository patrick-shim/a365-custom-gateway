BeforeAll {
    $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    foreach ($module in @('Common', 'Experience', 'Azure', 'Entra', 'PurviewPackage', 'PurviewExecutor')) {
        Import-Module "$repository/bootstrap/modules/$module.psm1" -Force -DisableNameChecking
    }
    if (Test-Path "$repository/bootstrap/modules/PublisherRecovery.psm1") {
        Import-Module "$repository/bootstrap/modules/PublisherRecovery.psm1" -Force -DisableNameChecking
    }
    # Reuse the existing non-executable, independently hashed ZIP fixture.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile("$repository/tests/Bootstrap.Tests/PurviewPackage.Tests.ps1", [ref]$tokens, [ref]$errors)
    $definition = $ast.Find({ param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'New-TestExecutorPackage'
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
    $engineAst = [Management.Automation.Language.Parser]::ParseFile("$repository/bootstrap/bootstrap.ps1", [ref]$tokens, [ref]$errors)
    foreach ($name in @('Get-GatewayResumeExecutionSource', 'Invoke-GatewayStateStep')) {
        $definition = $engineAst.Find({ param($n)
            $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $runtimeCommand = $engineAst.Find({ param($n)
        $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Invoke-GatewayStateStep' -and
        @($n.CommandElements | Where-Object { $_ -is [Management.Automation.Language.StringConstantExpressionAst] -and
            $_.Value -ceq 'Gateway runtime deployment' }).Count -eq 1
    }, $true)
    for ($i = 0; $i -lt $runtimeCommand.CommandElements.Count; $i++) {
        if ($runtimeCommand.CommandElements[$i] -is [Management.Automation.Language.CommandParameterAst] -and
            $runtimeCommand.CommandElements[$i].ParameterName -ceq 'Action') {
            $body = $runtimeCommand.CommandElements[$i + 1].ScriptBlock.Extent.Text
            $shippedRuntimeAction = [scriptblock]::Create($body.Substring(1, $body.Length - 2))
        }
    }
    function Invoke-ShippedRuntimeFixture {
        param($State)
        $f = $global:publisherRecoveryFixture
        $configuration = $f.config; $statePath = Get-BootstrapStatePath -Config $f.config
        $foundation = $State.steps['Azure foundation'].evidence; $inert = $State.steps['Inert identity deployment'].evidence
        $database = $f.database; $purviewRuntimeAutomation = $f.automation; $freshPurviewExecutorSelected = $true
        $purviewExecutorParameters = @{}; $identity = @{}; $blueprint = @{ managerApplicationIds = @() }
        $images = @{ api = 'fixture-api'; worker = 'fixture-worker' }; $purviewCapability = @{}; $enableProvisioning = $false
        Invoke-RecoveryStepFixture -State $State -Name 'Gateway runtime deployment' -Action {
            try { & $shippedRuntimeAction }
            catch {
                # Synthetic fixture diagnostics, before the normal wrapper drops
                # exception chains. Never installed in production tooling.
                $global:publisherRecoveryFixture.runtimeFailure = $_
                throw
            }
        }
    }
    function Invoke-RecoveryStepFixture {
        param($State, $Name, [scriptblock]$Action, [scriptblock]$Validate, [switch]$AlwaysRun, [string]$Mode = 'Resume')
        $statePath = Get-BootstrapStatePath -Config $global:publisherRecoveryFixture.config
        $configuration = $global:publisherRecoveryFixture.config
        $stepNames = @(Get-GatewayBootstrapStepNames)
        $activeAcceptedPlanFingerprint = $State.acceptedPlan.planFingerprint
        $activeDeploymentSourceFingerprint = $State.acceptedPlan.sourceFingerprint
        $executionSourceRoot = Assert-BootstrapPublisherRecoveryReceipt -State $State
        $activeExecutionSourceFingerprint = Get-BootstrapSourceFingerprint -Root $executionSourceRoot
        $stopwatch = [Diagnostics.Stopwatch]::StartNew(); $OutputFormat = 'Json'
        Invoke-GatewayStateStep -Name $Name -Action $Action -Validate $Validate -AlwaysRun:$AlwaysRun
    }
    function Set-FixtureInstalledState {
        param($State)
        $r = $State.freshPurviewExecutor; $proof = $State.publisherMetadataReconciliation.plan.provider
        $r.publication = ConvertTo-BootstrapCanonicalValue -Value $proof.publication
        $r.operations.publish.status = 'Completed'
        $r.operations.publish.evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $proof.publication
        $r.operations[$proof.enableName] = @{ status = 'Completed'; intentFingerprint = $proof.enableIntentFingerprint
            evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $r.host }
        $r.status = 'Installed'
        $f = $global:publisherRecoveryFixture
        $f.resources[$f.ids.site].properties.enabled = $true
        $f.hostSettings = @{
            WEBSITE_RUN_FROM_PACKAGE = "$($r.host.packageContainerUri.value)/$(([string]$r.package.receipt.packageDigest).Substring(7)).zip"
            WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID = 'SystemAssigned'; SCM_DO_BUILD_DURING_DEPLOYMENT = 'false'
            DOTNET_EnableDiagnostics = '0'; ASPNETCORE_ENVIRONMENT = 'Production'
            Executor__ClaimsContainerUri = "$($r.host.packageContainerUri.value -replace '/purview-executor-packages$', '/purview-executor-claims')"
            Executor__RuntimeManifestDigest = $r.package.receipt.runtimeManifestDigest; Executor__OperationTimeoutSeconds = '195'
            Purview__PolicyProvisioningEnabled = 'true'; Purview__PolicyProvisioningOrganization = $r.context.organization
            Purview__PolicyProvisioningApplicationId = $r.context.automationApplicationId
            Purview__PolicyProvisioningCertificateSecretUri = $r.context.certificateSecretUri
            Purview__PolicyProvisioningTimeoutSeconds = '180'
        }
        foreach ($entry in $r.host.executorBinding.value.GetEnumerator()) { $f.hostSettings["Executor__Binding__$($entry.Key)"] = [string]$entry.Value }
    }

    function ConvertTo-PublisherBaseFixtureSource {
        param([string]$Path, [string]$Text)
        # Reconstruct only the bounded pre-amendment glue in synthetic snapshots.
        # No Git dependency, operator snapshot, or production validator is mocked.
        if ($Path -ceq 'bootstrap/reconcile-publisher-metadata.ps1') {
            $Text = $Text.Replace(", 'AmendmentPlan', 'AmendmentExecute'", '')
            $start = $Text.IndexOf("    if (`$Mode -cin @('AmendmentPlan'")
            $end = $Text.IndexOf("`n}", $start)
            return $Text.Substring(0, $start) + @'
    Invoke-BootstrapPublisherMetadataReconciliation -Mode $Mode -Config $configuration `
        -StatePath (Get-BootstrapStatePath -Config $configuration) -ExpectedPlanFingerprint $ExpectedPlanFingerprint -Yes:$Yes |
        ConvertTo-Json -Depth 5
'@ + $Text.Substring($end)
        }
        $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        $functions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            Sort-Object { $_.Extent.StartOffset } -Descending)
        foreach ($function in $functions) {
            $body = $function.Extent.Text
            $body = $body.Replace("    if (`$State.Contains('hostSettingsAmendment') -and -not `$State.Contains('publisherMetadataReconciliation')) { throw 'Host settings amendment requires its original completed publisher receipt.' }", '')
            switch ($function.Name) {
                'Get-BootstrapAzureCliArguments' {
                    $start = $body.IndexOf("    if (`$commandGroup -ceq 'webapp')")
                    $end = $body.IndexOf('    $resourceCommandGroups', $start)
                    $body = $body.Remove($start, $end - $start)
                }
                'Get-BootstrapEffectiveDeploymentSourceFingerprint' {
                    $body = $body.Replace('$publisherRoot = Assert-BootstrapPublisherRecoveryReceipt', '$null = Assert-BootstrapPublisherRecoveryReceipt').
                        Replace('(Get-BootstrapSourceFingerprint -Root $publisherRoot)', '[string]$State.publisherMetadataReconciliation.plan.correctedSourceFingerprint')
                }
                'Get-BootstrapAssetSourceRoot' {
                    $body = $body.Replace('(Get-BootstrapSourceFingerprint -Root $corrected)', '[string]$State.publisherMetadataReconciliation.plan.correctedSourceFingerprint')
                }
                'Get-PurviewExecutorArmSettings' {
                    $body = @'
function Get-PurviewExecutorArmSettings {
    param([Parameter(Mandatory)][string]$SiteId)
    $scope = Get-PurviewExecutorArmScope -Id $SiteId
    if ($scope.resourcePath -notmatch '^Microsoft.Web/sites/[A-Za-z0-9-]+$') {
        throw 'Executor settings read requires the exact owned Web site resource ID.'
    }
    return Invoke-AzJson -CaptureStdoutOnly -Arguments @(
        'resource', 'invoke-action', '--subscription', $scope.subscriptionId,
        '--ids', "$SiteId/config/appsettings", '--action', 'list', '--api-version', '2024-11-01', '--query', 'properties')
}
'@
                }
                { $_ -cin @('Invoke-PurviewExecutorDeployment', 'Build-PurviewExecutorPublisher',
                    'Get-PurviewExecutorFreshContext', 'Install-BootstrapPurviewExecutor', 'Get-PurviewExecutorWorkerGrant') } {
                    $stateName = if ($_ -cin @('Invoke-PurviewExecutorDeployment', 'Build-PurviewExecutorPublisher')) {
                        '$PublisherRecoveryState'
                    } elseif ($_ -ceq 'Get-PurviewExecutorWorkerGrant') { '$state' } else { '$State' }
                    $body = $body.Replace('(Get-BootstrapSourceFingerprint -Root (Get-BootstrapExecutionSourceRoot))',
                        "$stateName.publisherMetadataReconciliation.plan.correctedSourceFingerprint")
                }
                'Get-BootstrapPublisherStableState' { $body = $body.Replace(", 'hostSettingsAmendment'", '') }
                'Assert-BootstrapPublisherParentPlan' {
                    $body = $body.Replace('Assert-BootstrapPublisherParentPlan', 'Assert-BootstrapPublisherRecoveryPlan').
                        Replace('[string]$State.source.lastWritten.bootstrapSourceFingerprint -cne [string]$plan.originalSourceFingerprint)',
                            "[string]`$State.source.lastWritten.bootstrapSourceFingerprint -cne [string]`$plan.originalSourceFingerprint -or`n        [string]`$plan.correctedSourceFingerprint -cne (Get-BootstrapSourceFingerprint))")
                }
                'Assert-BootstrapPublisherParentReceipt' {
                    $body = $body.Replace('Assert-BootstrapPublisherParentReceipt', 'Assert-BootstrapPublisherRecoveryReceipt').
                        Replace('Assert-BootstrapPublisherParentPlan', 'Assert-BootstrapPublisherRecoveryPlan')
                }
                { $_ -cin @('Assert-BootstrapPublisherRecoveryPlan', 'Assert-BootstrapPublisherRecoveryReceipt',
                    'Get-BootstrapHostSettingsReviewedFunctions', 'Get-BootstrapHostSettingsSourceSurface',
                    'Assert-BootstrapHostSettingsSourceDelta', 'Assert-BootstrapHostSettingsEligibility',
                    'Assert-BootstrapHostSettingsPlan', 'Assert-BootstrapHostSettingsAmendment',
                    'Get-BootstrapHostSettingsProof', 'Invoke-BootstrapHostSettingsAmendment') } { $body = '' }
            }
            $Text = $Text.Remove($function.Extent.StartOffset, $function.Extent.EndOffset - $function.Extent.StartOffset).
                Insert($function.Extent.StartOffset, $body)
        }
        return $Text
    }

    function New-PublisherRecoveryFixture {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory "$root/bootstrap/modules" -Force
        # Only known source files; never copy configuration, private inputs, or
        # deployment evidence from the checkout.
        foreach ($file in Get-ChildItem "$repository/bootstrap/modules" -Filter '*.psm1' -File) {
            Copy-Item $file.FullName "$root/bootstrap/modules"
        }
        Copy-Item "$repository/bootstrap/bootstrap.ps1" "$root/bootstrap"
        Copy-Item "$repository/bootstrap/reconcile-publisher-metadata.ps1" "$root/bootstrap"
        $null = New-Item -ItemType Directory "$root/bootstrap/infra", "$root/infrastructure/bicep", "$root/src/fixture" -Force
        Copy-Item "$repository/bootstrap/infra/purview-windows-executor.bicep" "$root/bootstrap/infra"
        Copy-Item "$repository/bootstrap/infra/purview-package-publisher-job.bicep" "$root/bootstrap/infra"
        [IO.File]::WriteAllText("$root/infrastructure/bicep/admin-ui.bicep", '// immutable synthetic asset')
        [IO.File]::WriteAllText("$root/src/fixture/runtime.cs", '// immutable synthetic runtime')
        [IO.File]::WriteAllText("$root/src/A365Gateway.slnx", '<Solution />')
        foreach ($path in @('bootstrap/modules/Common.psm1', 'bootstrap/modules/PurviewExecutor.psm1',
            'bootstrap/modules/PublisherRecovery.psm1', 'bootstrap/reconcile-publisher-metadata.ps1')) {
            $file = Join-Path $root $path
            [IO.File]::WriteAllText($file, (ConvertTo-PublisherBaseFixtureSource -Path $path -Text ([IO.File]::ReadAllText($file))))
        }
        $owner = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
        $accepted = 'sha256:' + ('a' * 64)
        $originalRelative = ".bootstrap/accepted-source/$owner/$($accepted.Substring(7))"
        $originalRoot = Join-Path $root $originalRelative
        $null = New-Item -ItemType Directory $originalRoot -Force
        foreach ($directory in @('bootstrap', 'infrastructure', 'src')) { Copy-Item "$root/$directory" $originalRoot -Recurse }
        $enginePath = "$originalRoot/bootstrap/bootstrap.ps1"
        $oldEngine = [IO.File]::ReadAllText($enginePath).Replace(", 'PublisherRecovery'", '').
            Replace('Initialize-BootstrapPublisherRecoveryTooling -State $state -Config $configuration -Mode $Mode;', '').
            Replace('-PublisherRecoveryState $state', '').
            Replace("(`$activeExecutionSourceFingerprint -ceq `$activeDeploymentSourceFingerprint -or `$state.Contains('publisherMetadataReconciliation'))",
                '$activeExecutionSourceFingerprint -ceq $activeDeploymentSourceFingerprint')
        [IO.File]::WriteAllText($enginePath, $oldEngine)
        # Model the prior parser without the service imageType exception. All
        # shared source machinery is real; never modify an operator snapshot.
        $parserPath = "$originalRoot/bootstrap/modules/PurviewExecutor.psm1"
        $parser = [IO.File]::ReadAllText($parserPath)
        $start = $parser.IndexOf('    $metadataOptional = @()')
        $end = $parser.IndexOf('    foreach ($name in $containerOptional)', $start)
        $parser = $parser.Remove($start, $end - $start).Insert($start,
            "    Assert-PurviewPublisherObjectFields -Object `$container -Required @('name', 'image', 'resources', 'env') -Optional `$containerOptional`n")
        [IO.File]::WriteAllText($parserPath, $parser)
        $oldSource = Get-BootstrapSourceFingerprint -Root $originalRoot
        $config = @{ tenantId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; subscriptionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            resourceGroupName = 'rg-publisher'; projectName = 'fixture'; environment = 'dev'; location = 'koreacentral'; purview = @{ enabled = $true } }
        $operator = @{ tenantId = $config.tenantId; subscriptionId = $config.subscriptionId; userObjectId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
        $scope = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroupName)"
        $ids = @{
            storage = "$scope/providers/Microsoft.Storage/storageAccounts/package"
            vnet = "$scope/providers/Microsoft.Network/virtualNetworks/private"
            blobEndpoint = "$scope/providers/Microsoft.Network/privateEndpoints/blob"
            blobNic = "$scope/providers/Microsoft.Network/networkInterfaces/blob"
            blobZone = "$scope/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
            site = "$scope/providers/Microsoft.Web/sites/executor"
            siteEndpoint = "$scope/providers/Microsoft.Network/privateEndpoints/site"
            siteNic = "$scope/providers/Microsoft.Network/networkInterfaces/site"
            siteZone = "$scope/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net"
        }
        $foundation = @{
            deploymentOwnershipId = $owner; sourceFingerprint = $oldSource; virtualNetworkName = 'private'
            privateEndpointSubnetId = "$($ids.vnet)/subnets/private"
            runtimeImagePullIdentityId = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pull"
            runtimeImagePullIdentityPrincipalId = '11111111-1111-4111-8111-111111111111'
            containerAppsEnvironmentId = "$scope/providers/Microsoft.App/managedEnvironments/private"; acrLoginServer = 'fixture.azurecr.io'; acrName = 'fixture'
        }
        $runtime = @{ deploymentOwnershipId = $owner; sourceFingerprint = $oldSource; storageAccountId = $ids.storage
            apiPrincipalId = '22222222-2222-4222-8222-222222222222'; workerPrincipalId = '33333333-3333-4333-8333-333333333333' }
        $context = @{
            deploymentOwnershipId = $owner; sourceFingerprint = $oldSource; configurationFingerprint = Get-BootstrapConfigurationFingerprint $config
            planFingerprint = $accepted; tenantId = $config.tenantId; subscriptionId = $config.subscriptionId; resourceGroupName = $config.resourceGroupName
            apiPrincipalId = $runtime.apiPrincipalId; workerPrincipalId = $runtime.workerPrincipalId
            workerApplicationId = '44444444-4444-4444-8444-444444444444'
            runtimePrincipalId = $foundation.runtimeImagePullIdentityPrincipalId; runtimeClientId = '55555555-5555-4555-8555-555555555555'
            automationApplicationId = '66666666-6666-4666-8666-666666666666'; automationServicePrincipalId = '77777777-7777-4777-8777-777777777777'
            organization = 'fixture.onmicrosoft.com'; keyVaultResourceId = "$scope/providers/Microsoft.KeyVault/vaults/kv-fixture-dev"
            certificateName = 'purview-automation-certificate'; certificateSecretUri = 'https://kv-fixture-dev.vault.azure.net/secrets/purview-automation-certificate'
        }
        $packageDirectory = "$root/.bootstrap/package"
        $receipt = New-TestExecutorPackage -Directory $packageDirectory -Source $oldSource
        $record = @{
            schemaVersion = 1; status = 'Installing'; intentId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'; context = $context
            operations = @{}; packageDirectory = $packageDirectory
            package = @{ receipt = $receipt; receiptFingerprint = Get-BootstrapObjectFingerprint -InputObject $receipt }
            identity = @{ applicationObjectId = '88888888-8888-4888-8888-888888888888'; applicationId = '99999999-9999-4999-8999-999999999999'
                servicePrincipalId = '10101010-1010-4010-8010-101010101010'; roleAssignmentId = 'synthetic-role' }
            publisherImage = @{ digest = 'sha256:' + ('c' * 64); runId = 'run-fixture' }
            network = @{ storageAccountName = 'package'; privateEndpointIp = '10.42.2.4' }
            host = @{
                executorId = @{ value = $ids.site }; executorPrincipalId = @{ value = '12121212-1212-4212-8212-121212121212' }
                executorEndpoint = @{ value = 'https://executor.azurewebsites.net' }
                integrationSubnetId = @{ value = "$($ids.vnet)/subnets/executor" }
                privateEndpointId = @{ value = $ids.siteEndpoint }; privateDnsZoneId = @{ value = $ids.siteZone }
                packageContainerId = @{ value = "$($ids.storage)/blobServices/default/containers/purview-executor-packages" }
                packageContainerUri = @{ value = 'https://package.blob.core.windows.net/purview-executor-packages' }
                claimsContainerId = @{ value = "$($ids.storage)/blobServices/default/containers/purview-executor-claims" }
            }
            publisher = @{
                jobId = @{ value = "$scope/providers/Microsoft.App/jobs/publisher" }; jobName = @{ value = 'publisher' }
                jobPrincipalId = @{ value = '13131313-1313-4313-8313-131313131313' }
                publisherImage = @{ value = 'fixture.azurecr.io/publisher@sha256:' + ('c' * 64) }
            }
        }
        $record.host.executorBinding = @{ value = @{
            DeploymentOwnershipId = $owner; TenantId = $config.tenantId; BootstrapSourceFingerprint = $oldSource; ExecutionSourceFingerprint = $oldSource
            PackageDigest = $receipt.packageDigest; AutomationApplicationId = $context.automationApplicationId
            AutomationServicePrincipalObjectId = $context.automationServicePrincipalId; KeyVaultResourceId = $context.keyVaultResourceId
            CertificateName = $context.certificateName; CertificateSecretUri = $context.certificateSecretUri
            GatewayApiPrincipalId = $context.apiPrincipalId; GatewayWorkerPrincipalId = $context.workerPrincipalId
            RuntimeClientId = $context.runtimeClientId; RuntimePrincipalId = $context.runtimePrincipalId
            ExecutorApplicationId = $record.identity.applicationId; ExecutorPrincipalId = $record.host.executorPrincipalId.value
            CallerApplicationId = $context.workerApplicationId
        } }
        $envValues = @{
            PUBLISHER_DEPLOYMENT_OWNERSHIP_ID = $owner; PUBLISHER_EXECUTION_INTENT_ID = $record.intentId
            PUBLISHER_EXECUTION_SOURCE_FINGERPRINT = $oldSource; PUBLISHER_PACKAGE_DIGEST = $receipt.packageDigest
            PUBLISHER_PACKAGE_BYTES = [string]$receipt.packageBytes; PUBLISHER_CONTAINER_URI = $record.host.packageContainerUri.value
            PUBLISHER_PRIVATE_ENDPOINT_IP = '10.42.2.4'
        }
        $container = @{ name = 'purview-package-publisher'; image = $record.publisher.publisherImage.value
            env = @($envValues.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value } })
            resources = @{ cpu = 0.5; memory = '1Gi'; ephemeralStorage = '1Gi' }; probes = @() }
        $job = @{
            id = $record.publisher.jobId.value; tags = @{ bootstrapOwnershipId = $owner; bootstrapSourceFingerprint = $oldSource }
            identity = @{ type = 'SystemAssigned,UserAssigned'; principalId = $record.publisher.jobPrincipalId.value
                userAssignedIdentities = @{ $foundation.runtimeImagePullIdentityId = @{} } }
            properties = @{ environmentId = $foundation.containerAppsEnvironmentId
                configuration = @{ triggerType = 'Manual'; replicaRetryLimit = 0; replicaTimeout = 660; secrets = $null
                    manualTriggerConfig = @{ parallelism = 1; replicaCompletionCount = 1 }
                    registries = @(@{ server = $foundation.acrLoginServer; identity = $foundation.runtimeImagePullIdentityId })
                    identitySettings = @(@{ identity = 'system'; lifecycle = 'Main' }, @{ identity = $foundation.runtimeImagePullIdentityId; lifecycle = 'None' })
                }; template = @{ containers = @($container) }
            }
        }
        $executionContainer = ConvertTo-BootstrapCanonicalValue -Value $container
        $executionContainer.Remove('probes'); $executionContainer.imageType = 'ContainerImage'
        $execution = @{ name = 'exact-execution'; properties = @{ status = 'Succeeded'; template = @{ containers = @($executionContainer) } } }
        foreach ($name in @('application', 'audience', 'principal', 'invokeRole', 'publisherImage',
            'a365gw-fixture-executor-host-dev', 'a365gw-fixture-executor-publisher-dev')) {
            $record.operations[$name] = @{ status = 'Completed'; intentFingerprint = 'sha256:' + ('d' * 64); evidenceFingerprint = 'sha256:' + ('e' * 64) }
        }
        $hostParameters = Get-PurviewExecutorHostParameters -Config $config -Foundation $foundation -Record $record
        $hostHash = (Get-FileHash "$originalRoot/bootstrap/infra/purview-windows-executor.bicep" -Algorithm SHA256).Hash.ToLowerInvariant()
        $record.operations['a365gw-fixture-executor-host-dev'].intentFingerprint = Get-BootstrapObjectFingerprint @{
            templateSha256 = $hostHash; parameters = $hostParameters
        }
        $record.operations.publish = @{ status = 'Started'; intentFingerprint = Get-BootstrapObjectFingerprint @{
            jobId = $record.publisher.jobId.value; template = $job.properties.template; intentId = $record.intentId
        } }
        $state = @{
            schemaVersion = 2; bootstrapVersion = '2.0.0'; deploymentKey = "$($config.subscriptionId)/rg-publisher/dev"
            deploymentOwnershipId = $owner; configurationFingerprint = $context.configurationFingerprint
            configuration = @{}; createdAtUtc = '2026-09-07T00:00:00.0000000+00:00'; updatedAtUtc = '2026-09-07T01:00:00.0000000+00:00'
            source = @{ created = @{ bootstrapSourceFingerprint = $oldSource }; lastWritten = @{ bootstrapSourceFingerprint = $oldSource } }
            acceptedPlan = @{ bootstrapVersion = '2.0.0'; sourceFingerprint = $oldSource; planFingerprint = $accepted
                configurationFingerprint = $context.configurationFingerprint; bootstrapClientIpv4 = '192.0.2.1'
                acceptedAtUtc = '2026-09-07T00:00:00.0000000+00:00'; executionSource = $originalRelative }
            steps = @{}; outputs = @{}; freshPurviewExecutor = $record
        }
        foreach ($field in Get-BootstrapDeploymentIdentityFieldNames) { $state.configuration[$field] = $config[$field] }
        foreach ($name in @(Get-GatewayBootstrapStepNames)[0..13]) { $state.steps[$name] = @{
            status = 'Completed'; sourceFingerprint = $oldSource; evidence = @{ verified = $true }; completedAtUtc = '2026-09-07T00:00:00.0000000+00:00'
        } }
        $state.steps['Azure authentication'].evidence = $operator
        $state.steps['Azure foundation'].evidence = $foundation
        $state.steps['Inert identity deployment'].evidence = $runtime
        $runtime.sharedKeyVaultId = $context.keyVaultResourceId
        $runtime.keyVaultUri = 'https://kv-fixture-dev.vault.azure.net/'
        $database = @{ acceptedSourceFingerprint = $oldSource; deploymentOwnershipId = $owner
            apiPrincipalObjectId = $context.apiPrincipalId; workerPrincipalObjectId = $context.workerPrincipalId; workerPrincipalClientId = $context.workerApplicationId }
        $state.steps['Gateway database'].evidence = $database
        $automation = @{ deploymentOwnershipId = $owner; sourceFingerprint = $oldSource; status = 'Installed'
            policyConfiguration = 'NotPerformed'; policyReadiness = 'NotClaimed'; certificateSecretUri = $context.certificateSecretUri
            certificateSecretResourceId = "$($context.keyVaultResourceId)/secrets/$($context.certificateName)"
            automationApplicationId = $context.automationApplicationId; automationServicePrincipalId = $context.automationServicePrincipalId
            organization = $context.organization }
        $tags = @(Get-BootstrapApplicationTags -DeploymentOwnershipId $owner) + @("A365GatewaySource:$oldSource", 'A365GatewayPurviewExecutor')
        $role = Get-PurviewExecutorRole
        $app = @{ id = $record.identity.applicationObjectId; appId = $record.identity.applicationId
            displayName = "A365 Gateway Purview Executor - $owner"; signInAudience = 'AzureADMyOrg'; tags = $tags
            isFallbackPublicClient = $false; identifierUris = @("api://$($record.identity.applicationId)")
            api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @(); acceptMappedClaims = $false }
            appRoles = @($role); requiredResourceAccess = @(); passwordCredentials = @(); keyCredentials = @()
            web = @{ redirectUris = @(); implicitGrantSettings = @{ enableAccessTokenIssuance = $false; enableIdTokenIssuance = $false } }
            spa = @{ redirectUris = @() }; publicClient = @{ redirectUris = @() }
        }
        $sp = @{ id = $record.identity.servicePrincipalId; appId = $record.identity.applicationId; servicePrincipalType = 'Application'
            accountEnabled = $true; appRoleAssignmentRequired = $true; tags = $tags
            servicePrincipalNames = @($record.identity.applicationId, "api://$($record.identity.applicationId)")
            appRoles = @($role); passwordCredentials = @(); keyCredentials = @(); oauth2PermissionScopes = @(); alternativeNames = @()
        }
        $opInputs = @{
            application = @{ intent = @{ name = $app.displayName; tags = $tags; role = $role; tenantId = $config.tenantId }
                evidence = @{ objectId = $app.id; applicationId = $app.appId } }
            audience = @{ intent = @{ objectId = $app.id; audience = "api://$($app.appId)" }; evidence = @{ audience = "api://$($app.appId)" } }
            principal = @{ intent = @{ applicationId = $app.appId; tags = $tags; assignmentRequired = $true }; evidence = @{ objectId = $sp.id; applicationId = $sp.appId } }
            invokeRole = @{ intent = @{ principalId = $context.workerPrincipalId; resourceId = $sp.id; appRoleId = $role.id }
                evidence = @{ id = $record.identity.roleAssignmentId } }
        }
        foreach ($name in $opInputs.Keys) {
            $record.operations[$name].intentFingerprint = Get-BootstrapObjectFingerprint $opInputs[$name].intent
            $record.operations[$name].evidenceFingerprint = Get-BootstrapObjectFingerprint $opInputs[$name].evidence
        }
        $imageTag = Get-BootstrapImageBuildIntentTag -DeploymentOwnershipId $owner -SourceFingerprint $oldSource -IntentId $record.intentId
        $record.operations.publisherImage.intentFingerprint = Get-BootstrapObjectFingerprint @{
            registry = 'fixture'; repository = 'gateway-purview-package-publisher'; tag = $imageTag; receiptFingerprint = $record.package.receiptFingerprint
        }
        $record.operations.publisherImage.evidenceFingerprint = Get-BootstrapObjectFingerprint $record.publisherImage
        $record.operations['a365gw-fixture-executor-host-dev'].evidenceFingerprint = Get-BootstrapObjectFingerprint $record.host
        $publisherParameters = @{
            location = $config.location; environmentName = $config.environment; projectName = $config.projectName
            deploymentOwnershipId = $owner; bootstrapSourceFingerprint = $oldSource; executionSourceFingerprint = $oldSource
            executionIntentId = $record.intentId; containerAppsEnvironmentId = $foundation.containerAppsEnvironmentId
            imagePullIdentityResourceId = $foundation.runtimeImagePullIdentityId; acrLoginServer = $foundation.acrLoginServer
            publisherImageDigest = $record.publisherImage.digest; packageDigest = $record.package.receipt.packageDigest
            packageBytes = [int]$record.package.receipt.packageBytes; storageAccountName = 'package'; expectedStoragePrivateEndpointIp = '10.42.2.4'
        }
        $publisherTemplateHash = (Get-FileHash "$originalRoot/bootstrap/infra/purview-package-publisher-job.bicep" -Algorithm SHA256).Hash.ToLowerInvariant()
        $record.operations['a365gw-fixture-executor-publisher-dev'].intentFingerprint = Get-BootstrapObjectFingerprint @{
            templateSha256 = $publisherTemplateHash; parameters = $publisherParameters
        }
        $record.operations['a365gw-fixture-executor-publisher-dev'].evidenceFingerprint = Get-BootstrapObjectFingerprint $record.publisher
        $state.steps['Gateway runtime deployment'] = @{ status = 'Failed'; sourceFingerprint = $oldSource
            message = "Bootstrap step 'Gateway runtime deployment' failed because property 'publisher.publish.execution.template' disagreed." }
        $resources = @{}
        function Add-Resource($Id, $Properties) {
            $resources[$Id] = @{ id = $Id; name = $Id.Split('/')[-1]; properties = $Properties
                tags = @{ bootstrapOwnershipId = $owner; bootstrapSourceFingerprint = $oldSource } }
        }
        Add-Resource $ids.storage @{ publicNetworkAccess = 'Disabled'; allowBlobPublicAccess = $false; allowSharedKeyAccess = $false
            privateEndpointConnections = @(@{ properties = @{ privateLinkServiceConnectionState = @{ status = 'Approved' }; privateEndpoint = @{ id = $ids.blobEndpoint } } }) }
        foreach ($type in @('blob', 'site')) {
            $endpoint = $ids["${type}Endpoint"]; $nic = $ids["${type}Nic"]; $zone = $ids["${type}Zone"]
            $target = if ($type -ceq 'blob') { $ids.storage } else { $ids.site }
            $group = if ($type -ceq 'blob') { 'blob' } else { 'sites' }
            Add-Resource $endpoint @{ subnet = @{ id = $foundation.privateEndpointSubnetId }
                networkInterfaces = @(@{ id = $nic }); privateLinkServiceConnections = @(@{ properties = @{
                    privateLinkServiceId = $target; groupIds = @($group); privateLinkServiceConnectionState = @{ status = 'Approved' }
                } }) }
            Add-Resource $nic @{ ipConfigurations = @(@{ properties = @{ subnet = @{ id = $foundation.privateEndpointSubnetId }; privateIPAddress = '10.42.2.4' } }) }
            Add-Resource "$endpoint/privateDnsZoneGroups/exact" @{ privateDnsZoneConfigs = @(@{ properties = @{ privateDnsZoneId = $zone } }) }
            Add-Resource "$zone/virtualNetworkLinks/exact" @{ virtualNetwork = @{ id = $ids.vnet }; registrationEnabled = $false; virtualNetworkLinkState = 'Completed' }
        }
        foreach ($pair in @(@($ids.blobZone, 'package'), @($ids.siteZone, 'executor'), @($ids.siteZone, 'executor.scm'))) {
            Add-Resource "$($pair[0])/A/$($pair[1])" @{ aRecords = @(@{ ipv4Address = '10.42.2.4' }) }
        }
        Add-Resource $ids.vnet @{ addressSpace = @{ addressPrefixes = @('10.42.0.0/16') } }
        Add-Resource $foundation.containerAppsEnvironmentId @{ vnetConfiguration = @{ infrastructureSubnetId = "$($ids.vnet)/subnets/snet-container-apps" } }
        Add-Resource $foundation.runtimeImagePullIdentityId @{ principalId = $context.runtimePrincipalId; clientId = $context.runtimeClientId }
        $planId = "$scope/providers/Microsoft.Web/serverfarms/asp-fixture-dev-purview"
        Add-Resource $planId @{ reserved = $false }
        $resources[$planId].sku = @{ name = 'B1'; capacity = 1 }
        Add-Resource $ids.site @{ enabled = $false; publicNetworkAccess = 'Disabled'; httpsOnly = $true; defaultHostName = 'executor.azurewebsites.net'
            virtualNetworkSubnetId = $record.host.integrationSubnetId.value; serverFarmId = $planId; outboundVnetRouting = @{ allTraffic = $true } }
        $resources[$ids.site].identity = @{ type = 'SystemAssigned'; principalId = $record.host.executorPrincipalId.value }
        $resources[$ids.site].tags.purviewExecutionSourceFingerprint = $oldSource
        Add-Resource $record.host.integrationSubnetId.value @{ addressPrefix = '10.42.3.0/26'; delegations = @(@{ properties = @{ serviceName = 'Microsoft.Web/serverFarms' } }) }
        Add-Resource "$($ids.site)/config/authsettingsV2" @{ platform = @{ enabled = $true }; globalValidation = @{ requireAuthentication = $true; unauthenticatedClientAction = 'Return401' }
            login = @{ tokenStore = @{ enabled = $false } }; identityProviders = @{ azureActiveDirectory = @{
                enabled = $true; registration = @{ clientId = $record.identity.applicationId; openIdIssuer = "https://login.microsoftonline.com/$($config.tenantId)/v2.0" }
                validation = @{ allowedAudiences = @($record.identity.applicationId); defaultAuthorizationPolicy = @{
                    allowedApplications = @($context.workerApplicationId); allowedPrincipals = @{ identities = @($context.workerPrincipalId) }
                } }
            } } }
        foreach ($name in @('ftp', 'scm')) { Add-Resource "$($ids.site)/basicPublishingCredentialsPolicies/$name" @{ allow = $false } }
        Add-Resource "$($ids.site)/config/web" @{ ftpsState = 'Disabled'; use32BitWorkerProcess = $false; remoteDebuggingEnabled = $false
            httpLoggingEnabled = $false; detailedErrorLoggingEnabled = $false; requestTracingEnabled = $false; minTlsVersion = '1.2' }
        $resources[$job.id] = $job
        return @{ root = $root; originalRoot = $originalRoot; config = $config; operator = $operator; state = $state; resources = $resources
            job = $job; execution = $execution; ids = $ids; count = 1; calls = [Collections.Generic.List[object]]::new()
            app = $app; sp = $sp; role = $role; automation = $automation; database = $database; publisherParameters = $publisherParameters; hostParameters = $hostParameters
            imageTag = $imageTag; enableDeployment = $false; allowRuntime = $false; allowAdmin = $false
            acrRun = @{ runId = 'run-fixture'; status = 'Succeeded'; runType = 'QuickRun'
                outputImages = @(@{ repository = 'gateway-purview-package-publisher'; tag = $imageTag; digest = $record.publisherImage.digest }) } }
    }
}

Describe 'Publisher metadata reconciliation entrypoint contract' {
    It 'provides a separate Plan/Execute operator utility, not a replacement installer' {
        $path = Join-Path $repository 'bootstrap/reconcile-publisher-metadata.ps1'
        Test-Path $path | Should -BeTrue
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $names = @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
        $names | Should -Contain 'ExpectedPlanFingerprint'
        $names | Should -Contain 'Yes'
        $names | Should -Not -Contain 'Force'
        $names | Should -Not -Contain 'AssetRoot'
    }

    Describe 'Publisher reconciliation exact receipt and provider boundary' {
        BeforeEach {
            $global:publisherRecoveryFixture = New-PublisherRecoveryFixture
            $f = $global:publisherRecoveryFixture
            $savedPath = $env:PATH
            if (-not $IsWindows) {
                # Keep native Azure tools isolated while exercising the real mode-600 guard.
                $chmod = @(Get-Command chmod -CommandType Application -ErrorAction Stop)[0]
                $isolatedChmod = Join-Path $TestDrive 'chmod'
                Copy-Item -LiteralPath $chmod.Source -Destination $isolatedChmod -Force
                [IO.File]::SetUnixFileMode($isolatedChmod, (
                    [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute))
            }
            $env:PATH = $TestDrive
            Mock Get-RepositoryRoot -ModuleName Common { $global:publisherRecoveryFixture.root }
            Mock Get-RepositoryRoot -ModuleName PublisherRecovery { $global:publisherRecoveryFixture.root }
            # Substitute only process/HTTP I/O. All source, state, package, locks,
            # intent, template, ownership and network validators execute unchanged.
            $processBoundary = {
                param($FilePath, $ArgumentList)
                $f = $global:publisherRecoveryFixture
                $a = @($ArgumentList); $f.calls.Add($a)
                function Arg($n) { $i = [array]::IndexOf($a, $n); if ($i -ge 0) { return $a[$i + 1] }; return '' }
                $prefix = $a[0..([Math]::Min(3, $a.Count - 1))] -join ' '
                if ($a[0] -ceq 'account' -and $a[1] -ceq 'show') { $result = @{ id = $f.config.subscriptionId; tenantId = $f.config.tenantId } }
                elseif ($a[0] -ceq 'account' -and $a[1] -ceq 'get-access-token') {
                    $result = @{ subscription = $f.config.subscriptionId; tenant = $f.config.tenantId; tokenType = 'Bearer'
                        expires_on = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600; accessToken = 'synthetic-fixture-only' }
                }
                elseif ($a[0] -ceq 'resource' -and $a[1] -ceq 'show') {
                    $id = Arg '--ids'; if (-not $f.resources.ContainsKey($id)) { throw 'Unknown synthetic resource' }; $result = $f.resources[$id]
                }
                elseif ($a[0] -ceq 'resource' -and $a[1] -ceq 'invoke-action' -and
                    (Arg '--ids') -ceq "$($f.ids.site)/config/appsettings" -and (Arg '--action') -ceq 'list') {
                    $result = if ($f.ContainsKey('amendmentSource')) { @{} } else { $f.hostSettings }
                }
                elseif ($prefix -ceq 'webapp config appsettings list') {
                    (Arg '--name') | Should -BeExactly $f.ids.site.Split('/')[-1]
                    (Arg '--resource-group') | Should -BeExactly $f.config.resourceGroupName
                    (Arg '--subscription') | Should -BeExactly $f.config.subscriptionId
                    $result = @($f.hostSettings.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value; slotSetting = $false } })
                }
                elseif ($a[0] -ceq 'provider' -and $a[1] -ceq 'show') { return 'Registered' }
                elseif (($a[0..2] -join ' ') -ceq 'acr task list-runs') { $result = @($f.acrRun) }
                elseif (($a[0..2] -join ' ') -ceq 'acr task show-run') { $result = $f.acrRun }
                elseif (($a[0..2] -join ' ') -ceq 'acr repository list') { $result = @('gateway-purview-package-publisher') }
                elseif (($a[0..2] -join ' ') -ceq 'acr repository show-tags') { $result = @($f.imageTag) }
                elseif (($a[0..2] -join ' ') -ceq 'acr manifest show-metadata') { return $f.state.freshPurviewExecutor.publisherImage.digest }
                elseif (($a[0..2] -join ' ') -ceq 'deployment group list') {
                    $query = Arg '--query'
                    if ($f.allowAdmin -and $query.StartsWith('length(')) { return '0' }
                    $name = if ($query -match "name=='([^']+)'") { $Matches[1] } else { throw 'Unknown synthetic deployment query' }
                    $result = @(if ($name -match '-executor-enable-' -and -not $f.enableDeployment) { @() } else { @{ name = $name } })
                }
                elseif (($a[0..2] -join ' ') -ceq 'deployment group show') {
                    $name = Arg '--name'; $r = $f.state.freshPurviewExecutor
                    $parameters = if ($name -match '-executor-publisher-') { $f.publisherParameters } else {
                        $copy = ConvertTo-BootstrapCanonicalValue -Value $f.hostParameters
                        $copy.enableRuntime = $name -match '-executor-enable-'; $copy
                    }
                    $parameterEnvelope = @{}; foreach ($key in $parameters.Keys) { $parameterEnvelope[$key] = @{ value = $parameters[$key] } }
                    $result = @{ state = 'Succeeded'; parameters = $parameterEnvelope
                        outputs = if ($name -match '-executor-publisher-') { $r.publisher } else { $r.host } }
                    if ($name -match '-executor-enable-' -and $f.ContainsKey('enableReadFailed')) { $result.state = 'Failed' }
                }
                elseif (($a[0..2] -join ' ') -ceq 'deployment group create' -and ($f.allowRuntime -or $f.allowAdmin)) {
                    $name = Arg '--name'; $template = Arg '--template-file'
                    if ($name -ceq 'a365gw-fixture-executor-enable-dev' -and $f.allowRuntime) {
                        $template | Should -BeExactly (Join-Path $f.originalRoot 'bootstrap/infra/purview-windows-executor.bicep')
                        $f.enableDeployment = $true; $f.resources[$f.ids.site].properties.enabled = $true
                        $result = @{ properties = @{ outputs = $f.state.freshPurviewExecutor.host } }
                    }
                    elseif ($name -ceq 'a365gw-fixture-bootstrap-admin-dev' -and $f.allowAdmin) {
                        $template | Should -BeExactly (Join-Path $f.originalRoot 'infrastructure/bicep/admin-ui.bicep')
                        $result = @{ properties = @{ outputs = @{
                            deploymentOwnershipId = @{ value = $f.state.deploymentOwnershipId }
                            bootstrapSourceFingerprint = @{ value = $f.state.acceptedPlan.sourceFingerprint }
                            adminUiContainerImage = @{ value = 'fixture-admin' }
                            adminUiFqdn = @{ value = 'admin.fixture.invalid' }; adminUiUrl = @{ value = 'https://admin.fixture.invalid' }
                            adminUiPrincipalId = @{ value = '14141414-1414-4414-8414-141414141414' }
                            adminUiSignInRedirectUri = @{ value = 'https://admin.fixture.invalid/signin-oidc' }
                            adminUiSignedOutCallbackUri = @{ value = 'https://admin.fixture.invalid/signout-callback-oidc' }
                        } } }
                    }
                    else { throw 'No other synthetic deployment is permitted' }
                }
                elseif ($a[0] -ceq 'resource' -and $a[1] -ceq 'list' -and $f.allowAdmin) { return '0' }
                elseif ($prefix -ceq 'network private-endpoint dns-zone-group list') {
                    $id = "$($f.ids[(Arg '--endpoint-name') + 'Endpoint'])/privateDnsZoneGroups/exact"
                    $result = @{ value = @(@{ id = $id }) }
                }
                elseif ($prefix -ceq 'network private-dns link vnet') {
                    $id = "/subscriptions/$($f.config.subscriptionId)/resourceGroups/$($f.config.resourceGroupName)/providers/Microsoft.Network/privateDnsZones/$(Arg '--zone-name')/virtualNetworkLinks/exact"
                    $result = @{ value = @(@{ id = $id }) }
                }
                elseif (($a[0..2] -join ' ') -ceq 'role assignment list') {
                    $r = $f.state.freshPurviewExecutor; $principal = Arg '--assignee-object-id'
                    $pairs = @(if ($principal -ceq $r.publisher.jobPrincipalId.value) {
                        ,@($r.host.packageContainerId.value, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
                    } else { @(
                        @($r.host.packageContainerId.value, '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'),
                        @($r.host.claimsContainerId.value, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'),
                        @("$($r.context.keyVaultResourceId)/secrets/$($r.context.certificateName)", '4633458b-17de-408a-b874-0445c86b69e6')
                    ) })
                    $result = @($pairs | ForEach-Object { @{ principalId = $principal; scope = $_[0]; roleDefinitionId = "/roles/$($_[1])" } })
                }
                elseif ($prefix -ceq 'containerapp job execution list') { $result = @(for ($i=0; $i -lt $f.count; $i++) { @{ name = 'exact-execution' } }) }
                elseif ($prefix -ceq 'containerapp job execution show') { $result = $f.execution }
                else { throw 'Unapproved synthetic process call; no mutation is permitted' }
                return ConvertTo-Json -InputObject $result -Depth 60 -Compress
            }
            foreach ($module in @('Common', 'Entra', 'Azure', 'PurviewExecutor')) {
                Mock Invoke-BootstrapCommand -ModuleName $module -MockWith $processBoundary
            }
            $client = [pscustomobject]@{}
            $client | Add-Member -MemberType ScriptMethod -Name SendAsync -Value {
                param($Request, $CompletionOption)
                if ([string]$Request.Method -cne 'GET') { throw 'No HTTP mutation allowed' }
                $f = $global:publisherRecoveryFixture
                $f.calls.Add(@('HTTP', 'GET', $Request.RequestUri.AbsolutePath))
                $path = $Request.RequestUri.AbsolutePath
                $r = $f.state.freshPurviewExecutor
                $value = if ($path -ceq '/v1.0/me') { @{ id = $f.operator.userObjectId } }
                elseif ($path -ceq '/v1.0/applications') { @{ value = @($f.app) } }
                elseif ($path -ceq '/v1.0/servicePrincipals') { @{ value = @($f.sp) } }
                elseif ($path -ceq "/v1.0/servicePrincipals/$($r.context.workerPrincipalId)") {
                    @{ id = $r.context.workerPrincipalId; appId = $r.context.workerApplicationId; servicePrincipalType = 'ManagedIdentity' }
                }
                elseif ($path -ceq "/v1.0/servicePrincipals/$($f.sp.id)/appRoleAssignedTo") {
                    @{ value = @(@{ id = $r.identity.roleAssignmentId; principalId = $r.context.workerPrincipalId
                        resourceId = $f.sp.id; appRoleId = $f.role.id; principalType = 'ServicePrincipal' }) }
                }
                else { @{ value = @() } }
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
                $response.Content = [Net.Http.StringContent]::new((ConvertTo-Json -InputObject $value -Depth 60 -Compress))
                $task = [Threading.Tasks.TaskCompletionSource[Net.Http.HttpResponseMessage]]::new()
                $task.SetResult($response); return $task.Task
            }
            $global:publisherRecoveryHttp = $client
            Mock Get-BootstrapGraphHttpClient -ModuleName Common { $global:publisherRecoveryHttp }
            $statePath = Get-BootstrapStatePath -Config $f.config
            $null = New-Item -ItemType Directory (Split-Path -Parent $statePath) -Force
            [IO.File]::WriteAllText($statePath, (ConvertTo-Json -InputObject $f.state -Depth 100))
            Set-BootstrapAzureSubscriptionContext -SubscriptionId $f.config.subscriptionId -TenantId $f.config.tenantId
            Set-BootstrapExecutionSourceRoot -Path $f.root
            function Plan-Fixture {
                Invoke-BootstrapPublisherMetadataReconciliation -Mode Plan -Config $f.config -StatePath $statePath
            }
            function Execute-Fixture($Fingerprint) {
                Invoke-BootstrapPublisherMetadataReconciliation -Mode Execute -Config $f.config -StatePath $statePath -ExpectedPlanFingerprint $Fingerprint -Yes
            }
            function Read-FixtureState {
                $s = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json -AsHashtable -Depth 100
                Convert-BootstrapParsedJsonDatesToStrings -Value $s
                return $s
            }
            function New-HostSettingsFixture {
                $review = Plan-Fixture; $null = Execute-Fixture $review.planFingerprint
                $s = Read-FixtureState
                Set-FixtureInstalledState -State $s
                $s.freshPurviewExecutor.status = 'Installing'
                $s.steps['Gateway runtime deployment'].message = "Bootstrap step 'Gateway runtime deployment' failed. Review the local terminal output, correct the cause, and run Resume."
                $f.enableDeployment = $true
                $f.parentRoot = Assert-BootstrapPublisherRecoveryReceipt -State $s
                $f.parentHash = Get-BootstrapObjectFingerprint -InputObject $s.publisherMetadataReconciliation
                $f.originalStateHash = Get-BootstrapObjectFingerprint -InputObject $s
                $f.state = $s
                [IO.File]::WriteAllText($statePath, (ConvertTo-Json -InputObject $s -Depth 100))
                foreach ($path in @('bootstrap/modules/Common.psm1', 'bootstrap/modules/PurviewExecutor.psm1',
                    'bootstrap/modules/PublisherRecovery.psm1', 'bootstrap/reconcile-publisher-metadata.ps1')) {
                    Copy-Item -LiteralPath (Join-Path $repository $path) -Destination (Join-Path $f.root $path) -Force
                }
                $f.amendmentSource = $true
            }
            function Plan-HostSettings {
                Invoke-BootstrapHostSettingsAmendment -Mode Plan -Config $f.config -StatePath $statePath
            }
            function Execute-HostSettings($Fingerprint) {
                Invoke-BootstrapHostSettingsAmendment -Mode Execute -Config $f.config -StatePath $statePath `
                    -ExpectedPlanFingerprint $Fingerprint -Yes
            }
            function Initialize-AmendedFixture($State, $Mode) {
                Initialize-BootstrapPublisherRecoveryTooling -State $State -Config $f.config -Mode $Mode
                $pinned = Assert-BootstrapPublisherRecoveryReceipt -State $State
                foreach ($module in @(Get-Module -All | Where-Object {
                    $_.Path -and $_.Path.StartsWith($pinned, [StringComparison]::OrdinalIgnoreCase)
                })) {
                    & $module {
                        param($process)
                        Set-Item Function:script:Invoke-BootstrapCommand -Value $process
                        if ($ExecutionContext.SessionState.Module.Name -ceq 'Common') {
                            Set-Item Function:script:Get-BootstrapGraphHttpClient -Value { $global:publisherRecoveryHttp }
                        }
                    } $processBoundary
                }
            }
        }
        It 'keeps Azure CLI unavailable while permitting the real local chmod boundary' -Skip:$IsWindows {
            @(Get-Command az -CommandType Application -ErrorAction SilentlyContinue).Count | Should -Be 0
            $commands = @(Get-Command chmod -CommandType Application -ErrorAction Stop)
            $commands.Count | Should -Be 1
            $commands[0].Source | Should -BeExactly (Join-Path $TestDrive 'chmod')
            $probe = Join-Path $TestDrive 'permission-probe'
            [IO.File]::WriteAllText($probe, 'synthetic permission fixture')
            & $commands[0].Source 600 $probe
            $LASTEXITCODE | Should -Be 0
            [IO.File]::GetUnixFileMode($probe) |
                Should -Be ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }

        AfterEach {
            foreach ($call in $f.calls) {
                ($call -join ' ') | Should -Not -Match 'job start|account set|acr build|listSecrets'
                if (-not $f.allowRuntime -and -not $f.allowAdmin) { ($call -join ' ') | Should -Not -Match 'deployment group create' }
            }
            Clear-BootstrapAzureSubscriptionContext
            $env:PATH = $savedPath
            Set-BootstrapExecutionSourceRoot -Path $repository
            # Pinned PurviewPackage imports its own nested Common/Azure. Remove
            # only this test's snapshot modules, otherwise Pester cannot resolve
            # a unique process boundary for the next test (or affected file).
            $snapshotModules = @(Get-Module -All | Where-Object {
                $_.Path -and $_.Path.StartsWith($TestDrive, [StringComparison]::OrdinalIgnoreCase)
            })
            if ($snapshotModules.Count -gt 0) {
                $snapshotModules | Remove-Module -Force -ErrorAction SilentlyContinue
                foreach ($module in @('Common', 'Experience', 'Azure', 'Entra', 'PurviewPackage', 'PurviewExecutor', 'PublisherRecovery')) {
                    Import-Module "$repository/bootstrap/modules/$module.psm1" -Force -DisableNameChecking
                }
            }
            $global:publisherRecoveryFixture = $null; $global:publisherRecoveryHttp = $null
        }

        It 'host amendment Plan is read-only and Execute adds only the separately approved receipt' {
            New-HostSettingsFixture
            $before = (Get-FileHash $statePath).Hash
            { Get-GatewayResumeExecutionSource -State $f.state } | Should -Throw
            $review = Plan-HostSettings
            (Get-FileHash $statePath).Hash | Should -BeExactly $before
            { Invoke-BootstrapHostSettingsAmendment -Mode Execute -Config $f.config -StatePath $statePath `
                -ExpectedPlanFingerprint $review.planFingerprint } | Should -Throw '*requires Yes*'
            { Execute-HostSettings ('sha256:' + ('f' * 64)) } | Should -Throw '*approval fingerprint*'
            $lock = Enter-BootstrapLock -StatePath $statePath
            try { { Execute-HostSettings $review.planFingerprint } | Should -Throw '*lock*' }
            finally { $lock.Dispose() }
            $null = Execute-HostSettings $review.planFingerprint
            $s = Read-FixtureState
            $s.steps['Gateway runtime deployment'].status | Should -BeExactly 'Failed'
            $s.freshPurviewExecutor.status | Should -BeExactly 'Installing'
            $s.freshPurviewExecutor.operations.publish.status | Should -BeExactly 'Completed'
            (Get-BootstrapObjectFingerprint -InputObject $s.publisherMetadataReconciliation) | Should -BeExactly $f.parentHash
            (Get-BootstrapSourceFingerprint -Root $f.parentRoot) | Should -BeExactly $s.publisherMetadataReconciliation.plan.correctedSourceFingerprint
            $copy = ConvertTo-BootstrapCanonicalValue -Value $s; $copy.Remove('hostSettingsAmendment')
            (Get-BootstrapObjectFingerprint -InputObject $copy) | Should -BeExactly $f.originalStateHash
            $selection = Get-GatewayResumeExecutionSource -State $s
            $selection.executionSourceFingerprint | Should -BeExactly $review.correctedSourceFingerprint
            $selection.deploymentSourceFingerprint | Should -BeExactly $s.acceptedPlan.sourceFingerprint
            Set-BootstrapExecutionSourceRoot -Path $selection.executionSourceRoot
            (Get-BootstrapAssetSourceRoot -State $s -ExecutionSourceFingerprint $selection.executionSourceFingerprint `
                -DeploymentSourceFingerprint $selection.deploymentSourceFingerprint) | Should -BeExactly $f.originalRoot
            { Get-BootstrapAssetSourceRoot -State $s -ExecutionSourceFingerprint $s.publisherMetadataReconciliation.plan.correctedSourceFingerprint `
                -DeploymentSourceFingerprint $selection.deploymentSourceFingerprint } | Should -Throw
            $receiptHash = (Get-FileHash $statePath).Hash
            $null = Execute-HostSettings $review.planFingerprint
            (Get-FileHash $statePath).Hash | Should -BeExactly $receiptHash
            @($f.calls | Where-Object { ($_ -join ' ') -match 'webapp config appsettings list' }).Count | Should -BeGreaterThan 0
        }

        It 'host amendment creation rejects partial core runtime evidence before any provider read' {
            New-HostSettingsFixture
            $s = Read-FixtureState
            $s.steps['Gateway runtime deployment'].evidence = @{ partialRuntime = $true }
            [IO.File]::WriteAllText($statePath, (ConvertTo-Json -InputObject $s -Depth 100))
            $before = (Get-FileHash $statePath).Hash
            $calls = $f.calls.Count
            { Plan-HostSettings } | Should -Throw
            $f.calls.Count | Should -Be $calls
            (Get-FileHash $statePath).Hash | Should -BeExactly $before
        }

        It 'host amendment rejects pre-review source or eligibility drift <Fault>' -ForEach @(
            @{ Fault = 'publisher Started' }, @{ Fault = 'enable Started' }, @{ Fault = 'Installed' },
            @{ Fault = 'parent receipt' }, @{ Fault = 'runtime asset' }, @{ Fault = 'Azure source' },
            @{ Fault = 'CLI' }, @{ Fault = 'guard body' }, @{ Fault = 'other recovery' }
        ) {
            New-HostSettingsFixture
            $s = Read-FixtureState
            switch ($Fault) {
                'publisher Started' { $s.freshPurviewExecutor.operations.publish.status = 'Started' }
                'enable Started' { $s.freshPurviewExecutor.operations['a365gw-fixture-executor-enable-dev'].status = 'Started' }
                'Installed' { $s.freshPurviewExecutor.status = 'Installed' }
                'parent receipt' { $s.publisherMetadataReconciliation.completionFingerprint = 'sha256:' + ('f' * 64) }
                'runtime asset' { [IO.File]::AppendAllText("$($f.root)/src/fixture/runtime.cs", '// changed') }
                'Azure source' { [IO.File]::AppendAllText("$($f.root)/bootstrap/modules/Azure.psm1", "`nfunction Unapproved-Mutation {}") }
                'CLI' { [IO.File]::AppendAllText("$($f.root)/bootstrap/reconcile-publisher-metadata.ps1", "`nWrite-Output unapproved") }
                'guard body' {
                    $path = "$($f.root)/bootstrap/modules/PublisherRecovery.psm1"
                    [IO.File]::WriteAllText($path, ([IO.File]::ReadAllText($path).Replace(
                        "throw 'Host settings amendment snapshot changed.'", 'return $root')))
                }
                'other recovery' { $s.databaseRecoveryPlan = @{} }
            }
            [IO.File]::WriteAllText($statePath, (ConvertTo-Json -InputObject $s -Depth 100))
            $before = (Get-FileHash $statePath).Hash
            { Plan-HostSettings } | Should -Throw
            (Get-FileHash $statePath).Hash | Should -BeExactly $before
        }

        It 'host amendment rejects a failed enable deployment record even when enabled resources match' {
            New-HostSettingsFixture
            $f.enableReadFailed = $true
            $before = (Get-FileHash $statePath).Hash
            { Plan-HostSettings } | Should -Throw
            (Get-FileHash $statePath).Hash | Should -BeExactly $before
        }

        It 'host amendment rejects provider drift without a fallback or mutation <Fault>' -ForEach @(
            @{ Fault = 'setting value' }, @{ Fault = 'extra setting' }, @{ Fault = 'extra execution' },
            @{ Fault = 'CloudBuild' }, @{ Fault = 'raw intent' }, @{ Fault = 'network' }, @{ Fault = 'operator' }
        ) {
            New-HostSettingsFixture
            switch ($Fault) {
                'setting value' { $f.hostSettings.DOTNET_EnableDiagnostics = '1' }
                'extra setting' { $f.hostSettings.Unreviewed = 'unsupported' }
                'extra execution' { $f.count = 2 }
                'CloudBuild' { $f.execution.properties.template.containers[0].imageType = 'CloudBuild' }
                'raw intent' { $f.job.properties.template.containers[0].resources.memory = '3Gi'; $f.execution.properties.template.containers[0].resources.memory = '3Gi' }
                'network' { $f.resources[$f.ids.storage].properties.publicNetworkAccess = 'Enabled' }
                'operator' { $f.operator.userObjectId = 'ffffffff-ffff-4fff-8fff-ffffffffffff' }
            }
            $before = (Get-FileHash $statePath).Hash
            { Plan-HostSettings } | Should -Throw
            (Get-FileHash $statePath).Hash | Should -BeExactly $before
        }

        It 'host amendment rejects post-Plan state, artifact or config drift <Fault>' -ForEach @(
            @{ Fault = 'state' }, @{ Fault = 'config' }, @{ Fault = 'plan' }, @{ Fault = 'partial' },
            @{ Fault = 'snapshot' }, @{ Fault = 'owner' }, @{ Fault = 'package' },
            @{ Fault = 'settings' }, @{ Fault = 'execution' }
        ) {
            New-HostSettingsFixture
            $review = Plan-HostSettings
            $s = Read-FixtureState
            $p = Get-Content -LiteralPath $review.planPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            switch ($Fault) {
                'state' { $s.steps['Gateway runtime deployment'].message = 'different failure' }
                'config' { $f.config.location = 'other' }
                'plan' { $p.plan.parentReceiptFingerprint = 'sha256:' + ('f' * 64) }
                'partial' { $p.Remove('plan') }
                'snapshot' {
                    $path = Join-Path $f.root "$($p.executionSource)/src/fixture/runtime.cs"
                    (Get-Item $path).IsReadOnly = $false
                    [IO.File]::AppendAllText($path, '// changed')
                }
                'owner' { $p.executionSource = $p.executionSource.Replace($s.deploymentOwnershipId, 'ffffffff-ffff-4fff-8fff-ffffffffffff') }
                'package' { [IO.File]::AppendAllText((Join-Path $s.freshPurviewExecutor.packageDirectory $s.freshPurviewExecutor.package.receipt.packageFileName), 'changed') }
                'settings' { $f.hostSettings.DOTNET_EnableDiagnostics = '1' }
                'execution' { $f.count = 2 }
            }
            [IO.File]::WriteAllText($review.planPath, (ConvertTo-Json -InputObject $p -Depth 100))
            [IO.File]::WriteAllText($statePath, (ConvertTo-Json -InputObject $s -Depth 100))
            $before = (Get-FileHash $statePath).Hash
            { Execute-HostSettings $review.planFingerprint } | Should -Throw
            (Get-FileHash $statePath).Hash | Should -BeExactly $before
        }

        It 'host amendment pins real Resume and Verify callbacks and survives forward progress with no publication or enable replay' {
            New-HostSettingsFixture
            $review = Plan-HostSettings; $null = Execute-HostSettings $review.planFingerprint
            $s = Read-FixtureState
            $operations = Get-BootstrapObjectFingerprint -InputObject $s.freshPurviewExecutor.operations
            $prefix = @{}; foreach ($name in @(Get-GatewayBootstrapStepNames)[2..13]) {
                $prefix[$name] = Get-BootstrapObjectFingerprint -InputObject $s.steps[$name]
            }
            Initialize-AmendedFixture $s Resume
            (Get-Command Get-PurviewExecutorArmSettings).Module.Path | Should -BeLike "*$($review.planFingerprint.Substring(7))*"
            foreach ($delivery in 1..2) {
                { Invoke-ShippedRuntimeFixture -State $s } | Should -Throw
                $s.freshPurviewExecutor.status | Should -BeExactly 'Installed'
                (Get-BootstrapObjectFingerprint -InputObject $s.freshPurviewExecutor.operations) | Should -BeExactly $operations
                $s = Read-FixtureState
            }
            # After amendment completion, a later ordinary core attempt may retain
            # partial evidence. Creation-only restrictions must not invalidate it.
            $s.steps['Gateway runtime deployment'].evidence = @{ partialRuntime = $true }
            $null = Assert-BootstrapPublisherRecoveryReceipt -State $s
            foreach ($name in @(Get-GatewayBootstrapStepNames)[0..1]) {
                $evidence = $s.steps[$name].evidence
                $null = Invoke-RecoveryStepFixture -State $s -Name $name -AlwaysRun -Action { $evidence }
            }
            foreach ($name in @(Get-GatewayBootstrapStepNames)[2..13]) {
                $null = Invoke-RecoveryStepFixture -State $s -Name $name -Validate { $true } -Action { throw 'Immutable prefix replay forbidden' }
                (Get-BootstrapObjectFingerprint -InputObject $s.steps[$name]) | Should -BeExactly $prefix[$name]
            }
            foreach ($name in @(Get-GatewayBootstrapStepNames)[14..18]) {
                $null = Invoke-RecoveryStepFixture -State $s -Name $name -Action { @{ verified = $true } }
                $null = Assert-BootstrapPublisherRecoveryReceipt -State $s
            }
            Initialize-AmendedFixture $s Verify
            $verified = Install-BootstrapPurviewExecutor -Config $f.config -State $s -StatePath $statePath `
                -Foundation $s.steps['Azure foundation'].evidence -Runtime $s.steps['Inert identity deployment'].evidence `
                -Automation $f.automation -Database $f.database -ReadOnly
            $verified.packageDigest | Should -BeExactly $s.freshPurviewExecutor.package.receipt.packageDigest
            $null = Invoke-RecoveryStepFixture -State $s -Name 'End-to-end deployment verification' -Mode Verify -AlwaysRun -Action { @{ verified = $true } }
            $null = Execute-HostSettings $review.planFingerprint
            (Get-BootstrapObjectFingerprint -InputObject $s.publisherMetadataReconciliation) | Should -BeExactly $f.parentHash
            @($f.calls | Where-Object { ($_ -join ' ') -match 'deployment group create|job start|acr build' }).Count | Should -Be 0
            $f.count = 2
            $sentinel = @{ called = $false }
            { Invoke-RecoveryStepFixture -State $s -Name 'Gateway runtime deployment' -Action { $sentinel.called = $true } } | Should -Throw
            $sentinel.called | Should -BeFalse
            $f.count = 1
            foreach ($fault in @('partial', 'parent', 'hash', 'prefix', 'operations', 'package', 'config')) {
                $copy = ConvertTo-BootstrapCanonicalValue -Value $s
                switch ($fault) {
                    'partial' { $copy.hostSettingsAmendment.Remove('completedAtUtc') }
                    'parent' { $copy.Remove('publisherMetadataReconciliation') }
                    'hash' { $copy.hostSettingsAmendment.completionFingerprint = 'sha256:' + ('f' * 64) }
                    'prefix' { $copy.steps['Gateway database'].evidence.verified = $false }
                    'operations' { $copy.freshPurviewExecutor.operations.unknown = @{ status = 'Completed' } }
                    'package' { $copy.freshPurviewExecutor.package.receipt.packageBytes++ }
                    'config' { $copy.configurationFingerprint = 'sha256:' + ('f' * 64) }
                }
                { Get-GatewayResumeExecutionSource -State $copy } | Should -Throw
            }
        }

        It 'plans read-only and executes only a separate receipt; same approved plan is restart-idempotent' {
            $beforeBytes = (Get-FileHash $statePath -Algorithm SHA256).Hash
            $before = Get-BootstrapObjectFingerprint -InputObject $f.state
            $review = Plan-Fixture
            $review.status | Should -BeExactly 'ReviewedReadOnly'
            (Get-FileHash $statePath -Algorithm SHA256).Hash | Should -BeExactly $beforeBytes
            (Execute-Fixture $review.planFingerprint).status | Should -BeExactly 'Completed'
            $s = Read-FixtureState
            $s.steps['Gateway runtime deployment'].status | Should -BeExactly 'Failed'
            $s.freshPurviewExecutor.operations.publish.status | Should -BeExactly 'Started'
            $receipt = $s.publisherMetadataReconciliation
            $s.Remove('publisherMetadataReconciliation')
            (Get-BootstrapObjectFingerprint -InputObject $s) | Should -BeExactly $before
            $s.publisherMetadataReconciliation = $receipt
            $null = Assert-BootstrapPublisherRecoveryReceipt -State $s
            $receiptBytes = (Get-FileHash $statePath -Algorithm SHA256).Hash
            $null = Execute-Fixture $review.planFingerprint
            (Get-FileHash $statePath -Algorithm SHA256).Hash | Should -BeExactly $receiptBytes
        }

        It 'rejects current job and execution drifting together away from the original raw intent' {
            $f.job.properties.template.containers[0].resources.cpu = 1.0
            $f.execution.properties.template.containers[0].resources.cpu = 1.0
            { Plan-Fixture } | Should -Throw '*raw job intent*'
            @($f.calls | Where-Object { ($_ -join ' ') -match 'job execution list' }).Count | Should -Be 0
        }

        It 'rejects unsupported provider publication <Fault>' -ForEach @(
            @{ Fault = 'CloudBuild' }, @{ Fault = 'extra execution' }, @{ Fault = 'missing execution' },
            @{ Fault = 'unknown container' }, @{ Fault = 'image' }, @{ Fault = 'env' }, @{ Fault = 'network' }, @{ Fault = 'owner' }
        ) {
            switch ($Fault) {
                'CloudBuild' { $f.execution.properties.template.containers[0].imageType = 'CloudBuild' }
                'extra execution' { $f.count = 2 }
                'missing execution' { $f.count = 0 }
                'unknown container' { $f.execution.properties.template.containers[0].unreviewed = $null }
                'image' { $f.execution.properties.template.containers[0].image = 'fixture.azurecr.io/changed@sha256:' + ('f' * 64) }
                'env' { $f.execution.properties.template.containers[0].env[0].value = 'changed' }
                'network' { $f.resources[$f.ids.storage].properties.publicNetworkAccess = 'Enabled' }
                'owner' { $f.job.tags.bootstrapOwnershipId = 'ffffffff-ffff-4fff-8fff-ffffffffffff' }
            }
            $hash = (Get-FileHash $statePath -Algorithm SHA256).Hash
            { Plan-Fixture } | Should -Throw
            (Get-FileHash $statePath -Algorithm SHA256).Hash | Should -BeExactly $hash
        }

        It 'requires explicit Yes and exact approval, with exclusive original state locking' {
            $review = Plan-Fixture
            { Invoke-BootstrapPublisherMetadataReconciliation -Mode Execute -Config $f.config -StatePath $statePath -ExpectedPlanFingerprint $review.planFingerprint } | Should -Throw '*requires Yes*'
            { Execute-Fixture ('sha256:' + ('f' * 64)) } | Should -Throw '*approval fingerprint*'
            $lock = Enter-BootstrapLock -StatePath $statePath
            try { { Execute-Fixture $review.planFingerprint } | Should -Throw '*lock*' }
            finally { $lock.Dispose() }
        }

        It 'rejects changed plan or exact original state before Execute: <Fault>' -ForEach @(
            @{ Fault = 'plan' }, @{ Fault = 'failed step' }, @{ Fault = 'prefix' }, @{ Fault = 'package' },
            @{ Fault = 'config' }, @{ Fault = 'operator' }, @{ Fault = 'other recovery' }, @{ Fault = 'late operation' }
        ) {
            $review = Plan-Fixture
            $s = Read-FixtureState
            switch ($Fault) {
                'plan' {
                    $p = Get-Content $review.planPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
                    $p.plan.provider.publication.name = 'changed'
                    [IO.File]::WriteAllText($review.planPath, (ConvertTo-Json -InputObject $p -Depth 100))
                }
                'failed step' { $s.steps['Gateway runtime deployment'].message = 'changed' }
                'prefix' { $s.steps['Gateway database'].evidence.verified = $false }
                'package' { [IO.File]::AppendAllText((Join-Path $s.freshPurviewExecutor.packageDirectory $s.freshPurviewExecutor.package.receipt.packageFileName), 'changed') }
                'config' { $f.config.location = 'other' }
                'operator' { $f.operator.userObjectId = 'ffffffff-ffff-4fff-8fff-ffffffffffff' }
                'other recovery' { $s.databaseRecoveryPlan = @{} }
                'late operation' { $s.freshPurviewExecutor.operations.unknown = @{ status = 'Completed' } }
            }
            [IO.File]::WriteAllText($statePath, (ConvertTo-Json -InputObject $s -Depth 100))
            { Execute-Fixture $review.planFingerprint } | Should -Throw
            (Read-FixtureState).Contains('publisherMetadataReconciliation') | Should -BeFalse
        }

        It 'rejects immutable source drift and unrelated tooling changes: <Path>' -ForEach @(
            @{ Path = 'src/fixture/runtime.cs' }, @{ Path = 'infrastructure/bicep/admin-ui.bicep' },
            @{ Path = 'bootstrap/modules/Entra.psm1' }, @{ Path = 'bootstrap/modules/PurviewExecutor.psm1' }
        ) {
            if ($Path -ceq 'bootstrap/modules/PurviewExecutor.psm1') {
                [IO.File]::AppendAllText((Join-Path $f.root $Path), "`nfunction Unreviewed-Override { return 1 }")
            } else { [IO.File]::AppendAllText((Join-Path $f.root $Path), "`n//changed") }
            { Plan-Fixture } | Should -Throw
        }

        It 'rejects arbitrary edits inside an otherwise allowlisted function' {
            $path = "$($f.root)/bootstrap/modules/Azure.psm1"
            $text = [IO.File]::ReadAllText($path).Replace(
                "throw 'The workload execution source no longer matches the accepted content-addressed snapshot.'",
                "return @{ bypassed = `$true }")
            [IO.File]::WriteAllText($path, $text)
            { Plan-Fixture } | Should -Throw '*exact reviewed metadata repair*'
        }

        It 'rejects snapshot or review-artifact tampering after Plan: <Fault>' -ForEach @(
            @{ Fault = 'original snapshot' }, @{ Fault = 'corrected snapshot' },
            @{ Fault = 'snapshot owner' }, @{ Fault = 'partial plan' }
        ) {
            $review = Plan-Fixture
            $p = Get-Content $review.planPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            switch ($Fault) {
                'original snapshot' { [IO.File]::AppendAllText("$($f.originalRoot)/src/fixture/runtime.cs", '// changed') }
                'corrected snapshot' {
                    $path = Join-Path $f.root "$($p.executionSource)/src/fixture/runtime.cs"
                    (Get-Item -LiteralPath $path).IsReadOnly = $false
                    [IO.File]::AppendAllText($path, '// changed')
                }
                'snapshot owner' { $p.executionSource = $p.executionSource.Replace($f.state.deploymentOwnershipId, 'ffffffff-ffff-4fff-8fff-ffffffffffff') }
                'partial plan' { $p.Remove('plan') }
            }
            [IO.File]::WriteAllText($review.planPath, (ConvertTo-Json -InputObject $p -Depth 100))
            $before = (Get-FileHash $statePath).Hash
            { Execute-Fixture $review.planFingerprint } | Should -Throw
            (Get-FileHash $statePath).Hash | Should -BeExactly $before
        }

        It 'rejects fresh provider drift before a normal callback after receipt: <Fault>' -ForEach @(
            @{ Fault = 'extra execution' }, @{ Fault = 'CloudBuild' }, @{ Fault = 'private network' }
        ) {
            $review = Plan-Fixture; $null = Execute-Fixture $review.planFingerprint
            $s = Read-FixtureState
            switch ($Fault) {
                'extra execution' { $f.count = 2 }
                'CloudBuild' { $f.execution.properties.template.containers[0].imageType = 'CloudBuild' }
                'private network' { $f.resources[$f.ids.storage].properties.publicNetworkAccess = 'Enabled' }
            }
            $before = (Get-FileHash $statePath).Hash
            $sentinel = @{ called = $false }
            { Invoke-RecoveryStepFixture -State $s -Name 'Gateway runtime deployment' -Action { $sentinel.called = $true } } | Should -Throw
            $sentinel.called | Should -BeFalse
            (Get-FileHash $statePath).Hash | Should -BeExactly $before
        }

        It 'separately proves corrected tooling and original assets after restart' {
            $review = Plan-Fixture; $null = Execute-Fixture $review.planFingerprint
            $s = Read-FixtureState
            $corrected = Assert-BootstrapPublisherRecoveryReceipt -State $s
            Set-BootstrapExecutionSourceRoot -Path $corrected
            $old = $s.acceptedPlan.sourceFingerprint
            $new = $s.publisherMetadataReconciliation.plan.correctedSourceFingerprint
            (Get-BootstrapAssetSourceRoot -State $s -ExecutionSourceFingerprint $new -DeploymentSourceFingerprint $old) | Should -BeExactly $f.originalRoot
            { Get-BootstrapAssetSourceRoot -State $s -ExecutionSourceFingerprint $old -DeploymentSourceFingerprint $old } | Should -Throw
            Set-BootstrapExecutionSourceRoot -Path $f.originalRoot
            { Get-BootstrapAssetSourceRoot -State $s -ExecutionSourceFingerprint $new -DeploymentSourceFingerprint $old } | Should -Throw
        }

        It 'retains the receipt through real AlwaysRun checks, publication checkpoint, and nineteen-step forward progress' {
            $review = Plan-Fixture; $null = Execute-Fixture $review.planFingerprint
            $s = Read-FixtureState
            $binding = Get-GatewayResumeExecutionSource -State $s
            $binding.executionSourceFingerprint | Should -BeExactly $s.publisherMetadataReconciliation.plan.correctedSourceFingerprint
            $binding.deploymentSourceFingerprint | Should -BeExactly $s.acceptedPlan.sourceFingerprint
            $prefixBefore = @{}
            foreach ($name in @(Get-GatewayBootstrapStepNames)[2..13]) { $prefixBefore[$name] = Get-BootstrapObjectFingerprint -InputObject $s.steps[$name] }
            foreach ($name in @(Get-GatewayBootstrapStepNames)[0..1]) {
                $evidence = $s.steps[$name].evidence
                $null = Invoke-RecoveryStepFixture -State $s -Name $name -AlwaysRun -Action { $evidence }
                $null = Assert-BootstrapPublisherRecoveryReceipt -State $s
            }
            foreach ($name in @(Get-GatewayBootstrapStepNames)[2..13]) {
                $null = Invoke-RecoveryStepFixture -State $s -Name $name -Validate { $true } -Action { throw 'Completed prefix replay forbidden' }
                (Get-BootstrapObjectFingerprint -InputObject $s.steps[$name]) | Should -BeExactly $prefixBefore[$name]
            }
            $null = Invoke-RecoveryStepFixture -State $s -Name 'Gateway runtime deployment' -Action {
                (Get-BootstrapAssetSourceRoot -State $s -ExecutionSourceFingerprint $binding.executionSourceFingerprint `
                    -DeploymentSourceFingerprint $binding.deploymentSourceFingerprint) | Should -BeExactly $f.originalRoot
                $r = $s.freshPurviewExecutor
                $r.publication = Start-PurviewPublisherOnce -Config $f.config -Template $f.job.properties.template -Record $r -Checkpoint {
                    Save-BootstrapState -State $s -Path $statePath
                }
                $r.operations.publish.status | Should -BeExactly 'Completed'
                $null = Assert-BootstrapPublisherRecoveryReceipt -State $s
                # The local receipt validator is tested against the expected normal
                # enable transition, not used as provider evidence for that mutation.
                Set-FixtureInstalledState -State $s
                return @{ verified = $true }
            }
            foreach ($name in @(Get-GatewayBootstrapStepNames)[15..18]) {
                $null = Invoke-RecoveryStepFixture -State $s -Name $name -Action { @{ verified = $true } }
                $s = Read-FixtureState
                $null = Assert-BootstrapPublisherRecoveryReceipt -State $s
            }
            $s.steps.Count | Should -Be 19
            @($s.steps.Values | Where-Object status -CEQ 'Completed').Count | Should -Be 19
            foreach ($name in $prefixBefore.Keys) { (Get-BootstrapObjectFingerprint -InputObject $s.steps[$name]) | Should -BeExactly $prefixBefore[$name] }
            $null = Invoke-RecoveryStepFixture -State $s -Mode Verify -Name 'End-to-end deployment verification' -AlwaysRun -Action { @{ verified = $true } }
            $null = Assert-BootstrapPublisherRecoveryReceipt -State $s
        }

        It 'rejects a tampered completed receipt after forward progress: <Fault>' -ForEach @(
            @{ Fault = 'partial receipt' }, @{ Fault = 'receipt hash' }, @{ Fault = 'prefix' }, @{ Fault = 'plan' },
            @{ Fault = 'original operation' }, @{ Fault = 'raw intent' }, @{ Fault = 'enable intent' },
            @{ Fault = 'unknown operation' }, @{ Fault = 'package record' }, @{ Fault = 'identity' },
            @{ Fault = 'source' }, @{ Fault = 'configuration' }, @{ Fault = 'incompatible generation' }
        ) {
            $review = Plan-Fixture; $null = Execute-Fixture $review.planFingerprint
            $s = Read-FixtureState
            Set-FixtureInstalledState -State $s
            switch ($Fault) {
                'partial receipt' { $s.publisherMetadataReconciliation.Remove('completedAtUtc') }
                'receipt hash' { $s.publisherMetadataReconciliation.completionFingerprint = 'sha256:' + ('f' * 64) }
                'prefix' { $s.steps['Gateway database'].evidence.verified = $false }
                'plan' { $s.acceptedPlan.planFingerprint = 'sha256:' + ('f' * 64) }
                'original operation' { $s.freshPurviewExecutor.operations.application.evidenceFingerprint = 'sha256:' + ('f' * 64) }
                'raw intent' { $s.freshPurviewExecutor.operations.publish.intentFingerprint = 'sha256:' + ('f' * 64) }
                'enable intent' { $s.freshPurviewExecutor.operations['a365gw-fixture-executor-enable-dev'].intentFingerprint = 'sha256:' + ('f' * 64) }
                'unknown operation' { $s.freshPurviewExecutor.operations.lateUnknown = @{ status = 'Completed' } }
                'package record' { $s.freshPurviewExecutor.package.receipt.packageBytes++ }
                'identity' { $s.freshPurviewExecutor.context.workerPrincipalId = 'ffffffff-ffff-4fff-8fff-ffffffffffff' }
                'source' { $s.source.lastWritten.bootstrapSourceFingerprint = 'sha256:' + ('f' * 64) }
                'configuration' { $s.configurationFingerprint = 'sha256:' + ('f' * 64) }
                'incompatible generation' { $s.purviewPrerequisiteReconciliation = @{} }
            }
            { Assert-BootstrapPublisherRecoveryReceipt -State $s } | Should -Throw
        }

        It 'selects pinned corrected modules for both Resume and Verify while original parser still rejects imageType' {
            $review = Plan-Fixture; $null = Execute-Fixture $review.planFingerprint
            $s = Read-FixtureState
            $originalAst = [Management.Automation.Language.Parser]::ParseFile("$($f.originalRoot)/bootstrap/modules/PurviewExecutor.psm1", [ref]$null, [ref]$null)
            $originalFunction = $originalAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -ceq 'ConvertTo-PurviewPublisherExecutionTemplate' }, $true)
            $originalBody = $originalFunction.Body.Extent.Text
            $originalParser = [scriptblock]::Create($originalBody.Substring(1, $originalBody.Length - 2))
            { & $originalParser -Template $f.execution.properties.template } | Should -Throw
            foreach ($mode in @('Resume', 'Verify')) {
                Initialize-BootstrapPublisherRecoveryTooling -State $s -Config $f.config -Mode $mode
                $selected = Get-GatewayResumeExecutionSource -State $s
                [IO.Path]::GetFullPath((Get-Command ConvertTo-PurviewPublisherExecutionTemplate).Module.Path) |
                    Should -BeExactly ([IO.Path]::GetFullPath("$($selected.executionSourceRoot)/bootstrap/modules/PurviewExecutor.psm1"))
                $null = ConvertTo-PurviewPublisherExecutionTemplate -Template $f.execution.properties.template
                (Get-BootstrapAssetSourceRoot -State $s -ExecutionSourceFingerprint $selected.executionSourceFingerprint `
                    -DeploymentSourceFingerprint $selected.deploymentSourceFingerprint) | Should -BeExactly $f.originalRoot
            }
        }

        It 'runs the shipped runtime callback through the real installer and corrected parser without rebuilding or restarting' {
            $review = Plan-Fixture; $null = Execute-Fixture $review.planFingerprint
            $s = Read-FixtureState
            Initialize-BootstrapPublisherRecoveryTooling -State $s -Config $f.config -Mode Resume
            $pinned = Assert-BootstrapPublisherRecoveryReceipt -State $s
            [IO.Path]::GetFullPath((Get-Command Install-BootstrapPurviewExecutor).Module.Path) |
                Should -BeExactly ([IO.Path]::GetFullPath("$pinned/bootstrap/modules/PurviewExecutor.psm1"))
            # Pester's name-only selector cannot distinguish the nested snapshot
            # Common/Azure copies. Substitute only those modules' external I/O,
            # leaving their actual source/root/receipt functions untouched.
            foreach ($module in @(Get-Module -All | Where-Object {
                $_.Path -and $_.Path.StartsWith($pinned, [StringComparison]::OrdinalIgnoreCase)
            })) {
                & $module {
                    param($process)
                    Set-Item Function:script:Invoke-BootstrapCommand -Value $process
                    if ($ExecutionContext.SessionState.Module.Name -ceq 'Common') {
                        Set-Item Function:script:Get-BootstrapGraphHttpClient -Value { $global:publisherRecoveryHttp }
                    }
                } $processBoundary
            }
            $copy = ConvertTo-BootstrapCanonicalValue -Value $s
            Set-FixtureInstalledState -State $copy
            $f.resources[$f.ids.site].properties.enabled = $false
            $f.allowRuntime = $true
            $packageBefore = (Get-FileHash (Join-Path $s.freshPurviewExecutor.packageDirectory $s.freshPurviewExecutor.package.receipt.packageFileName)).Hash
            foreach ($delivery in 1..2) {
                # This fixture deliberately has no full core runtime foundation. The
                # shipped callback must finish the real executor sequence, then stop
                # at the unchanged core provider guard, not an executor/source guard.
                $failure = { Invoke-ShippedRuntimeFixture -State $s } | Should -Throw -PassThru
                if ($s.freshPurviewExecutor.status -cne 'Installed') {
                    throw "Synthetic runtime stopped before executor completion: $($f.runtimeFailure.Exception.Message) at $($f.runtimeFailure.ScriptStackTrace)"
                }
                $s.freshPurviewExecutor.status | Should -BeExactly 'Installed'
                $s.freshPurviewExecutor.operations.publish.status | Should -BeExactly 'Completed'
                $s.freshPurviewExecutor.publication.name | Should -BeExactly 'exact-execution'
                $null = Assert-BootstrapPublisherRecoveryReceipt -State $s
                $s = Read-FixtureState
            }
            # Verification.psm1 uses this same pinned, real read-only installer.
            # It must accept the completed publication without a local rebuild.
            $verified = Install-BootstrapPurviewExecutor -Config $f.config -State $s -StatePath $statePath `
                -Foundation $s.steps['Azure foundation'].evidence -Runtime $s.steps['Inert identity deployment'].evidence `
                -Automation $f.automation -Database $f.database -ReadOnly
            $verified.packageDigest | Should -BeExactly $s.freshPurviewExecutor.package.receipt.packageDigest
            (Get-FileHash (Join-Path $s.freshPurviewExecutor.packageDirectory $s.freshPurviewExecutor.package.receipt.packageFileName)).Hash | Should -BeExactly $packageBefore
            @($f.calls | Where-Object { ($_ -join ' ') -match 'deployment group create' }).Count | Should -Be 1
            @($f.calls | Where-Object { ($_ -join ' ') -match 'job start|acr build|build-purview-executor-package' }).Count | Should -Be 0
        }

        It 'runs the actual Admin deployment source guard and consumes the original Bicep asset' {
            $review = Plan-Fixture; $null = Execute-Fixture $review.planFingerprint
            $s = Read-FixtureState
            Set-BootstrapExecutionSourceRoot -Path (Assert-BootstrapPublisherRecoveryReceipt -State $s)
            $f.allowAdmin = $true
            $result = Deploy-GatewayAdminUi -Config $f.config -Foundation @{ containerAppsEnvironmentName = 'private'; privateEndpointSubnetId = 'private'; virtualNetworkId = 'private' } `
                -Identity @{ gatewayApiScopeBaseUri = 'api://fixture' } -AdminIdentity @{ adminUiClientId = $f.operator.userObjectId } `
                -AdminUiImage 'fixture-admin' -AdminUiSecretUri 'https://kv-fixture-dev.vault.azure.net/secrets/admin-reference' `
                -DeploymentOwnershipId $s.deploymentOwnershipId -SourceFingerprint $s.acceptedPlan.sourceFingerprint `
                -ExecutionSourceFingerprint $s.publisherMetadataReconciliation.plan.correctedSourceFingerprint -PublisherRecoveryState $s
            $result.sourceFingerprint | Should -BeExactly $s.acceptedPlan.sourceFingerprint
            @($f.calls | Where-Object { ($_ -join ' ') -match 'deployment group create' }).Count | Should -Be 1
        }
    }

    It 'provides independent creation and completed receipt validation' {
        Import-Module "$repository/bootstrap/modules/PublisherRecovery.psm1" -Force -DisableNameChecking -ErrorAction Stop
        Get-Command Assert-BootstrapPublisherRecoveryEligibility -ErrorAction Stop | Should -Not -BeNullOrEmpty
        Get-Command Assert-BootstrapPublisherRecoveryReceipt -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }

    It 'provides an original-asset resolver without an arbitrary path override' {
        $command = Get-Command Get-BootstrapAssetSourceRoot -ErrorAction Stop
        $command.Parameters.Keys | Should -Contain 'State'
        $command.Parameters.Keys | Should -Contain 'ExecutionSourceFingerprint'
        $command.Parameters.Keys | Should -Not -Contain 'AssetRoot'
    }
}
