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
        $module | Should -Match "'-DeploymentOwnershipId'"
        $module | Should -Match "'-AcceptedSourceFingerprint'"
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
        $pristinePosition = $source.IndexOf('ReadPristineDatabaseSurfaceAsync(connection)', [StringComparison]::Ordinal)
        $writePosition = $source.IndexOf('WriteDatabaseInitializationMarkerAsync(connection, expectedMarker)', [StringComparison]::Ordinal)

        $pristinePosition | Should -BeGreaterThan -1
        $writePosition | Should -BeGreaterThan $pristinePosition
        $source | Should -Match 'FROM sys\.triggers WHERE is_ms_shipped = 0'
        $source | Should -Match 'FROM sys\.synonyms'
        $source | Should -Match 'FROM sys\.sequences'
        $source | Should -Match 'FROM sys\.database_role_members'
        $source | Should -Match 'catalog_collation_type_desc'
        $source | Should -Match 'DatabaseOwnerSidSha256'
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
