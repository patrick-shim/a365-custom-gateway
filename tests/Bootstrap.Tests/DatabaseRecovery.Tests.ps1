BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Import-Module (Join-Path $script:repoRoot 'bootstrap/modules/Common.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'bootstrap/modules/Azure.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'bootstrap/modules/Database.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'bootstrap/modules/Experience.psm1') -Force
}

Describe 'First-class database recovery contract' {
    It 'derives stable distinct intent identifiers without provider state' {
        $first = Get-BootstrapDeterministicGuid -Material 'owner|old|new|failed|image'
        $second = Get-BootstrapDeterministicGuid -Material 'owner|old|new|failed|image'
        $execution = Get-BootstrapDeterministicGuid -Material 'owner|old|new|failed|execution'

        $first | Should -BeExactly $second
        $first | Should -Match '^[0-9a-f-]{36}$'
        $first | Should -Not -BeExactly $execution
    }

    It 'requires ResumeAfterSchemaCompleted in the exact three evidence records' {
        $ownership = '11111111-1111-4111-8111-111111111111'
        $intent = '22222222-2222-4222-8222-222222222222'
        $source = 'sha256:' + ('a' * 64)
        $schema = 'sha256:' + ('b' * 64)
        $api = [ordered]@{ displayName = 'ca-gateway-api-dev'; clientId = '33333333-3333-4333-8333-333333333333' }
        $worker = [ordered]@{ displayName = 'ca-gateway-worker-dev-v3'; clientId = '44444444-4444-4444-8444-444444444444' }
        $initialize = [ordered]@{
            Phase = 'initialize'; Server = 'sql-demo-dev.database.windows.net'; Database = 'GatewayDb'; ExecutionIntentId = $intent
            Verification = [ordered]@{ CurrentEfModelReady = $true; WorkflowV2Ready = $true; CurrentSchemaFingerprint = $schema }
            InitializationIntent = [ordered]@{
                SchemaVersion = 1; MarkerName = 'A365GatewayBootstrapInitializationIntent'; Server = 'sql-demo-dev.database.windows.net'; Database = 'GatewayDb'
                DatabaseCollation = 'SQL_Latin1_General_CP1_CI_AS'; CatalogCollation = 'SQL_Latin1_General_CP1_CI_AS'
                DatabaseOwnerSidSha256 = 'sha256:' + ('c' * 64); DeploymentOwnershipId = $ownership
                AcceptedSourceFingerprint = $source; ExactReadbackVerified = $true; RecoveryMode = 'ResumeAfterSchemaCompleted'
            }
        }
        function New-PrincipalRecord($principal, $permissions) {
            [ordered]@{
                Phase = 'principal'; Server = 'sql-demo-dev.database.windows.net'; Database = 'GatewayDb'; ExecutionIntentId = $intent
                Verification = [ordered]@{ CurrentEfModelReady = $true; WorkflowV2Ready = $true; CurrentSchemaFingerprint = $schema }
                RuntimePrincipal = [ordered]@{ Name = $principal.displayName; ClientId = $principal.clientId; DatabaseRoles = @('db_datareader', 'db_datawriter'); DirectPermissions = $permissions }
            }
        }
        $records = @($initialize, (New-PrincipalRecord $api @('VIEW DEFINITION')), (New-PrincipalRecord $worker @()))

        $summary = Get-GatewayDatabaseEvidenceSummary -Records $records -SqlServerFqdn 'sql-demo-dev.database.windows.net' -DeploymentOwnershipId $ownership -AcceptedSourceFingerprint $source -ExecutionIntentId $intent -ApiPrincipal $api -WorkerPrincipal $worker -RequiredRecoveryMode 'ResumeAfterSchemaCompleted'
        $summary.initializationIntent.recoveryMode | Should -BeExactly 'ResumeAfterSchemaCompleted'

        $initialize.InitializationIntent.RecoveryMode = 'InitializeFreshDatabase'
        { Get-GatewayDatabaseEvidenceSummary -Records $records -SqlServerFqdn 'sql-demo-dev.database.windows.net' -DeploymentOwnershipId $ownership -AcceptedSourceFingerprint $source -ExecutionIntentId $intent -ApiPrincipal $api -WorkerPrincipal $worker -RequiredRecoveryMode 'ResumeAfterSchemaCompleted' } | Should -Throw '*exact authorized resume-after-schema mode*'
    }

    It 'will only start the deterministic recovery Job when Recovery is explicit' {
        InModuleScope Database {
            Mock Invoke-AzJson { [ordered]@{ name = 'job-demo-db-recover-dev-abcde' } }
            $config = [ordered]@{ projectName = 'demo'; environment = 'dev'; resourceGroupName = 'rg-demo' }

            { Start-GatewayDatabaseBootstrapExecution -Config $config -JobName 'job-demo-db-init-dev' -Recovery } | Should -Throw '*deterministic Job name*'
            $result = Start-GatewayDatabaseBootstrapExecution -Config $config -JobName 'job-demo-db-recover-dev' -Recovery
            $result.name | Should -BeExactly 'job-demo-db-recover-dev-abcde'
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                ($Arguments -join '|') -eq 'containerapp|job|start|--resource-group|rg-demo|--name|job-demo-db-recover-dev'
            }
        }
    }

    It 'derives a distinct second-attempt Job, receipt, evidence directory, and start target' {
        InModuleScope Database {
            $config = [ordered]@{ projectName = 'demo'; environment = 'dev'; resourceGroupName = 'rg-demo' }
            $first = Get-GatewayDatabaseRecoveryAttemptContract -Config $config -AttemptNumber 1
            $second = Get-GatewayDatabaseRecoveryAttemptContract -Config $config -AttemptNumber 2
            $first.jobName | Should -BeExactly 'job-demo-db-recover-dev'
            $second.jobName | Should -BeExactly 'job-demo-db-recov2-dev'
            $second.receiptFileName | Should -BeExactly 'private-database-bootstrap-recovery2-receipt.json'
            $second.evidenceDirectoryName | Should -BeExactly 'recovery2'
            Mock Invoke-AzJson { [ordered]@{ name = 'job-demo-db-recov2-dev-abcde' } }
            { Start-GatewayDatabaseBootstrapExecution -Config $config -JobName $first.jobName -Recovery -RecoveryAttemptNumber 2 } |
                Should -Throw '*deterministic Job name*'
            (Start-GatewayDatabaseBootstrapExecution -Config $config -JobName $second.jobName -Recovery -RecoveryAttemptNumber 2).name |
                Should -BeExactly 'job-demo-db-recov2-dev-abcde'

            $maximum = Get-GatewayDatabaseRecoveryAttemptContract `
                -Config ([ordered]@{ projectName = 'abcdefgh'; environment = 'staging'; resourceGroupName = 'rg-demo' }) `
                -AttemptNumber 2
            $maximum.jobName.Length | Should -BeLessThan 32
        }
    }

    It 'keeps recovery separate from the multi-image builder and original Job start' {
        $bootstrap = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/bootstrap.ps1') -Raw
        $common = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/modules/Common.psm1') -Raw
        $database = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/modules/Database.psm1') -Raw
        $azure = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/modules/Azure.psm1') -Raw

        $bootstrap | Should -Match "ValidateSet\([^\r\n]+RecoverDatabase"
        $bootstrap | Should -Match 'Build-GatewayDatabaseRecoveryImage'
        $common | Should -Match '\$jobStem = if \(\$AttemptNumber -eq 1\) \{ ''db-recover'' \} else \{ ''db-recov2'' \}'
        $common | Should -Match 'private-database-bootstrap-recovery\$suffix-receipt\.json'
        $azure | Should -Match 'function Build-GatewayDatabaseRecoveryImage'
        $azure | Should -Not -Match 'function Build-GatewayDatabaseRecoveryImage[\s\S]{0,4000}Build-GatewayImages\s'
    }

    It 'binds a recovery receipt to the exact accepted plan intent and never generates a recovery intent at execution time' {
        $database = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/modules/Database.psm1') -Raw
        $initializeStart = $database.IndexOf('function Initialize-GatewayDatabase', [StringComparison]::Ordinal)
        $initializeEnd = $database.IndexOf('function ', $initializeStart + 'function Initialize-GatewayDatabase'.Length, [StringComparison]::Ordinal)
        if ($initializeEnd -lt 0) { $initializeEnd = $database.Length }
        $initialize = $database.Substring($initializeStart, $initializeEnd - $initializeStart)

        $initialize | Should -Match 'executionIntentId\s*=\s*if \(\$isRecovery\) \{ \$recoveryExecutionIntentId \} else \{ \[guid\]::NewGuid\(\)\.ToString\(''D''\) \}'
        $initialize | Should -Not -Match 'executionIntentId\s*=\s*\[guid\]::NewGuid'
        $database | Should -Match 'function Assert-GatewayPrivateDatabaseRecoveryRecord[\s\S]+\[Parameter\(Mandatory\)\]\[string\]\$ExpectedExecutionIntentId'
        ([regex]::Matches($database, '-ExpectedExecutionIntentId \$recoveryExecutionIntentId')).Count | Should -Be 2
        $database | Should -Match '\[string\]\$Record\.executionIntentId -cne \$canonicalExpectedExecutionIntentId'
        $experience = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/modules/Experience.psm1') -Raw
        $experience | Should -Match '-ExpectedExecutionIntentId \(\[string\]\$DatabaseRecoveryPlan\.recoveryJob\.executionIntentId\)'
    }

    It 'adds the exact pre-mutation recovery classification gate only to recovery Job arguments' {
        InModuleScope Database {
            $common = @{
                SqlServerFqdn = 'sql-demo-dev.database.windows.net'
                ExpectedPrivateEndpointIpv4Address = '10.42.2.4'
                DeploymentOwnershipId = '11111111-1111-4111-8111-111111111111'
                SourceFingerprint = 'sha256:' + ('a' * 64)
                ApiPrincipal = [ordered]@{
                    displayName = 'ca-gateway-api-dev'
                    clientId = '22222222-2222-4222-8222-222222222222'
                }
                WorkerPrincipal = [ordered]@{
                    displayName = 'ca-gateway-worker-dev-v3'
                    clientId = '33333333-3333-4333-8333-333333333333'
                }
            }
            $normal = @(Get-GatewayDatabaseBootstrapJobArguments @common)
            $recovery = @(Get-GatewayDatabaseBootstrapJobArguments @common -Recovery)

            $normal | Should -Not -Contain '--required-recovery-mode'
            $recovery.Count | Should -Be ($normal.Count + 2)
            $modeIndex = [Array]::IndexOf($recovery, '--required-recovery-mode')
            $modeIndex | Should -BeGreaterThan -1
            $recovery[$modeIndex + 1] | Should -BeExactly 'ResumeAfterSchemaCompleted'
            @($recovery | Where-Object { $_ -ceq '--required-recovery-mode' }).Count | Should -Be 1
        }
    }

    It 'accepts existing in-scope resources only as Ignore beside the sole recovery Job Create' {
        InModuleScope Experience {
            $config = [ordered]@{
                subscriptionId = '11111111-1111-4111-8111-111111111111'
                resourceGroupName = 'rg-demo'
                projectName = 'demo'
                environment = 'dev'
                location = 'koreacentral'
            }
            $foundation = [ordered]@{
                containerAppsEnvironmentId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-demo/providers/Microsoft.App/managedEnvironments/cae-demo-dev-vnet'
                acrLoginServer = 'acrdemodev.azurecr.io'
                runtimeImagePullIdentityId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-demo/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-runtime-pull-dev'
            }
            $api = [ordered]@{ displayName = 'ca-gateway-api-dev'; clientId = '22222222-2222-4222-8222-222222222222' }
            $worker = [ordered]@{ displayName = 'ca-gateway-worker-dev-v3'; clientId = '33333333-3333-4333-8333-333333333333' }
            $jobId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-demo/providers/Microsoft.App/jobs/job-demo-db-recov2-dev'
            $existingId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-demo/providers/Microsoft.Sql/servers/sql-demo-dev'
            Mock Invoke-AzJson {
                [ordered]@{
                    status = 'Succeeded'
                    changes = @(
                        [ordered]@{ changeType = 'Ignore'; resourceId = $existingId }
                        [ordered]@{ changeType = 'Create'; resourceId = $jobId }
                    )
                }
            }

            $result = Invoke-GatewayDatabaseRecoveryWhatIf `
                -Config $config -Foundation $foundation -RepositoryRoot '/accepted/source' `
                -SqlServerFqdn 'sql-demo-dev.database.windows.net' `
                -ExpectedPrivateEndpointIpv4Address '10.42.2.4' `
                -DatabaseMigratorImageDigest ('sha256:' + ('a' * 64)) `
                -DeploymentOwnershipId '44444444-4444-4444-8444-444444444444' `
                -OriginalAcceptedSourceFingerprint ('sha256:' + ('b' * 64)) `
                -RecoverySourceFingerprint ('sha256:' + ('c' * 64)) `
                -RecoveryPlanFingerprint ('sha256:' + ('d' * 64)) `
                -RecoveryExecutionIntentId '55555555-5555-4555-8555-555555555555' `
                -OriginalFailedDatabaseBoundaryFingerprint ('sha256:' + ('e' * 64)) `
                -PriorFailedRecoveryBoundaryFingerprint ('sha256:' + ('f' * 64)) `
                -RecoveryAttemptNumber 2 `
                -ApiPrincipal $api -WorkerPrincipal $worker

            $result.applyReady | Should -BeTrue
            @($result.changes | Where-Object { $_.changeType -ceq 'Create' }).Count | Should -Be 1
            @($result.changes | Where-Object { $_.changeType -ceq 'Ignore' }).Count | Should -Be 1
            [string]@($result.changes | Where-Object { $_.changeType -ceq 'Create' })[0].resourceId | Should -Match 'db-recov2-dev$'
        }
    }

    It 'rejects any recovery What-If mutation other than the sole recovery Job Create' {
        InModuleScope Experience {
            $config = [ordered]@{
                subscriptionId = '11111111-1111-4111-8111-111111111111'; resourceGroupName = 'rg-demo'
                projectName = 'demo'; environment = 'dev'; location = 'koreacentral'
            }
            $foundation = [ordered]@{
                containerAppsEnvironmentId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-demo/providers/Microsoft.App/managedEnvironments/cae-demo-dev-vnet'
                acrLoginServer = 'acrdemodev.azurecr.io'
                runtimeImagePullIdentityId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-demo/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-runtime-pull-dev'
            }
            $api = [ordered]@{ displayName = 'ca-gateway-api-dev'; clientId = '22222222-2222-4222-8222-222222222222' }
            $worker = [ordered]@{ displayName = 'ca-gateway-worker-dev-v3'; clientId = '33333333-3333-4333-8333-333333333333' }
            Mock Invoke-AzJson {
                [ordered]@{
                    status = 'Succeeded'
                    changes = @(
                        [ordered]@{ changeType = 'Create'; resourceId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-demo/providers/Microsoft.App/jobs/job-demo-db-recover-dev' }
                        [ordered]@{ changeType = 'Modify'; resourceId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-demo/providers/Microsoft.Sql/servers/sql-demo-dev' }
                    )
                }
            }

            { Invoke-GatewayDatabaseRecoveryWhatIf `
                    -Config $config -Foundation $foundation -RepositoryRoot '/accepted/source' `
                    -SqlServerFqdn 'sql-demo-dev.database.windows.net' -ExpectedPrivateEndpointIpv4Address '10.42.2.4' `
                    -DatabaseMigratorImageDigest ('sha256:' + ('a' * 64)) `
                    -DeploymentOwnershipId '44444444-4444-4444-8444-444444444444' `
                    -OriginalAcceptedSourceFingerprint ('sha256:' + ('b' * 64)) `
                    -RecoverySourceFingerprint ('sha256:' + ('c' * 64)) -RecoveryPlanFingerprint ('sha256:' + ('d' * 64)) `
                    -RecoveryExecutionIntentId '55555555-5555-4555-8555-555555555555' `
                    -OriginalFailedDatabaseBoundaryFingerprint ('sha256:' + ('e' * 64)) -ApiPrincipal $api -WorkerPrincipal $worker } |
                Should -Throw '*every existing resource may appear only as an in-scope Ignore*'
        }
    }

    It 'expires only an unstarted accepted plan and keeps a running exact-intent plan resumable' {
        InModuleScope Common {
            $configurationFingerprint = 'sha256:' + ('1' * 64)
            $originalSourceFingerprint = 'sha256:' + ('2' * 64)
            $correctedSourceFingerprint = 'sha256:' + ('3' * 64)
            $originalPlanFingerprint = 'sha256:' + ('4' * 64)
            $recoveryPlanFingerprint = 'sha256:' + ('5' * 64)
            $executionSource = '.bootstrap/accepted-source/11111111-1111-4111-8111-111111111111/original'
            $state = [ordered]@{
                configurationFingerprint = $configurationFingerprint
                deploymentOwnershipId = '11111111-1111-4111-8111-111111111111'
                acceptedPlan = [ordered]@{
                    sourceFingerprint = $originalSourceFingerprint
                    planFingerprint = $originalPlanFingerprint
                    executionSource = $executionSource
                }
                databaseRecoveryPlan = [ordered]@{
                    planFingerprint = $recoveryPlanFingerprint
                    configurationFingerprint = $configurationFingerprint
                    deploymentOwnershipId = '11111111-1111-4111-8111-111111111111'
                    originalSourceFingerprint = $originalSourceFingerprint
                    correctedSourceFingerprint = $correctedSourceFingerprint
                    originalAcceptedPlan = [ordered]@{
                        sourceFingerprint = $originalSourceFingerprint
                        planFingerprint = $originalPlanFingerprint
                        executionSource = $executionSource
                    }
                    recoveryJob = [ordered]@{
                        recoveryMode = 'ResumeAfterSchemaCompleted'
                        replicaRetryLimit = 0
                        maximumExecutions = 1
                    }
                    status = 'Running'
                    acceptedAtUtc = [DateTimeOffset]::UtcNow.AddDays(-7).ToString('O')
                }
            }
            Mock Get-BootstrapSourceFingerprint { $correctedSourceFingerprint }
            Mock Resolve-BootstrapDatabaseRecoverySourceRoot { '/accepted/recovery/source' }

            Assert-BootstrapAcceptedDatabaseRecoveryPlan `
                -State $state -PlanFingerprint $recoveryPlanFingerprint -MaximumAge ([TimeSpan]::FromMinutes(1)) |
                Should -BeTrue

            $state.databaseRecoveryPlan.status = 'Accepted'
            { Assert-BootstrapAcceptedDatabaseRecoveryPlan `
                    -State $state -PlanFingerprint $recoveryPlanFingerprint -MaximumAge ([TimeSpan]::FromMinutes(1)) } |
                Should -Throw '*outside its 60-minute validity window*'
        }
    }

    It 'accepts exactly one immutable failed-attempt history record before attempt two' {
        InModuleScope Common {
            $owner = '11111111-1111-4111-8111-111111111111'
            $original = 'sha256:' + ('1' * 64)
            $firstSource = 'sha256:' + ('2' * 64)
            $secondSource = 'sha256:' + ('3' * 64)
            $configFingerprint = 'sha256:' + ('4' * 64)
            $originalPlanFingerprint = 'sha256:' + ('5' * 64)
            $firstPlanFingerprint = 'sha256:' + ('6' * 64)
            $secondPlanFingerprint = 'sha256:' + ('7' * 64)
            $failedBoundaryFingerprint = 'sha256:' + ('8' * 64)
            $priorPlan = [ordered]@{
                schemaVersion = 1; planFingerprint = $firstPlanFingerprint; configurationFingerprint = $configFingerprint
                deploymentOwnershipId = $owner; originalSourceFingerprint = $original; correctedSourceFingerprint = $firstSource
                originalAcceptedPlan = [ordered]@{ sourceFingerprint = $original; planFingerprint = $originalPlanFingerprint; executionSource = '.bootstrap/original' }
                failedJob = [ordered]@{ boundaryFingerprint = 'sha256:' + ('9' * 64) }
                correctedImage = [ordered]@{ image = 'acr.example/gateway-db-migrator@sha256:' + ('a' * 64) }
                recoveryJob = [ordered]@{ name = 'job-demo-db-recover-dev'; executionIntentId = '22222222-2222-4222-8222-222222222222'; recoveryMode = 'ResumeAfterSchemaCompleted'; replicaRetryLimit = 0; maximumExecutions = 1 }
                whatIf = [ordered]@{ applyReady = $true }
                status = 'Running'; executionSource = '.bootstrap/first'; acceptedAtUtc = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('O')
                databaseEvidenceFingerprint = ''; completedAtUtc = ''
            }
            $failed = [ordered]@{
                boundaryFingerprint = $failedBoundaryFingerprint; recoveryPlanFingerprint = $firstPlanFingerprint
                recoverySourceFingerprint = $firstSource; jobName = 'job-demo-db-recover-dev'; executionName = 'job-demo-db-recover-dev-abcde'
                executionIntentId = '22222222-2222-4222-8222-222222222222'
            }
            $state = [ordered]@{
                configurationFingerprint = $configFingerprint; deploymentOwnershipId = $owner
                acceptedPlan = [ordered]@{ sourceFingerprint = $original; planFingerprint = $originalPlanFingerprint; executionSource = '.bootstrap/original' }
                databaseRecoveryPlan = $priorPlan
            }
            $secondPlan = [ordered]@{
                schemaVersion = 2; attemptNumber = 2; planFingerprint = $secondPlanFingerprint; configurationFingerprint = $configFingerprint
                deploymentOwnershipId = $owner; originalSourceFingerprint = $original; correctedSourceFingerprint = $secondSource
                originalAcceptedPlan = $state.acceptedPlan; failedJob = $priorPlan.failedJob
                previousRecoveryPlanFingerprint = $firstPlanFingerprint; previousRecoveryPlan = $priorPlan; priorFailedRecovery = $failed
                correctedImage = [ordered]@{ state = 'Planned' }; recoveryJob = [ordered]@{ name = 'job-demo-db-recov2-dev' }
                whatIf = [ordered]@{ applyReady = $true }
            }
            Mock Get-BootstrapSourceFingerprint { $secondSource }
            Mock Resolve-BootstrapDatabaseRecoveryPlanSourceRoot { '/snapshot' }
            Mock New-BootstrapAcceptedSourceSnapshot { '.bootstrap/second' }
            Mock Save-BootstrapState { }

            $accepted = Set-BootstrapAcceptedDatabaseRecoveryContinuationPlan -State $state -StatePath '/state.json' -Plan $secondPlan -FailedRecovery $failed
            $accepted.status | Should -BeExactly 'Accepted'
            $accepted.attemptNumber | Should -Be 2
            @($state.databaseRecoveryHistory).Count | Should -Be 1
            $state.databaseRecoveryHistory[0].status | Should -BeExactly 'Failed'
            Assert-BootstrapDatabaseRecoveryHistory -State $state -CurrentPlan $accepted | Should -BeTrue

            $state.databaseRecoveryHistory[0].failedRecovery.executionName = 'tampered'
            { Assert-BootstrapDatabaseRecoveryHistory -State $state -CurrentPlan $accepted } | Should -Throw '*history*changed*'
        }
    }

    It 'hard-caps recovery plan attempts at two' {
        InModuleScope Common {
            { Get-BootstrapDatabaseRecoveryAttemptNumber -Plan ([ordered]@{ attemptNumber = 3 }) } |
                Should -Throw '*capped at exactly two*'
        }
    }

    It 'keeps a running first attempt resumable until an exact failed receipt is present' {
        InModuleScope Common {
            (Test-BootstrapDatabaseRecoveryFailureReceiptCandidate -Receipt $null) | Should -BeFalse
            (Test-BootstrapDatabaseRecoveryFailureReceiptCandidate -Receipt ([ordered]@{
                jobStartIntentAtUtc = ''; executionName = ''; administratorRestoredAtUtc = ''
                executionSucceededAtUtc = ''; evidenceFingerprint = ''; evidenceRecoveredAtUtc = ''; completedAtUtc = ''
            })) | Should -BeFalse
            (Test-BootstrapDatabaseRecoveryFailureReceiptCandidate -Receipt ([ordered]@{
                jobStartIntentAtUtc = '2026-08-30T21:19:45.0000000+00:00'
                executionName = 'job-demo-db-recover-dev-abcde'
                administratorRestoredAtUtc = '2026-08-30T21:21:11.5729500+00:00'
                executionSucceededAtUtc = ''; evidenceFingerprint = ''; evidenceRecoveredAtUtc = ''; completedAtUtc = ''
            })) | Should -BeTrue
        }

        $bootstrap = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/bootstrap.ps1') -Raw
        $bootstrap | Should -Match '\$currentRecoveryAttempt -eq 1 -and \$null -ne \$attemptOneFailedRecovery'
        $bootstrap | Should -Not -Match 'elseif \(\$currentRecoveryAttempt -eq 1 -and \[string\]\$state\.databaseRecoveryPlan\.status -ceq ''Running''\) \{\s*Get-GatewayDatabaseRecoveryPlan'
    }

    It 'permanently blocks standard plan and apply paths after completed database recovery' {
        InModuleScope Common {
            $state = [ordered]@{
                databaseRecoveryPlan = [ordered]@{ status = 'Completed' }
                steps = [ordered]@{}
            }
            $steps = @('Admin UI identity', 'Gateway runtime deployment')
            (Test-BootstrapDatabaseRecoveryRequiresNarrowContinuation -State $state -ContinuationStepNames $steps) |
                Should -BeTrue
            foreach ($name in $steps) { $state.steps[$name] = [ordered]@{ status = 'Completed' } }
            (Test-BootstrapDatabaseRecoveryRequiresNarrowContinuation -State $state -ContinuationStepNames $steps) |
                Should -BeTrue

            $state.databaseRecoveryPlan.status = 'Running'
            (Test-BootstrapDatabaseRecoveryRequiresNarrowContinuation -State $state -ContinuationStepNames $steps) |
                Should -BeFalse
        }

        $bootstrap = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/bootstrap.ps1') -Raw
        $guard = $bootstrap.IndexOf('Test-BootstrapDatabaseRecoveryRequiresNarrowContinuation', [StringComparison]::Ordinal)
        $guardBlockStart = $bootstrap.LastIndexOf("if (`$Mode -in @('Plan', 'Apply', 'Up', 'Resume')", $guard, [StringComparison]::Ordinal)
        $normalPlan = $bootstrap.IndexOf("if (`$Mode -in @('Plan', 'Up', 'Resume')) {", $guard + 1, [StringComparison]::Ordinal)
        $guard | Should -BeGreaterOrEqual 0
        $guardBlockStart | Should -BeGreaterOrEqual 0
        $normalPlan | Should -BeGreaterThan $guard
        $bootstrap.Substring($guardBlockStart, $guard - $guardBlockStart) | Should -Match "'Apply'"
        $bootstrap | Should -Match 'Run gateway continue-bootstrap to execute only the remaining deployment steps'
    }

    It 'preserves an absent provider end time in the failed recovery boundary' {
        InModuleScope Database {
            $tenantId = '11111111-1111-4111-8111-111111111111'
            $subscriptionId = '22222222-2222-4222-8222-222222222222'
            $ownershipId = '33333333-3333-4333-8333-333333333333'
            $administratorId = '44444444-4444-4444-8444-444444444444'
            $executionIntentId = '55555555-5555-4555-8555-555555555555'
            $source = 'sha256:' + ('a' * 64)
            $recoverySource = 'sha256:' + ('b' * 64)
            $planFingerprint = 'sha256:' + ('c' * 64)
            $failedBoundary = 'sha256:' + ('d' * 64)
            $image = 'acrdemodev.azurecr.io/gateway-db-migrator@sha256:' + ('e' * 64)
            $start = '2026-08-30T21:19:49.0000000+00:00'
            $restored = '2026-08-30T21:21:11.5729500+00:00'
            $config = [ordered]@{
                subscriptionId = $subscriptionId; tenantId = $tenantId; resourceGroupName = 'rg-demo'
                projectName = 'demo'; environment = 'dev'
            }
            $api = [ordered]@{ displayName = 'ca-gateway-api-dev'; clientId = '66666666-6666-4666-8666-666666666666' }
            $worker = [ordered]@{ displayName = 'ca-gateway-worker-dev-v3'; clientId = '77777777-7777-4777-8777-777777777777' }
            $plan = [ordered]@{
                deploymentOwnershipId = $ownershipId
                originalSourceFingerprint = $source
                correctedSourceFingerprint = $recoverySource
                planFingerprint = $planFingerprint
                failedJob = [ordered]@{ boundaryFingerprint = $failedBoundary }
                correctedImage = [ordered]@{ image = $image }
                recoveryJob = [ordered]@{ executionIntentId = $executionIntentId }
            }
            $receipt = [ordered]@{
                jobStartIntentAtUtc = '2026-08-30T21:19:45.0000000+00:00'
                executionName = 'job-demo-db-recover-dev-abcde'
                administratorRestoredAtUtc = $restored
                executionSucceededAtUtc = ''; evidenceFingerprint = ''; evidenceRecoveredAtUtc = ''; completedAtUtc = ''
                executionStartedAtUtc = $start; jobPrincipalId = '88888888-8888-4888-8888-888888888888'
                executionIntentId = $executionIntentId
            }
            $arguments = @(Get-GatewayDatabaseBootstrapJobArguments `
                -SqlServerFqdn 'sql-demo-dev.database.windows.net' `
                -ExpectedPrivateEndpointIpv4Address '10.42.2.4' `
                -DeploymentOwnershipId $ownershipId -SourceFingerprint $source `
                -ApiPrincipal $api -WorkerPrincipal $worker -Recovery)
            $container = [pscustomobject]@{
                name = 'database-recovery'; image = $image
                command = @('dotnet', 'Gateway.DatabaseMigrator.dll'); args = $arguments
                env = @([pscustomobject]@{ name = 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID'; value = $executionIntentId })
                volumeMounts = @(); probes = @(); resources = [pscustomobject]@{ cpu = 0.5; memory = '1Gi' }
            }
            $execution = [pscustomobject]@{
                name = $receipt.executionName
                properties = [pscustomobject]@{
                    status = 'Failed'; startTime = $start; endTime = $null
                    template = [pscustomobject]@{ containers = @($container); initContainers = @(); volumes = @() }
                }
            }

            Mock Get-RepositoryRoot { $TestDrive }
            Mock Read-GatewayPrivateDatabaseBootstrapRecord { $receipt }
            Mock Assert-GatewayPrivateDatabaseRecoveryRecord { $true }
            Mock Get-GatewayDatabaseBootstrapJobEvidence {
                [ordered]@{ jobId = '/subscriptions/test/jobs/recovery'; jobName = 'job-demo-db-recover-dev'; jobPrincipalId = $receipt.jobPrincipalId }
            }
            Mock Get-GatewayDatabaseBootstrapExecutions {
                @([pscustomobject]@{ name = $receipt.executionName; status = 'Failed'; startTime = $start; endTime = $null })
            }
            Mock Invoke-AzJson { $execution }
            Mock Get-GatewaySqlEntraAdministrator {
                [ordered]@{ objectId = $administratorId; login = 'admin@example.test'; tenantId = $tenantId }
            }

            $parameters = @{
                Config = $config; Foundation = [ordered]@{}; SqlPrivateEndpoint = [ordered]@{ privateEndpointIpv4Address = '10.42.2.4' }
                SqlServerFqdn = 'sql-demo-dev.database.windows.net'; RecoveryPlan = $plan
                ApiPrincipal = $api; WorkerPrincipal = $worker
                OriginalAdministratorObjectId = $administratorId; OriginalAdministratorLogin = 'admin@example.test'
            }
            $boundary = Get-GatewayFailedDatabaseRecoveryBoundary @parameters
            $boundary.executionEndTimePresent | Should -BeFalse
            $boundary.executionFailedAtUtc | Should -BeExactly ''
            $boundary.administratorRestoredAtUtc | Should -BeExactly $restored

            $container.probes = @([pscustomobject]@{ type = 'Liveness' })
            { Get-GatewayFailedDatabaseRecoveryBoundary @parameters } |
                Should -Throw '*exact immutable image, arguments, or managed-identity intent*'
        }
    }
}
