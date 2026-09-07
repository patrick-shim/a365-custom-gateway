& {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    foreach ($module in @('Common', 'Experience', 'Azure', 'Entra', 'PurviewRecovery')) {
        Import-Module (Join-Path $root "bootstrap/modules/$module.psm1") -Force -DisableNameChecking
    }
}

InModuleScope Common {
BeforeAll {
    $root = Get-RepositoryRoot
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'bootstrap/bootstrap.ps1'), [ref]$tokens, [ref]$errors)
    $errors.Count | Should -Be 0
    foreach ($name in @('Invoke-GatewayStateStep', 'Invoke-GatewayExactReconciliation', 'Get-GatewayResumeExecutionSource')) {
        $definition = $ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $true)
        $definition.Count | Should -Be 1
        . ([scriptblock]::Create($definition[0].Extent.Text.Replace("function $name {", "function script:$name {")))
        if ($name -ceq 'Get-GatewayResumeExecutionSource') {
            $body = $definition[0].Body.Extent.Text
            $script:resumeSourceFunction = [scriptblock]::Create($body.Substring(1, $body.Length - 2))
        }

    }
    $commands = $ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-GatewayStateStep' -and
        @($node.CommandElements | Where-Object { $_ -is [Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -ceq 'Purview capability prerequisites' }).Count -eq 1
    }, $true)
    $commands.Count | Should -Be 1
    for ($i = 0; $i -lt $commands[0].CommandElements.Count; $i++) {
        $element = $commands[0].CommandElements[$i]
        if ($element -is [Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -ceq 'Reconcile') {
            $body = $commands[0].CommandElements[$i + 1].ScriptBlock.Extent.Text
            $script:shippedReconcile = [scriptblock]::Create($body.Substring(1, $body.Length - 2))
        }
    }
}

