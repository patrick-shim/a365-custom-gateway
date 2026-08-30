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

    It 'keeps recovery separate from the multi-image builder and original Job start' {
        $bootstrap = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/bootstrap.ps1') -Raw
        $database = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/modules/Database.psm1') -Raw
        $azure = Get-Content -LiteralPath (Join-Path $script:repoRoot 'bootstrap/modules/Azure.psm1') -Raw

        $bootstrap | Should -Match "ValidateSet\([^\r\n]+RecoverDatabase"
        $bootstrap | Should -Match 'Build-GatewayDatabaseRecoveryImage'
        $database | Should -Match 'private-database-bootstrap-recovery-receipt\.json'
        $database | Should -Match 'job-\$\(\$Config\.projectName\)-db-recover-\$\(\$Config\.environment\)'
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
            $jobId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-demo/providers/Microsoft.App/jobs/job-demo-db-recover-dev'
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
                -ApiPrincipal $api -WorkerPrincipal $worker

            $result.applyReady | Should -BeTrue
            @($result.changes | Where-Object { $_.changeType -ceq 'Create' }).Count | Should -Be 1
            @($result.changes | Where-Object { $_.changeType -ceq 'Ignore' }).Count | Should -Be 1
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
                    -RecoveryExecutionIntentId '55555555-5555-4555-8555-555555555555' -ApiPrincipal $api -WorkerPrincipal $worker } |
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
}
