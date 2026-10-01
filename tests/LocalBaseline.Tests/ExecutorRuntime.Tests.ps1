BeforeAll {
    $tokens = $null
    $parseErrors = $null
    $source = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '..\..\operations\build-purview-executor-package.ps1'),
        [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw 'The authored package builder must parse.' }
    $validation = $source.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Assert-PurviewPowerShellRuntimeIdentity'
    }, $false)
    if ($null -eq $validation) { throw 'The packaged runtime identity validator is required.' }
    . ([scriptblock]::Create($validation.Extent.Text))
}

Describe 'Pinned Windows executor PowerShell identity' {
    It 'admits only the exact version and x64 runtime from a successful probe' {
        { Assert-PurviewPowerShellRuntimeIdentity -Identity @('7.6.5|X64') -ExitCode 0 } | Should -Not -Throw
    }

    It 'rejects mismatched, missing, additional or failed probe output' -ForEach @(
        @{ Identity = @('7.6.5|Arm64'); ExitCode = 0 },
        @{ Identity = @('7.6.5|X86'); ExitCode = 0 },
        @{ Identity = @('7.6.6|X64'); ExitCode = 0 },
        @{ Identity = @('7.6.5|x64'); ExitCode = 0 },
        @{ Identity = @('7.6.5|X64 '); ExitCode = 0 },
        @{ Identity = @('7.6.5'); ExitCode = 0 },
        @{ Identity = @('7.6.5|X64', 'unexpected-output'); ExitCode = 0 },
        @{ Identity = @(); ExitCode = 0 },
        @{ Identity = $null; ExitCode = 0 },
        @{ Identity = @('7.6.5|X64'); ExitCode = 1 }
    ) {
        { Assert-PurviewPowerShellRuntimeIdentity -Identity $Identity -ExitCode $ExitCode } |
            Should -Throw '*requires PowerShell 7.6.5 Windows x64 exactly*'
    }
}
