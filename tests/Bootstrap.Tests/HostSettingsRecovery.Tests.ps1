BeforeAll {
    $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    foreach ($module in @('Common', 'Azure', 'PurviewExecutor')) {
        Import-Module "$repository/bootstrap/modules/$module.psm1" -Force -DisableNameChecking
    }

}

Describe 'Host settings amendment entrypoint' {
    It 'provides a separate parent-preserving amendment command' {
        Import-Module "$repository/bootstrap/modules/PublisherRecovery.psm1" -Force -DisableNameChecking
        Get-Command Invoke-BootstrapHostSettingsAmendment -ErrorAction Stop | Should -Not -BeNullOrEmpty
        Get-Command Assert-BootstrapHostSettingsAmendment -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }
}

Describe 'Dedicated settings through the actual native boundary' {
    It 'uses real Common scope enforcement and stdout-only capture, without Graph or a fallback' {
        $savedPath = $env:PATH
        $directory = Join-Path $TestDrive 'native'
        $null = New-Item -ItemType Directory $directory
        $scriptPath = Join-Path $directory 'fixture.ps1'
        $trace = Join-Path $directory 'arguments.jsonl'
        $payload = Join-Path $directory 'synthetic-array.json'
        $env:A365GW_SETTINGS_TEST_TRACE = $trace
        $env:A365GW_SETTINGS_TEST_PAYLOAD = $payload
        [IO.File]::WriteAllText($scriptPath, @'
if (($args[0..3] -join ' ') -cne 'webapp config appsettings list') { exit 93 }
[IO.File]::AppendAllText($env:A365GW_SETTINGS_TEST_TRACE, (ConvertTo-Json -InputObject @($args) -Compress) + "`n")
[Console]::Out.Write([IO.File]::ReadAllText($env:A365GW_SETTINGS_TEST_PAYLOAD))
'@)
        if ($IsWindows) {
            $command = Join-Path $directory 'az.cmd'
            [IO.File]::WriteAllText($command, "@echo off`r`n`"$PSHOME\pwsh.exe`" -NoLogo -NoProfile -NonInteractive -File `"$scriptPath`" %*`r`n")
        }
        else {
            $command = Join-Path $directory 'az'
            [IO.File]::WriteAllText($command, "#!/bin/sh`nexec '$PSHOME/pwsh' -NoLogo -NoProfile -NonInteractive -File '$scriptPath' `"`$@`"`n")
            [IO.File]::SetUnixFileMode($command, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
        try {
            $env:PATH = $directory
            @(Get-Command az -CommandType Application).Count | Should -Be 1
            (Get-Command az -CommandType Application).Source | Should -BeExactly $command
            $subscription = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            Set-BootstrapAzureSubscriptionContext -SubscriptionId $subscription -TenantId 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
            Mock Get-BootstrapGraphHttpClient -ModuleName Common { throw 'No Graph dispatch is permitted for host settings.' }
            $site = "/subscriptions/$subscription/resourceGroups/fixture/providers/Microsoft.Web/sites/fixture-host"
            [IO.File]::WriteAllText($payload, '[{"name":"KNOWN","value":"synthetic","slotSetting":false}]')
            (Get-PurviewExecutorArmSettings -SiteId $site).KNOWN | Should -BeExactly 'synthetic'
            [IO.File]::WriteAllText($payload, '{}')
            { Get-PurviewExecutorArmSettings -SiteId $site } | Should -Throw '*nonempty array*'
            $calls = @(Get-Content $trace)
            $calls.Count | Should -Be 2
            foreach ($line in $calls) {
                $call = @(ConvertFrom-Json $line)
                ($call -join ' ') | Should -BeExactly "webapp config appsettings list --subscription $subscription --resource-group fixture --name fixture-host --output json --only-show-errors"
            }
        }
        finally {
            Clear-BootstrapAzureSubscriptionContext
            $env:PATH = $savedPath
            $env:A365GW_SETTINGS_TEST_TRACE = $null
            $env:A365GW_SETTINGS_TEST_PAYLOAD = $null
        }
    }
}

Describe 'Exact dedicated executor host settings read' {
    BeforeEach {
        $savedPath = $env:PATH
        $env:PATH = $TestDrive
        $subscription = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $tenant = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        Set-BootstrapAzureSubscriptionContext -SubscriptionId $subscription -TenantId $tenant
        $site = "/subscriptions/$subscription/resourceGroups/fixture/providers/Microsoft.Web/sites/fixture-host"
        $arguments = @('webapp', 'config', 'appsettings', 'list', '--subscription', $subscription,
            '--resource-group', 'fixture', '--name', 'fixture-host')
        $global:settingsFixture = @{ value = @(@{ name = 'KNOWN'; value = 'synthetic'; slotSetting = $false }); calls = 0 }
        $processBoundary = {
            param($FilePath, $ArgumentList)
            $global:settingsFixture.calls++
            ($ArgumentList[0..3] -join ' ') | Should -BeExactly 'webapp config appsettings list'
            @($ArgumentList | Where-Object { $_ -cin @('set', 'delete', 'invoke-action', '--query', '--slot') }).Count | Should -Be 0
            ConvertTo-Json -InputObject $global:settingsFixture.value -Depth 12 -Compress
        }
        Mock Invoke-BootstrapCommand -ModuleName Common -MockWith $processBoundary
        Mock Invoke-BootstrapCommand -ModuleName PurviewExecutor -MockWith $processBoundary
    }
    AfterEach {
        $env:PATH = $savedPath
        Clear-BootstrapAzureSubscriptionContext
        $global:settingsFixture = $null
    }

    It 'uses only the exact scoped dedicated list and maps string settings' {
        $settings = Get-PurviewExecutorArmSettings -SiteId $site
        $settings.Count | Should -Be 1
        $settings.KNOWN | Should -BeExactly 'synthetic'
        $global:settingsFixture.calls | Should -Be 1
    }

    It 'rejects unverifiable dedicated response shape <Fault> with no fallback' -ForEach @(
        @{ Fault = 'object' }, @{ Fault = 'null' }, @{ Fault = 'empty' }, @{ Fault = 'duplicate' },
        @{ Fault = 'case duplicate' }, @{ Fault = 'unknown' }, @{ Fault = 'name type' },
        @{ Fault = 'value type' }, @{ Fault = 'null value' }, @{ Fault = 'slot type' },
        @{ Fault = 'slot enabled' }, @{ Fault = 'missing value' }
    ) {
        switch ($Fault) {
            'object' { $global:settingsFixture.value = @{} }
            'null' { $global:settingsFixture.value = $null }
            'empty' { $global:settingsFixture.value = @() }
            'duplicate' { $global:settingsFixture.value += @{ name = 'KNOWN'; value = 'synthetic' } }
            'case duplicate' { $global:settingsFixture.value += @{ name = 'known'; value = 'synthetic' } }
            'unknown' { $global:settingsFixture.value[0].extra = 'unsupported' }
            'name type' { $global:settingsFixture.value[0].name = 1 }
            'value type' { $global:settingsFixture.value[0].value = 1 }
            'null value' { $global:settingsFixture.value[0].value = $null }
            'slot type' { $global:settingsFixture.value[0].slotSetting = 'false' }
            'slot enabled' { $global:settingsFixture.value[0].slotSetting = $true }
            'missing value' { $global:settingsFixture.value[0].Remove('value') }
        }
        { Get-PurviewExecutorArmSettings -SiteId $site } | Should -Throw
        $global:settingsFixture.calls | Should -Be 1
    }

    It 'accepts absent optional slotSetting without weakening value validation' {
        $global:settingsFixture.value[0].Remove('slotSetting')
        (Get-PurviewExecutorArmSettings -SiteId $site).KNOWN | Should -BeExactly 'synthetic'
    }

    It 'allows only the reviewed explicit command shape after authentication' {
        (Get-BootstrapAzureCliArguments -Arguments $arguments) -join ' ' | Should -BeExactly ($arguments -join ' ')
    }

    It 'rejects unapproved webapp command or scope <Fault>' -ForEach @(
        @{ Fault = 'set' }, @{ Fault = 'delete' }, @{ Fault = 'show' }, @{ Fault = 'connection-string' },
        @{ Fault = 'publishing-profile' }, @{ Fault = 'slot' }, @{ Fault = 'query' },
        @{ Fault = 'missing subscription' }, @{ Fault = 'wrong subscription' }, @{ Fault = 'extra' },
        @{ Fault = 'wrong case' }
    ) {
        switch ($Fault) {
            'set' { $arguments[3] = 'set' }
            'delete' { $arguments[3] = 'delete' }
            'show' { $arguments = @('webapp', 'show') }
            'connection-string' { $arguments[2] = 'connection-string' }
            'publishing-profile' { $arguments[2] = 'publishing-profiles' }
            'slot' { $arguments += @('--slot', 'other') }
            'query' { $arguments += @('--query', '[].value') }
            'missing subscription' { $arguments = @($arguments[0..3]) + @($arguments[6..9]) }
            'wrong subscription' { $arguments[5] = $tenant }
            'extra' { $arguments += '--debug' }
            'wrong case' { $arguments[0] = 'WebApp' }
        }
        { Get-BootstrapAzureCliArguments -Arguments $arguments } | Should -Throw
        $global:settingsFixture.calls | Should -Be 0
    }
}
