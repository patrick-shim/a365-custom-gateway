BeforeAll {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'operations\GatewayUpgradeExecution.psm1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'The real maintenance revision helpers must parse.' }
    $definitions = foreach ($name in @('Assert-GatewayUpgradeWorkloadHealthy', 'Assert-GatewayUpgradeMaintenanceApiRevision')) {
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $false)
        if ($null -eq $definition) { throw "The real '$name' helper is required." }
        $definition.Extent.Text
    }
    $common = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'bootstrap\modules\Common.psm1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'The real shared revision-state predicate must parse.' }
    $runningPredicate = $common.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Test-GatewayContainerAppRevisionRunning'
    }, $false)
    if ($null -eq $runningPredicate) { throw 'The shared revision-state predicate is required.' }
    $definitions += $runningPredicate.Extent.Text
    $core = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'operations\GatewayUpgrade.psm1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'The real ARM identity predicate must parse.' }
    $identityPredicate = $core.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Test-GatewayUpgradeResourceId'
    }, $false)
    if ($null -eq $identityPredicate) { throw 'The shared ARM identity predicate is required.' }
    $definitions += $identityPredicate.Extent.Text
    $healthModule = New-Module -Name "UpgradeRevisionFixture_$([guid]::NewGuid().ToString('N'))" `
        -ArgumentList ($definitions -join "`n") -ScriptBlock {
        param($definitions)
        Set-StrictMode -Version Latest
        function Invoke-AzJson { param($Arguments) throw 'Unscripted Azure access is forbidden.' }
        function Get-GatewayCurrentDatabaseAttestationEvidence { param($ApiFqdn) throw 'Unscripted API access is forbidden.' }
        function Wait-HttpsHealth { param($Url) throw 'Unscripted HTTP access is forbidden.' }
        function Get-GatewayUpgradeMaintenanceEnvironment { param($Context, $Phase) throw 'Unscripted phase lookup is forbidden.' }
        function Invoke-GatewayUpgradeArm {
            param($Context, $Method, $ResourceId, $ApiVersion)
            throw 'Unscripted ARM access is forbidden.'
        }
        . ([scriptblock]::Create($definitions))
        Export-ModuleMember -Function Assert-GatewayUpgradeWorkloadHealthy, Assert-GatewayUpgradeMaintenanceApiRevision
    }
    $healthModule | Import-Module -NoClobber -DisableNameChecking
    $workloadHealth = $healthModule.ExportedCommands['Assert-GatewayUpgradeWorkloadHealthy']
    $maintenanceHealth = $healthModule.ExportedCommands['Assert-GatewayUpgradeMaintenanceApiRevision']
}

Describe 'Consistent revision state across maintenance transitions' {
    It 'uses the shared revision predicate at every <Function> readiness gate' -ForEach @(
        @{ Function = 'Invoke-GatewayUpgradeWorkload'; Count = 2 }
        @{ Function = 'Invoke-GatewayUpgradePreSchemaApi'; Count = 1 }
        @{ Function = 'Assert-GatewayUpgradeMaintenanceApiRevision'; Count = 1 }
        @{ Function = 'Assert-GatewayUpgradeWorkloadHealthy'; Count = 1 }
        @{ Function = 'Assert-GatewayUpgradeJointReadback'; Count = 1 }
    ) {
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Function
        }, $false)
        $calls = @($definition.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Test-GatewayContainerAppRevisionRunning'
        }, $true))
        $calls.Count | Should -Be $Count
    }
}

AfterAll {
    if ($null -ne $healthModule) { Remove-Module -Name $healthModule.Name -Force }
}

