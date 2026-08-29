$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Database.psm1') -Force

Describe 'Database bootstrap evidence contract' {
    InModuleScope Database {
        BeforeEach {
            $script:ownershipId = '11111111-1111-4111-8111-111111111111'
            $script:sourceFingerprint = "sha256:$('a' * 64)"
            $script:schemaFingerprint = "sha256:$('b' * 64)"
            $script:api = [pscustomobject]@{
                displayName = 'ca-gateway-api-dev'
                clientId = '22222222-2222-4222-8222-222222222222'
            }
            $script:worker = [pscustomobject]@{
                displayName = 'ca-gateway-worker-dev-v3'
                clientId = '33333333-3333-4333-8333-333333333333'
            }
            $verification = [pscustomobject]@{
                CurrentEfModelReady = $true
                WorkflowV2Ready = $true
                CurrentSchemaFingerprint = $script:schemaFingerprint
            }
            $script:records = @(
                [pscustomobject]@{
                    Phase = 'initialize'
                    Server = 'sql-safe-dev.database.windows.net'
                    Database = 'GatewayDb'
                    Verification = $verification
                    InitializationIntent = [pscustomobject]@{
                        MarkerName = 'A365GatewayBootstrapInitializationIntent'
                        SchemaVersion = 1
                        DeploymentOwnershipId = $script:ownershipId
                        AcceptedSourceFingerprint = $script:sourceFingerprint
                        Server = 'sql-safe-dev.database.windows.net'
                        Database = 'GatewayDb'
                        DatabaseCollation = 'SQL_Latin1_General_CP1_CI_AS'
                        CatalogCollation = 'SQL_Latin1_General_CP1_CI_AS'
                        DatabaseOwnerSidSha256 = "sha256:$('c' * 64)"
                        ExactReadbackVerified = $true
                    }
                },
                [pscustomobject]@{
                    Phase = 'principal'
                    Server = 'sql-safe-dev.database.windows.net'
                    Database = 'GatewayDb'
                    Verification = $verification
                    RuntimePrincipal = [pscustomobject]@{
                        Name = $script:api.displayName
                        ClientId = $script:api.clientId
                        DatabaseRoles = @('db_datawriter', 'db_datareader')
                        DirectPermissions = @('VIEW DEFINITION')
                    }
                },
                [pscustomobject]@{
                    Phase = 'principal'
                    Server = 'sql-safe-dev.database.windows.net'
                    Database = 'GatewayDb'
                    Verification = $verification
                    RuntimePrincipal = [pscustomobject]@{
                        Name = $script:worker.displayName
                        ClientId = $script:worker.clientId
                        DatabaseRoles = @('db_datareader', 'db_datawriter')
                        DirectPermissions = @()
                    }
                }
            )
        }

        It 'accepts one exact marker/schema record and the exact API/worker authority records' {
            $result = Get-GatewayDatabaseEvidenceSummary `
                -Records $script:records `
                -SqlServerFqdn 'sql-safe-dev.database.windows.net' `
                -DeploymentOwnershipId $script:ownershipId `
                -AcceptedSourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api `
                -WorkerPrincipal $script:worker

            $result.schemaFingerprint | Should -Be $script:schemaFingerprint
            $result.initializationIntent.databaseCollation | Should -Be 'SQL_Latin1_General_CP1_CI_AS'
            $result.initializationIntent.catalogCollation | Should -Be 'SQL_Latin1_General_CP1_CI_AS'
            $result.initializationIntent.databaseOwnerSidSha256 | Should -Match '^sha256:[0-9a-f]{64}$'
        }

        It 'rejects any additional worker direct permission' {
            $script:records[2].RuntimePrincipal.DirectPermissions = @('VIEW DEFINITION')

            { Get-GatewayDatabaseEvidenceSummary `
                -Records $script:records `
                -SqlServerFqdn 'sql-safe-dev.database.windows.net' `
                -DeploymentOwnershipId $script:ownershipId `
                -AcceptedSourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api `
                -WorkerPrincipal $script:worker } |
                Should -Throw '*least-privilege*'
        }

        It 'rejects a marker bound to a different accepted source' {
            $script:records[0].InitializationIntent.AcceptedSourceFingerprint = "sha256:$('d' * 64)"

            { Get-GatewayDatabaseEvidenceSummary `
                -Records $script:records `
                -SqlServerFqdn 'sql-safe-dev.database.windows.net' `
                -DeploymentOwnershipId $script:ownershipId `
                -AcceptedSourceFingerprint $script:sourceFingerprint `
                -ApiPrincipal $script:api `
                -WorkerPrincipal $script:worker } |
                Should -Throw '*ownership/source-bound*'
        }
    }
}
