BeforeAll {
    $script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    foreach ($module in @('Common', 'Experience', 'Prerequisites', 'Azure', 'Entra', 'Agent365', 'Database', 'Purview', 'Verification')) {
        Import-Module (Join-Path $script:repoRoot "bootstrap/modules/$module.psm1") -Force -DisableNameChecking
    }
    $tokens = $null
    $errors = $null
    $script:ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $script:repoRoot 'bootstrap/bootstrap.ps1'), [ref]$tokens, [ref]$errors)
    $errors.Count | Should -Be 0
    foreach ($name in @('Get-GatewayResumeExecutionSource', 'Invoke-GatewayResumePreflight')) {
        $definition = $script:ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $true)
        if ($definition.Count -eq 1) { . ([scriptblock]::Create($definition[0].Extent.Text)) }
    }
    $postResume = $script:ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -ceq '$Mode -eq ''Resume''' -and
            $node.Clauses[0].Item2.Extent.Text.Contains('$activeAcceptedPlanFingerprint = $recordedPlanFingerprint')
    }, $true)
    $postResume.Count | Should -Be 1
    $script:postResumeSource = $postResume[0].Clauses[0].Item2.Statements.Extent.Text -join [Environment]::NewLine
}

Describe 'Resume after completed database recovery' {
    BeforeEach {
        $script:original = 'sha256:' + ('a' * 64)
        $script:corrected = 'sha256:' + ('b' * 64)
        $script:current = $script:corrected
        $script:owner = '11111111-1111-4111-8111-111111111111'
        $script:config = [ordered]@{
            tenantId = '22222222-2222-4222-8222-222222222222'
            subscriptionId = '33333333-3333-4333-8333-333333333333'
        }
        $script:configHash = Get-BootstrapConfigurationFingerprint -Config $script:config
        $accepted = [ordered]@{
            planFingerprint = 'sha256:' + ('c' * 64)
            sourceFingerprint = $script:original
            configurationFingerprint = $script:configHash
            executionSource = 'original-snapshot'
        }
        $script:state = [ordered]@{
            deploymentOwnershipId = $script:owner
            configurationFingerprint = $script:configHash
            acceptedPlan = $accepted
            source = [ordered]@{ lastWritten = @{ bootstrapSourceFingerprint = $script:original } }
            steps = [ordered]@{}
            databaseRecoveryPlan = [ordered]@{
                schemaVersion = 1
                status = 'Completed'
                planFingerprint = 'sha256:' + ('d' * 64)
                configurationFingerprint = $script:configHash
                deploymentOwnershipId = $script:owner
                originalSourceFingerprint = $script:original
                correctedSourceFingerprint = $script:corrected
                originalAcceptedPlan = ConvertTo-BootstrapCanonicalValue -Value $accepted
                executionSource = 'recovery-snapshot'
                recoveryJob = @{ recoveryMode = 'ResumeAfterSchemaCompleted'; replicaRetryLimit = 0; maximumExecutions = 1 }
            }
        }
        foreach ($name in @(Get-GatewayBootstrapStepNames)[0..10]) {
            $script:state.steps[$name] = [ordered]@{
                status = 'Completed'; sourceFingerprint = $script:original; evidence = [ordered]@{ verified = $true }
            }
        }
        $script:actor = '44444444-4444-4444-8444-444444444444'
        $script:state.steps['Azure authentication'].evidence = @{
            tenantId = $script:config.tenantId; subscriptionId = $script:config.subscriptionId; userObjectId = $script:actor
        }
        $script:state.steps['Immutable workload images'].evidence = @{
            api = 'registry/api@sha256:original'; worker = 'registry/worker@sha256:original'
            databaseMigrator = 'registry/migrator@sha256:original'
        }
        $script:state.steps['Inert identity deployment'].evidence = @{
            workerPrincipalId = '55555555-5555-4555-8555-555555555555'
            sqlServerFqdn = 'sql-demo-dev.database.windows.net'
        }
        $script:state.steps['Gateway database'].sourceFingerprint = $script:corrected
        $script:state.steps['Gateway database'].evidence = [ordered]@{
            databaseRecoveryPlanFingerprint = $script:state.databaseRecoveryPlan.planFingerprint
            acceptedSourceFingerprint = $script:original
            recoverySourceFingerprint = $script:corrected
            deploymentOwnershipId = $script:owner
        }
        $script:state.databaseRecoveryPlan.databaseEvidenceFingerprint =
            Get-BootstrapObjectFingerprint -InputObject $script:state.steps['Gateway database'].evidence
        $script:originalRoot = Join-Path $TestDrive 'original'
        $script:recoveryRoot = Join-Path $TestDrive 'recovery'
        Mock Get-BootstrapSourceFingerprint { $script:current }
        Mock Get-BootstrapSourceFingerprint -ModuleName Common { $script:current }
        Mock Resolve-BootstrapAcceptedSourceRoot { $script:originalRoot }
        Mock Resolve-BootstrapDatabaseRecoverySourceRoot { $script:recoveryRoot }
        Mock Resolve-BootstrapDatabaseRecoverySourceRoot -ModuleName Common { $script:recoveryRoot }
        Mock Assert-BootstrapAcceptedPlan {
            if ($SourceFingerprint -cne $script:original -or $ConfigurationFingerprint -cne $script:configHash) {
                throw 'Original authorization changed.'
            }
            return $true
        }
        Mock Import-Module {}
        Mock Set-BootstrapExecutionSourceRoot {}
        Mock Write-GatewayExperienceEvent {}
        Mock Assert-BootstrapPrerequisites {}
        Mock Connect-BootstrapAzure { @{ userObjectId = $script:actor } }
        foreach ($validator in @('Test-GatewayResourceProviderEvidence', 'Test-GatewaySubscriptionDeploymentEvidence',
            'Test-GatewayApplicationEvidence', 'Test-GatewayImmutableImageEvidence', 'Test-GatewayGroupDeploymentEvidence',
            'Test-GatewayBlueprintEvidence', 'Test-GatewayWorkflowIdentityEvidence', 'Test-GatewaySqlPrivateEndpointEvidence',
            'Test-GatewayDatabaseEvidence')) {
            Mock $validator { $true }
        }
        function Invoke-TestResume {
            Invoke-GatewayResumePreflight -Configuration $script:config -State $script:state -Format Json `
                -InstallLocalPrerequisites:$false -NonInteractive
        }
        function Invoke-TestAuthorizedResume($Review) {
            Invoke-GatewayResumePreflight -Configuration $script:config -State $script:state -Format Json `
                -InstallLocalPrerequisites:$false -NonInteractive -ExplicitlyAuthorized `
                -ExpectedAcceptedPlanFingerprint $Review.acceptedPlanFingerprint `
                -ExpectedResumeAuthorizationFingerprint $Review.resumeAuthorizationFingerprint
        }
        function Invoke-TestPostResume($Preflight) {
            $resumePreflight = $Preflight
            $state = $script:state
            $configuration = $script:config
            . ([scriptblock]::Create($script:postResumeSource))
            return @{
                accepted = $activeAcceptedSourceFingerprint
                execution = $activeExecutionSourceFingerprint
                deployment = $activeDeploymentSourceFingerprint
            }
        }
    }

    It 'revalidates the recovered database and reviews step twelve without replacing original authority or images' {
        $before = Get-BootstrapObjectFingerprint -InputObject $script:state
        $result = Invoke-TestResume
        $result.reviewOnly | Should -BeTrue
        $result.checkpoint.currentStep | Should -BeExactly 'Admin UI identity'
        $result.acceptedSourceFingerprint | Should -BeExactly $script:original
        $result.executionSourceFingerprint | Should -BeExactly $script:corrected
        $result.deploymentSourceFingerprint | Should -BeExactly $script:original
        $result.executionSourceRoot | Should -BeExactly $script:recoveryRoot
        (Get-BootstrapObjectFingerprint -InputObject $script:state) | Should -BeExactly $before
        Should -Invoke Test-GatewayDatabaseEvidence -Times 1 -Exactly -ParameterFilter {
            $SourceFingerprint -ceq $script:original -and $DatabaseRecoveryPlan.status -ceq 'Completed'
        }
    }

    It 'retains the original source path when there is no recovery' {
        $script:current = $script:original
        $script:state.Remove('databaseRecoveryPlan')
        $script:state.steps.Remove('Gateway database')
        $result = Invoke-TestResume
        $result.executionSourceFingerprint | Should -BeExactly $script:original
        $result.executionSourceRoot | Should -BeExactly $script:originalRoot
        $result.checkpoint.currentStep | Should -BeExactly 'Gateway database'
    }

    It 'rejects a changed source without a completed recovery: <Status>' -ForEach @(
        @{ Status = 'Absent' }, @{ Status = 'Accepted' }, @{ Status = 'Running' }, @{ Status = 'Failed' }
    ) {
        if ($Status -ceq 'Absent') { $script:state.Remove('databaseRecoveryPlan') }
        else { $script:state.databaseRecoveryPlan.status = $Status }
        { Invoke-TestResume } | Should -Throw '*RP00_ACCEPTED_AUTHORIZATION*'
        Should -Invoke Connect-BootstrapAzure -Times 0 -Exactly
    }

    It 'rejects completed recovery drift before provider work: <Boundary>' -ForEach @(
        @{ Boundary = 'source' }, @{ Boundary = 'configuration' }, @{ Boundary = 'ownership' },
        @{ Boundary = 'evidence' }, @{ Boundary = 'snapshot' }, @{ Boundary = 'originalPlan' },
        @{ Boundary = 'databaseStepSource' }
    ) {
        switch ($Boundary) {
            source { $script:current = 'sha256:' + ('e' * 64) }
            configuration { $script:state.databaseRecoveryPlan.configurationFingerprint = 'sha256:' + ('e' * 64) }
            ownership { $script:state.databaseRecoveryPlan.deploymentOwnershipId = '66666666-6666-4666-8666-666666666666' }
            evidence { $script:state.steps['Gateway database'].evidence.recoverySourceFingerprint = 'sha256:' + ('e' * 64) }
            snapshot { Mock Resolve-BootstrapDatabaseRecoverySourceRoot -ModuleName Common { throw 'Snapshot changed.' } }
            originalPlan { $script:state.databaseRecoveryPlan.originalAcceptedPlan['unexpected'] = 'changed' }
            databaseStepSource { $script:state.steps['Gateway database'].sourceFingerprint = $script:original }
        }
        { Invoke-TestResume } | Should -Throw '*RP00_ACCEPTED_AUTHORIZATION*'
        Should -Invoke Connect-BootstrapAzure -Times 0 -Exactly
    }

    It 'carries separate execution and deployment sources through confirmation and the final mutation guard' {
        $review = Invoke-TestResume
        $authorized = Invoke-TestAuthorizedResume $review
        $authorized.explicitlyAuthorized | Should -BeTrue
        $guard = Invoke-TestPostResume $authorized
        $guard.accepted | Should -BeExactly $script:original
        $guard.execution | Should -BeExactly $script:corrected
        $guard.deployment | Should -BeExactly $script:original
    }

    It 'rejects execution source changes after an authorized review' {
        $authorized = Invoke-TestAuthorizedResume (Invoke-TestResume)
        $script:current = 'sha256:' + ('e' * 64)
        { Invoke-TestPostResume $authorized } | Should -Throw
    }

    It 'rejects snapshot or evidence changes between review and execution: <Boundary>' -ForEach @(
        @{ Boundary = 'snapshot' }, @{ Boundary = 'evidence' }
    ) {
        $authorized = Invoke-TestAuthorizedResume (Invoke-TestResume)
        if ($Boundary -ceq 'snapshot') {
            Mock Resolve-BootstrapDatabaseRecoverySourceRoot -ModuleName Common { throw 'Snapshot changed.' }
        }
        else { $script:state.steps['Gateway database'].evidence['unexpected'] = 'changed' }
        { Invoke-TestPostResume $authorized } | Should -Throw
    }
}