Describe 'Canonical untouched workload revision health' {
    BeforeEach {
        $context = @{ config = @{ resourceGroupName = 'synthetic-workload-group' } }
        $snapshot = @{
            name = 'synthetic-workload'; revision = 'synthetic-workload--1'; fqdn = 'synthetic.invalid'
            raw = @{ properties = @{ provisioningState = 'Succeeded' } }
        }
        $revision = @{ name = $snapshot.revision; health = 'Healthy'; running = 'Running'; replicas = 1 }
        Mock Invoke-AzJson -ModuleName $healthModule.Name {
            $Arguments[0] | Should -BeExactly 'containerapp'
            $Arguments[1] | Should -BeExactly 'revision'
            $Arguments[2] | Should -BeExactly 'list'
            $Arguments[[Array]::IndexOf($Arguments, '--name') + 1] | Should -BeExactly $snapshot.name
            $Arguments[[Array]::IndexOf($Arguments, '--resource-group') + 1] | Should -BeExactly $context.config.resourceGroupName
            @($revision)
        }
        Mock Get-GatewayCurrentDatabaseAttestationEvidence -ModuleName $healthModule.Name {
            $ApiFqdn | Should -BeExactly $snapshot.fqdn
            @{ attested = $true }
        }
        Mock Wait-HttpsHealth -ModuleName $healthModule.Name {
            $Url | Should -BeExactly "https://$($snapshot.fqdn)/health"
            200
        }
    }

    It 'accepts <Component> with a ready <Running> revision' -ForEach @(
        @{ Component = 'api'; Running = 'Running' }
        @{ Component = 'api'; Running = 'RunningAtMaxScale' }
        @{ Component = 'worker'; Running = 'Running' }
        @{ Component = 'worker'; Running = 'RunningAtMaxScale' }
        @{ Component = 'adminUi'; Running = 'Running' }
        @{ Component = 'adminUi'; Running = 'RunningAtMaxScale' }
    ) {
        $revision.running = $Running
        { & $workloadHealth $context $snapshot $Component } | Should -Not -Throw
        Should -Invoke Invoke-AzJson -ModuleName $healthModule.Name -Exactly -Times 1
        Should -Invoke Get-GatewayCurrentDatabaseAttestationEvidence -ModuleName $healthModule.Name -Exactly -Times $(if ($Component -ceq 'api') { 1 } else { 0 })
        Should -Invoke Wait-HttpsHealth -ModuleName $healthModule.Name -Exactly -Times $(if ($Component -ceq 'adminUi') { 1 } else { 0 })
    }

    It 'rejects an otherwise healthy <_> revision' -ForEach @('Stopped', 'Degraded', 'Failed', 'Processing', 'Unknown', 'running', '') {
        $revision.running = $_
        { & $workloadHealth $context $snapshot api } | Should -Throw '*revision is not exactly healthy*'
        Should -Invoke Get-GatewayCurrentDatabaseAttestationEvidence -ModuleName $healthModule.Name -Exactly -Times 0
    }

    It 'does not let the max-scale state bypass <Label>' -ForEach @(
        @{ Label = 'failed provisioning'; Change = { $snapshot.raw.properties.provisioningState = 'Failed' } }
        @{ Label = 'revision identity'; Change = { $revision.name = 'synthetic-workload--2' } }
        @{ Label = 'unhealthy state'; Change = { $revision.health = 'Unhealthy' } }
        @{ Label = 'zero replicas'; Change = { $revision.replicas = 0 } }
    ) {
        $revision.running = 'RunningAtMaxScale'
        . $Change
        { & $workloadHealth $context $snapshot api } | Should -Throw 'UpgradeOutcomeUnknown:*'
        Should -Invoke Get-GatewayCurrentDatabaseAttestationEvidence -ModuleName $healthModule.Name -Exactly -Times 0
    }
}

