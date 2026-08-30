Describe 'Azure SQL temporary firewall cleanup proof' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $tokens = $null
        $parseErrors = $null
        $migrationAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:RepositoryRoot 'tools/apply-migrations.ps1'),
            [ref]$tokens,
            [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw 'Migration script did not parse for SQL network recovery tests.' }
        foreach ($functionName in @('Get-TemporarySqlFirewallRule', 'Get-TemporarySqlFirewallRuleName', 'Remove-TemporarySqlFirewallRuleExact')) {
            $definition = @($migrationAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true))
            if ($definition.Count -ne 1) { throw "Expected one $functionName definition in migration script." }
            . ([scriptblock]::Create($definition[0].Extent.Text))
        }
        function Invoke-AzCommand {
            param([string[]]$Arguments, [string]$ErrorMessage)
        }
    }

    BeforeEach {
        Mock Start-Sleep { }
    }

    It 'does not translate an unavailable Azure list into proven absence' {
        Mock Invoke-AzCommand {
            throw 'private-provider-body-marker'
        }

        try {
            Get-TemporarySqlFirewallRule -ResourceGroupName 'rg-safe' -ServerName 'sql-safe' -RuleName 'temp-a365gw-migration-111111111111111111111111'
            throw 'Expected unavailable discovery to fail.'
        }
        catch {
            $_.Exception.Message | Should -BeLike '*discovery was unavailable; absence was not proven*'
            $_.Exception.Message | Should -Not -Match 'private-provider-body-marker'
        }
    }

    It 'binds the exact cleanup rule to operation, resource group, server, and database' {
        $operationId = [guid]'11111111-1111-4111-8111-111111111111'
        $first = Get-TemporarySqlFirewallRuleName -OperationId $operationId -ResourceGroupName 'rg-safe' -ServerName 'sql-safe' -TargetDatabaseName 'GatewayDb'
        $same = Get-TemporarySqlFirewallRuleName -OperationId $operationId -ResourceGroupName 'RG-SAFE' -ServerName 'SQL-SAFE' -TargetDatabaseName 'gatewaydb'
        $different = Get-TemporarySqlFirewallRuleName -OperationId $operationId -ResourceGroupName 'rg-other' -ServerName 'sql-safe' -TargetDatabaseName 'GatewayDb'

        $first | Should -Match '^temp-a365gw-migration-[0-9a-f]{24}$'
        $same | Should -Be $first
        $different | Should -Not -Be $first
    }

    It 'requires recovery metadata to match the current operation and exact derived rule before deletion' {
        $source = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tools/apply-migrations.ps1') -Raw

        $source | Should -Match "recovery\.operationId.+NetworkOperationId"
        $source | Should -Match "recovery\.firewallRuleName.+firewallRuleName"
        $source | Should -Match 'RequireInitiallyDisabledPublicNetwork'
    }

    It 'binds bootstrap network recovery and the migrator child to ownership and accepted source' {
        $source = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tools/apply-migrations.ps1') -Raw
        $module = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'bootstrap/modules/Database.psm1') -Raw

        $source | Should -Match 'recovery\.deploymentOwnershipId.+DeploymentOwnershipId'
        $source | Should -Match 'recovery\.acceptedSourceFingerprint.+AcceptedSourceFingerprint'
        $source | Should -Match "'--deployment-ownership-id'"
        $source | Should -Match "'--accepted-source-fingerprint'"
        $source | Should -Match "'--expected-api-principal-name'"
        $source | Should -Match "'--expected-worker-principal-client-id'"
        $source | Should -Match "'--require-all-expected-principals-after-mutation'"
        $module | Should -Match "'--deployment-ownership-id'"
        $module | Should -Match "'--accepted-source-fingerprint'"
        $module | Should -Not -Match "'-TemporarilyEnablePublicNetwork'"
    }

    It 'preserves all principal and bootstrap binding flags as independent Booleans' {
        $path = Join-Path $script:RepositoryRoot 'tools/apply-migrations.ps1'
        $source = Get-Content -LiteralPath $path -Raw
        $start = $source.IndexOf('[bool[]]$principalArgumentsProvided = @(', [StringComparison]::Ordinal)
        $end = $source.IndexOf("if (`$Phase -eq 'Initialize' -and `$NetworkOperationId", $start, [StringComparison]::Ordinal)
        $start | Should -BeGreaterOrEqual 0
        $end | Should -BeGreaterThan $start
        $bindingSource = $source.Substring($start, $end - $start)
        $runner = [scriptblock]::Create(@"
param(
    [string]`$ApiPrincipalName,
    [guid]`$ApiPrincipalClientId,
    [string]`$WorkerPrincipalName,
    [guid]`$WorkerPrincipalClientId,
    [guid]`$DeploymentOwnershipId,
    [string]`$AcceptedSourceFingerprint,
    [string]`$Phase
)
Set-StrictMode -Version Latest
$bindingSource
return [ordered]@{
    principalArrayCount = `$principalArgumentsProvided.Count
    principalProvidedCount = `$principalArgumentCount
    bootstrapArrayCount = `$bootstrapBindingArgumentsProvided.Count
    bootstrapProvidedCount = `$bootstrapBindingArgumentCount
    hasBootstrapDatabaseBinding = `$hasBootstrapDatabaseBinding
}
"@)
        $arguments = @{
            ApiPrincipalName = 'ca-gateway-api-dev'
            ApiPrincipalClientId = [guid]'11111111-1111-4111-8111-111111111111'
            WorkerPrincipalName = 'ca-gateway-worker-dev-v3'
            WorkerPrincipalClientId = [guid]'22222222-2222-4222-8222-222222222222'
            DeploymentOwnershipId = [guid]'33333333-3333-4333-8333-333333333333'
            AcceptedSourceFingerprint = "sha256:$('a' * 64)"
            Phase = 'Initialize'
        }

        $result = & $runner @arguments

        $result.principalArrayCount | Should -Be 4
        $result.principalProvidedCount | Should -Be 4
        $result.bootstrapArrayCount | Should -Be 2
        $result.bootstrapProvidedCount | Should -Be 2
        $result.hasBootstrapDatabaseBinding | Should -BeTrue

        ([regex]::Matches($source, '\$principalArgumentCount -eq 4')).Count | Should -Be 2
        ([regex]::Matches($source, '\$principalArgumentCount = @\(\$principalArgumentsProvided \| Where-Object \{ \$_ \}\)\.Count')).Count | Should -Be 1
        ([regex]::Matches($source, '\$bootstrapBindingArgumentCount = @\(\$bootstrapBindingArgumentsProvided \| Where-Object \{ \$_ \}\)\.Count')).Count | Should -Be 1
        $source | Should -Not -Match '\(\$principalArgumentsProvided \| Where-Object \{ \$_ \}\)\.Count\s+-eq'

        foreach ($missingName in @('ApiPrincipalName', 'ApiPrincipalClientId', 'WorkerPrincipalName', 'WorkerPrincipalClientId')) {
            $invalid = @{} + $arguments
            $invalid[$missingName] = if ($missingName.EndsWith('ClientId', [StringComparison]::Ordinal)) { [guid]::Empty } else { '' }
            { & $runner @invalid } | Should -Throw '*principal names/client IDs must be supplied together*'
        }
        $missingSource = @{} + $arguments
        $missingSource.AcceptedSourceFingerprint = ''
        { & $runner @missingSource } | Should -Throw '*DeploymentOwnershipId and AcceptedSourceFingerprint must be supplied together*'
    }

    It 'writes and revalidates the durable database marker before EF schema mutation' {
        $source = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tools/Gateway.DatabaseMigrator/Program.cs') -Raw
        $contract = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tools/Gateway.DatabaseMigrator/DatabaseBootstrapRecoveryContract.cs') -Raw
        $writePosition = $source.IndexOf('WriteDatabaseInitializationMarkerAsync(connection, expectedMarker)', [StringComparison]::Ordinal)
        $schemaPosition = $source.IndexOf('context.Database.EnsureCreatedAsync()', [StringComparison]::Ordinal)

        $writePosition | Should -BeGreaterThan -1
        $schemaPosition | Should -BeGreaterThan $writePosition
        $source | Should -Match 'sp_addextendedproperty'
        $source | Should -Match 'sp_getapplock'
        $contract | Should -Match 'ResumeAfterSchemaCompleted'
    }

    It 'proves the full pristine surface before writing the initialization marker' {
        $source = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tools/Gateway.DatabaseMigrator/Program.cs') -Raw
        $contract = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tools/Gateway.DatabaseMigrator/DatabaseBootstrapRecoveryContract.cs') -Raw
        $initializationStart = $source.IndexOf('static async Task<InitializationIntentEvidence> EnsureEmptyDatabaseInitializedUnderLockAsync(', [StringComparison]::Ordinal)
        $pristinePosition = $source.IndexOf('ReadPristineDatabaseSurfaceAfterAuditConvergenceAsync(connection)', $initializationStart, [StringComparison]::Ordinal)
        $writePosition = $source.IndexOf('WriteDatabaseInitializationMarkerAsync(connection, expectedMarker)', $initializationStart, [StringComparison]::Ordinal)
        $cteMethodStart = $source.IndexOf('static string GetDatabasePermissionTelemetryCteSql()', [StringComparison]::Ordinal)
        $projectionMethodStart = $source.IndexOf('static string GetDatabasePermissionTelemetryProjectionSql()', $cteMethodStart, [StringComparison]::Ordinal)
        $pristineMethodStart = $source.IndexOf('static async Task<PristineDatabaseSurfaceSnapshot> ReadPristineDatabaseSurfaceAsync(', [StringComparison]::Ordinal)
        $pristineMethodEnd = $source.IndexOf('static Task WaitForAzureSqlAuditSpecificationReadinessAsync(', $pristineMethodStart, [StringComparison]::Ordinal)
        $authorityMethodStart = $source.IndexOf('static async Task AssertExpectedDatabaseAuthorityAsync(', [StringComparison]::Ordinal)
        $authorityMethodEnd = $source.IndexOf('static async Task<string> ReadDatabaseCollationAsync(', $authorityMethodStart, [StringComparison]::Ordinal)
        $cteSource = $source.Substring($cteMethodStart, $projectionMethodStart - $cteMethodStart)
        $pristineSource = $source.Substring($pristineMethodStart, $pristineMethodEnd - $pristineMethodStart)
        $authoritySource = $source.Substring($authorityMethodStart, $authorityMethodEnd - $authorityMethodStart)
        $permissionBlockStart = $authoritySource.IndexOf('int unexpectedDirectPermissionCount;', [StringComparison]::Ordinal)
        $permissionBlockEnd = $authoritySource.IndexOf('var observed = principals.Values', $permissionBlockStart, [StringComparison]::Ordinal)
        $postSchemaPermissionSource = $authoritySource.Substring($permissionBlockStart, $permissionBlockEnd - $permissionBlockStart)
        $allowanceStart = $cteSource.IndexOf('CROSS APPLY', [StringComparison]::Ordinal)
        $allowanceEnd = $cteSource.IndexOf(') AS permission_shape', $allowanceStart, [StringComparison]::Ordinal)
        $allowanceSource = $cteSource.Substring($allowanceStart, $allowanceEnd - $allowanceStart)

        $pristinePosition | Should -BeGreaterThan -1
        $writePosition | Should -BeGreaterThan $pristinePosition
        $cteMethodStart | Should -BeGreaterOrEqual 0
        $projectionMethodStart | Should -BeGreaterThan $cteMethodStart
        $authorityMethodStart | Should -BeGreaterOrEqual 0
        $authorityMethodEnd | Should -BeGreaterThan $authorityMethodStart
        $permissionBlockStart | Should -BeGreaterOrEqual 0
        $permissionBlockEnd | Should -BeGreaterThan $permissionBlockStart
        $allowanceStart | Should -BeGreaterOrEqual 0
        $allowanceEnd | Should -BeGreaterThan $allowanceStart
        $source | Should -Match 'FROM sys\.triggers WHERE is_ms_shipped = 0'
        $source | Should -Match 'FROM sys\.synonyms'
        $source | Should -Match 'FROM sys\.sequences'
        $source | Should -Match 'FROM sys\.database_role_members'
        $negativeSystemSelectAllowance = "permissions\.class\s*=\s*1\s+AND\s+permissions\.minor_id\s*=\s*0\s+AND\s+permissions\.permission_name\s*=\s*N'SELECT'\s+AND\s+permissions\.state\s*=\s*N'G'\s+AND\s+grantees\.name\s*=\s*N'public'\s+AND\s+permissions\.major_id\s*<\s*0"
        ([regex]::Matches($cteSource, $negativeSystemSelectAllowance)).Count | Should -Be 1
        $positiveSystemSelectAllowance = "(?s)permissions\.class\s*=\s*1\s+AND\s+permissions\.minor_id\s*=\s*0\s+AND\s+permissions\.permission_name\s*=\s*N'SELECT'\s+AND\s+permissions\.state\s*=\s*N'G'\s+AND\s+grantees\.name\s*=\s*N'public'\s+AND\s+permissions\.major_id\s*=\s*OBJECT_ID\(N'sys\.database_firewall_rules'\)\s+AND\s+permissions\.grantor_principal_id\s*=\s*DATABASE_PRINCIPAL_ID\(N'sys'\)\s+AND\s+EXISTS\s*\(\s*SELECT\s+1\s+FROM\s+sys\.all_objects\s+AS\s+allowed_shipped_objects\s+WHERE\s+allowed_shipped_objects\.object_id\s*=\s*permissions\.major_id\s+AND\s+allowed_shipped_objects\.is_ms_shipped\s*=\s*1\s+AND\s+allowed_shipped_objects\.schema_id\s*=\s*SCHEMA_ID\(N'sys'\)\s+AND\s+allowed_shipped_objects\.type\s*=\s*N'V'\s*\)"
        ([regex]::Matches($cteSource, $positiveSystemSelectAllowance)).Count | Should -Be 1
        $dboConnectAllowance = "(?s)permissions\.class\s*=\s*0\s+AND\s+permissions\.major_id\s*=\s*0\s+AND\s+permissions\.minor_id\s*=\s*0\s+AND\s+permissions\.permission_name\s*=\s*N'CONNECT'\s+AND\s+permissions\.state\s*=\s*N'G'\s+AND\s+grantees\.name\s*=\s*N'dbo'\s+AND\s+permissions\.grantor_principal_id\s*=\s*DATABASE_PRINCIPAL_ID\(N'dbo'\)"
        ([regex]::Matches($cteSource, $dboConnectAllowance)).Count | Should -Be 1
        $contract | Should -Match 'ExpectedPositiveIdPublicSelectTargetCount\s*=\s*1'
        $contract | Should -Match 'ExpectedPositiveIdPublicSelectMsShippedObjectTargetCount\s*=\s*1'
        $contract | Should -Match 'ExpectedPositiveIdPublicSelectMsShippedSystemCatalogTargetCount\s*=\s*0'
        $contract | Should -Match 'ExpectedPositiveIdPublicSelectMsShippedDatabaseObjectOnlyTargetCount\s*=\s*1'
        $contract | Should -Match '(?s)var baselineMismatch\s*=.*?positiveIdPublicSelectTargetCount\s*==\s*ExpectedPositiveIdPublicSelectTargetCount.*?positiveIdPublicSelectMsShippedObjectTargetCount\s*==\s*ExpectedPositiveIdPublicSelectMsShippedObjectTargetCount.*?positiveIdPublicSelectMsShippedSystemCatalogTargetCount\s*==\s*ExpectedPositiveIdPublicSelectMsShippedSystemCatalogTargetCount.*?positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargetCount\s*==\s*ExpectedPositiveIdPublicSelectMsShippedDatabaseObjectOnlyTargetCount.*?positiveIdPublicSelectNonMsShippedOrUnresolvedTargetCount\s*==\s*0'
        $source | Should -Match "(?s)HASHBYTES\(N'SHA2_256', CONVERT\(varbinary\(max\), name\)\)\s*=\s*0xe0f4f7f5e21d49507cf14e0bf1bc6f6b43e7085aaf424fc68e81b33e4ff2ec26.*?is_state_enabled = 1.*?audit_guid IS NOT NULL.*?audit_guid <> CAST\(N'00000000-0000-0000-0000-000000000000' AS uniqueidentifier\).*?NOT EXISTS \(SELECT 1 FROM sys\.database_audit_specification_details\)"
        $pristineSource | Should -Match 'DatabaseDirectPermissionTelemetry\.FromOrderedCounts\(permissionCounts\)'
        $postSchemaPermissionSource | Should -Match 'DatabaseDirectPermissionTelemetry\.FromOrderedCounts\(permissionCounts\)'
        ([regex]::Matches($pristineSource, 'GetDatabasePermissionTelemetryCteSql\(\)')).Count | Should -Be 1
        ([regex]::Matches($pristineSource, 'GetDatabasePermissionTelemetryProjectionSql\(\)')).Count | Should -Be 1
        ([regex]::Matches($postSchemaPermissionSource, 'GetDatabasePermissionTelemetryCteSql\(\)')).Count | Should -Be 1
        ([regex]::Matches($postSchemaPermissionSource, 'GetDatabasePermissionTelemetryProjectionSql\(\)')).Count | Should -Be 1
        $pristineSource | Should -Match 'AddWithValue\("@allowMetadataPrincipalViewDefinition", 0\)'
        $postSchemaPermissionSource | Should -Match 'AddWithValue\("@allowMetadataPrincipalViewDefinition", 1\)'
        $allowanceSource | Should -Not -Match 'VIEW ANY COLUMN (MASTER|ENCRYPTION) KEY DEFINITION'
        ([regex]::Matches($cteSource, "WHEN N'VIEW ANY COLUMN MASTER KEY DEFINITION' THEN 4")).Count | Should -Be 1
        ([regex]::Matches($cteSource, "WHEN N'VIEW ANY COLUMN ENCRYPTION KEY DEFINITION' THEN 5")).Count | Should -Be 1
        $source | Should -Match "roles\.name = N'db_owner'\s+AND\s+roles\.is_fixed_role = 1\s+AND\s+members\.name = N'dbo'\s+AND\s+members\.principal_id = DATABASE_PRINCIPAL_ID\(N'dbo'\)"
        $source | Should -Match 'SELECT CASE WHEN COUNT\(\*\) = 1 THEN 0 ELSE 1 END'
        $source | Should -Match 'roleName\.Equals\("db_owner", StringComparison\.Ordinal\)'
        $source | Should -Match 'memberName\.Equals\("dbo", StringComparison\.Ordinal\)'
        $source | Should -Match 'builtInDboOwnerMembershipCount != 1'
        $source | Should -Match 'catalog_collation_type_desc'
        $source | Should -Match 'DatabaseOwnerSidSha256'
    }

    It 'bounds the exact count-only Azure SQL audit-specification readiness transition' {
        $source = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tools/Gateway.DatabaseMigrator/Program.cs') -Raw
        $contract = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tools/Gateway.DatabaseMigrator/DatabaseBootstrapRecoveryContract.cs') -Raw
        $convergenceStart = $source.IndexOf('ReadPristineDatabaseSurfaceAfterAuditConvergenceAsync', [StringComparison]::Ordinal)
        $fullReadStart = $source.IndexOf('static async Task<PristineDatabaseSurfaceSnapshot> ReadPristineDatabaseSurfaceAsync(', $convergenceStart, [StringComparison]::Ordinal)
        $waitStart = $source.IndexOf('static Task WaitForAzureSqlAuditSpecificationReadinessAsync(', $fullReadStart, [StringComparison]::Ordinal)
        $readinessReadStart = $source.IndexOf('static async Task<AzureSqlAuditSpecificationReadinessSnapshot>', $waitStart, [StringComparison]::Ordinal)
        $platformDiagnosticStart = $source.IndexOf('static async Task<AzureSqlPristinePlatformDiagnostic>', $readinessReadStart, [StringComparison]::Ordinal)

        $convergenceStart | Should -BeGreaterOrEqual 0
        $fullReadStart | Should -BeGreaterThan $convergenceStart
        $waitStart | Should -BeGreaterThan $fullReadStart
        $readinessReadStart | Should -BeGreaterThan $waitStart
        $platformDiagnosticStart | Should -BeGreaterThan $readinessReadStart

        $readinessReadSource = $source.Substring(
            $readinessReadStart,
            $platformDiagnosticStart - $readinessReadStart)
        $expectedAliases = @(
            'auditSpecificationsTotal',
            'auditSpecificationsExpectedNameHashMatches',
            'auditSpecificationsEnabled',
            'auditSpecificationsDisabled',
            'auditSpecificationsNullGuid',
            'auditSpecificationsZeroGuid',
            'auditSpecificationsNonzeroGuid',
            'auditDetailsTotal'
        )
        $actualAliases = @([regex]::Matches(
                $readinessReadSource,
                '(?m)\) AS ([A-Za-z][A-Za-z0-9]+),?\s*$') |
            ForEach-Object { $_.Groups[1].Value })
        ($actualAliases -join ',') | Should -Be ($expectedAliases -join ',')
        $readinessReadSource | Should -Match 'COUNT\(\*\) AS auditSpecificationsTotal'
        ([regex]::Matches($readinessReadSource, 'COUNT\(CASE WHEN')).Count | Should -Be 6
        $readinessReadSource | Should -Match '\(SELECT COUNT\(\*\) FROM sys\.database_audit_specification_details\) AS auditDetailsTotal'
        $readinessReadSource | Should -Not -Match '(?im)^\s*SELECT\s+(?:name|audit_guid|is_state_enabled)\b'
        $readinessReadSource | Should -Not -Match 'Console\.Write'
        ([regex]::Matches(
                $source,
                '0xe0f4f7f5e21d49507cf14e0bf1bc6f6b43e7085aaf424fc68e81b33e4ff2ec26')).Count | Should -Be 2

        $contract | Should -Match '(?s)TotalCount == 1.*?ExpectedNameHashMatchCount == 1.*?EnabledCount == 1.*?DisabledCount == 0.*?NullGuidCount == 0.*?ZeroGuidCount == 0.*?NonzeroGuidCount == 1.*?DetailCount == 0'
        $contract | Should -Match 'snapshot\.Counts\.All\(count => count == 0\)'
        $contract | Should -Match '(?s)exactRowPending.*?TotalCount == 1.*?ExpectedNameHashMatchCount == 1.*?DetailCount == 0.*?EnabledCount \+ snapshot\.DisabledCount == 1.*?NullGuidCount \+ snapshot\.ZeroGuidCount \+ snapshot\.NonzeroGuidCount == 1'
        $source | Should -Match 'AzureSqlAuditSpecificationConvergence\.WaitAsync'
        $source | Should -Match 'token => ReadAzureSqlAuditSpecificationReadinessAsync\(connection, token\)'
        $source | Should -Match 'TimeSpan\.FromMinutes\(10\)'
        $source | Should -Match 'TimeSpan\.FromSeconds\(5\)'
        $readinessReadSource | Should -Match 'ExecuteReaderAsync\(cancellationToken\)'
        ([regex]::Matches($readinessReadSource, 'ReadAsync\(cancellationToken\)')).Count | Should -Be 2
        $contract | Should -Match 'Stopwatch\.GetTimestamp\(\)'
        $contract | Should -Match 'Stopwatch\.GetElapsedTime\(startedAt\)'
        $contract | Should -Match 'for \(var attempt = 1; attempt <= maximumAttempts; attempt\+\+\)'
        ([regex]::Matches($contract, 'CancelAfter\(remaining\)')).Count | Should -Be 2
        $contract | Should -Match 'Task\.Delay\(delay, token\)'
        $contract | Should -Match 'cancellationToken\.ThrowIfCancellationRequested\(\)'
        $contract | Should -Match 'did not converge before the bounded monotonic deadline'

        $initializationStart = $source.IndexOf('static async Task<InitializationIntentEvidence> EnsureEmptyDatabaseInitializedUnderLockAsync(', [StringComparison]::Ordinal)
        $initializationEnd = $source.IndexOf('static DatabaseInitializationIntent CreateDatabaseInitializationIntent(', $initializationStart, [StringComparison]::Ordinal)
        $initializationSource = $source.Substring($initializationStart, $initializationEnd - $initializationStart)
        $convergedReadPosition = $initializationSource.IndexOf('ReadPristineDatabaseSurfaceAfterAuditConvergenceAsync(connection)', [StringComparison]::Ordinal)
        $assertPosition = $initializationSource.IndexOf('DatabaseBootstrapRecoveryContract.AssertPristine(pristineSurface)', [StringComparison]::Ordinal)
        $markerPosition = $initializationSource.IndexOf('WriteDatabaseInitializationMarkerAsync(connection, expectedMarker)', [StringComparison]::Ordinal)
        $schemaPosition = $initializationSource.IndexOf('context.Database.EnsureCreatedAsync()', [StringComparison]::Ordinal)
        $convergedReadPosition | Should -BeGreaterOrEqual 0
        $assertPosition | Should -BeGreaterThan $convergedReadPosition
        $markerPosition | Should -BeGreaterThan $assertPosition
        $schemaPosition | Should -BeGreaterThan $markerPosition
        ([regex]::Matches($source, 'ReadPristineDatabaseSurfaceAfterAuditConvergenceAsync\(connection\)')).Count | Should -Be 2
    }

    It 'uses one fixed count-only database permission diagnostic in pristine and post-schema checks' {
        $source = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tools/Gateway.DatabaseMigrator/Program.cs') -Raw
        $contract = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tools/Gateway.DatabaseMigrator/DatabaseBootstrapRecoveryContract.cs') -Raw

        $contract | Should -Match 'SumChecked\(categoryCounts\)'
        $contract | Should -Match 'surface\.UnexpectedObjectCount\s*==\s*0'
        $contract | Should -Match 'catalog=\[\{surface\.CatalogSurface\.ToSafeSummary\(\)\}\]'
        $source | Should -Match 'reader\.GetName\(index\)\.Equals\(expectedFieldNames\[index\], StringComparison\.Ordinal\)'

        $categoryStart = $contract.IndexOf('private static readonly string[] FixedCategoryNames', [StringComparison]::Ordinal)
        $categoryEnd = $contract.IndexOf('private static readonly string[] FixedProgrammableObjectTypeNames', $categoryStart, [StringComparison]::Ordinal)
        $categoryStart | Should -BeGreaterOrEqual 0
        $categoryEnd | Should -BeGreaterThan $categoryStart
        $categorySource = $contract.Substring($categoryStart, $categoryEnd - $categoryStart)
        ([regex]::Matches($categorySource, '(?m)^\s*"[A-Za-z][A-Za-z0-9]+",?\s*$')).Count | Should -Be 24

        $typeStart = $categoryEnd
        $typeEnd = $contract.IndexOf('private static readonly string[] FixedSqlFieldNames', $typeStart, [StringComparison]::Ordinal)
        $typeEnd | Should -BeGreaterThan $typeStart
        $typeSource = $contract.Substring($typeStart, $typeEnd - $typeStart)
        ([regex]::Matches($typeSource, '(?m)^\s*"[A-Za-z][A-Za-z0-9]+",?\s*$')).Count | Should -Be 9
        $contract | Should -Match '\.\. FixedCategoryNames'
        $contract | Should -Match '\.\. FixedProgrammableObjectTypeNames'

        $projectionStart = $source.IndexOf('static string GetUnexpectedDatabaseSurfaceProjectionSql()', [StringComparison]::Ordinal)
        $projectionEnd = $source.IndexOf('static string GetDatabasePermissionTelemetryCteSql()', $projectionStart, [StringComparison]::Ordinal)
        $projectionStart | Should -BeGreaterOrEqual 0
        $projectionEnd | Should -BeGreaterThan $projectionStart
        $projectionSource = $source.Substring($projectionStart, $projectionEnd - $projectionStart)
        $projectionSource | Should -Not -Match 'sys\.system_objects'
        $projectionSource | Should -Not -Match '(?im)^\s*SELECT\s+(?:[A-Za-z_][A-Za-z0-9_]*\.)?(?:name|object_id|principal_id|sid)\b'
        $projectionSource | Should -Not -Match 'Console\.Write'

        $expectedCatalogAliases = @(
            'programmableObjects', 'triggers', 'synonyms', 'sequences', 'externalTables',
            'externalDataSources', 'externalFileFormats', 'databaseScopedCredentials', 'columnMasterKeys',
            'columnEncryptionKeys', 'userAssemblies', 'userDefinedOrTableTypes', 'partitionFunctions',
            'partitionSchemes', 'fullTextCatalogs', 'fullTextIndexes', 'userXmlSchemaCollections',
            'databaseAuditSpecifications', 'securityPolicies', 'databaseFirewallRules', 'changeTrackingTables',
            'temporalPeriods', 'sensitivityClassifications', 'extendedProperties', 'views', 'sqlStoredProcedures',
            'clrStoredProcedures', 'sqlScalarFunctions', 'sqlInlineTableValuedFunctions',
            'sqlTableValuedFunctions', 'clrScalarFunctions', 'clrTableValuedFunctions', 'aggregateFunctions'
        )
        $catalogAliases = @([regex]::Matches($projectionSource, '\)\s+AS\s+([A-Za-z][A-Za-z0-9]+)') |
            ForEach-Object { $_.Groups[1].Value })
        ($catalogAliases -join ',') | Should -Be ($expectedCatalogAliases -join ',')

        [string[]]$expectedPermissionAliases = @(
            'rawNonWhitelistedDirectPermissions',
            'positiveIdPublicSelectTargets',
            'positiveIdPublicSelectMsShippedObjectTargets',
            'positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelations',
            'positiveIdPublicSelectMsShippedSystemCatalogTargets',
            'positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargets',
            'positiveIdPublicSelectNonMsShippedOrUnresolvedTargets'
        )
        $expectedPermissionAliases += @('DatabasePermissions', 'ObjectOrColumnPermissions', 'OtherPermissions') |
            ForEach-Object { "rawClass$_" }
        $expectedPermissionAliases += @('GrantPermissions', 'GrantWithGrantOptionPermissions', 'DenyPermissions', 'RevokePermissions', 'OtherPermissions') |
            ForEach-Object { "rawState$_" }
        $expectedPermissionAliases += @('PublicPermissions', 'GuestPermissions', 'DboPermissions', 'FixedRolePermissions', 'OtherPermissions') |
            ForEach-Object { "rawGrantee$_" }
        $expectedPermissionAliases += @(
            'rawPermissionNameConnect',
            'rawPermissionNameSelect',
            'rawPermissionNameViewDefinition',
            'rawPermissionNameViewAnyColumnMasterKeyDefinition',
            'rawPermissionNameViewAnyColumnEncryptionKeyDefinition',
            'rawPermissionNameOther'
        )
        $expectedPermissionAliases += @('Database', 'NegativeObject', 'ZeroObject', 'PositiveObject', 'Column', 'Other') |
            ForEach-Object { "rawAddress$_" }
        $expectedPermissionAliases += @('rawGrantorDbo', 'rawGrantorOther')
        $targetTypeSuffixes = @(
            'AggregateFunctions', 'CheckConstraints', 'DefaultConstraints', 'EdgeConstraints', 'ExternalTables',
            'ForeignKeys', 'SqlScalarFunctions', 'ClrScalarFunctions', 'ClrTableValuedFunctions',
            'SqlInlineTableValuedFunctions', 'InternalTables', 'SqlStoredProcedures', 'ClrStoredProcedures',
            'PlanGuides', 'PrimaryKeys', 'Rules', 'ReplicationFilterProcedures', 'SystemTables', 'Synonyms',
            'Sequences', 'ServiceQueues', 'StatisticsTrees', 'ClrDmlTriggers', 'SqlTableValuedFunctions',
            'SqlDmlTriggers', 'TableTypes', 'UserTables', 'UniqueConstraints', 'Views',
            'ExtendedStoredProcedures', 'OtherOrUnresolved'
        )
        $expectedPermissionAliases += $targetTypeSuffixes | ForEach-Object { "positiveIdPublicSelectType$_" }
        $expectedPermissionAliases += @('Sys', 'Dbo', 'OtherOrUnresolved') |
            ForEach-Object { "positiveIdPublicSelectSchema$_" }
        $expectedPermissionAliases += @('Parentless', 'Parented', 'ParentUnresolved') |
            ForEach-Object { "positiveIdPublicSelect$_" }
        $specializedCatalogSuffixes = @(
            'Views', 'Procedures', 'SqlModules', 'Tables', 'InternalTables', 'Sequences', 'Synonyms', 'Triggers'
        )
        $expectedPermissionAliases += $specializedCatalogSuffixes |
            ForEach-Object { "positiveIdPublicSelectIn$_" }
        $expectedPermissionAliases += @(
            'positiveIdPublicSelectWithSpecializedCatalogMembership',
            'positiveIdPublicSelectWithoutSpecializedCatalogMembership'
        )

        $permissionCteStart = $source.IndexOf('static string GetDatabasePermissionTelemetryCteSql()', [StringComparison]::Ordinal)
        $permissionProjectionStart = $source.IndexOf('static string GetDatabasePermissionTelemetryProjectionSql()', $permissionCteStart, [StringComparison]::Ordinal)
        $permissionProjectionEnd = $source.IndexOf('static async Task<UnexpectedDatabaseSurfaceTelemetry> ReadUnexpectedDatabaseSurfaceTelemetryAsync(', $permissionProjectionStart, [StringComparison]::Ordinal)
        $permissionCteStart | Should -BeGreaterOrEqual 0
        $permissionProjectionStart | Should -BeGreaterThan $permissionCteStart
        $permissionProjectionEnd | Should -BeGreaterThan $permissionProjectionStart
        $permissionCteSource = $source.Substring($permissionCteStart, $permissionProjectionStart - $permissionCteStart)
        $permissionProjectionSource = $source.Substring($permissionProjectionStart, $permissionProjectionEnd - $permissionProjectionStart)
        ([regex]::Matches($permissionCteSource, 'WITH databasePermissionTelemetry AS')).Count | Should -Be 1

        $permissionProjectionMatches = [regex]::Matches(
            $permissionProjectionSource,
            '(?m)^\s*COUNT\(CASE WHEN [^\r\n]+ THEN 1 END\) AS ([A-Za-z][A-Za-z0-9]+),?\s*$')
        $permissionProjectionAliases = @($permissionProjectionMatches | ForEach-Object { $_.Groups[1].Value })
        $permissionProjectionMatches.Count | Should -Be $expectedPermissionAliases.Count
        ($permissionProjectionAliases -join ',') | Should -Be ($expectedPermissionAliases -join ',')
        $permissionProjectionSource | Should -Not -Match 'SELECT COUNT\(\*\) FROM databasePermissionTelemetry'
        $permissionProjectionSource | Should -Not -Match '(?i)\b(?:SUM|COALESCE|COUNT_BIG)\s*\('
        $permissionProjectionSource | Should -Not -Match '(?i)\b(?:DISTINCT|ELSE|GROUP\s+BY|HAVING|UNION)\b'
        $permissionProjectionSource | Should -Not -Match '(?i)\b(?:name|object_id|principal_id|sid|permission_name|major_id|minor_id|grantor_principal_id)\b'
        $permissionProjectionSource | Should -Not -Match 'Console\.Write'

        $permissionFieldArraysStart = $contract.IndexOf('private static readonly string[] FixedLeadingFieldNames', [StringComparison]::Ordinal)
        $permissionFieldArraysEnd = $contract.IndexOf('private static readonly string[] FixedSqlFieldNames', $permissionFieldArraysStart, [StringComparison]::Ordinal)
        $permissionFieldArraysStart | Should -BeGreaterOrEqual 0
        $permissionFieldArraysEnd | Should -BeGreaterThan $permissionFieldArraysStart
        $permissionFieldArraysSource = $contract.Substring($permissionFieldArraysStart, $permissionFieldArraysEnd - $permissionFieldArraysStart)
        $contractPermissionAliases = @([regex]::Matches($permissionFieldArraysSource, '(?m)^\s*"([A-Za-z][A-Za-z0-9]+)",?\s*$') |
            ForEach-Object { $_.Groups[1].Value })
        ($contractPermissionAliases -join ',') | Should -Be ($expectedPermissionAliases -join ',')

        foreach ($rawPartition in @(
                'FixedRawClassFieldNames',
                'FixedRawStateFieldNames',
                'FixedRawGranteeFieldNames',
                'FixedRawPermissionNameFieldNames',
                'FixedRawAddressFieldNames',
                'FixedRawGrantorFieldNames')) {
            $contract | Should -Match "ValidateExactPartition\(counts, ref cursor, $rawPartition\.Length, rawNonWhitelistedCount\)"
        }
        foreach ($targetPartition in @(
                'FixedPositiveTargetTypeFieldNames',
                'FixedPositiveTargetSchemaFieldNames',
                'FixedPositiveTargetParentFieldNames')) {
            $contract | Should -Match "ValidateExactPartition\(counts, ref cursor, $targetPartition\.Length, positiveIdPublicSelectTargetCount\)"
        }
        $contract | Should -Match '(?s)specializedMembershipCount\s*\+\s*noSpecializedMembershipCount\)\s*!=\s*positiveIdPublicSelectTargetCount'
        $contract | Should -Match '(?s)counts\[index\]\s*>\s*specializedMembershipCount.*?specializedCorrelationTotal\s*=\s*checked\(specializedCorrelationTotal\s*\+\s*counts\[index\]\)'
        $contract | Should -Match 'specializedMembershipCount\s*>\s*specializedCorrelationTotal'

        foreach ($bucketAlias in @(
                'raw_class_bucket',
                'raw_state_bucket',
                'raw_grantee_bucket',
                'raw_permission_name_bucket',
                'raw_address_bucket',
                'raw_grantor_bucket',
                'positive_target_origin_bucket',
                'positive_target_type_bucket',
                'positive_target_schema_bucket',
                'positive_target_parent_bucket',
                'has_positive_target_specialized_catalog_membership')) {
            $permissionCteSource | Should -Match "END AS $bucketAlias"
        }
        $permissionCteSource | Should -Not -Match '(?im)^\s*(?:SELECT|,)\s+(?:permissions|grantees|target_[A-Za-z0-9_]+)\.(?:name|object_id|principal_id|sid|permission_name|major_id|minor_id|grantor_principal_id)\s*(?:AS\s+|,|$)'
        $permissionCteSource | Should -Match '(?s)FROM sys\.system_objects AS system_catalog_objects.*?system_catalog_objects\.is_ms_shipped = 1.*?THEN 1.*?FROM sys\.objects AS shipped_database_objects.*?shipped_database_objects\.is_ms_shipped = 1.*?THEN 2.*?ELSE 3.*?END AS positive_target_origin_bucket'
        $permissionCteSource | Should -Match '(?s)permissions\.class = 0.*?THEN 1.*?permissions\.class = 1.*?THEN 2.*?ELSE 3.*?END AS raw_class_bucket'
        $permissionCteSource | Should -Match "(?s)CASE permissions\.state.*?WHEN N'G' THEN 1.*?WHEN N'W' THEN 2.*?WHEN N'D' THEN 3.*?WHEN N'R' THEN 4.*?ELSE 5.*?END AS raw_state_bucket"
        $permissionCteSource | Should -Match "(?s)grantees\.name = N'public' THEN 1.*?grantees\.name = N'guest' THEN 2.*?grantees\.name = N'dbo' THEN 3.*?grantees\.is_fixed_role = 1 THEN 4.*?ELSE 5.*?END AS raw_grantee_bucket"
        $permissionCteSource | Should -Match "(?s)CASE permissions\.permission_name.*?WHEN N'CONNECT' THEN 1.*?WHEN N'SELECT' THEN 2.*?WHEN N'VIEW DEFINITION' THEN 3.*?WHEN N'VIEW ANY COLUMN MASTER KEY DEFINITION' THEN 4.*?WHEN N'VIEW ANY COLUMN ENCRYPTION KEY DEFINITION' THEN 5.*?ELSE 6.*?END AS raw_permission_name_bucket"
        $permissionCteSource | Should -Match '(?s)permissions\.class = 0\s+AND permissions\.major_id = 0\s+AND permissions\.minor_id = 0 THEN 1.*?permissions\.class = 1\s+AND permissions\.major_id < 0\s+AND permissions\.minor_id = 0 THEN 2.*?permissions\.class = 1\s+AND permissions\.major_id = 0\s+AND permissions\.minor_id = 0 THEN 3.*?permissions\.class = 1\s+AND permissions\.major_id > 0\s+AND permissions\.minor_id = 0 THEN 4.*?permissions\.class = 1\s+AND permissions\.minor_id > 0 THEN 5.*?ELSE 6.*?END AS raw_address_bucket'
        $permissionCteSource | Should -Match "(?s)permissions\.grantor_principal_id = DATABASE_PRINCIPAL_ID\(N'dbo'\) THEN 1.*?ELSE 2.*?END AS raw_grantor_bucket"

        $targetTypeCodes = @(
            'AF', 'C', 'D', 'EC', 'ET', 'F', 'FN', 'FS', 'FT', 'IF', 'IT', 'P', 'PC', 'PG', 'PK',
            'R', 'RF', 'S', 'SN', 'SO', 'SQ', 'ST', 'TA', 'TF', 'TR', 'TT', 'U', 'UQ', 'V', 'X'
        )
        for ($index = 0; $index -lt $targetTypeCodes.Count; $index++) {
            $bucket = $index + 1
            $permissionCteSource | Should -Match "WHEN N'$($targetTypeCodes[$index])' THEN $bucket"
        }
        $permissionCteSource | Should -Match "(?s)WHEN N'X' THEN 30\s+ELSE 31.*?END AS positive_target_type_bucket"
        $permissionCteSource | Should -Match '(?s)SELECT CASE target_schemas\.name\s+WHEN N''sys'' THEN 1\s+WHEN N''dbo'' THEN 2\s+ELSE 3.*?END AS positive_target_schema_bucket'
        $permissionCteSource | Should -Match '(?s)SELECT CASE WHEN target_parent_objects\.parent_object_id = 0 THEN 1 ELSE 2 END.*?3\s*\).*?END AS positive_target_parent_bucket'
        foreach ($specializedCatalog in @('views', 'procedures', 'sql_modules', 'tables', 'internal_tables', 'sequences', 'synonyms', 'triggers')) {
            $permissionCteSource | Should -Match "EXISTS \(SELECT 1 FROM sys\.$specializedCatalog WHERE object_id = permissions\.major_id\)"
        }

        $contract | Should -Match '(?s)positiveIdPublicSelectMsShippedSystemCatalogTargetCount\s*\+\s*positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargetCount\).*?positiveIdPublicSelectMsShippedObjectTargetCount'
        $contract | Should -Match '(?s)positiveIdPublicSelectMsShippedSystemCatalogTargetCount\s*\+\s*positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargetCount\s*\+\s*positiveIdPublicSelectNonMsShippedOrUnresolvedTargetCount\).*?positiveIdPublicSelectTargetCount'

        $pristineStart = $source.IndexOf('static async Task<PristineDatabaseSurfaceSnapshot> ReadPristineDatabaseSurfaceAsync(', [StringComparison]::Ordinal)
        $pristineEnd = $source.IndexOf('static Task WaitForAzureSqlAuditSpecificationReadinessAsync(', $pristineStart, [StringComparison]::Ordinal)
        $pristineStart | Should -BeGreaterOrEqual 0
        $pristineEnd | Should -BeGreaterThan $pristineStart
        $pristineSource = $source.Substring($pristineStart, $pristineEnd - $pristineStart)
        ([regex]::Matches($pristineSource, 'connection\.CreateCommand\(\)')).Count | Should -Be 1
        ([regex]::Matches($pristineSource, 'command\.CommandText\s*=')).Count | Should -Be 1
        ([regex]::Matches($pristineSource, 'ExecuteReaderAsync\(\)')).Count | Should -Be 1
        ([regex]::Matches($pristineSource, 'reader\.ReadAsync\(\)')).Count | Should -Be 2
        ([regex]::Matches($pristineSource, 'GetUnexpectedDatabaseSurfaceProjectionSql\(\)')).Count | Should -Be 1
        ([regex]::Matches($pristineSource, 'GetDatabasePermissionTelemetryCteSql\(\)')).Count | Should -Be 1
        ([regex]::Matches($pristineSource, 'GetDatabasePermissionTelemetryProjectionSql\(\)')).Count | Should -Be 1
        ([regex]::Matches($pristineSource, 'FROM databasePermissionTelemetry;')).Count | Should -Be 1
        $pristineSource | Should -Not -Match 'ReadUnexpectedDatabaseSurfaceTelemetryAsync\(connection\)'
        $pristineSource | Should -Not -Match 'ExecuteScalarAsync\('
        $pristineSource | Should -Match 'AssertExactSqlFieldContract\(\s*reader,\s*PristineDatabaseSurfaceSnapshot\.SqlFieldNames'
        $expectedPristineOnlyAliases = @(
            'userTables', 'unexpectedSchemas', 'unexpectedPrincipals', 'unexpectedRoleMemberships', 'unsafeDatabaseOptions',
            'databaseOwnerMismatches'
        )
        $pristineOnlyAliases = @([regex]::Matches($pristineSource, '\)\s+AS\s+([A-Za-z][A-Za-z0-9]+)') |
            ForEach-Object { $_.Groups[1].Value })
        ($pristineOnlyAliases -join ',') | Should -Be ($expectedPristineOnlyAliases -join ',')
        $pristineSource | Should -Match '(?s)GetUnexpectedDatabaseSurfaceProjectionSql\(\).*?AS userTables.*?AS unexpectedRoleMemberships.*?GetDatabasePermissionTelemetryProjectionSql\(\).*?AS unsafeDatabaseOptions.*?AS databaseOwnerMismatches'
        $contract | Should -Match '(?s)\.\. UnexpectedDatabaseSurfaceTelemetry\.SqlFieldNames,.*?"userTables".*?"unexpectedRoleMemberships".*?\.\. DatabaseDirectPermissionTelemetry\.SqlFieldNames,.*?"unsafeDatabaseOptions".*?"databaseOwnerMismatches"'

        $schemaStart = $source.IndexOf('static async Task<ExactDatabaseSchemaSnapshot> GetActualSchemaContractAsync(', [StringComparison]::Ordinal)
        $schemaEnd = $source.IndexOf('static IReadOnlyCollection<string> GetExpectedIncludedIndexColumns(', $schemaStart, [StringComparison]::Ordinal)
        $schemaStart | Should -BeGreaterOrEqual 0
        $schemaEnd | Should -BeGreaterThan $schemaStart
        $schemaSource = $source.Substring($schemaStart, $schemaEnd - $schemaStart)
        ([regex]::Matches($schemaSource, 'ReadUnexpectedDatabaseSurfaceTelemetryAsync\(connection\)')).Count | Should -Be 1
        $schemaSource | Should -Match 'var unexpectedSurfaceCount\s*=\s*checked\(\s*catalogSurface\.TotalCount\s*\+\s*supplementalUnexpectedSurfaceCount\)'

        $authorityStart = $source.IndexOf('static async Task AssertExpectedDatabaseAuthorityAsync(', [StringComparison]::Ordinal)
        $authorityEnd = $source.IndexOf('static async Task<string> ReadDatabaseCollationAsync(', $authorityStart, [StringComparison]::Ordinal)
        $authoritySource = $source.Substring($authorityStart, $authorityEnd - $authorityStart)
        $permissionBlockStart = $authoritySource.IndexOf('int unexpectedDirectPermissionCount;', [StringComparison]::Ordinal)
        $permissionBlockEnd = $authoritySource.IndexOf('var observed = principals.Values', $permissionBlockStart, [StringComparison]::Ordinal)
        $postSchemaPermissionSource = $authoritySource.Substring($permissionBlockStart, $permissionBlockEnd - $permissionBlockStart)
        ([regex]::Matches($postSchemaPermissionSource, 'connection\.CreateCommand\(\)')).Count | Should -Be 1
        ([regex]::Matches($postSchemaPermissionSource, 'command\.CommandText\s*=')).Count | Should -Be 1
        ([regex]::Matches($postSchemaPermissionSource, 'ExecuteReaderAsync\(\)')).Count | Should -Be 1
        ([regex]::Matches($postSchemaPermissionSource, 'reader\.ReadAsync\(\)')).Count | Should -Be 2
        ([regex]::Matches($postSchemaPermissionSource, 'GetDatabasePermissionTelemetryCteSql\(\)')).Count | Should -Be 1
        ([regex]::Matches($postSchemaPermissionSource, 'GetDatabasePermissionTelemetryProjectionSql\(\)')).Count | Should -Be 1
        ([regex]::Matches($postSchemaPermissionSource, 'FROM databasePermissionTelemetry;')).Count | Should -Be 1
        $postSchemaPermissionSource | Should -Match 'AssertExactSqlFieldContract\(\s*reader,\s*DatabaseDirectPermissionTelemetry\.SqlFieldNames'
        $postSchemaPermissionSource | Should -Match 'DatabaseDirectPermissionTelemetry\.FromOrderedCounts\(permissionCounts\)\.UnexpectedCount'
        $postSchemaPermissionSource | Should -Not -Match 'ExecuteScalarAsync\('
        $source | Should -Not -Match 'ReadDatabasePermissionTelemetryAsync'
    }

    It 'retains one exact bootstrap database Job start call' {
        $module = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'bootstrap/modules/Database.psm1') -Raw

        ([regex]::Matches($module, "'containerapp', 'job', 'start'")).Count | Should -Be 1
    }

    It 'reconciles exact network recovery before database absence or initial-state rejection' {
        $source = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'tools/apply-migrations.ps1') -Raw
        $recoveryPosition = $source.IndexOf('if (Test-Path -LiteralPath $recoveryPath)', [StringComparison]::Ordinal)
        $lostRecordCommentPosition = $source.IndexOf('# Reconcile the deterministic bootstrap-owned rule', [StringComparison]::Ordinal)
        $lostRecordCleanupPosition = $source.IndexOf('Remove-TemporarySqlFirewallRuleExact', $lostRecordCommentPosition, [StringComparison]::Ordinal)
        $initialStateRejectionPosition = $source.IndexOf('if ($RequireInitiallyDisabledPublicNetwork -and $originalPublicNetworkAccess', [StringComparison]::Ordinal)
        $databaseAssertionPosition = $source.IndexOf("'sql', 'db', 'show'", [StringComparison]::Ordinal)

        $recoveryPosition | Should -BeGreaterThan -1
        $lostRecordCleanupPosition | Should -BeGreaterThan $recoveryPosition
        $initialStateRejectionPosition | Should -BeGreaterThan $lostRecordCleanupPosition
        $databaseAssertionPosition | Should -BeGreaterThan $initialStateRejectionPosition
        $source | Should -Match 'no matching recovery record authorized changing the still-public server'
    }

    It 'returns absent only after a successful exact-name list returns zero matches' {
        Mock Invoke-AzCommand { return '[]' }

        $result = Get-TemporarySqlFirewallRule -ResourceGroupName 'rg-safe' -ServerName 'sql-safe' -RuleName 'temp-a365gw-migration-222222222222222222222222'

        $result | Should -BeNullOrEmpty
    }

    It 'deletes the exact rule and proves absence before succeeding' {
        $script:ruleExists = $true
        Mock Invoke-AzCommand {
            if ($script:ruleExists) {
                '[{"name":"temp-a365gw-migration-333333333333333333333333","startIpAddress":"192.0.2.10","endIpAddress":"192.0.2.10"}]'
            }
            else { '[]' }
        } -ParameterFilter { $Arguments -contains 'list' }
        Mock Invoke-AzCommand {
            $script:ruleExists = $false
            return @()
        } -ParameterFilter { $Arguments -contains 'delete' }

        Remove-TemporarySqlFirewallRuleExact -ResourceGroupName 'rg-safe' -ServerName 'sql-safe' -RuleName 'temp-a365gw-migration-333333333333333333333333' | Should -BeTrue

        $script:ruleExists | Should -BeFalse
        Should -Invoke Invoke-AzCommand -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'delete' }
    }

    It 'fails closed when deletion does not become observable' {
        Mock Invoke-AzCommand {
            '[{"name":"temp-a365gw-migration-444444444444444444444444","startIpAddress":"192.0.2.11","endIpAddress":"192.0.2.11"}]'
        } -ParameterFilter { $Arguments -contains 'list' }
        Mock Invoke-AzCommand { return @() } -ParameterFilter { $Arguments -contains 'delete' }

        { Remove-TemporarySqlFirewallRuleExact -ResourceGroupName 'rg-safe' -ServerName 'sql-safe' -RuleName 'temp-a365gw-migration-444444444444444444444444' } |
            Should -Throw '*could not be proven removed*'
    }
}
