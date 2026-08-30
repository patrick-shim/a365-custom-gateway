$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Database.psm1') -Force

Describe 'Private database bootstrap recovery and evidence contract' {
    InModuleScope Database {
        BeforeEach {
            $script:config = [pscustomobject]@{
                subscriptionId = '11111111-1111-4111-8111-111111111111'
                tenantId = '22222222-2222-4222-8222-222222222222'
                resourceGroupName = 'rg-gateway-dev'
                location = 'koreacentral'
                environment = 'dev'
                projectName = 'gateway'
            }
            $script:sqlServerFqdn = 'sql-gateway-dev.database.windows.net'
            $script:jobName = 'job-gateway-db-init-dev'
            $script:jobImage = "gatewayacr.azurecr.io/gateway-db-migrator@sha256:$('a' * 64)"
            $script:ownershipId = '33333333-3333-4333-8333-333333333333'
            $script:sourceFingerprint = "sha256:$('b' * 64)"
            $script:executionIntentId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            $script:originalAdministratorObjectId = '44444444-4444-4444-8444-444444444444'
            $script:originalAdministratorLogin = 'bootstrap-administrator'
            $script:jobPrincipalId = '55555555-5555-4555-8555-555555555555'
            $script:apiPrincipalId = '66666666-6666-4666-8666-666666666666'
            $script:workerPrincipalId = '77777777-7777-4777-8777-777777777777'
            $script:api = [pscustomobject]@{
                objectId = $script:apiPrincipalId
                clientId = '88888888-8888-4888-8888-888888888888'
                displayName = 'ca-gateway-api-dev'
            }
            $script:worker = [pscustomobject]@{
                objectId = $script:workerPrincipalId
                clientId = '99999999-9999-4999-8999-999999999999'
                displayName = 'ca-gateway-worker-dev-v3'
            }
            $script:receipt = [ordered]@{
                schemaVersion = 1
                subscriptionId = $script:config.subscriptionId
                tenantId = $script:config.tenantId
                resourceGroupName = $script:config.resourceGroupName
                server = $script:sqlServerFqdn
                database = 'GatewayDb'
                deploymentOwnershipId = $script:ownershipId
                acceptedSourceFingerprint = $script:sourceFingerprint
                jobDeploymentName = 'a365gw-gateway-bootstrap-database-job-dev'
                jobName = $script:jobName
                jobImage = $script:jobImage
                originalAdministratorObjectId = $script:originalAdministratorObjectId
                originalAdministratorLogin = $script:originalAdministratorLogin
                jobPrincipalId = $script:jobPrincipalId
                executionIntentId = $script:executionIntentId
                deploymentIntentAtUtc = '2026-08-30T00:00:00.0000000+00:00'
                deploymentVerifiedAtUtc = '2026-08-30T00:01:00.0000000+00:00'
                administratorSwapIntentAtUtc = '2026-08-30T00:02:00.0000000+00:00'
                administratorSwappedAtUtc = '2026-08-30T00:03:00.0000000+00:00'
                jobStartIntentAtUtc = '2026-08-30T00:04:00.0000000+00:00'
                executionName = ''
                executionStartedAtUtc = ''
                executionSucceededAtUtc = ''
                evidenceFingerprint = ''
                evidenceRecoveredAtUtc = ''
                administratorRestoredAtUtc = ''
                completedAtUtc = ''
            }
        }

        It 'accepts only a receipt exactly bound to the subscription, source, job, and original administrator' {
            $result = Assert-GatewayPrivateDatabaseBootstrapRecord `
                -Record $script:receipt `
                -Config $script:config `
                -SqlServerFqdn $script:sqlServerFqdn `
                -JobName $script:jobName `
                -JobImage $script:jobImage `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -OriginalAdministratorObjectId $script:originalAdministratorObjectId `
                -OriginalAdministratorLogin $script:originalAdministratorLogin

            $result | Should -BeTrue

            $script:receipt.acceptedSourceFingerprint = "sha256:$('c' * 64)"
            { Assert-GatewayPrivateDatabaseBootstrapRecord `
                -Record $script:receipt `
                -Config $script:config `
                -SqlServerFqdn $script:sqlServerFqdn `
                -JobName $script:jobName `
                -JobImage $script:jobImage `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -OriginalAdministratorObjectId $script:originalAdministratorObjectId `
                -OriginalAdministratorLogin $script:originalAdministratorLogin } |
                Should -Throw '*does not match the exact subscription, database, source, job, or original administrator boundary*'
        }

        It 'rejects malformed or structurally extended durable receipts' {
            $malformedPath = Join-Path $TestDrive 'malformed-private-database-receipt.json'
            '{"schemaVersion":' | Set-Content -LiteralPath $malformedPath -NoNewline

            { Read-GatewayPrivateDatabaseBootstrapRecord -Path $malformedPath } |
                Should -Throw '*recovery record is malformed*'

            $script:receipt.unreviewedField = 'not-allowed'
            { Assert-GatewayPrivateDatabaseBootstrapRecord `
                -Record $script:receipt `
                -Config $script:config `
                -SqlServerFqdn $script:sqlServerFqdn `
                -JobName $script:jobName `
                -JobImage $script:jobImage `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -OriginalAdministratorObjectId $script:originalAdministratorObjectId `
                -OriginalAdministratorLogin $script:originalAdministratorLogin } |
                Should -Throw '*does not match the exact subscription, database, source, job, or original administrator boundary*'
        }

        It 'requires one singular exact ActiveDirectory SQL administrator readback' {
            Mock Invoke-AzJson {
                return [pscustomobject]@{
                    administratorType = 'ActiveDirectory'
                    login = $script:originalAdministratorLogin
                    sid = $script:originalAdministratorObjectId
                    tenantId = $script:config.tenantId
                }
            }

            $administrator = Get-GatewaySqlEntraAdministrator `
                -Config $script:config `
                -ServerName 'sql-gateway-dev'

            $administrator.administratorType | Should -BeExactly 'ActiveDirectory'
            $administrator.login | Should -BeExactly $script:originalAdministratorLogin
            $administrator.objectId | Should -BeExactly $script:originalAdministratorObjectId
            $administrator.tenantId | Should -BeExactly $script:config.tenantId
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                $Arguments.Count -eq 10 -and
                [string]$Arguments[0] -ceq 'sql' -and
                [string]$Arguments[1] -ceq 'server' -and
                [string]$Arguments[2] -ceq 'ad-admin' -and
                [string]$Arguments[3] -ceq 'list' -and
                [string]$Arguments[4] -ceq '--resource-group' -and
                [string]$Arguments[5] -ceq 'rg-gateway-dev' -and
                [string]$Arguments[6] -ceq '--server-name' -and
                [string]$Arguments[7] -ceq 'sql-gateway-dev' -and
                [string]$Arguments[8] -ceq '--query' -and
                [string]$Arguments[9] -ceq '[].{administratorType:administratorType,login:login,sid:sid,tenantId:tenantId}'
            }
        }

        It 'rejects zero or multiple SQL administrators rather than selecting one' {
            Mock Invoke-AzJson { return @() }
            { Get-GatewaySqlEntraAdministrator -Config $script:config -ServerName 'sql-gateway-dev' } |
                Should -Throw '*exactly one singular ActiveDirectory administrator*'

            Mock Invoke-AzJson {
                return @(
                    [pscustomobject]@{
                        administratorType = 'ActiveDirectory'
                        login = 'first'
                        sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
                        tenantId = $script:config.tenantId
                    },
                    [pscustomobject]@{
                        administratorType = 'ActiveDirectory'
                        login = 'second'
                        sid = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
                        tenantId = $script:config.tenantId
                    }
                )
            }
            { Get-GatewaySqlEntraAdministrator -Config $script:config -ServerName 'sql-gateway-dev' } |
                Should -Throw '*exactly one singular ActiveDirectory administrator*'
        }

        It 'builds the exact immutable database-migrator bootstrap argument sequence' {
            $actual = @(Get-GatewayDatabaseBootstrapJobArguments `
                -SqlServerFqdn $script:sqlServerFqdn `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api `
                -WorkerPrincipal $script:worker)
            $expected = @(
                '--server', 'sql-gateway-dev.database.windows.net',
                '--database', 'GatewayDb',
                '--phase', 'bootstrap',
                '--repeat', '1',
                '--repository-root', '/app',
                '--deployment-ownership-id', '33333333-3333-4333-8333-333333333333',
                '--accepted-source-fingerprint', "sha256:$('b' * 64)",
                '--expected-api-principal-name', 'ca-gateway-api-dev',
                '--expected-api-principal-client-id', '88888888-8888-4888-8888-888888888888',
                '--expected-worker-principal-name', 'ca-gateway-worker-dev-v3',
                '--expected-worker-principal-client-id', '99999999-9999-4999-8999-999999999999',
                '--evidence-stdout', 'true'
            )

            $actual.Count | Should -Be 24
            ($actual -join "`n") | Should -BeExactly ($expected -join "`n")
        }

        It 'accepts the Azure display-name form for the exact database Job region and rejects punctuation drift' {
            Test-GatewayDatabaseBootstrapLocationEquivalent `
                -ActualLocation 'Korea Central' `
                -ExpectedLocation 'koreacentral' | Should -BeTrue

            Test-GatewayDatabaseBootstrapLocationEquivalent `
                -ActualLocation 'Korea-Central' `
                -ExpectedLocation 'koreacentral' | Should -BeFalse

            Test-GatewayDatabaseBootstrapLocationEquivalent `
                -ActualLocation 'West US' `
                -ExpectedLocation 'koreacentral' | Should -BeFalse
        }

        It 'normalizes provider-null optional Job arrays to exact absence without hiding entries' {
            @(ConvertTo-GatewayDatabaseBootstrapCollection -Value $null).Count | Should -Be 0
            @(ConvertTo-GatewayDatabaseBootstrapCollection -Value @()).Count | Should -Be 0
            @(ConvertTo-GatewayDatabaseBootstrapCollection -Value @($null)).Count | Should -Be 0

            $entry = [pscustomobject]@{ name = 'unexpected' }
            $actual = @(ConvertTo-GatewayDatabaseBootstrapCollection -Value @($entry))
            $actual.Count | Should -Be 1
            [string]$actual[0].name | Should -BeExactly 'unexpected'
        }

        It 'accepts the exact live Azure Job shape with a display-name region and provider-null absent arrays' {
            $pullIdentityId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-pull-dev"
            $userAssignedIdentities = [pscustomobject]@{}
            $userAssignedIdentities | Add-Member -NotePropertyName $pullIdentityId -NotePropertyValue ([pscustomobject]@{})
            $foundation = [pscustomobject]@{
                acrLoginServer = 'gatewayacr.azurecr.io'
                containerAppsEnvironmentId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/managedEnvironments/cae-gateway-dev"
                runtimeImagePullIdentityId = $pullIdentityId
            }
            $arguments = @(Get-GatewayDatabaseBootstrapJobArguments `
                -SqlServerFqdn $script:sqlServerFqdn `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api `
                -WorkerPrincipal $script:worker)
            $job = [pscustomobject]@{
                id = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/jobs/$($script:jobName)"
                name = $script:jobName
                location = 'Korea Central'
                identity = [pscustomobject]@{
                    type = 'SystemAssigned, UserAssigned'
                    tenantId = $script:config.tenantId
                    principalId = $script:jobPrincipalId
                    userAssignedIdentities = $userAssignedIdentities
                }
                tags = [pscustomobject]@{
                    bootstrapOwnershipId = $script:ownershipId
                    bootstrapSourceFingerprint = $script:sourceFingerprint
                    workload = 'database-bootstrap'
                }
                properties = [pscustomobject]@{
                    provisioningState = 'Succeeded'
                    environmentId = $foundation.containerAppsEnvironmentId
                    configuration = [pscustomobject]@{
                        triggerType = 'Manual'
                        replicaTimeout = 1800
                        replicaRetryLimit = 0
                        manualTriggerConfig = [pscustomobject]@{ parallelism = 1; replicaCompletionCount = 1 }
                        registries = @([pscustomobject]@{ server = $foundation.acrLoginServer; identity = $pullIdentityId })
                        secrets = $null
                        identitySettings = @(
                            [pscustomobject]@{ identity = 'system'; lifecycle = 'Main' },
                            [pscustomobject]@{ identity = $pullIdentityId.ToLowerInvariant(); lifecycle = 'None' }
                        )
                    }
                    template = [pscustomobject]@{
                        initContainers = $null
                        volumes = $null
                        containers = @([pscustomobject]@{
                            name = 'database-bootstrap'
                            image = $script:jobImage
                            command = @('dotnet', 'Gateway.DatabaseMigrator.dll')
                            args = $arguments
                            env = $null
                            volumeMounts = $null
                            probes = $null
                            resources = [pscustomobject]@{ cpu = 0.5; memory = '1Gi' }
                        })
                    }
                }
            }
            Mock Invoke-AzJson { return $job }

            $result = Get-GatewayDatabaseBootstrapJobEvidence `
                -Config $script:config -Foundation $foundation `
                -SqlServerFqdn $script:sqlServerFqdn -JobImage $script:jobImage `
                -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api -WorkerPrincipal $script:worker

            [string]$result.jobName | Should -BeExactly $script:jobName
            [string]$result.jobPrincipalId | Should -BeExactly $script:jobPrincipalId
        }

        It 'performs the first dormant deployment after a persisted intent when both deterministic ARM records remain absent' {
            $script:foundation = [pscustomobject]@{
                acrLoginServer = 'gatewayacr.azurecr.io'
                containerAppsEnvironmentId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/managedEnvironments/cae-gateway-dev"
                runtimeImagePullIdentityId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-pull-dev"
            }
            $script:deploymentName = 'a365gw-gateway-bootstrap-database-job-dev'
            $script:deployment = [pscustomobject]@{
                name = $script:deploymentName
                properties = [pscustomobject]@{
                    provisioningState = 'Succeeded'
                    parameters = [pscustomobject]@{
                        location = [pscustomobject]@{ value = $script:config.location }
                        environment = [pscustomobject]@{ value = $script:config.environment }
                        projectName = [pscustomobject]@{ value = $script:config.projectName }
                        containerAppsEnvironmentId = [pscustomobject]@{ value = $script:foundation.containerAppsEnvironmentId }
                        databaseMigratorImageDigest = [pscustomobject]@{ value = "sha256:$('a' * 64)" }
                        acrLoginServer = [pscustomobject]@{ value = $script:foundation.acrLoginServer }
                        imagePullIdentityResourceId = [pscustomobject]@{ value = $script:foundation.runtimeImagePullIdentityId }
                        sqlServerFqdn = [pscustomobject]@{ value = $script:sqlServerFqdn }
                        deploymentOwnershipId = [pscustomobject]@{ value = $script:ownershipId }
                        bootstrapSourceFingerprint = [pscustomobject]@{ value = $script:sourceFingerprint }
                        apiDatabasePrincipalName = [pscustomobject]@{ value = $script:api.displayName }
                        apiDatabasePrincipalClientId = [pscustomobject]@{ value = $script:api.clientId }
                        workerDatabasePrincipalName = [pscustomobject]@{ value = $script:worker.displayName }
                        workerDatabasePrincipalClientId = [pscustomobject]@{ value = $script:worker.clientId }
                    }
                }
            }
            Mock Get-BootstrapExecutionSourceRoot { return $TestDrive }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'resource') { return @() }
                if ([string]$Arguments[0] -ceq 'deployment' -and [string]$Arguments[2] -ceq 'list') { return @() }
                if ([string]$Arguments[0] -ceq 'deployment' -and [string]$Arguments[2] -ceq 'create') { return $script:deployment }
                throw 'Unexpected Azure call in dormant deployment test.'
            }
            Mock Get-GatewayDatabaseBootstrapJobEvidence {
                return [ordered]@{ jobName = $script:jobName; jobPrincipalId = $script:jobPrincipalId }
            }

            $result = Deploy-GatewayDatabaseBootstrapJob `
                -Config $script:config -Foundation $script:foundation `
                -SqlServerFqdn $script:sqlServerFqdn -JobImage $script:jobImage `
                -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api -WorkerPrincipal $script:worker -FreshIntent:$true

            [string]$result.jobName | Should -BeExactly $script:jobName
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'deployment' -and [string]$Arguments[2] -ceq 'create'
            }
        }

        It 'adopts an exact succeeded dormant deployment after an unknown submit outcome without replaying ARM create' {
            $script:foundation = [pscustomobject]@{
                acrLoginServer = 'gatewayacr.azurecr.io'
                containerAppsEnvironmentId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/managedEnvironments/cae-gateway-dev"
                runtimeImagePullIdentityId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-pull-dev"
            }
            $script:deployment = [pscustomobject]@{
                name = 'a365gw-gateway-bootstrap-database-job-dev'
                properties = [pscustomobject]@{
                    provisioningState = 'Succeeded'
                    parameters = [pscustomobject]@{
                        location = [pscustomobject]@{ value = $script:config.location }
                        environment = [pscustomobject]@{ value = $script:config.environment }
                        projectName = [pscustomobject]@{ value = $script:config.projectName }
                        containerAppsEnvironmentId = [pscustomobject]@{ value = $script:foundation.containerAppsEnvironmentId }
                        databaseMigratorImageDigest = [pscustomobject]@{ value = "sha256:$('a' * 64)" }
                        acrLoginServer = [pscustomobject]@{ value = $script:foundation.acrLoginServer }
                        imagePullIdentityResourceId = [pscustomobject]@{ value = $script:foundation.runtimeImagePullIdentityId }
                        sqlServerFqdn = [pscustomobject]@{ value = $script:sqlServerFqdn }
                        deploymentOwnershipId = [pscustomobject]@{ value = $script:ownershipId }
                        bootstrapSourceFingerprint = [pscustomobject]@{ value = $script:sourceFingerprint }
                        apiDatabasePrincipalName = [pscustomobject]@{ value = $script:api.displayName }
                        apiDatabasePrincipalClientId = [pscustomobject]@{ value = $script:api.clientId }
                        workerDatabasePrincipalName = [pscustomobject]@{ value = $script:worker.displayName }
                        workerDatabasePrincipalClientId = [pscustomobject]@{ value = $script:worker.clientId }
                    }
                }
            }
            $script:expectedJobId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/jobs/$($script:jobName)"
            Mock Get-BootstrapExecutionSourceRoot { return $TestDrive }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                if ([string]$Arguments[0] -ceq 'resource') { return @([pscustomobject]@{ id = $script:expectedJobId }) }
                if ([string]$Arguments[0] -ceq 'deployment' -and [string]$Arguments[2] -ceq 'list') { return @([pscustomobject]@{ name = $script:deployment.name }) }
                if ([string]$Arguments[0] -ceq 'deployment' -and [string]$Arguments[2] -ceq 'show') { return $script:deployment }
                throw 'Unexpected Azure call in dormant adoption test.'
            }
            Mock Get-GatewayDatabaseBootstrapJobEvidence {
                return [ordered]@{ jobName = $script:jobName; jobPrincipalId = $script:jobPrincipalId }
            }

            $null = Deploy-GatewayDatabaseBootstrapJob `
                -Config $script:config -Foundation $script:foundation `
                -SqlServerFqdn $script:sqlServerFqdn -JobImage $script:jobImage `
                -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api -WorkerPrincipal $script:worker -FreshIntent:$true

            Should -Invoke Invoke-AzJson -Times 0 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'deployment' -and [string]$Arguments[2] -ceq 'create'
            }
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'deployment' -and [string]$Arguments[2] -ceq 'show'
            }
        }

        It 'reassembles indexed intent-bound chunks containing exactly three evidence records' {
            $records = @(
                [ordered]@{ Phase = 'initialize'; Sequence = 1; ExecutionIntentId = $script:executionIntentId },
                [ordered]@{ Phase = 'principal'; Sequence = 2; ExecutionIntentId = $script:executionIntentId },
                [ordered]@{ Phase = 'principal'; Sequence = 3; ExecutionIntentId = $script:executionIntentId }
            )
            $json = ConvertTo-Json -InputObject $records -Depth 10 -Compress
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
            $encoded = [Convert]::ToBase64String($bytes)
            $digest = "sha256:$([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant())"
            $chunkLength = 40
            $chunkCount = [int][Math]::Ceiling($encoded.Length / [double]$chunkLength)
            $lines = @(for ($index = 0; $index -lt $chunkCount; $index++) {
                $length = [Math]::Min($chunkLength, $encoded.Length - ($index * $chunkLength))
                "A365GW_DB_EVIDENCE|$($script:executionIntentId)|$($index + 1)|$chunkCount|$digest|$($encoded.Substring($index * $chunkLength, $length))"
            })

            $payload = ConvertFrom-GatewayDatabaseBootstrapEvidenceLogLines `
                -LogLines @($lines | Sort-Object -Descending) `
                -ExecutionIntentId $script:executionIntentId

            @($payload.records).Count | Should -Be 3
            @($payload.records | ForEach-Object { [string]$_.Phase }) -join '|' |
                Should -BeExactly 'initialize|principal|principal'
            [string]$payload.fingerprint | Should -Match '^sha256:[0-9a-f]{64}$'
        }

        It 'rejects evidence payloads with any record count other than exactly three' {
            $twoRecords = @(
                [ordered]@{ Phase = 'initialize'; ExecutionIntentId = $script:executionIntentId },
                [ordered]@{ Phase = 'principal'; ExecutionIntentId = $script:executionIntentId }
            )
            $json = ConvertTo-Json -InputObject $twoRecords -Depth 10 -Compress
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
            $encoded = [Convert]::ToBase64String($bytes)
            $digest = "sha256:$([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant())"
            $line = "A365GW_DB_EVIDENCE|$($script:executionIntentId)|1|1|$digest|$encoded"

            { ConvertFrom-GatewayDatabaseBootstrapEvidenceLogLines `
                -LogLines @($line) -ExecutionIntentId $script:executionIntentId } |
                Should -Throw '*did not return exactly three schema/principal evidence records*'
        }

        It 'rejects duplicate durable evidence chunks from one execution' {
            $records = @(
                [ordered]@{ Phase = 'initialize'; ExecutionIntentId = $script:executionIntentId },
                [ordered]@{ Phase = 'principal'; ExecutionIntentId = $script:executionIntentId },
                [ordered]@{ Phase = 'principal'; ExecutionIntentId = $script:executionIntentId }
            )
            $json = ConvertTo-Json -InputObject $records -Depth 10 -Compress
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
            $encoded = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($json))
            $digest = "sha256:$([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant())"
            $line = "A365GW_DB_EVIDENCE|$($script:executionIntentId)|1|1|$digest|$encoded"

            { ConvertFrom-GatewayDatabaseBootstrapEvidenceLogLines `
                -LogLines @($line, $line) -ExecutionIntentId $script:executionIntentId } |
                Should -Throw '*duplicated, inconsistent, or outside its bounds*'
        }

        It 'validates the exact successful execution template, intent, times, and absence of mounted replacement surfaces' {
            $script:expectedExecutionArguments = @(Get-GatewayDatabaseBootstrapJobArguments `
                -SqlServerFqdn $script:sqlServerFqdn `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api `
                -WorkerPrincipal $script:worker)
            Mock Invoke-AzJson {
                return [pscustomobject]@{
                    name = "$($script:jobName)-abc12"
                    properties = [pscustomobject]@{
                        status = 'Succeeded'
                        startTime = '2026-08-30T00:04:30.0000000+00:00'
                        endTime = '2026-08-30T00:05:30.0000000+00:00'
                        template = [pscustomobject]@{
                            initContainers = @()
                            volumes = @()
                            containers = @([pscustomobject]@{
                                name = 'database-bootstrap'
                                image = $script:jobImage
                                command = @('dotnet', 'Gateway.DatabaseMigrator.dll')
                                args = $script:expectedExecutionArguments
                                env = @([pscustomobject]@{
                                    name = 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID'
                                    value = $script:executionIntentId
                                    secretRef = ''
                                })
                                volumeMounts = @()
                                resources = [pscustomobject]@{ cpu = 0.5; memory = '1Gi' }
                            })
                        }
                    }
                }
            }

            $result = Get-GatewayDatabaseBootstrapExecutionEvidence `
                -Config $script:config -JobName $script:jobName `
                -ExecutionName "$($script:jobName)-abc12" `
                -JobImage $script:jobImage -SqlServerFqdn $script:sqlServerFqdn `
                -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api -WorkerPrincipal $script:worker `
                -ExecutionIntentId $script:executionIntentId

            $result.status | Should -BeExactly 'Succeeded'
            $result.executionIntentId | Should -BeExactly $script:executionIntentId
            $result.startTimeUtc | Should -BeExactly '2026-08-30T00:04:30.0000000+00:00'
            $result.endTimeUtc | Should -BeExactly '2026-08-30T00:05:30.0000000+00:00'
        }

        It 'rejects an execution with an init container, volume, mount, or intent drift' {
            $script:expectedExecutionArguments = @(Get-GatewayDatabaseBootstrapJobArguments `
                -SqlServerFqdn $script:sqlServerFqdn `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api `
                -WorkerPrincipal $script:worker)
            $script:executionTamper = 'init'
            Mock Invoke-AzJson {
                $container = [pscustomobject]@{
                    name = 'database-bootstrap'
                    image = $script:jobImage
                    command = @('dotnet', 'Gateway.DatabaseMigrator.dll')
                    args = $script:expectedExecutionArguments
                    env = @([pscustomobject]@{
                        name = 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID'
                        value = if ($script:executionTamper -ceq 'intent') { 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' } else { $script:executionIntentId }
                        secretRef = ''
                    })
                    volumeMounts = if ($script:executionTamper -ceq 'mount') { @([pscustomobject]@{ volumeName = 'replacement'; mountPath = '/app' }) } else { @() }
                    probes = if ($script:executionTamper -ceq 'probe') { @([pscustomobject]@{ type = 'Liveness' }) } else { @() }
                    resources = [pscustomobject]@{ cpu = 0.5; memory = '1Gi' }
                }
                return [pscustomobject]@{
                    name = "$($script:jobName)-abc12"
                    properties = [pscustomobject]@{
                        status = 'Succeeded'
                        startTime = '2026-08-30T00:04:30.0000000+00:00'
                        endTime = '2026-08-30T00:05:30.0000000+00:00'
                        template = [pscustomobject]@{
                            initContainers = if ($script:executionTamper -ceq 'init') { @([pscustomobject]@{ name = 'replacement' }) } else { @() }
                            volumes = if ($script:executionTamper -ceq 'volume') { @([pscustomobject]@{ name = 'replacement' }) } else { @() }
                            containers = @($container)
                        }
                    }
                }
            }
            $invoke = {
                Get-GatewayDatabaseBootstrapExecutionEvidence `
                    -Config $script:config -JobName $script:jobName `
                    -ExecutionName "$($script:jobName)-abc12" `
                    -JobImage $script:jobImage -SqlServerFqdn $script:sqlServerFqdn `
                    -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint `
                    -ApiPrincipal $script:api -WorkerPrincipal $script:worker `
                    -ExecutionIntentId $script:executionIntentId
            }

            foreach ($tamper in @('init', 'volume', 'mount', 'probe', 'intent')) {
                $script:executionTamper = $tamper
                $invoke | Should -Throw '*does not match the exact immutable image, intent, process, environment, volume, and resource contract*'
            }
        }

        It 'retries a transient execution-list failure and accepts exactly one discovered execution' {
            $script:listAttempt = 0
            Mock Get-GatewayDatabaseBootstrapExecutions {
                $script:listAttempt++
                if ($script:listAttempt -eq 1) { throw 'transient management-plane read' }
                return @([pscustomobject]@{ name = "$($script:jobName)-abc12"; status = 'Unknown' })
            }
            Mock Start-Sleep { }

            $result = @(Get-GatewayDatabaseBootstrapExecutionsBounded `
                -Config $script:config -JobName $script:jobName `
                -MaximumAttempts 2 -PollIntervalSeconds 0)

            $result.Count | Should -Be 1
            [string]$result[0].name | Should -BeExactly "$($script:jobName)-abc12"
            Should -Invoke Get-GatewayDatabaseBootstrapExecutions -Times 2 -Exactly
        }

        It 'treats Unknown as nonterminal and waits for the exact execution to succeed' {
            $script:showAttempt = 0
            Mock Invoke-AzJson {
                $script:showAttempt++
                return [pscustomobject]@{
                    name = "$($script:jobName)-abc12"
                    properties = [pscustomobject]@{
                        status = if ($script:showAttempt -eq 1) { 'Unknown' } else { 'Succeeded' }
                    }
                }
            }
            Mock Start-Sleep { }

            $result = Wait-GatewayDatabaseBootstrapExecution `
                -Config $script:config -JobName $script:jobName `
                -ExecutionName "$($script:jobName)-abc12" `
                -MaximumAttempts 2 -PollIntervalSeconds 0

            [string]$result.properties.status | Should -BeExactly 'Succeeded'
            Should -Invoke Invoke-AzJson -Times 2 -Exactly
        }

        It 'settles a previously started execution before restoring SQL admin after a Resume preparation failure' {
            $script:testRepositoryRoot = $TestDrive
            $script:receipt.executionName = "$($script:jobName)-abc12"
            $receiptPath = Join-Path $script:testRepositoryRoot ".bootstrap/evidence/$($script:config.resourceGroupName)/database/private-database-bootstrap-receipt.json"
            Save-GatewayPrivateDatabaseBootstrapRecord -Record $script:receipt -Path $receiptPath
            $script:foundation = [pscustomobject]@{
                acrLoginServer = 'gatewayacr.azurecr.io'
                deploymentOwnershipId = $script:ownershipId
                sourceFingerprint = $script:sourceFingerprint
                resourceGroupName = $script:config.resourceGroupName
            }
            $script:executionSettledBeforeRestore = $false

            Mock Get-RepositoryRoot { return $script:testRepositoryRoot }
            Mock Get-BootstrapExecutionSourceRoot { return $script:testRepositoryRoot }
            Mock Get-BootstrapSourceFingerprint { return $script:sourceFingerprint }
            Mock Get-ManagedIdentityClientId { throw 'transient Graph managed-identity lookup' }
            Mock Wait-GatewayDatabaseBootstrapExecution {
                $script:executionSettledBeforeRestore = $true
                return [pscustomobject]@{ name = "$($script:jobName)-abc12"; properties = [pscustomobject]@{ status = 'Succeeded' } }
            }
            Mock Get-GatewaySqlEntraAdministrator {
                return [ordered]@{
                    administratorType = 'ActiveDirectory'
                    login = $script:jobName
                    objectId = $script:jobPrincipalId
                    tenantId = $script:config.tenantId
                }
            }
            Mock Set-GatewaySqlEntraAdministratorExact {
                if (-not $script:executionSettledBeforeRestore) {
                    throw 'SQL administrator restoration occurred before execution settlement.'
                }
            }

            { Initialize-GatewayDatabase `
                -Config $script:config `
                -Foundation $script:foundation `
                -SqlServerFqdn $script:sqlServerFqdn `
                -ApiPrincipalId $script:apiPrincipalId `
                -WorkerPrincipalId $script:workerPrincipalId `
                -DeploymentOwnershipId $script:ownershipId `
                -DatabaseMigratorImage $script:jobImage `
                -OriginalEntraAdministratorObjectId $script:originalAdministratorObjectId `
                -OriginalEntraAdministratorLogin $script:originalAdministratorLogin `
                -BootstrapClientIpv4 '10.20.30.40' } |
                Should -Throw '*transient Graph managed-identity lookup*'

            Should -Invoke Wait-GatewayDatabaseBootstrapExecution -Times 1 -Exactly
            Should -Invoke Set-GatewaySqlEntraAdministratorExact -Times 1 -Exactly -ParameterFilter {
                $ObjectId -ceq $script:originalAdministratorObjectId -and
                    $Login -ceq $script:originalAdministratorLogin
            }
        }

        It 'never starts the job again when durable start intent has an ambiguous zero-execution outcome' {
            $script:testRepositoryRoot = $TestDrive
            $receiptPath = Join-Path $script:testRepositoryRoot ".bootstrap/evidence/$($script:config.resourceGroupName)/database/private-database-bootstrap-receipt.json"
            Save-GatewayPrivateDatabaseBootstrapRecord -Record $script:receipt -Path $receiptPath
            $script:foundation = [pscustomobject]@{
                acrLoginServer = 'gatewayacr.azurecr.io'
                deploymentOwnershipId = $script:ownershipId
                sourceFingerprint = $script:sourceFingerprint
                resourceGroupName = $script:config.resourceGroupName
                containerAppsEnvironmentId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/managedEnvironments/cae-gateway-dev"
                runtimeImagePullIdentityId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-pull-dev"
            }

            Mock Get-RepositoryRoot { return $script:testRepositoryRoot }
            Mock Get-BootstrapExecutionSourceRoot { return $script:testRepositoryRoot }
            Mock Get-BootstrapSourceFingerprint { return $script:sourceFingerprint }
            Mock Get-ManagedIdentityClientId {
                if ($PrincipalObjectId -ceq $script:apiPrincipalId) { return $script:api }
                if ($PrincipalObjectId -ceq $script:workerPrincipalId) { return $script:worker }
                throw 'Unexpected managed identity lookup.'
            }
            Mock Invoke-AzTsv { return 'Disabled' }
            Mock Invoke-AzJson { return @() }
            Mock Deploy-GatewayDatabaseBootstrapJob {
                return [ordered]@{
                    jobId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/jobs/$($script:jobName)"
                    jobName = $script:jobName
                    jobPrincipalId = $script:jobPrincipalId
                    jobImage = $script:jobImage
                    containerName = 'database-bootstrap'
                }
            }
            Mock Get-GatewayDatabaseBootstrapExecutionsBounded { return @() }
            Mock Get-GatewaySqlEntraAdministrator {
                return [ordered]@{
                    administratorType = 'ActiveDirectory'
                    login = $script:originalAdministratorLogin
                    objectId = $script:originalAdministratorObjectId
                    tenantId = $script:config.tenantId
                }
            }
            Mock Start-Sleep {}

            { Initialize-GatewayDatabase `
                -Config $script:config `
                -Foundation $script:foundation `
                -SqlServerFqdn $script:sqlServerFqdn `
                -ApiPrincipalId $script:apiPrincipalId `
                -WorkerPrincipalId $script:workerPrincipalId `
                -DeploymentOwnershipId $script:ownershipId `
                -DatabaseMigratorImage $script:jobImage `
                -OriginalEntraAdministratorObjectId $script:originalAdministratorObjectId `
                -OriginalEntraAdministratorLogin $script:originalAdministratorLogin `
                -BootstrapClientIpv4 '10.20.30.40' } |
                Should -Throw '*recorded database-bootstrap job start has an unknown provider outcome after the full job-timeout recovery window. It will not be repeated*'

            Should -Invoke Get-GatewayDatabaseBootstrapExecutionsBounded -Times 1 -Exactly
            Should -Invoke Deploy-GatewayDatabaseBootstrapJob -Times 1 -Exactly -ParameterFilter { -not $FreshIntent }
            Should -Invoke Invoke-AzJson -Times 0 -Exactly -ParameterFilter {
                $Arguments.Count -ge 3 -and
                [string]$Arguments[0] -ceq 'containerapp' -and
                [string]$Arguments[1] -ceq 'job' -and
                [string]$Arguments[2] -ceq 'start'
            }
        }
    }
}
