Describe 'Azure CLI subscription and output boundary' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $script:OriginalSubscriptionPin = [Environment]::GetEnvironmentVariable('A365GW_BOOTSTRAP_SUBSCRIPTION_ID')
        . (Join-Path $script:RepositoryRoot 'tools/_common.ps1')
    }

    AfterAll {
        [Environment]::SetEnvironmentVariable(
            'A365GW_BOOTSTRAP_SUBSCRIPTION_ID',
            $script:OriginalSubscriptionPin)
    }

    BeforeEach {
        [Environment]::SetEnvironmentVariable(
            'A365GW_BOOTSTRAP_SUBSCRIPTION_ID',
            '11111111-1111-4111-8111-111111111111')
    }

    It 'appends the canonical bootstrap subscription to an unpinned Azure CLI command' {
        $actual = @(Add-A365GatewayAzureSubscriptionPin -Arguments @('group', 'show', '--name', 'rg-safe') -Required)

        $actual | Should -Be @(
            'group', 'show', '--name', 'rg-safe',
            '--subscription', '11111111-1111-4111-8111-111111111111')
    }

    It 'keeps one matching explicit subscription without duplication' {
        $actual = @(Add-A365GatewayAzureSubscriptionPin -Arguments @(
            'account', 'show', '--subscription', '11111111-1111-4111-8111-111111111111') -Required)

        @($actual | Where-Object { $_ -ceq '--subscription' }).Count | Should -Be 1
    }

    It 'rejects a conflicting explicit subscription' {
        { Add-A365GatewayAzureSubscriptionPin -Arguments @(
                'group', 'show', '--subscription', '22222222-2222-4222-8222-222222222222') -Required } |
            Should -Throw '*do not match the exact bootstrap subscription pin*'
    }

    It 'rejects a malformed or noncanonical environment pin' {
        [Environment]::SetEnvironmentVariable(
            'A365GW_BOOTSTRAP_SUBSCRIPTION_ID',
            '11111111-1111-4111-8111-11111111111A')

        { Get-A365GatewayBootstrapSubscriptionId -Required } |
            Should -Throw '*canonical, non-empty lowercase GUID*'
    }

    It 'does not include provider output in Azure CLI failures' {
        function az {
            'private-provider-body-marker'
            $global:LASTEXITCODE = 29
        }

        try {
            Invoke-AzCommand -Arguments @('group', 'show', '--name', 'rg-safe') -ErrorMessage 'Resource lookup failed.'
            throw 'Expected the Azure CLI wrapper to fail.'
        }
        catch {
            $_.Exception.Message | Should -Match 'Resource lookup failed'
            $_.Exception.Message | Should -Match 'exit code: 29'
            $_.Exception.Message | Should -Not -Match 'private-provider-body-marker'
        }
    }

    It 'keeps the Entra mutation helper guarded by an immediate exact context check' {
        $source = Get-Content -LiteralPath (
            Join-Path $script:RepositoryRoot 'tools/configure-workflow-v3-entra.ps1') -Raw

        $source | Should -Match 'function Invoke-AzMutation[\s\S]+Assert-ExpectedAzureContext[\s\S]+Invoke-AzJson'
        $source | Should -Match 'Add-ExactSubscriptionPin -Arguments \$Arguments'
    }
}