Describe 'Shipped Purview recovery Resume composition' {
    BeforeEach {
        $script:Mode = 'Resume'
        $script:OutputFormat = 'Json'
        $script:activeAcceptedPlanFingerprint = 'sha256:' + ('c' * 64)
        $script:activeExecutionSourceFingerprint = 'sha256:' + ('b' * 64)
        $script:activeDeploymentSourceFingerprint = 'sha256:' + ('a' * 64)
        $script:executionSourceRoot = Join-Path $TestDrive 'corrected'
        $script:configuration = @{ purview = @{ enabled = $true }; projectName = 'safe'; environment = 'dev'; resourceGroupName = 'rg-safe'
            subscriptionId = '11111111-1111-4111-8111-111111111111'; tenantId = '22222222-2222-4222-8222-222222222222' }
        $script:state = [ordered]@{ deploymentOwnershipId = '33333333-3333-4333-8333-333333333333'
            acceptedPlan = @{ sourceFingerprint = $script:activeDeploymentSourceFingerprint }
            purviewPrerequisiteRecoveryPlan = @{}
            steps = [ordered]@{ 'Purview capability prerequisites' = [ordered]@{ status = 'Failed'; sourceFingerprint = $script:activeDeploymentSourceFingerprint } } }
        $script:statePath = Join-Path $TestDrive 'state.json'
        $script:stepNames = @(Get-GatewayBootstrapStepNames)
        $script:stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $script:azureIdentity = @{ userObjectId = '44444444-4444-4444-8444-444444444444' }
        $script:identity = @{}
        $script:inert = @{ keyVaultUri = 'https://kv-safe-dev.vault.azure.net/' }
        $script:workloadIdentity = @{}
        Mock Save-BootstrapState -ModuleName Common { }
        # Pester discovery reloads Common in other files. Use one isolated root
        # cell so the wrapper and Azure guard mocks observe the same state.
        $global:PurviewRecoveryResumeTestRoot = ''
        Mock Set-BootstrapExecutionSourceRoot { param($Path) $global:PurviewRecoveryResumeTestRoot = [IO.Path]::GetFullPath($Path) }
        Mock Get-BootstrapExecutionSourceRoot { $global:PurviewRecoveryResumeTestRoot }
        Mock Get-BootstrapExecutionSourceRoot -ModuleName Azure { $global:PurviewRecoveryResumeTestRoot }
        Mock Assert-BootstrapAcceptedPlan { Set-BootstrapExecutionSourceRoot -Path (Join-Path $TestDrive 'original') }
        Mock Assert-BootstrapAzureContext { $true }
        Mock Get-GatewayResumeExecutionSource { [ordered]@{ executionSourceRoot = $script:executionSourceRoot
                executionSourceFingerprint = $script:activeExecutionSourceFingerprint
                deploymentSourceFingerprint = $script:activeDeploymentSourceFingerprint } }
        Mock Ensure-BootstrapPurviewAutomationIdentity {
            if (-not $ReconcileOnly) { throw 'A prior stage must not be repeated' }
            @{ status = 'Installed' }
        }
        Mock Get-GatewayPurviewCapabilityEvidence { @{ status = 'Installed' } }
        Mock Get-GatewayBootstrapCapabilityEvidence { [ordered]@{ readbackAtUtc = '2026-09-06T00:00:00.0000000+00:00'; purview = @{ status = 'Installed' } } }
        Mock Get-BootstrapSourceFingerprint -ModuleName Azure {
            param($Root)
            if ($Root.EndsWith('corrected')) { 'sha256:' + ('b' * 64) } else { 'sha256:' + ('a' * 64) }
        }
        Mock Assert-GatewayRuntimeImagePullFoundationEvidence -ModuleName Azure { throw 'Stop after exact source guard, before provider work' }
        Mock Invoke-AzTsv -ModuleName Azure { throw 'Stop after exact source guard, before provider work' }
    }

    It 'runs the shipped read-only reconciliation through the real durable state machine' {
        $script:actionCalls = 0
        $result = Invoke-GatewayStateStep -Name 'Purview capability prerequisites' -Reconcile $script:shippedReconcile `
            -NoAutomaticReplayAfterStart -Action { $script:actionCalls++; throw 'Forbidden repeat' }
        $result.purview.status | Should -BeExactly 'Installed'
        $script:state.steps['Purview capability prerequisites'].status | Should -BeExactly 'Completed'
        $script:state.steps['Purview capability prerequisites'].sourceFingerprint | Should -BeExactly $script:activeDeploymentSourceFingerprint
        $script:actionCalls | Should -Be 0
        Should -Invoke Ensure-BootstrapPurviewAutomationIdentity -Times 1 -Exactly -ParameterFilter { $ReconcileOnly }
        Should -Invoke Save-BootstrapState -ModuleName Common -Times 1 -Exactly
    }

    It 'selects the corrected immutable source for the new reconciliation receipt' {
        $script:state = [ordered]@{
            deploymentOwnershipId = '33333333-3333-4333-8333-333333333333'
            acceptedPlan = @{ sourceFingerprint = $script:activeDeploymentSourceFingerprint }
            purviewPrerequisiteReconciliation = @{ plan = @{ correctedSourceFingerprint = $script:activeExecutionSourceFingerprint } }
            steps = [ordered]@{}
        }
        Mock Assert-BootstrapStateAllowsSourcePlan { }
        Mock Resolve-BootstrapAcceptedSourceRoot { Join-Path $TestDrive 'original' }
        Mock Get-BootstrapSourceFingerprint { $script:activeExecutionSourceFingerprint }
        Mock Get-BootstrapCompletedDatabaseValidationPlans { @{ databaseRecoveryPlan = $null; manualDatabaseRepairPlan = $null } }
        Mock Assert-BootstrapPurviewCompletePrerequisiteReconciliationPlan { Join-Path $TestDrive 'corrected' }
        Mock Get-BootstrapEffectiveDeploymentSourceFingerprint { $script:activeDeploymentSourceFingerprint }
        $result = & $script:resumeSourceFunction -State $script:state
        $result.executionSourceFingerprint | Should -BeExactly $script:activeExecutionSourceFingerprint
        $result.deploymentSourceFingerprint | Should -BeExactly $script:activeDeploymentSourceFingerprint
        $result.executionSourceRoot | Should -BeExactly (Join-Path $TestDrive 'corrected')
        Should -Invoke Assert-BootstrapPurviewCompletePrerequisiteReconciliationPlan -Times 1 -Exactly
    }

    It 'keeps failed readback unresolved without repeating the shipped stage action' {
        Mock Ensure-BootstrapPurviewAutomationIdentity { throw 'Synthetic readback failure' }
        $before = Get-BootstrapObjectFingerprint -InputObject $script:state.steps
        $script:actionCalls = 0
        { Invoke-GatewayStateStep -Name 'Purview capability prerequisites' -Reconcile $script:shippedReconcile `
            -NoAutomaticReplayAfterStart -Action { $script:actionCalls++ } } | Should -Throw
        $script:actionCalls | Should -Be 0
        (Get-BootstrapObjectFingerprint -InputObject $script:state.steps) | Should -BeExactly $before
    }

    It 'restores the corrected immutable root before the actual runtime deployment guard' {
        { Invoke-GatewayStateStep -Name 'Gateway runtime deployment' -Action {
            Deploy-GatewayCore -Config $script:configuration -Foundation @{} -Identity @{} -ApiImage 'safe-api' -WorkerImage 'safe-worker' `
                -WorkerPrincipalId '' -ManagerApplicationIds @() -DeploymentOwnershipId $script:state.deploymentOwnershipId `
                -SourceFingerprint $script:activeDeploymentSourceFingerprint -ExecutionSourceFingerprint $script:activeExecutionSourceFingerprint
        } } | Should -Throw
        Should -Invoke Assert-GatewayRuntimeImagePullFoundationEvidence -ModuleName Azure -Times 1 -Exactly
        Get-BootstrapExecutionSourceRoot | Should -BeExactly $script:executionSourceRoot
    }

    It 'restores the corrected immutable root before the actual Admin UI deployment guard' {
        { Invoke-GatewayStateStep -Name 'Admin UI deployment' -Action {
            Deploy-GatewayAdminUi -Config $script:configuration -Foundation @{} -Identity @{} -AdminIdentity @{} -AdminUiImage 'safe-admin' `
                -AdminUiSecretUri 'https://kv-safe-dev.vault.azure.net/secrets/admin-ui-client-secret' `
                -DeploymentOwnershipId $script:state.deploymentOwnershipId -SourceFingerprint $script:activeDeploymentSourceFingerprint `
                -ExecutionSourceFingerprint $script:activeExecutionSourceFingerprint
        } } | Should -Throw
        Should -Invoke Invoke-AzTsv -ModuleName Azure -Times 1 -Exactly
        Get-BootstrapExecutionSourceRoot | Should -BeExactly $script:executionSourceRoot
    }

    It 'preserves an exact retained database record on transient verification failure' {
        $script:state.steps['Gateway database'] = [ordered]@{ status = 'Completed'; evidence = @{ verified = $true }; sourceFingerprint = $script:activeDeploymentSourceFingerprint }
        $before = Get-BootstrapObjectFingerprint -InputObject $script:state.steps['Gateway database']
        $script:actionCalls = 0
        { Invoke-GatewayStateStep -Name 'Gateway database' -Validate { throw 'Synthetic transient readback failure' } -Action { $script:actionCalls++ } } | Should -Throw
        (Get-BootstrapObjectFingerprint -InputObject $script:state.steps['Gateway database']) | Should -BeExactly $before
        $script:actionCalls | Should -Be 0
        Should -Invoke Save-BootstrapState -ModuleName Common -Times 0
    }

    It 'rejects a late execution binding change before any stage callback' {
        Mock Get-GatewayResumeExecutionSource { @{ executionSourceRoot = $script:executionSourceRoot
                executionSourceFingerprint = 'sha256:' + ('d' * 64); deploymentSourceFingerprint = $script:activeDeploymentSourceFingerprint } }
        $script:actionCalls = 0
        { Invoke-GatewayStateStep -Name 'Gateway runtime deployment' -Action { $script:actionCalls++ } } | Should -Throw '*binding changed*'
        $script:actionCalls | Should -Be 0
        Should -Invoke Save-BootstrapState -ModuleName Common -Times 0
    }
}

}
