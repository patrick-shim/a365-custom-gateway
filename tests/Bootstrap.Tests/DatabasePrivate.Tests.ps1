$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Azure.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Database.psm1') -Force

Describe 'Private database bootstrap recovery and evidence contract' {
    InModuleScope Database {
        BeforeAll {
            $script:newTestGatewayDatabaseBootstrapJob = {
                param(
                    [Parameter(Mandatory)]$Config,
                    [Parameter(Mandatory)]$Foundation,
                    [Parameter(Mandatory)][string]$SqlServerFqdn,
                    [Parameter(Mandatory)][string]$ExpectedPrivateEndpointIpv4Address,
                    [Parameter(Mandatory)][string]$JobImage,
                    [Parameter(Mandatory)][string]$DeploymentOwnershipId,
                    [Parameter(Mandatory)][string]$SourceFingerprint,
                    [Parameter(Mandatory)]$ApiPrincipal,
                    [Parameter(Mandatory)]$WorkerPrincipal,
                    [Parameter(Mandatory)][string]$JobPrincipalId,
                    [Parameter(Mandatory)][string]$ExecutionIntentId,
                    [switch]$IncludeEmptySecretRef
                )

            $jobName = "job-$($Config.projectName)-db-init-$($Config.environment)"
            $arguments = @(Get-GatewayDatabaseBootstrapJobArguments `
                -SqlServerFqdn $SqlServerFqdn `
                -ExpectedPrivateEndpointIpv4Address $ExpectedPrivateEndpointIpv4Address `
                -DeploymentOwnershipId $DeploymentOwnershipId `
                -SourceFingerprint $SourceFingerprint `
                -ApiPrincipal $ApiPrincipal `
                -WorkerPrincipal $WorkerPrincipal)
            $environment = [pscustomobject]@{
                name = 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID'
                value = $ExecutionIntentId
            }
            if ($IncludeEmptySecretRef) {
                $environment | Add-Member -NotePropertyName secretRef -NotePropertyValue ''
            }
            $userAssignedIdentities = [pscustomobject]@{}
            $userAssignedIdentities | Add-Member `
                -NotePropertyName ([string]$Foundation.runtimeImagePullIdentityId) `
                -NotePropertyValue ([pscustomobject]@{})

            return [pscustomobject]@{
                id = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.App/jobs/$jobName"
                name = $jobName
                location = 'Korea Central'
                identity = [pscustomobject]@{
                    type = 'SystemAssigned, UserAssigned'
                    tenantId = $Config.tenantId
                    principalId = $JobPrincipalId
                    userAssignedIdentities = $userAssignedIdentities
                }
                tags = [pscustomobject]@{
                    bootstrapOwnershipId = $DeploymentOwnershipId
                    bootstrapSourceFingerprint = $SourceFingerprint
                    workload = 'database-bootstrap'
                }
                properties = [pscustomobject]@{
                    provisioningState = 'Succeeded'
                    environmentId = $Foundation.containerAppsEnvironmentId
                    configuration = [pscustomobject]@{
                        triggerType = 'Manual'
                        replicaTimeout = 1800
                        replicaRetryLimit = 0
                        manualTriggerConfig = [pscustomobject]@{ parallelism = 1; replicaCompletionCount = 1 }
                        registries = @([pscustomobject]@{
                            server = $Foundation.acrLoginServer
                            identity = $Foundation.runtimeImagePullIdentityId
                        })
                        secrets = $null
                        identitySettings = @(
                            [pscustomobject]@{ identity = 'system'; lifecycle = 'Main' },
                            [pscustomobject]@{
                                identity = ([string]$Foundation.runtimeImagePullIdentityId).ToLowerInvariant()
                                lifecycle = 'None'
                            }
                        )
                    }
                    template = [pscustomobject]@{
                        initContainers = $null
                        volumes = $null
                        containers = @([pscustomobject]@{
                            name = 'database-bootstrap'
                            image = $JobImage
                            command = @('dotnet', 'Gateway.DatabaseMigrator.dll')
                            args = $arguments
                            env = @($environment)
                            volumeMounts = $null
                            probes = $null
                            resources = [pscustomobject]@{ cpu = 0.5; memory = '1Gi' }
                        })
                    }
                }
            }
            }
        }

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
            $script:privateEndpointIpv4Address = '10.42.1.4'
            $script:privateEndpointNetworkInterfaceId = "/subscriptions/$($script:config.subscriptionId)/resourcegroups/$($script:config.resourceGroupName)/providers/microsoft.network/networkinterfaces/pe-sql-gateway-dev.nic.12121212-1212-4212-8212-121212121212"
            $script:privateDnsARecordSetId = "/subscriptions/$($script:config.subscriptionId)/resourcegroups/$($script:config.resourceGroupName)/providers/microsoft.network/privatednszones/privatelink.database.windows.net/a/sql-gateway-dev"
            $script:sqlPrivateEndpoint = [ordered]@{
                privateEndpointNetworkInterfaceId = $script:privateEndpointNetworkInterfaceId
                privateEndpointIpv4Address = $script:privateEndpointIpv4Address
                privateDnsARecordSetId = $script:privateDnsARecordSetId
                privateDnsARecordName = 'sql-gateway-dev'
                privateDnsARecordIpv4Address = $script:privateEndpointIpv4Address
            }
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
                schemaVersion = 2
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
                privateEndpointNetworkInterfaceId = $script:privateEndpointNetworkInterfaceId
                privateEndpointIpv4Address = $script:privateEndpointIpv4Address
                privateDnsARecordSetId = $script:privateDnsARecordSetId
                privateDnsARecordName = 'sql-gateway-dev'
                privateDnsARecordIpv4Address = $script:privateEndpointIpv4Address
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
                -OriginalAdministratorLogin $script:originalAdministratorLogin `
                -SqlPrivateEndpoint $script:sqlPrivateEndpoint

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
                -OriginalAdministratorLogin $script:originalAdministratorLogin `
                -SqlPrivateEndpoint $script:sqlPrivateEndpoint } |
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
                -OriginalAdministratorLogin $script:originalAdministratorLogin `
                -SqlPrivateEndpoint $script:sqlPrivateEndpoint } |
                Should -Throw '*does not match the exact subscription, database, source, job, or original administrator boundary*'
        }

        It 'rejects a recovery receipt whose persisted private-endpoint tuple drifts' {
            $script:receipt.privateEndpointIpv4Address = '10.42.1.5'

            { Assert-GatewayPrivateDatabaseBootstrapRecord `
                -Record $script:receipt -Config $script:config `
                -SqlServerFqdn $script:sqlServerFqdn -JobName $script:jobName `
                -JobImage $script:jobImage -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -OriginalAdministratorObjectId $script:originalAdministratorObjectId `
                -OriginalAdministratorLogin $script:originalAdministratorLogin `
                -SqlPrivateEndpoint $script:sqlPrivateEndpoint } |
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
                -ExpectedPrivateEndpointIpv4Address $script:privateEndpointIpv4Address `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api `
                -WorkerPrincipal $script:worker)
            $expected = @(
                '--server', 'sql-gateway-dev.database.windows.net',
                '--expected-private-endpoint-ip', '10.42.1.4',
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

            $actual.Count | Should -Be 26
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

        It 'accepts the exact intent-bound live Azure Job shape with an empty or omitted secretRef' {
            $pullIdentityId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-pull-dev"
            $foundation = [pscustomobject]@{
                acrLoginServer = 'gatewayacr.azurecr.io'
                containerAppsEnvironmentId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/managedEnvironments/cae-gateway-dev"
                runtimeImagePullIdentityId = $pullIdentityId
            }
            Mock Invoke-AzJson { return $script:jobFixture }

            foreach ($includeEmptySecretRef in @($false, $true)) {
                $script:jobFixture = & $script:newTestGatewayDatabaseBootstrapJob `
                    -Config $script:config -Foundation $foundation `
                    -SqlServerFqdn $script:sqlServerFqdn -JobImage $script:jobImage `
                    -ExpectedPrivateEndpointIpv4Address $script:privateEndpointIpv4Address `
                    -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint `
                    -ApiPrincipal $script:api -WorkerPrincipal $script:worker `
                    -JobPrincipalId $script:jobPrincipalId -ExecutionIntentId $script:executionIntentId `
                    -IncludeEmptySecretRef:$includeEmptySecretRef

                $result = Get-GatewayDatabaseBootstrapJobEvidence `
                    -Config $script:config -Foundation $foundation `
                    -SqlServerFqdn $script:sqlServerFqdn -JobImage $script:jobImage `
                    -ExpectedPrivateEndpointIpv4Address $script:privateEndpointIpv4Address `
                    -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint `
                    -ApiPrincipal $script:api -WorkerPrincipal $script:worker `
                    -ExecutionIntentId $script:executionIntentId

                [string]$result.jobName | Should -BeExactly $script:jobName
                [string]$result.jobPrincipalId | Should -BeExactly $script:jobPrincipalId
            }
        }

        It 'rejects missing, wrong, noncanonical, empty, extra, or secret-backed dormant Job intent environment' {
            $foundation = [pscustomobject]@{
                acrLoginServer = 'gatewayacr.azurecr.io'
                containerAppsEnvironmentId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/managedEnvironments/cae-gateway-dev"
                runtimeImagePullIdentityId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-pull-dev"
            }
            $script:jobFixture = & $script:newTestGatewayDatabaseBootstrapJob `
                -Config $script:config -Foundation $foundation `
                -SqlServerFqdn $script:sqlServerFqdn -JobImage $script:jobImage `
                -ExpectedPrivateEndpointIpv4Address $script:privateEndpointIpv4Address `
                -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api -WorkerPrincipal $script:worker `
                -JobPrincipalId $script:jobPrincipalId -ExecutionIntentId $script:executionIntentId
            Mock Invoke-AzJson { return $script:jobFixture }
            $invoke = {
                Get-GatewayDatabaseBootstrapJobEvidence `
                    -Config $script:config -Foundation $foundation `
                    -SqlServerFqdn $script:sqlServerFqdn -JobImage $script:jobImage `
                    -ExpectedPrivateEndpointIpv4Address $script:privateEndpointIpv4Address `
                    -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint `
                    -ApiPrincipal $script:api -WorkerPrincipal $script:worker `
                    -ExecutionIntentId $script:executionIntentId
            }

            $unsafeEnvironmentCases = @(
                [pscustomobject]@{ environment = [object[]]@() },
                [pscustomobject]@{ environment = [object[]]@(
                    [pscustomobject]@{ name = 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID'; value = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' }
                ) },
                [pscustomobject]@{ environment = [object[]]@(
                    [pscustomobject]@{ name = 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID'; value = $script:executionIntentId.ToUpperInvariant() }
                ) },
                [pscustomobject]@{ environment = [object[]]@(
                    [pscustomobject]@{ name = 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID'; value = '' }
                ) },
                [pscustomobject]@{ environment = [object[]]@(
                    [pscustomobject]@{ name = 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID'; value = $script:executionIntentId },
                    [pscustomobject]@{ name = 'UNREVIEWED'; value = 'present' }
                ) },
                [pscustomobject]@{ environment = [object[]]@([pscustomobject]@{
                    name = 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID'
                    value = $script:executionIntentId
                    secretRef = 'replacement-secret'
                }) }
            )
            foreach ($unsafeEnvironmentCase in $unsafeEnvironmentCases) {
                $script:jobFixture.properties.template.containers[0].env = $unsafeEnvironmentCase.environment
                $invoke | Should -Throw '*does not match the exact dormant, identity, image, network, trigger, or argument contract*'
            }
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
                        expectedPrivateEndpointIp = [pscustomobject]@{ value = $script:privateEndpointIpv4Address }
                        deploymentOwnershipId = [pscustomobject]@{ value = $script:ownershipId }
                        bootstrapSourceFingerprint = [pscustomobject]@{ value = $script:sourceFingerprint }
                        apiDatabasePrincipalName = [pscustomobject]@{ value = $script:api.displayName }
                        apiDatabasePrincipalClientId = [pscustomobject]@{ value = $script:api.clientId }
                        workerDatabasePrincipalName = [pscustomobject]@{ value = $script:worker.displayName }
                        workerDatabasePrincipalClientId = [pscustomobject]@{ value = $script:worker.clientId }
                        executionIntentId = [pscustomobject]@{ value = $script:executionIntentId }
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
                -ExpectedPrivateEndpointIpv4Address $script:privateEndpointIpv4Address `
                -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api -WorkerPrincipal $script:worker `
                -ExecutionIntentId $script:executionIntentId -FreshIntent:$true

            [string]$result.jobName | Should -BeExactly $script:jobName
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'deployment' -and
                [string]$Arguments[2] -ceq 'create' -and
                @($Arguments | Where-Object {
                    [string]$_ -ceq "executionIntentId=$($script:executionIntentId)"
                }).Count -eq 1 -and
                @($Arguments | Where-Object {
                    [string]$_ -ceq "expectedPrivateEndpointIp=$($script:privateEndpointIpv4Address)"
                }).Count -eq 1
            }
            Should -Invoke Get-GatewayDatabaseBootstrapJobEvidence -Times 1 -Exactly -ParameterFilter {
                $ExecutionIntentId -ceq $script:executionIntentId -and
                    $ExpectedPrivateEndpointIpv4Address -ceq $script:privateEndpointIpv4Address
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
                        expectedPrivateEndpointIp = [pscustomobject]@{ value = $script:privateEndpointIpv4Address }
                        deploymentOwnershipId = [pscustomobject]@{ value = $script:ownershipId }
                        bootstrapSourceFingerprint = [pscustomobject]@{ value = $script:sourceFingerprint }
                        apiDatabasePrincipalName = [pscustomobject]@{ value = $script:api.displayName }
                        apiDatabasePrincipalClientId = [pscustomobject]@{ value = $script:api.clientId }
                        workerDatabasePrincipalName = [pscustomobject]@{ value = $script:worker.displayName }
                        workerDatabasePrincipalClientId = [pscustomobject]@{ value = $script:worker.clientId }
                        executionIntentId = [pscustomobject]@{ value = $script:executionIntentId }
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
                -ExpectedPrivateEndpointIpv4Address $script:privateEndpointIpv4Address `
                -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api -WorkerPrincipal $script:worker `
                -ExecutionIntentId $script:executionIntentId -FreshIntent:$true

            Should -Invoke Invoke-AzJson -Times 0 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'deployment' -and [string]$Arguments[2] -ceq 'create'
            }
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'deployment' -and [string]$Arguments[2] -ceq 'show'
            }
            Should -Invoke Get-GatewayDatabaseBootstrapJobEvidence -Times 1 -Exactly -ParameterFilter {
                $ExecutionIntentId -ceq $script:executionIntentId -and
                    $ExpectedPrivateEndpointIpv4Address -ceq $script:privateEndpointIpv4Address
            }
        }

        It 'starts the reviewed Job without replacing any part of its persisted template' {
            Mock Invoke-AzJson {
                return [pscustomobject]@{ name = "$($script:jobName)-abc12" }
            }

            $result = Start-GatewayDatabaseBootstrapExecution `
                -Config $script:config -JobName $script:jobName

            [string]$result.name | Should -BeExactly "$($script:jobName)-abc12"
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                $CaptureStdoutOnly -and
                $Arguments.Count -eq 7 -and
                [string]$Arguments[0] -ceq 'containerapp' -and
                [string]$Arguments[1] -ceq 'job' -and
                [string]$Arguments[2] -ceq 'start' -and
                [string]$Arguments[3] -ceq '--resource-group' -and
                [string]$Arguments[4] -ceq $script:config.resourceGroupName -and
                [string]$Arguments[5] -ceq '--name' -and
                [string]$Arguments[6] -ceq $script:jobName -and
                @($Arguments | Where-Object { $_ -in @('--env-vars', '--container-name', '--image', '--yaml') }).Count -eq 0
            }
        }

        It 'revalidates the exact Job and zero executions before SQL elevation and the sole start intent' {
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile(
                (Get-Module Database).Path, [ref]$tokens, [ref]$parseErrors)
            $parseErrors.Count | Should -Be 0
            $function = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq 'Initialize-GatewayDatabase'
            }, $true)
            $source = $function.Extent.Text
            $boundaryStart = $source.IndexOf('$preStartJobEvidence = Get-GatewayDatabaseBootstrapJobEvidence', [StringComparison]::Ordinal)
            $boundaryStart | Should -BeGreaterOrEqual 0
            $boundary = $source.Substring($boundaryStart)
            $zeroRead = $boundary.IndexOf('$preStartExecutions = @(Get-GatewayDatabaseBootstrapExecutions', [StringComparison]::Ordinal)
            $zeroGuard = $boundary.IndexOf('$preStartExecutions.Count -ne 0', [StringComparison]::Ordinal)
            $addressReadiness = $boundary.IndexOf('$preAdministratorAddressTuple = Get-GatewaySqlPrivateEndpointReadyAddressEvidence', [StringComparison]::Ordinal)
            $addressGuard = $boundary.IndexOf('The persisted SQL private-endpoint NIC and private-DNS A-record tuple changed', [StringComparison]::Ordinal)
            $swapIntent = $boundary.IndexOf('$receipt.administratorSwapIntentAtUtc =', [StringComparison]::Ordinal)
            $elevation = $boundary.IndexOf('Set-GatewaySqlEntraAdministratorExact', [StringComparison]::Ordinal)
            $startIntent = $boundary.IndexOf('$receipt.jobStartIntentAtUtc =', [StringComparison]::Ordinal)
            $start = $boundary.IndexOf('Start-GatewayDatabaseBootstrapExecution -Config $Config -JobName $jobName', [StringComparison]::Ordinal)
            ([regex]::Matches(
                $source,
                [regex]::Escape('Start-GatewayDatabaseBootstrapExecution -Config $Config -JobName $jobName'),
                [Text.RegularExpressions.RegexOptions]::CultureInvariant)).Count | Should -Be 1
            foreach ($index in @($zeroRead, $zeroGuard, $addressReadiness, $addressGuard, $swapIntent, $elevation, $startIntent, $start)) {
                $index | Should -BeGreaterOrEqual 0
            }
            $zeroRead | Should -BeLessThan $zeroGuard
            $zeroGuard | Should -BeLessThan $addressReadiness
            $addressReadiness | Should -BeLessThan $addressGuard
            $addressGuard | Should -BeLessThan $swapIntent
            foreach ($propertyName in @(
                'privateEndpointNetworkInterfaceId', 'privateEndpointIpv4Address',
                'privateDnsARecordSetId', 'privateDnsARecordName', 'privateDnsARecordIpv4Address'
            )) {
                $boundary | Should -Match ([regex]::Escape("'$propertyName'"))
            }
            $swapIntent | Should -BeLessThan $elevation
            $elevation | Should -BeLessThan $startIntent
            $startIntent | Should -BeLessThan $start
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

        It 'validates the exact successful execution with empty or omitted secretRef and no replacement surfaces' {
            $script:expectedExecutionArguments = @(Get-GatewayDatabaseBootstrapJobArguments `
                -SqlServerFqdn $script:sqlServerFqdn `
                -ExpectedPrivateEndpointIpv4Address $script:privateEndpointIpv4Address `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api `
                -WorkerPrincipal $script:worker)
            $script:executionSecretReferenceShape = 'omitted'
            Mock Invoke-AzJson {
                $environmentEntry = [ordered]@{
                    name = 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID'
                    value = $script:executionIntentId
                }
                if ($script:executionSecretReferenceShape -ceq 'empty') {
                    $environmentEntry.secretRef = ''
                }
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
                                env = @([pscustomobject]$environmentEntry)
                                volumeMounts = @()
                                resources = [pscustomobject]@{ cpu = 0.5; memory = '1Gi' }
                            })
                        }
                    }
                }
            }

            foreach ($shape in @('omitted', 'empty')) {
                $script:executionSecretReferenceShape = $shape
                $result = Get-GatewayDatabaseBootstrapExecutionEvidence `
                    -Config $script:config -JobName $script:jobName `
                    -ExecutionName "$($script:jobName)-abc12" `
                    -JobImage $script:jobImage -SqlServerFqdn $script:sqlServerFqdn `
                    -ExpectedPrivateEndpointIpv4Address $script:privateEndpointIpv4Address `
                    -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint `
                    -ApiPrincipal $script:api -WorkerPrincipal $script:worker `
                    -ExecutionIntentId $script:executionIntentId

                $result.status | Should -BeExactly 'Succeeded'
                $result.executionIntentId | Should -BeExactly $script:executionIntentId
                $result.startTimeUtc | Should -BeExactly '2026-08-30T00:04:30.0000000+00:00'
                $result.endTimeUtc | Should -BeExactly '2026-08-30T00:05:30.0000000+00:00'
            }
        }

        It 'rejects an execution with an init container, volume, mount, or intent drift' {
            $script:expectedExecutionArguments = @(Get-GatewayDatabaseBootstrapJobArguments `
                -SqlServerFqdn $script:sqlServerFqdn `
                -ExpectedPrivateEndpointIpv4Address $script:privateEndpointIpv4Address `
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
                        secretRef = if ($script:executionTamper -ceq 'secret') { 'replacement-secret' } else { '' }
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
                    -ExpectedPrivateEndpointIpv4Address $script:privateEndpointIpv4Address `
                    -DeploymentOwnershipId $script:ownershipId -SourceFingerprint $script:sourceFingerprint `
                    -ApiPrincipal $script:api -WorkerPrincipal $script:worker `
                    -ExecutionIntentId $script:executionIntentId
            }

            foreach ($tamper in @('init', 'volume', 'mount', 'probe', 'intent', 'secret')) {
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

        It 'restores the exact original administrator and never repeats the manual repair start after log recovery fails and resumes' {
            $script:testRepositoryRoot = Join-Path $TestDrive 'manual-repair-resume'
            [IO.Directory]::CreateDirectory($script:testRepositoryRoot) | Out-Null
            $script:repairJobName = 'job-gateway-db-repair-dev'
            $script:repairSourceFingerprint = $script:sourceFingerprint
            $script:originalSourceFingerprint = "sha256:$('c' * 64)"
            $script:repairPlanFingerprint = "sha256:$('d' * 64)"
            $script:exhaustedRecoveryPlanFingerprint = "sha256:$('e' * 64)"
            $script:imageIntentId = '12121212-1212-4212-8212-121212121212'
            $script:repairExecutionIntentId = '13131313-1313-4313-8313-131313131313'
            $script:originalBoundary = "sha256:$('1' * 64)"
            $script:firstBoundary = "sha256:$('2' * 64)"
            $script:secondBoundary = "sha256:$('3' * 64)"
            $script:manualRepairPlan = [ordered]@{
                status = 'Running'
                planFingerprint = $script:repairPlanFingerprint
                deploymentOwnershipId = $script:ownershipId
                originalSourceFingerprint = $script:originalSourceFingerprint
                repairSourceFingerprint = $script:repairSourceFingerprint
                exhaustedRecoveryPlanFingerprint = $script:exhaustedRecoveryPlanFingerprint
                exhaustedRecoveryPlan = [ordered]@{
                    planFingerprint = $script:exhaustedRecoveryPlanFingerprint
                    previousRecoveryPlan = [ordered]@{ planFingerprint = "sha256:$('f' * 64)" }
                }
                originalFailedJob = [ordered]@{
                    jobName = 'job-gateway-db-init-dev'; executionName = 'job-gateway-db-init-dev-old01'
                    executionIntentId = '14141414-1414-4414-8414-141414141414'
                    jobImage = "gatewayacr.azurecr.io/gateway-db-migrator@sha256:$('9' * 64)"
                    boundaryFingerprint = $script:originalBoundary
                }
                firstFailedRecovery = [ordered]@{
                    jobName = 'job-gateway-db-recover-dev'; executionName = 'job-gateway-db-recover-dev-old01'
                    executionIntentId = '15151515-1515-4515-8515-151515151515'
                    recoveryPlanFingerprint = "sha256:$('f' * 64)"; recoverySourceFingerprint = "sha256:$('4' * 64)"
                    boundaryFingerprint = $script:firstBoundary
                }
                secondFailedRecovery = [ordered]@{
                    jobName = 'job-gateway-db-recov2-dev'; executionName = 'job-gateway-db-recov2-dev-old01'
                    executionIntentId = '16161616-1616-4616-8616-161616161616'
                    recoveryPlanFingerprint = $script:exhaustedRecoveryPlanFingerprint; recoverySourceFingerprint = "sha256:$('5' * 64)"
                    boundaryFingerprint = $script:secondBoundary
                }
                correctedImage = [ordered]@{
                    state = 'DigestCheckpointed'; component = 'databaseMigratorRecovery'
                    sourceFingerprint = $script:repairSourceFingerprint
                    deploymentOwnershipId = $script:ownershipId
                    recoveryPlanFingerprint = $script:repairPlanFingerprint
                    intentId = $script:imageIntentId; image = $script:jobImage
                }
                repairJob = [ordered]@{
                    name = $script:repairJobName; executionIntentId = $script:repairExecutionIntentId
                    imageIntentId = $script:imageIntentId; repairMode = 'ResumeAfterSchemaCompleted'
                    replicaRetryLimit = 0; maximumExecutions = 1
                }
            }
            $script:foundation = [pscustomobject]@{
                acrLoginServer = 'gatewayacr.azurecr.io'
                deploymentOwnershipId = $script:ownershipId
                sourceFingerprint = $script:originalSourceFingerprint
                resourceGroupName = $script:config.resourceGroupName
                containerAppsEnvironmentId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/managedEnvironments/cae-gateway-dev"
                runtimeImagePullIdentityId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-pull-dev"
                privateEndpointSubnetId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/vnet-gateway-dev/subnets/snet-private-endpoints"
            }
            $script:currentAdministratorObjectId = $script:originalAdministratorObjectId
            $script:currentAdministratorLogin = $script:originalAdministratorLogin
            $script:manualStartCount = 0
            $script:failedRecoveryReadCount = 0
            $script:executionStartUtc = [DateTimeOffset]::UtcNow.ToString('O')
            $script:executionEndUtc = [DateTimeOffset]::UtcNow.AddMinutes(1).ToString('O')
            $script:execution = [pscustomobject]@{ name = "$($script:repairJobName)-abc12"; status = 'Succeeded' }
            $script:jobEvidence = [ordered]@{
                jobId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/jobs/$($script:repairJobName)"
                jobName = $script:repairJobName; jobPrincipalId = $script:jobPrincipalId
                jobImage = $script:jobImage; containerName = 'database-manual-repair'
                executionIntentId = $script:repairExecutionIntentId
            }

            Mock Get-RepositoryRoot { $script:testRepositoryRoot }
            Mock Get-BootstrapExecutionSourceRoot { $script:testRepositoryRoot }
            Mock Get-BootstrapSourceFingerprint { $script:repairSourceFingerprint }
            Mock Get-ManagedIdentityClientId {
                if ($PrincipalObjectId -ceq $script:apiPrincipalId) { return $script:api }
                if ($PrincipalObjectId -ceq $script:workerPrincipalId) { return $script:worker }
                throw 'Unexpected managed identity lookup.'
            }
            Mock Invoke-AzTsv {
                if ($Arguments -contains 'ad-only-auth') { return 'true' }
                return 'Disabled'
            }
            Mock Invoke-AzJson { return @() }
            Mock Get-GatewayFailedDatabaseBootstrapBoundary {
                return [ordered]@{ boundaryFingerprint = $script:originalBoundary }
            }
            Mock Get-GatewayFailedDatabaseRecoveryBoundary {
                $script:failedRecoveryReadCount++
                if (($script:failedRecoveryReadCount % 2) -eq 1) {
                    return [ordered]@{ boundaryFingerprint = $script:firstBoundary }
                }
                return [ordered]@{ boundaryFingerprint = $script:secondBoundary }
            }
            Mock Assert-GatewayPrivateDatabaseManualRepairRecord { $true }
            Mock Get-GatewaySqlEntraAdministrator {
                return [ordered]@{
                    administratorType = 'ActiveDirectory'; login = $script:currentAdministratorLogin
                    objectId = $script:currentAdministratorObjectId; tenantId = $script:config.tenantId
                }
            }
            Mock Set-GatewaySqlEntraAdministratorExact {
                $script:currentAdministratorObjectId = $ObjectId
                $script:currentAdministratorLogin = $Login
            }
            Mock Deploy-GatewayDatabaseBootstrapJob { $script:jobEvidence }
            Mock Get-GatewayDatabaseBootstrapJobEvidence { $script:jobEvidence }
            Mock Get-GatewayDatabaseBootstrapExecutions { return @() }
            Mock Get-GatewaySqlPrivateEndpointReadyAddressEvidence { $script:sqlPrivateEndpoint }
            Mock Start-GatewayDatabaseBootstrapExecution {
                $script:manualStartCount++
                return [pscustomobject]@{ name = "$($script:repairJobName)-abc12" }
            }
            Mock Get-GatewayDatabaseBootstrapExecutionsBounded { return @($script:execution) }
            Mock Wait-GatewayDatabaseBootstrapExecution {
                return [pscustomobject]@{ name = "$($script:repairJobName)-abc12"; properties = [pscustomobject]@{ status = 'Succeeded' } }
            }
            Mock Get-GatewayDatabaseBootstrapExecutionEvidence {
                return [ordered]@{ startTimeUtc = $script:executionStartUtc; endTimeUtc = $script:executionEndUtc }
            }
            Mock Get-GatewayDatabaseBootstrapEvidenceFromLogs { throw 'simulated manual repair log evidence failure' }
            Mock Complete-GatewayDatabaseBootstrapExecutionRecoveryWindow { $true }
            Mock Start-Sleep { }

            $invoke = {
                Initialize-GatewayDatabase `
                    -Config $script:config -Foundation $script:foundation `
                    -SqlPrivateEndpoint $script:sqlPrivateEndpoint -SqlServerFqdn $script:sqlServerFqdn `
                    -ApiPrincipalId $script:apiPrincipalId -WorkerPrincipalId $script:workerPrincipalId `
                    -DeploymentOwnershipId $script:ownershipId -DatabaseMigratorImage $script:jobImage `
                    -OriginalEntraAdministratorObjectId $script:originalAdministratorObjectId `
                    -OriginalEntraAdministratorLogin $script:originalAdministratorLogin `
                    -BootstrapClientIpv4 '10.20.30.40' -ManualRepairPlan $script:manualRepairPlan
            }

            $invoke | Should -Throw '*simulated manual repair log evidence failure*'
            $script:currentAdministratorObjectId | Should -BeExactly $script:originalAdministratorObjectId
            $script:currentAdministratorLogin | Should -BeExactly $script:originalAdministratorLogin
            $invoke | Should -Throw '*simulated manual repair log evidence failure*'
            $script:currentAdministratorObjectId | Should -BeExactly $script:originalAdministratorObjectId
            $script:currentAdministratorLogin | Should -BeExactly $script:originalAdministratorLogin
            $script:manualStartCount | Should -Be 1

            Should -Invoke Start-GatewayDatabaseBootstrapExecution -Times 1 -Exactly -ParameterFilter {
                $ManualRepair -and $JobName -ceq $script:repairJobName
            }
            Should -Invoke Get-GatewaySqlPrivateEndpointReadyAddressEvidence -Times 1 -Exactly
            Should -Invoke Set-GatewaySqlEntraAdministratorExact -Times 1 -Exactly -ParameterFilter {
                $ObjectId -ceq $script:originalAdministratorObjectId -and $Login -ceq $script:originalAdministratorLogin
            }
            Should -Invoke Invoke-AzTsv -Times 0 -Exactly -ParameterFilter {
                @($Arguments | Where-Object { [string]$_ -in @('create', 'update', 'delete') }).Count -gt 0
            }
            Should -Invoke Invoke-AzJson -Times 0 -Exactly -ParameterFilter {
                @($Arguments | Where-Object { [string]$_ -in @('create', 'update', 'delete') }).Count -gt 0
            }
        }

        It 'keeps corrected execution source separate from original database deployment provenance' {
            $script:correctedSourceFingerprint = "sha256:$('c' * 64)"
            Mock Get-RepositoryRoot { return $TestDrive }
            Mock Get-BootstrapExecutionSourceRoot { return $TestDrive }
            Mock Get-BootstrapSourceFingerprint { return $script:correctedSourceFingerprint }
            Mock Assert-GatewaySqlPrivateEndpointAddressEvidenceTuple { throw 'source-boundary-passed' }

            $invokeParameters = @{
                Config = $script:config
                Foundation = [ordered]@{}
                SqlPrivateEndpoint = [ordered]@{}
                SqlServerFqdn = $script:sqlServerFqdn
                ApiPrincipalId = $script:apiPrincipalId
                WorkerPrincipalId = $script:workerPrincipalId
                DeploymentOwnershipId = $script:ownershipId
                DatabaseMigratorImage = $script:jobImage
                OriginalEntraAdministratorObjectId = $script:originalAdministratorObjectId
                OriginalEntraAdministratorLogin = $script:originalAdministratorLogin
                BootstrapClientIpv4 = '10.20.30.40'
                ExecutionSourceFingerprint = $script:correctedSourceFingerprint
                DeploymentSourceFingerprint = $script:sourceFingerprint
            }

            { Initialize-GatewayDatabase @invokeParameters } | Should -Throw '*source-boundary-passed*'
            Should -Invoke Assert-GatewaySqlPrivateEndpointAddressEvidenceTuple -Times 1 -Exactly

            $invokeParameters['ExecutionSourceFingerprint'] = "sha256:$('d' * 64)"
            { Initialize-GatewayDatabase @invokeParameters } |
                Should -Throw '*execution source no longer matches the accepted content-addressed snapshot*'
            Should -Invoke Assert-GatewaySqlPrivateEndpointAddressEvidenceTuple -Times 1 -Exactly
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
                -SqlPrivateEndpoint $script:sqlPrivateEndpoint `
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

        It 'refuses SQL administrator elevation and the sole Job start when the persisted NIC and A-record tuple changed' {
            $script:testRepositoryRoot = $TestDrive
            $script:receipt.administratorSwapIntentAtUtc = ''
            $script:receipt.administratorSwappedAtUtc = ''
            $script:receipt.jobStartIntentAtUtc = ''
            $receiptPath = Join-Path $script:testRepositoryRoot ".bootstrap/evidence/$($script:config.resourceGroupName)/database/private-database-bootstrap-receipt.json"
            Save-GatewayPrivateDatabaseBootstrapRecord -Record $script:receipt -Path $receiptPath
            $script:foundation = [pscustomobject]@{
                acrLoginServer = 'gatewayacr.azurecr.io'
                deploymentOwnershipId = $script:ownershipId
                sourceFingerprint = $script:sourceFingerprint
                resourceGroupName = $script:config.resourceGroupName
                containerAppsEnvironmentId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/managedEnvironments/cae-gateway-dev"
                runtimeImagePullIdentityId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-gateway-pull-dev"
                privateEndpointSubnetId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/vnet-gateway-dev/subnets/snet-private-endpoints"
            }

            Mock Get-RepositoryRoot { return $script:testRepositoryRoot }
            Mock Get-BootstrapExecutionSourceRoot { return $script:testRepositoryRoot }
            Mock Get-BootstrapSourceFingerprint { return $script:sourceFingerprint }
            Mock Get-ManagedIdentityClientId {
                if ($PrincipalObjectId -ceq $script:apiPrincipalId) { return $script:api }
                if ($PrincipalObjectId -ceq $script:workerPrincipalId) { return $script:worker }
                throw 'Unexpected managed identity lookup.'
            }
            Mock Invoke-AzTsv {
                if ($Arguments -contains 'ad-only-auth') { return 'true' }
                return 'Disabled'
            }
            Mock Invoke-AzJson { return @() }
            Mock Deploy-GatewayDatabaseBootstrapJob {
                return [ordered]@{
                    jobId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/jobs/$($script:jobName)"
                    jobName = $script:jobName
                    jobPrincipalId = $script:jobPrincipalId
                    jobImage = $script:jobImage
                    containerName = 'database-bootstrap'
                    executionIntentId = $script:executionIntentId
                }
            }
            Mock Get-GatewayDatabaseBootstrapJobEvidence {
                return [ordered]@{
                    jobId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/jobs/$($script:jobName)"
                    jobName = $script:jobName
                    jobPrincipalId = $script:jobPrincipalId
                    jobImage = $script:jobImage
                    containerName = 'database-bootstrap'
                    executionIntentId = $script:executionIntentId
                }
            }
            Mock Get-GatewayDatabaseBootstrapExecutions { return @() }
            Mock Get-GatewaySqlPrivateEndpointReadyAddressEvidence {
                $changed = [ordered]@{}
                foreach ($entry in $script:sqlPrivateEndpoint.GetEnumerator()) { $changed[$entry.Key] = $entry.Value }
                $changed.privateEndpointIpv4Address = '10.42.1.5'
                $changed.privateDnsARecordIpv4Address = '10.42.1.5'
                return $changed
            }
            Mock Get-GatewaySqlEntraAdministrator {
                return [ordered]@{
                    administratorType = 'ActiveDirectory'
                    login = $script:originalAdministratorLogin
                    objectId = $script:originalAdministratorObjectId
                    tenantId = $script:config.tenantId
                }
            }
            Mock Set-GatewaySqlEntraAdministratorExact { }
            Mock Start-GatewayDatabaseBootstrapExecution { }

            { Initialize-GatewayDatabase `
                -Config $script:config -Foundation $script:foundation `
                -SqlPrivateEndpoint $script:sqlPrivateEndpoint `
                -SqlServerFqdn $script:sqlServerFqdn `
                -ApiPrincipalId $script:apiPrincipalId -WorkerPrincipalId $script:workerPrincipalId `
                -DeploymentOwnershipId $script:ownershipId -DatabaseMigratorImage $script:jobImage `
                -OriginalEntraAdministratorObjectId $script:originalAdministratorObjectId `
                -OriginalEntraAdministratorLogin $script:originalAdministratorLogin `
                -BootstrapClientIpv4 '10.20.30.40' } |
                Should -Throw '*persisted SQL private-endpoint NIC and private-DNS A-record tuple changed*'

            Should -Invoke Get-GatewaySqlPrivateEndpointReadyAddressEvidence -Times 1 -Exactly
            Should -Invoke Set-GatewaySqlEntraAdministratorExact -Times 0 -Exactly
            Should -Invoke Start-GatewayDatabaseBootstrapExecution -Times 0 -Exactly
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
            Mock Invoke-AzTsv {
                if ($Arguments -contains 'ad-only-auth') { return 'true' }
                return 'Disabled'
            }
            Mock Invoke-AzJson { return @() }
            Mock Deploy-GatewayDatabaseBootstrapJob {
                return [ordered]@{
                    jobId = "/subscriptions/$($script:config.subscriptionId)/resourceGroups/$($script:config.resourceGroupName)/providers/Microsoft.App/jobs/$($script:jobName)"
                    jobName = $script:jobName
                    jobPrincipalId = $script:jobPrincipalId
                    jobImage = $script:jobImage
                    containerName = 'database-bootstrap'
                    executionIntentId = $script:executionIntentId
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
                -SqlPrivateEndpoint $script:sqlPrivateEndpoint `
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
            Should -Invoke Deploy-GatewayDatabaseBootstrapJob -Times 1 -Exactly -ParameterFilter {
                -not $FreshIntent -and $ExecutionIntentId -ceq $script:executionIntentId -and
                    $ExpectedPrivateEndpointIpv4Address -ceq $script:privateEndpointIpv4Address
            }
            Should -Invoke Invoke-AzJson -Times 0 -Exactly -ParameterFilter {
                $Arguments.Count -ge 3 -and
                [string]$Arguments[0] -ceq 'containerapp' -and
                [string]$Arguments[1] -ceq 'job' -and
                [string]$Arguments[2] -ceq 'start'
            }
        }
    }
}
