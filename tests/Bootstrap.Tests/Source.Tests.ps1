Describe 'Public bootstrap helper source boundaries' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    }

    It 'keeps Purview SIT discovery interactive, bounded, and safe-output-only' {
        $path = Join-Path $script:RepositoryRoot 'bootstrap/get-purview-sensitive-information-types.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $path,
            [ref]$tokens,
            [ref]$errors)

        $errors.Count | Should -Be 0
        $parameterNames = @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
        $parameterNames | Should -Be @('TenantId', 'UserPrincipalName')
        $source = $ast.Extent.Text
        $source | Should -Match 'Connect-BootstrapPurview'
        $source | Should -Match 'Get-BootstrapPurviewSensitiveInformationTypes'
        $source | Should -Not -Match 'Connect-BootstrapPurview(?s:.){0,250}-(?:AccessToken|Device)'
        $source | Should -Match 'schemaVersion\s*=\s*1'
        $source | Should -Match 'tenantId\s*=\s*\$canonicalTenantId'
        $source | Should -Match 'types\s*=\s*@\('
        $source | Should -Match 'id\s*=\s*\[string\]\$_\.id'
        $source | Should -Match 'name\s*=\s*\[string\]\$_\.name'
        $source | Should -Match 'publisher\s*=\s*\[string\]\$_\.publisher'
        $source | Should -Not -Match '\$_.Exception|ErrorDetails|ScriptStackTrace|providerItems'
    }

    It 'enumerates the full tenant SIT catalog without an Identity lookup' {
        $path = Join-Path $script:RepositoryRoot 'bootstrap/modules/Purview.psm1'
        $source = Get-Content -LiteralPath $path -Raw

        $source | Should -Match 'Get-DlpSensitiveInformationType\s+-ErrorAction\s+Stop'
        $source | Should -Not -Match 'Get-DlpSensitiveInformationType\s+-Identity'
    }

    It 'keeps every executable production SIT default empty' {
        $mainBicep = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'infrastructure/bicep/main.bicep') -Raw
        $workerBicep = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'infrastructure/bicep/modules/container-app-worker.bicep') -Raw
        $purviewOptions = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'src/Gateway.Purview/PurviewOptions.cs') -Raw
        $workerSettings = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'src/Gateway.Provisioning.Worker/appsettings.json') -Raw |
                ConvertFrom-Json -Depth 20 -ErrorAction Stop

        foreach ($source in @($mainBicep, $workerBicep)) {
            $source | Should -Match "param purviewDefaultSensitiveInformationType string = ''"
            $source | Should -Match "param purviewDefaultSensitiveInformationTypeId string = ''"
        }
        $purviewOptions | Should -Match (
            'DefaultSensitiveInformationTypeId\s*\{\s*get;\s*set;\s*\}\s*=\s*string\.Empty')
        $purviewOptions | Should -Match (
            'DefaultSensitiveInformationType\s*\{\s*get;\s*set;\s*\}\s*=\s*string\.Empty')
        [string]$workerSettings.Purview.DefaultSensitiveInformationTypeId |
            Should -BeExactly ''
        [string]$workerSettings.Purview.DefaultSensitiveInformationType |
            Should -BeExactly ''
    }
}