Describe 'Canonical maintenance API revision and replica health' {
    BeforeEach {
        $image = 'synthetic.invalid/api@sha256:' + ('1' * 64)
        $context = @{
            plan = @{ request = @{ images = @{ api = $image } } }
            cutoverInventory = @{ apps = @{ api = @{ configuration = @{ ingress = @{ targetPort = 8080 } } } } }
        }
        $revision = @{
            id = '/synthetic/app/revisions/api--1'
            properties = @{
                active = $true; healthState = 'Healthy'; runningState = 'Running'; replicas = 1
                template = @{ containers = @(@{
                    name = 'api'; image = $image
                    env = @(@{ name = 'MaintenanceCutover__Phase'; value = 'PreSchemaClosed' })
                    probes = @('Startup', 'Liveness', 'Readiness') | ForEach-Object {
                        @{ type = $_; httpGet = @{ path = '/health/maintenance'; port = 8080 } }
                    }
                }) }
            }
        }
        $replica = @{
            id = "$($revision.id)/replicas/replica-1"; name = 'replica-1'
            properties = @{
                runningState = 'Running'
                containers = @(@{ name = 'api'; ready = $true; started = $true })
            }
        }
        Mock Get-GatewayUpgradeMaintenanceEnvironment -ModuleName $healthModule.Name {
            @{ MaintenanceCutover__Phase = $Phase }
        }
        Mock Invoke-GatewayUpgradeArm -ModuleName $healthModule.Name {
            $Method | Should -BeExactly 'GET'
            $ResourceId | Should -BeExactly "$($revision.id)/replicas"
            $ApiVersion | Should -BeExactly '2025-01-01'
            @{ value = @($replica) }
        }
    }

    It 'accepts <Phase> with a ready <Running> revision and independently running replica' -ForEach @(
        @{ Phase = 'PreSchemaClosed'; Running = 'Running' }
        @{ Phase = 'PreSchemaClosed'; Running = 'RunningAtMaxScale' }
        @{ Phase = 'PostSchemaClosed'; Running = 'Running' }
        @{ Phase = 'PostSchemaClosed'; Running = 'RunningAtMaxScale' }
        @{ Phase = 'Open'; Running = 'Running' }
        @{ Phase = 'Open'; Running = 'RunningAtMaxScale' }
    ) {
        $revision.properties.runningState = $Running
        $revision.properties.template.containers[0].env[0].value = $Phase
        if ($Phase -ceq 'Open') {
            $revision.properties.template.containers[0].probes = @(
                @{ type = 'Readiness'; httpGet = @{ path = '/health/bootstrap-attestation'; port = 8080 } }
            )
        }
        { & $maintenanceHealth $context $revision $Phase } | Should -Not -Throw
        Should -Invoke Invoke-GatewayUpgradeArm -ModuleName $healthModule.Name -Exactly -Times 1
    }

    It 'keeps <Label> mandatory even at maximum scale' -ForEach @(
        @{ Label = 'an active revision'; Change = { $revision.properties.active = $false } }
        @{ Label = 'healthy state'; Change = { $revision.properties.healthState = 'Unhealthy' } }
        @{ Label = 'a positive replica count'; Change = { $revision.properties.replicas = 0 } }
        @{ Label = 'the approved image'; Change = { $revision.properties.template.containers[0].image = 'unapproved.invalid/image' } }
        @{ Label = 'the exact phase'; Change = { $revision.properties.template.containers[0].env[0].value = 'Open' } }
        @{ Label = 'the exact probe'; Change = { $revision.properties.template.containers[0].probes[2].httpGet.path = '/health' } }
        @{ Label = 'per-replica running state'; Change = { $replica.properties.runningState = 'RunningAtMaxScale' } }
        @{ Label = 'replica readiness'; Change = { $replica.properties.containers[0].ready = $false } }
        @{ Label = 'replica startup'; Change = { $replica.properties.containers[0].started = $false } }
        @{ Label = 'replica identity'; Change = { $replica.id = '/synthetic/unrelated/replicas/replica-1' } }
    ) {
        $revision.properties.runningState = 'RunningAtMaxScale'
        . $Change
        { & $maintenanceHealth $context $revision PreSchemaClosed } | Should -Throw 'UpgradeCutover*'
    }

    It 'accepts casing-only ARM replica identity differences without changing observed bytes' {
        $replica.id = $replica.id.Replace('/synthetic/app/', '/SYNTHETIC/APP/')
        $originalId = $replica.id
        { & $maintenanceHealth $context $revision PreSchemaClosed } | Should -Not -Throw
        $replica.id | Should -BeExactly $originalId
    }

    It 'rejects two casing aliases for one replica' {
        $revision.properties.replicas = 2
        $alias = $replica.Clone()
        $alias.id = $replica.id.Replace('/synthetic/app/', '/SYNTHETIC/APP/')
        Mock Invoke-GatewayUpgradeArm -ModuleName $healthModule.Name { @{ value = @($replica, $alias) } }
        { & $maintenanceHealth $context $revision PreSchemaClosed } | Should -Throw '*replica readiness is not proven*'
    }
}
