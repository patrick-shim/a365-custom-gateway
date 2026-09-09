BeforeAll {
    $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    Import-Module "$repository/bootstrap/modules/Common.psm1" -Force -DisableNameChecking
    Import-Module "$repository/bootstrap/modules/Azure.psm1" -Force -DisableNameChecking
}

Describe 'Read resilience distinct receipt entrypoint' {
    It 'exposes only a separate preserving amendment rather than rebinding the old child' {
        Import-Module "$repository/bootstrap/modules/PublisherRecovery.psm1" -Force -DisableNameChecking
        Get-Command Invoke-BootstrapReadResilienceAmendment -ErrorAction Stop | Should -Not -BeNullOrEmpty
        Get-Command Assert-BootstrapReadResilienceAmendment -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }

    It 'never exempts review-table code injected into another allowlisted source file' {
        Import-Module "$repository/bootstrap/modules/PublisherRecovery.psm1" -Force -DisableNameChecking
        $path = Join-Path $TestDrive 'Common.psm1'
        [IO.File]::WriteAllText($path, 'Set-StrictMode -Version Latest; function Get-BootstrapReadResilienceReviewedSources { return @{ injected = 1 } }')
        { Get-BootstrapReadResilienceSourceSurface -Path $path } | Should -Throw '*review table*'
    }
}

