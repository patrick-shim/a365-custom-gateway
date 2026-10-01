BeforeAll {
    $jointModule = $null
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $definitions = foreach ($source in @(
        @{ Path = 'operations\GatewayUpgradeExecution.psm1'; Names = @(
            'Assert-GatewayUpgradeJointReadback', 'Assert-GatewayUpgradeSourceOnlyWorkloadPreservation',
            'Get-GatewayUpgradeSourceOnlyWorkloadFingerprint', 'Get-GatewayUpgradeWorkloadDeploymentFingerprint'
        ) }
        @{ Path = 'operations\GatewayUpgrade.psm1'; Names = @(
            'ConvertTo-GatewayUpgradeCanonical', 'ConvertTo-GatewayUpgradeCanonicalJson', 'Get-GatewayUpgradeFingerprint',
            'Test-GatewayUpgradeResourceId'
        ) }
        @{ Path = 'bootstrap\modules\Common.psm1'; Names = @('Test-GatewayContainerAppRevisionRunning') }
    )) {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $root $source.Path), [ref]$tokens, [ref]$errors)
        if ($errors.Count -ne 0) { throw 'The real joint-readback helpers must parse.' }
        foreach ($name in $source.Names) {
            $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $false)
            if ($null -eq $definition) { throw "Missing real joint-readback helper: $name" }
            $definition.Extent.Text
        }
    }
    $jointModule = New-Module -Name "UpgradeJointFixture_$([guid]::NewGuid().ToString('N'))" `
        -ArgumentList ($definitions -join "`n") -ScriptBlock {
        param($definitions)
        Set-StrictMode -Version Latest
        function Assert-GatewayUpgradeCutoverHeld { param($Context) throw 'Unscripted cutover access is forbidden.' }
        function Assert-GatewayUpgradeRollbackContract { param($Context, $DatabaseReceipt) throw 'Unscripted rollback is forbidden.' }
        function Read-GatewayUpgradeExecutionRecord { param($Context, $Action, $Kind) throw 'Unscripted record access is forbidden.' }
        function Test-GatewayUpgradeDatabaseReceipt {
            param($Context, $ReceiptJson, $JobName, $ExecutionName)
            throw 'Unscripted database access is forbidden.'
        }
        function Get-GatewayUpgradeWorkloadSnapshot { param($Context, $Component) throw 'Unscripted workload access is forbidden.' }
        function Get-GatewayUpgradeMaintenanceEnvironment { param($Context, $Phase) throw 'Unscripted phase access is forbidden.' }
        function Get-GatewayUpgradeSourceOnlyEvidence {
            param($Context, $Name, $Value, [switch]$ReadOnly)
            throw 'Unscripted preservation evidence access is forbidden.'
        }
        function Get-GatewayUpgradeCutoverRevisions { param($Context, $AppId) throw 'Unscripted revision access is forbidden.' }
        function Invoke-GatewayUpgradeArm {
            param($Context, $Method, $ResourceId, $ApiVersion)
            throw 'Unscripted ARM access is forbidden.'
        }
        . ([scriptblock]::Create($definitions))
        Export-ModuleMember -Function Assert-GatewayUpgradeJointReadback,
            Get-GatewayUpgradeSourceOnlyWorkloadFingerprint, Get-GatewayUpgradeWorkloadDeploymentFingerprint
    }
    $jointModule | Import-Module -NoClobber -DisableNameChecking
    $jointReadback = $jointModule.ExportedCommands['Assert-GatewayUpgradeJointReadback']
    $originalFingerprint = $jointModule.ExportedCommands['Get-GatewayUpgradeSourceOnlyWorkloadFingerprint']
    $deploymentFingerprint = $jointModule.ExportedCommands['Get-GatewayUpgradeWorkloadDeploymentFingerprint']
}

AfterAll {
    if ($null -ne $jointModule) { Remove-Module -ModuleInfo $jointModule -Force }
}

