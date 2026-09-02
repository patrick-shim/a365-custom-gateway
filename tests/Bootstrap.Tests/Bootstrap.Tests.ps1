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

Describe 'Resume preflight Boolean revalidation gate' {
    BeforeAll {
        $script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $script:BootstrapPath = Join-Path $script:RepositoryRoot 'bootstrap/bootstrap.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $script:BootstrapPath,
            [ref]$tokens,
            [ref]$errors)
        $errors.Count | Should -Be 0

        $resume = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Invoke-GatewayResumePreflight'
        }, $true))
        $resume.Count | Should -Be 1

        # Exercise the exact shipped stage helpers rather than a copy, so a future
        # scoping regression in bootstrap.ps1 fails this test instead of silently
        # disabling every RP04-RP20 revalidation gate at runtime.
        $script:StageHelperSource = @($resume[0].FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -cin @('invokeStage', 'invokeBooleanStage')
        }, $true) | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
        $script:StageHelperSource | Should -Match 'invokeBooleanStage'

        # A scoping regression re-enters the wrapper until the call depth overflows,
        # which is slow enough to look like a hung suite. Bound it in a job so the
        # regression reports as a failure instead of stalling the run.
        $script:GateResult = $null
        $job = Start-Job -ArgumentList $script:StageHelperSource -ScriptBlock {
            param([string]$HelperSource)

            function Write-GatewayExperienceEvent {
                param($Type, $Message, $Data, $OutputFormat)
            }
            $eventBase = [ordered]@{ step = 'Resume preflight'; index = 1; total = 20 }
            $Format = 'Text'
            . ([scriptblock]::Create($HelperSource))

            $script:validatorRuns = 0
            $results = @{}
            try {
                & $invokeBooleanStage -Code 'RP_TEST' -Label 'test gate' -Action {
                    $script:validatorRuns++
                    return $true
                }
                $results['truePassed'] = $true
            }
            catch { $results['truePassed'] = $false }
            $results['validatorRuns'] = $script:validatorRuns

            foreach ($case in @(
                @{ name = 'false'; block = { return $false } },
                @{ name = 'nonBoolean'; block = { return 'true' } },
                @{ name = 'multiValue'; block = { Write-Output $true; Write-Output $true } }
            )) {
                try {
                    & $invokeBooleanStage -Code 'RP_TEST' -Label 'test gate' -Action $case.block
                    $results[$case.name] = 'passed'
                }
                catch { $results[$case.name] = 'stopped' }
            }
            return $results
        }
        if (Wait-Job -Job $job -Timeout 90) {
            $script:GateResult = Receive-Job -Job $job
        }
        Remove-Job -Job $job -Force
    }

    It 'evaluates the caller validator instead of re-entering its own wrapper' {
        $script:GateResult | Should -Not -BeNullOrEmpty
        $script:GateResult['validatorRuns'] | Should -Be 1
        $script:GateResult['truePassed'] | Should -BeTrue
    }

    It 'still fails closed on any result that is not exactly one true Boolean' {
        $script:GateResult | Should -Not -BeNullOrEmpty
        $script:GateResult['false'] | Should -BeExactly 'stopped'
        $script:GateResult['nonBoolean'] | Should -BeExactly 'stopped'
        $script:GateResult['multiValue'] | Should -BeExactly 'stopped'
    }
}
