#Requires -Version 7.0

Describe 'Bootstrap Admin UI-only upgrade surface' {
    BeforeAll {
        $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $scriptPath = Join-Path $repositoryRoot 'operations/upgrade-bootstrap-admin-ui.ps1'
        $scriptText = Get-Content -LiteralPath $scriptPath -Raw
        $bashText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'gateway') -Raw
        $cmdText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'gateway.cmd') -Raw
        $bicepText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infrastructure/bicep/admin-ui.bicep') -Raw
    }

    It 'is valid PowerShell and requires explicit acceptance' {
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors) | Out-Null
        @($parseErrors) | Should -HaveCount 0
        $scriptText | Should -Match 'if \(-not \$Yes\)'
    }

    It 'maps both public launchers directly to the narrow operations script' {
        $bashText | Should -Match "operations/upgrade-bootstrap-admin-ui\.ps1"
        $bashText | Should -Not -Match "upgrade-admin-ui\) mode="
        $cmdText | Should -Match "operations\\upgrade-bootstrap-admin-ui\.ps1"
        $cmdUpgradeBlock = $cmdText.Substring($cmdText.IndexOf(':run_upgrade'), $cmdText.IndexOf(':help_upgrade') - $cmdText.IndexOf(':run_upgrade'))
        $cmdUpgradeBlock | Should -Not -Match 'bootstrap\\bootstrap\.ps1|Mode=\$env:GATEWAY_MODE'
    }

    It 'records intent before remotely building only gateway-admin' {
        $saveIndex = $scriptText.IndexOf("acceptedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')")
        $buildIndex = $scriptText.LastIndexOf('Resolve-AdminUiBuild -Configuration')
        $saveIndex | Should -BeGreaterThan -1
        $buildIndex | Should -BeGreaterThan $saveIndex
        $scriptText | Should -Match '\$repository = ''gateway-admin'''
        $scriptText | Should -Match "'--file', 'src/Gateway\.AdminUi/Dockerfile'"
        $scriptText | Should -Not -Match "'acr', 'build'.*gateway-(?:api|worker|db-migrator)"
    }

    It 'enforces the exact What-If and same-resource-group deployment boundary' {
        $scriptText | Should -Match "'deployment', 'group', 'what-if'"
        $scriptText | Should -Match '\$changeType -in @\(''Delete'', ''Create''\)'
        $scriptText | Should -Match '-not \$allowed\.Contains\(\$resourceId\)'
        $scriptText | Should -Match 'deployKeyVaultPrivateEndpoint = \$false'
        $scriptText | Should -Match "mode = 'Incremental'"
        $scriptText | Should -Match "Invoke-ArmDeploymentWithSecureParameters"
    }

    It 'preserves bootstrap state and proves API worker and queue counts unchanged' {
        $scriptText | Should -Not -Match 'Save-BootstrapState'
        $scriptText | Should -Match 'acceptedBootstrapPlanRecordFingerprint'
        $scriptText | Should -Match 'ca-gateway-api-'
        $scriptText | Should -Match 'ca-gateway-worker-.*-v3'
        $scriptText | Should -Match 'Get-QueueCountSnapshot'
        $scriptText | Should -Match 'queueCountsAfter'
        $scriptText | Should -Not -Match "servicebus.*(?:peek|receive|purge|delete)"
    }

    It 'keeps original bootstrap provenance and adds upgrade provenance only to Admin UI resources' {
        $bicepText | Should -Match 'param adminUiUpgradeSourceFingerprint string'
        $bicepText | Should -Match 'tags: adminUiTags'
        $bicepText | Should -Match "module keyVaultPrivateEndpoint[\s\S]*?tags: tags"
        $bicepText | Should -Match 'output adminUiUpgradeSourceFingerprint string'
    }

    It 'uses only Entra and managed identity boundaries and writes safe ignored evidence' {
        $scriptText | Should -Match 'adminUserEnabled'
        $scriptText | Should -Match 'azureADAuthenticationAsArmPolicy'
        $scriptText | Should -Match 'enableRbacAuthorization'
        $scriptText | Should -Match 'managedIdentityRegistryPull'
        $scriptText | Should -Match '\.bootstrap/evidence/.*admin-ui-upgrade'
        $scriptText | Should -Not -Match '(?i)Get-Content[^\r\n]*\.secrets|list-keys|show-secret|secret\s+show'
    }
}