Describe 'Original worker preservation at the actual joint reopening boundary' {
    It '<Label>' -ForEach @(
        @{ Label = 'checks both original environments before enabling consumers'; ConsumersEnabled = $false; ApiOpen = $false; SchemaVersion = 2; Reject = $false; Change = {} }
        @{ Label = 'checks both original environments before opening the API'; ConsumersEnabled = $true; ApiOpen = $false; SchemaVersion = 2; Reject = $false; Change = {} }
        @{ Label = 'checks both original environments after opening the API'; ConsumersEnabled = $true; ApiOpen = $true; SchemaVersion = 2; Reject = $false; Change = {} }
        @{ Label = 'rejects a changed worker tenant even with a matching promotion record'; ConsumersEnabled = $true; ApiOpen = $false; SchemaVersion = 2; Reject = $true; Change = {
            $workerEnvironment[0].value = 'different-tenant'
        } }
        @{ Label = 'rejects a changed worker endpoint'; ConsumersEnabled = $true; ApiOpen = $false; SchemaVersion = 2; Reject = $true; Change = {
            $workerEnvironment[1].value = 'https://different.synthetic.invalid'
        } }
        @{ Label = 'rejects a changed worker secret reference'; ConsumersEnabled = $true; ApiOpen = $false; SchemaVersion = 2; Reject = $true; Change = {
            $workerEnvironment[2].secretRef = 'different-synthetic-secret'
        } }
        @{ Label = 'rejects a removed worker capability'; ConsumersEnabled = $true; ApiOpen = $false; SchemaVersion = 2; Reject = $true; Change = {
            $snapshots.worker.raw.properties.template.containers[0].env = @(
                $workerEnvironment | Where-Object name -CNE 'BootstrapCapabilities__Purview__Enabled')
        } }
        @{ Label = 'rejects an added unrelated worker setting'; ConsumersEnabled = $true; ApiOpen = $false; SchemaVersion = 2; Reject = $true; Change = {
            $snapshots.worker.raw.properties.template.containers[0].env += @{ name = 'Unreviewed__Setting'; value = 'changed' }
        } }
        @{ Label = 'preserves legacy non-source-only admission'; ConsumersEnabled = $true; ApiOpen = $false; SchemaVersion = 1; Reject = $false; Change = {
            $workerEnvironment[0].value = 'legacy-reviewed-tenant'
        } }
    ) {
        $database = @{ schemaFingerprint = 'sha256:' + ('1' * 64); receiptFingerprint = 'sha256:' + ('2' * 64) }
        $preparation = @{ factsFingerprint = 'sha256:' + ('3' * 64); receiptFingerprint = 'sha256:' + ('4' * 64) }
        $context = @{
            plan = @{ request = @{ schemaVersion = $SchemaVersion; images = @{} } }
            cutoverInventory = @{ apps = @{ worker = @{ outboxEnvironment = @(@{ name = 'OutboxRelay__Enabled'; value = 'true' }) } } }
        }
        $snapshots = @{}
        $environments = @{ api = @{}; worker = @{}; adminUi = @{} }
        $original = @{}
        $expectedPhase = if ($ApiOpen) { 'Open' } else { 'PostSchemaClosed' }
        foreach ($component in @('api', 'worker', 'adminUi')) {
            $image = "synthetic.invalid/$component@sha256:" + ('5' * 64)
            $context.plan.request.images[$component] = $image
            $environment = @(
                @{ name = 'PurviewExecutor__Binding__TenantId'; value = 'original-synthetic-tenant' }
                @{ name = 'PurviewExecutor__BaseUrl'; value = 'https://executor.synthetic.invalid' }
                @{ name = 'Synthetic__Credential'; secretRef = 'original-synthetic-secret' }
                @{ name = 'BootstrapCapabilities__Purview__Enabled'; value = 'true' }
            )
            if ($component -ceq 'api') {
                $environment += @(
                    @{ name = 'DatabaseAttestation__ExpectedSchemaFingerprint'; value = $database.schemaFingerprint }
                    @{ name = 'BootstrapCapabilities__Preparation__ReceiptFingerprint'; value = $preparation.receiptFingerprint }
                    @{ name = 'MaintenanceCutover__Phase'; value = $expectedPhase }
                )
            }
            if ($component -ceq 'worker') {
                $enabled = if ($ConsumersEnabled) { 'true' } else { 'false' }
                $environments.worker = @{
                    ProvisioningWorker__ProcessingEnabled = $enabled
                    ProtectionAdminWorker__ProcessingEnabled = $enabled
                }
                $environment += @(
                    @{ name = 'ProvisioningWorker__ProcessingEnabled'; value = $enabled }
                    @{ name = 'ProtectionAdminWorker__ProcessingEnabled'; value = $enabled }
                    @{ name = 'OutboxRelay__Enabled'; value = $enabled }
                    @{ name = 'PurviewExecutor__Binding__ExecutionSourceFingerprint'; value = 'original-source' }
                    @{ name = 'PurviewExecutor__Binding__PackageDigest'; value = 'original-package' }
                )
            }
            $snapshots[$component] = @{
                id = "/synthetic/apps/$component"; image = $image
                protectedConfigurationFingerprint = 'sha256:' + ('6' * 64)
                raw = @{
                    identity = @{ type = 'UserAssigned' }; tags = @{ owner = 'synthetic-fixture' }
                    properties = @{
                        provisioningState = 'Succeeded'
                        configuration = @{ ingress = @{ targetPort = 8080 }; secrets = @() }
                        template = @{ containers = @(@{
                            name = $component; image = $image; env = $environment
                            probes = @(@{ type = 'Readiness'; httpGet = @{
                                port = 8080; path = if ($ApiOpen) { '/health/bootstrap-attestation' } else { '/health/maintenance' }
                            } })
                        }) }
                    }
                }
            }
            $original["source-only-$component-environment.json"] = & $originalFingerprint $component $snapshots[$component]
        }
        $workerEnvironment = $snapshots.worker.raw.properties.template.containers[0].env
        ($workerEnvironment | Where-Object name -CEQ 'PurviewExecutor__Binding__ExecutionSourceFingerprint').value = 'approved-new-source'
        ($workerEnvironment | Where-Object name -CEQ 'PurviewExecutor__Binding__PackageDigest').value = 'approved-new-package'
        . $Change
        $records = @{
            'database-execution/result' = @{ record = @{ value = @{ receiptJson = 'synthetic-receipt'; jobName = 'synthetic-job'; executionName = 'synthetic-execution' } } }
        }
        foreach ($component in @('api', 'worker', 'adminUi')) {
            $action = "workload-$($component.ToLowerInvariant())"
            if ($component -ceq 'worker' -and $ConsumersEnabled) { $action += '-enable' }
            if ($component -ceq 'api' -and $ApiOpen) { $action += '-open' }
            $records["$action/intent"] = @{ record = @{ value = @{ input = @{
                deploymentFingerprint = & $deploymentFingerprint $snapshots[$component]
            } } } }
            $records["$action/result"] = @{ record = @{ value = @{ revision = "$component--1" } } }
        }
        Mock Read-GatewayUpgradeExecutionRecord -ModuleName $jointModule.Name {
            $records.Contains("$Action/$Kind") | Should -BeTrue
            $records["$Action/$Kind"]
        }
        Mock Test-GatewayUpgradeDatabaseReceipt -ModuleName $jointModule.Name {
            $ReceiptJson | Should -BeExactly 'synthetic-receipt'
            $JobName | Should -BeExactly 'synthetic-job'
            $ExecutionName | Should -BeExactly 'synthetic-execution'
            $database
        }
        Mock Get-GatewayUpgradeWorkloadSnapshot -ModuleName $jointModule.Name { $snapshots[$Component] }
        Mock Get-GatewayUpgradeMaintenanceEnvironment -ModuleName $jointModule.Name {
            $Phase | Should -BeExactly $expectedPhase
            @{ MaintenanceCutover__Phase = $expectedPhase }
        }
        Mock Get-GatewayUpgradeSourceOnlyEvidence -ModuleName $jointModule.Name {
            $ReadOnly.IsPresent | Should -BeTrue
            $Value | Should -BeNullOrEmpty
            $original.Contains($Name) | Should -BeTrue
            $original[$Name]
        }
        Mock Get-GatewayUpgradeCutoverRevisions -ModuleName $jointModule.Name {
            $component = $AppId.Split('/')[-1]
            $snapshots.Contains($component) | Should -BeTrue
            @(@{
                id = "$AppId/revisions/$component--1"; name = "$component--1"
                properties = @{
                    active = $true; healthState = 'Healthy'; runningState = 'RunningAtMaxScale'; replicas = 1
                    template = $snapshots[$component].raw.properties.template
                }
            })
        }
        Mock Invoke-GatewayUpgradeArm -ModuleName $jointModule.Name {
            $Method | Should -BeExactly 'GET'
            $ApiVersion | Should -BeExactly '2025-01-01'
            $ResourceId | Should -Match '^/synthetic/apps/(api|worker|adminUi)/revisions/\1--1/replicas$'
            $component = $ResourceId.Split('/')[3]
            @{ value = @(@{
                id = "$ResourceId/replica-1"; name = 'replica-1'
                properties = @{ runningState = 'Running'; containers = @(@{ name = $component; ready = $true; started = $true }) }
            }) }
        }
        $invoke = {
            & $jointReadback $context $database $preparation $environments -ConsumersEnabled:$ConsumersEnabled -ApiOpen:$ApiOpen
        }
        if ($Reject) {
            $invoke | Should -Throw 'UpgradeSourceOnly: original capability, identity, endpoint or other workload environment changed.'
            Should -Invoke Get-GatewayUpgradeCutoverRevisions -ModuleName $jointModule.Name -Exactly -Times 0 `
                -ParameterFilter { $AppId -ceq '/synthetic/apps/worker' }
        }
        else {
            $result = & $invoke
            $result.workloads.Count | Should -Be 3
            $result.databaseReceiptFingerprint | Should -BeExactly $database.receiptFingerprint
            Should -Invoke Get-GatewayUpgradeSourceOnlyEvidence -ModuleName $jointModule.Name -Exactly -Times $(if ($SchemaVersion -eq 2) { 2 } else { 0 })
            Should -Invoke Invoke-GatewayUpgradeArm -ModuleName $jointModule.Name -Exactly -Times 3
        }
    }
}
