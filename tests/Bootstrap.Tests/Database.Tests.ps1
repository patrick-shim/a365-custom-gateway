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

        It 'builds the exact managed-identity service-principal Graph URL under StrictMode' {
            $script:principalObjectId = '44444444-4444-4444-8444-444444444444'
            $script:principalClientId = '55555555-5555-4555-8555-555555555555'
            Mock Invoke-AzJson {
                [pscustomobject]@{
                    id = $script:principalObjectId
                    appId = $script:principalClientId
                    displayName = 'ca-gateway-api-dev'
                }
            }

            $result = Get-ManagedIdentityClientId -PrincipalObjectId $script:principalObjectId

            $result.objectId | Should -BeExactly $script:principalObjectId
            $result.clientId | Should -BeExactly $script:principalClientId
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                $Arguments.Count -eq 5 -and
                [string]$Arguments[0] -ceq 'rest' -and
                [string]$Arguments[1] -ceq '--method' -and
                [string]$Arguments[2] -ceq 'GET' -and
                [string]$Arguments[3] -ceq '--url' -and
                [string]$Arguments[4] -ceq 'https://graph.microsoft.com/v1.0/servicePrincipals/44444444-4444-4444-8444-444444444444?$select=id,appId,displayName'
            }
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

Describe 'Deployment PowerShell variable parsing contract' {
    BeforeAll {
        $script:DeploymentSourceRepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    }

    It 'rejects ambiguous question-mark variable paths while allowing the automatic status variable' {
        $automaticTokens = $null
        $automaticErrors = $null
        $automaticAst = [Management.Automation.Language.Parser]::ParseInput(
            '$? | Out-Null',
            [ref]$automaticTokens,
            [ref]$automaticErrors)
        @($automaticErrors).Count | Should -Be 0
        @($automaticAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.VariablePath.UserPath -cne '?' -and
            $node.VariablePath.UserPath.Contains('?')
        }, $true)).Count | Should -Be 0

        $bootstrapRoot = Join-Path $script:DeploymentSourceRepositoryRoot 'bootstrap'
        $powerShellFiles = @(
            Get-ChildItem -LiteralPath $bootstrapRoot -Recurse -File |
                Where-Object Extension -in @('.ps1', '.psm1')
            Get-ChildItem -LiteralPath (Join-Path $script:DeploymentSourceRepositoryRoot 'src/Gateway.Purview/Automation') -Recurse -File |
                Where-Object Extension -in @('.ps1', '.psm1')
        )
        foreach ($relativePath in @(
            'tools/apply-migrations.ps1',
            'tools/_common.ps1',
            'tools/configure-workflow-v3-entra.ps1',
            'tools/generate-local-config.ps1',
            'operations/BoundedUserCanaryState.psm1',
            'operations/invoke-bounded-user-canary.ps1',
            'operations/RuntimeImagePull.psm1',
            'operations/test-provisioning-prerequisites.ps1'
        )) {
            $fullPath = Join-Path $script:DeploymentSourceRepositoryRoot $relativePath
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                throw "Required deployment-affecting PowerShell source is missing: $relativePath"
            }
            $powerShellFiles += Get-Item -LiteralPath $fullPath
        }
        $rootGatewayScript = Join-Path $script:DeploymentSourceRepositoryRoot 'gateway.ps1'
        if (Test-Path -LiteralPath $rootGatewayScript -PathType Leaf) {
            $powerShellFiles += Get-Item -LiteralPath $rootGatewayScript
        }
        $powerShellFiles = @($powerShellFiles | Sort-Object FullName -Unique)

        $violations = [Collections.Generic.List[string]]::new()
        foreach ($file in $powerShellFiles) {
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile(
                $file.FullName,
                [ref]$tokens,
                [ref]$parseErrors)
            $relativePath = [IO.Path]::GetRelativePath($script:DeploymentSourceRepositoryRoot, $file.FullName)
            foreach ($parseError in @($parseErrors)) {
                $violations.Add("${relativePath}:$($parseError.Extent.StartLineNumber): parse error: $($parseError.Message)")
            }
            foreach ($variable in @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.VariablePath.UserPath -cne '?' -and
                $node.VariablePath.UserPath.Contains('?')
            }, $true))) {
                $violations.Add("${relativePath}:$($variable.Extent.StartLineNumber): ambiguous variable path '$($variable.VariablePath.UserPath)'")
            }
        }

        ($violations -join [Environment]::NewLine) | Should -BeNullOrEmpty
    }
}