Describe 'Exact ACR reads through the real native boundary' {
    BeforeEach {
        $savedPath = $env:PATH
        $savedConfig = $env:AZURE_CONFIG_DIR
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + ' native 한')
        $null = New-Item -ItemType Directory $directory
        $fixture = Join-Path $directory 'fixture.ps1'
        $env:A365GW_READ_FIXTURE = $directory
        [IO.File]::WriteAllText($fixture, @'
$root = $env:A365GW_READ_FIXTURE
$trace = Join-Path $root 'calls.jsonl'
[IO.File]::AppendAllText($trace, (ConvertTo-Json -InputObject @($args) -Compress) + "`n")
$count = @(Get-Content $trace).Count
if (($args[0..2] -join ' ') -ceq 'acr repository list') {
    [Console]::Out.Write('["gateway-api"]'); exit 0
}
if (($args[0..2] -join ' ') -ceq 'acr repository show-tags') {
    $query = $args[[Array]::IndexOf($args, '--query') + 1]
    [Console]::Out.Write((ConvertTo-Json -InputObject @($query.Substring(6, $query.Length - 8)) -Compress)); exit 0
}
$failures = [int][IO.File]::ReadAllText((Join-Path $root 'failures'))
if ($count -le $failures) {
    [Console]::Error.Write('synthetic-private-sentinel')
    exit 1
}
[Console]::Out.Write([IO.File]::ReadAllText((Join-Path $root 'output')))
exit 0
'@)
        if ($IsWindows) {
            $command = Join-Path $directory 'az.cmd'
            [IO.File]::WriteAllText($command, "@echo off`r`n`"$PSHOME\pwsh.exe`" -NoLogo -NoProfile -NonInteractive -File `"$fixture`" %*`r`n")
        }
        else {
            $command = Join-Path $directory 'az'
            [IO.File]::WriteAllText($command, "#!/bin/sh`nexec '$PSHOME/pwsh' -NoLogo -NoProfile -NonInteractive -File '$fixture' `"`$@`"`n")
            [IO.File]::SetUnixFileMode($command, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
        $env:PATH = $directory
        $env:AZURE_CONFIG_DIR = $directory
        (Get-Command az -CommandType Application).Source | Should -BeExactly $command
        $subscription = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        Set-BootstrapAzureSubscriptionContext -SubscriptionId $subscription -TenantId 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        $tag = 'bootstrap-' + ('a' * 32) + '-' + ('b' * 32) + '-' + ('c' * 32)
        $arguments = @('acr', 'manifest', 'show-metadata', '--registry', 'fixture', '--name',
            "gateway-api:$tag", '--query', 'digest', '--output', 'tsv', '--only-show-errors')
        [IO.File]::WriteAllText("$directory/failures", '2')
        [IO.File]::WriteAllText("$directory/output", ('sha256:' + ('d' * 64)))
        Mock Start-Sleep -ModuleName Common {}
    }
    AfterEach {
        Clear-BootstrapAzureSubscriptionContext
        Set-BootstrapProgressSink -Sink $null
        $env:PATH = $savedPath
        $env:AZURE_CONFIG_DIR = $savedConfig
        $env:A365GW_READ_FIXTURE = $null
    }

    It 'retries only native nonzero exits with exactly 2 and 5 second delays and exact scope' {
        Invoke-BootstrapCommand -FilePath az -ArgumentList $arguments | Should -BeExactly ('sha256:' + ('d' * 64))
        $calls = @(Get-Content "$directory/calls.jsonl")
        $calls.Count | Should -Be 3
        foreach ($line in $calls) {
            (@(ConvertFrom-Json $line) -join ' ') | Should -BeExactly ((@($arguments) + @('--subscription', $subscription)) -join ' ')
        }
        Should -Invoke Start-Sleep -ModuleName Common -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
        Should -Invoke Start-Sleep -ModuleName Common -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }

    It 'exhausts three unknown failures without leaking native diagnostics or claiming transient' {
        [IO.File]::WriteAllText("$directory/failures", '9')
        $failure = $null
        try { Invoke-BootstrapCommand -FilePath az -ArgumentList $arguments } catch { $failure = $_ }
        $failure | Should -Not -BeNullOrEmpty
        $failure.ToString() | Should -Not -Match 'synthetic-private-sentinel|transient'
        @(Get-Content "$directory/calls.jsonl").Count | Should -Be 3
    }

    It 'does not retry a successful malformed value' {
        [IO.File]::WriteAllText("$directory/failures", '0')
        [IO.File]::WriteAllText("$directory/output", 'not-a-digest')
        Invoke-BootstrapCommand -FilePath az -ArgumentList $arguments | Should -BeExactly 'not-a-digest'
        @(Get-Content "$directory/calls.jsonl").Count | Should -Be 1
        Should -Invoke Start-Sleep -ModuleName Common -Times 0 -Exactly
    }

    It 'keeps canonical digest validation outside native retries for successful <Value>' -ForEach @(
        @{ Value = 'null' }, @{ Value = '' }, @{ Value = 'not-a-digest' }, @{ Value = "noise`nsha256:bad" }
    ) {
        [IO.File]::WriteAllText("$directory/failures", '0')
        [IO.File]::WriteAllText("$directory/output", $Value)
        { Get-GatewayAcrExactTagDigest -Registry fixture -Repository gateway-api -Tag $tag } | Should -Throw '*canonical immutable digest*'
        @(Get-Content "$directory/calls.jsonl").Count | Should -Be 3
        Should -Invoke Start-Sleep -ModuleName Common -Times 0 -Exactly
    }

    It 'returns a fresh canonical digest to the unchanged exact caller instead of cached evidence' {
        [IO.File]::WriteAllText("$directory/failures", '0')
        $result = Get-GatewayAcrExactTagDigest -Registry fixture -Repository gateway-api -Tag $tag
        $result.digest | Should -BeExactly ('sha256:' + ('d' * 64))
        [IO.File]::WriteAllText("$directory/output", ('sha256:' + ('e' * 64)))
        $next = Get-GatewayAcrExactTagDigest -Registry fixture -Repository gateway-api -Tag $tag
        $next.digest | Should -Not -BeExactly $result.digest
        @(Get-Content "$directory/calls.jsonl").Count | Should -Be 6
    }

    It 'retains stdout-only semantics and ignores a failing progress sink' {
        Set-BootstrapProgressSink -Sink { throw 'decorative failure' }
        Invoke-BootstrapCommand -FilePath az -ArgumentList $arguments -CaptureStdoutOnly | Should -BeExactly ('sha256:' + ('d' * 64))
        @(Get-Content "$directory/calls.jsonl").Count | Should -Be 3
    }

    It 'does not retry nonallowlisted command shape <Fault>' -ForEach @(
        @{ Fault = 'mutation' }, @{ Fault = 'query' }, @{ Fault = 'tag' }, @{ Fault = 'registry' },
        @{ Fault = 'extra' }, @{ Fault = 'duplicate' }, @{ Fault = 'allowFailure' }, @{ Fault = 'noCapture' },
        @{ Fault = 'task' }, @{ Fault = 'no context' }
    ) {
        $options = @{}
        switch ($Fault) {
            mutation { $arguments = @('acr', 'build', '--registry', 'fixture', '--image', "gateway-api:$tag", '.') }
            query { $arguments[8] = 'name' }
            tag { $arguments[6] = 'gateway-api:latest' }
            registry { $arguments[4] = 'fixture.azurecr.io' }
            extra { $arguments += '--debug' }
            duplicate { $arguments += @('--query', 'digest') }
            allowFailure { $options.AllowFailure = $true }
            noCapture { $options.NoCapture = $true }
            task { $arguments = @('acr', 'task', 'list-runs', '--registry', 'fixture') }
            'no context' { Clear-BootstrapAzureSubscriptionContext }
        }
        try { $null = Invoke-BootstrapCommand -FilePath az -ArgumentList $arguments @options } catch {}
        @(Get-Content "$directory/calls.jsonl").Count | Should -Be 1
        Should -Invoke Start-Sleep -ModuleName Common -Times 0 -Exactly
    }

    It 'rejects cross-subscription arguments before any native attempt' {
        $arguments += @('--subscription', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')
        { Invoke-BootstrapCommand -FilePath az -ArgumentList $arguments } | Should -Throw
        Test-Path "$directory/calls.jsonl" | Should -BeFalse
    }

    It 'revalidates context after a failed attempt before another native process' {
        Mock Start-Sleep -ModuleName Common { Clear-BootstrapAzureSubscriptionContext }
        { Invoke-BootstrapCommand -FilePath az -ArgumentList $arguments } | Should -Throw
        @(Get-Content "$directory/calls.jsonl").Count | Should -Be 1
    }
}
