#Requires -Version 7.0

Describe 'Bootstrap expected configuration file fingerprint command boundary' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $script:BootstrapPath = Join-Path $script:RepositoryRoot 'bootstrap/bootstrap.ps1'
        $script:PowerShellPath = (Get-Command pwsh -ErrorAction Stop).Source
        $tokens = $null
        $errors = $null
        $script:BootstrapAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:BootstrapPath,
            [ref]$tokens,
            [ref]$errors)
        $errors.Count | Should -Be 0
        $script:BootstrapSource = Get-Content -LiteralPath $script:BootstrapPath -Raw

        function Invoke-TestBootstrapCommand {
            param([Parameter(Mandatory)][string[]]$Arguments)

            $output = & $script:PowerShellPath `
                -NoLogo `
                -NoProfile `
                -File $script:BootstrapPath `
                @Arguments 2>&1 | Out-String
            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output = $output
            }
        }
    }

    It 'declares the fingerprint as optional and forwards it only to the canonical configuration load' {
        $parameter = @($script:BootstrapAst.ParamBlock.Parameters | Where-Object {
            $_.Name.VariablePath.UserPath -ceq 'ExpectedConfigurationFileFingerprint'
        })

        $parameter.Count | Should -Be 1
        $parameter[0].DefaultValue.SafeGetValue() | Should -BeExactly ''
        ([regex]::Matches(
            $script:BootstrapSource,
            '(?s)Read-BootstrapConfig.{0,80}-Path\s+\$Config.{0,80}-ExpectedConfigurationFileFingerprint\s+\$ExpectedConfigurationFileFingerprint')).Count |
            Should -Be 1
    }

    It 'allows the fingerprint only for Plan before any configuration or external work' {
        $result = Invoke-TestBootstrapCommand -Arguments @(
            '-Mode', 'Doctor',
            '-Config', (Join-Path $TestDrive 'must-not-read.json'),
            '-InstallPrerequisites:$false',
            '-ExpectedConfigurationFileFingerprint', "sha256:$('a' * 64)"
        )

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'ExpectedConfigurationFileFingerprint is valid only for Plan'
        $result.Output | Should -Not -Match 'Gateway doctor|must-not-read'
    }

    It 'rejects noncanonical fingerprint text before configuration loading' {
        foreach ($invalid in @(' ', "SHA256:$('A' * 64)")) {
            $result = Invoke-TestBootstrapCommand -Arguments @(
                '-Mode', 'Plan',
                '-Config', (Join-Path $TestDrive 'must-not-read.json'),
                '-InstallPrerequisites:$false',
                '-ExpectedConfigurationFileFingerprint', $invalid
            )

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'must use canonical lowercase sha256 format'
            $result.Output | Should -Not -Match 'must-not-read'
        }
    }

    It 'keeps ordinary terminal Plan compatible when the optional fingerprint is omitted' {
        $result = Invoke-TestBootstrapCommand -Arguments @(
            '-Mode', 'Plan',
            '-Config', (Join-Path $TestDrive 'ordinary-missing.json'),
            '-InstallPrerequisites:$false',
            '-NonInteractive',
            '-OutputFormat', 'Json'
        )

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match '"failureCode":"configuration"'
        $result.Output | Should -Not -Match 'ExpectedConfigurationFileFingerprint'
    }
}
