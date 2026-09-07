BeforeAll {
    $builder = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../operations/build-purview-executor-package.ps1'))
}

Describe 'Installed executor prerequisites across the Windows process boundary' -Skip:(-not $IsWindows) {
    BeforeAll {
        $pwsh = Join-Path $PSHOME 'pwsh.exe'
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $installed = @(Get-Module -ListAvailable -FullyQualifiedName @{
            ModuleName = 'ExchangeOnlineManagement'; RequiredVersion = '3.10.1'
        })
        $hasPrerequisites = $PSVersionTable.PSVersion.ToString() -ceq '7.6.5' -and $installed.Count -gt 0
        function Invoke-PrerequisiteProcess {
            param([switch]$WindowsPowerShellParent, [string]$FirstModulePath = '')
            $pathSetup = if ($FirstModulePath) {
                "`$env:PSModulePath = '$($FirstModulePath.Replace("'", "''"));' + `$env:PSModulePath"
            } else { '' }
            $command = @"
`$ErrorActionPreference = 'Stop'
try {
    $pathSetup
    `$count = @(Get-Module -ListAvailable -FullyQualifiedName @{ ModuleName = 'ExchangeOnlineManagement'; RequiredVersion = '3.10.1' }).Count
    Write-Output "DISCOVERED=`$count"
    & '$($builder.Replace("'", "''"))' -ValidateOnly
    Write-Output 'VALIDATE_ONLY_PASSED'
    exit 0
} catch {
    Write-Output `$_.Exception.Message
    exit 1
}
"@
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $executable = $pwsh
            if ($WindowsPowerShellParent) {
                $command = @"
if (`$PSVersionTable.PSVersion.Major -ne 5 -or `$PSVersionTable.PSVersion.Minor -ne 1) { exit 2 }
& '$($pwsh.Replace("'", "''"))' -NoLogo -NoProfile -NonInteractive -EncodedCommand '$encoded'
exit `$LASTEXITCODE
"@
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
                $executable = $windowsPowerShell
            }
            $output = @(& $executable -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1)
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output -join "`n" }
        }
    }
    It 'validates in a direct no-profile pwsh process without creating a package' {
        if (-not $hasPrerequisites) { Set-ItResult -Skipped -Because 'Requires installed signed PowerShell 7.6.5 and EOM 3.10.1.'; return }
        $result = Invoke-PrerequisiteProcess
        Write-Host "Direct pwsh: exit=$($result.ExitCode); $($result.Output)"
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'VALIDATE_ONLY_PASSED'
    }
    It 'validates after Windows PowerShell 5.1 supplies its inherited module paths' {
        if (-not $hasPrerequisites) { Set-ItResult -Skipped -Because 'Requires installed signed PowerShell 7.6.5 and EOM 3.10.1.'; return }
        $result = Invoke-PrerequisiteProcess -WindowsPowerShellParent
        Write-Host "WindowsPowerShell child pwsh: exit=$($result.ExitCode); $($result.Output)"
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'VALIDATE_ONLY_PASSED'
    }
    It 'rejects a synthetic <Variant> shadow through the real process boundary (WindowsPowerShell parent=<Parent>)' -ForEach @(
        @{ Variant = 'unsigned'; Parent = $false }
        @{ Variant = 'unsigned'; Parent = $true }
        @{ Variant = 'ambiguous'; Parent = $false }
        @{ Variant = 'ambiguous'; Parent = $true }
    ) {
        if (-not $hasPrerequisites) { Set-ItResult -Skipped -Because 'Requires installed signed PowerShell 7.6.5 and EOM 3.10.1.'; return }
        $searchRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '/shadow modules')
        $moduleDirectory = Join-Path $searchRoot 'ExchangeOnlineManagement'
        $versionDirectory = Join-Path $moduleDirectory '3.10.1'
        [IO.Directory]::CreateDirectory($versionDirectory) | Out-Null
        [IO.File]::WriteAllText((Join-Path $versionDirectory 'ExchangeOnlineManagement.psd1'), "@{ ModuleVersion = '3.10.1' }")
        if ($Variant -eq 'ambiguous') {
            [IO.File]::WriteAllText((Join-Path $moduleDirectory 'ExchangeOnlineManagement.psd1'), "@{ ModuleVersion = '3.10.1' }")
        }
        $result = Invoke-PrerequisiteProcess -WindowsPowerShellParent:$Parent -FirstModulePath $searchRoot
        $result.ExitCode | Should -Be 1 -Because $result.Output
        $result.Output | Should -Not -Match 'VALIDATE_ONLY_PASSED'
        if ($Variant -eq 'unsigned') { $result.Output | Should -Match 'valid Microsoft signature' }
        else { $result.Output | Should -Match 'ambiguous' }
    }
}

Describe 'Pinned executor module discovery' {
    BeforeAll {
        # Exercise the actual resolver without running packaging, importing EOM, or
        # needing a signed synthetic module. Only the OS signature verifier is mocked.
        $ast = [Management.Automation.Language.Parser]::ParseFile($builder, [ref]$null, [ref]$null)
        foreach ($name in @('Assert-PurviewDependencyTree', 'Resolve-PurviewExecutorModuleRoot')) {
            $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            if ($null -eq $definition) { throw "Missing package prerequisite function $name." }
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
            function Get-AuthenticodeSignature {
                param([string]$LiteralPath)
                throw 'Synthetic fixtures require the OS signature verifier mock.'
            }
        }
        function New-ModuleFixture {
            param([string]$SearchRoot, [string]$Version = '3.10.1', [switch]$Unversioned)
            $directory = Join-Path $SearchRoot 'ExchangeOnlineManagement'
            if (-not $Unversioned) { $directory = Join-Path $directory '3.10.1' }
            [IO.Directory]::CreateDirectory($directory) | Out-Null
            [IO.File]::WriteAllText((Join-Path $directory 'ExchangeOnlineManagement.psd1'),
                "@{ ModuleVersion = '$Version'; GUID = 'cd5767b4-9ef3-4818-897f-26354b5c91ac'; RootModule = 'ExchangeOnlineManagement.psm1' }")
            [IO.File]::WriteAllText((Join-Path $directory 'ExchangeOnlineManagement.psm1'),
                "throw 'Module code must never execute during package discovery.'")
            return $directory
        }
    }
    BeforeEach {
        $first = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '/first modules')
        $second = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '/second modules')
        $searchPath = $first + [IO.Path]::PathSeparator + $second
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation' } }
        }
    }
    It 'pins the first exact-version installation and never imports module code' {
        $expected = New-ModuleFixture $first
        Resolve-PurviewExecutorModuleRoot -ModulePath $searchPath | Should -BeExactly $expected
        Should -Invoke Get-AuthenticodeSignature -Times 1 -Exactly
    }
    It 'uses path precedence for duplicate installations rather than enumeration or lexical order' {
        $one = New-ModuleFixture $first
        $two = New-ModuleFixture $second
        [IO.File]::AppendAllText((Join-Path $two 'ExchangeOnlineManagement.psm1'), '# distinct lower-priority bytes')
        Resolve-PurviewExecutorModuleRoot -ModulePath $searchPath | Should -BeExactly $one
        Resolve-PurviewExecutorModuleRoot -ModulePath ($second + [IO.Path]::PathSeparator + $first) | Should -BeExactly $two
    }
    It 'tolerates repeated search-path entries and supports an unversioned exact manifest' {
        $expected = New-ModuleFixture $first -Unversioned
        Resolve-PurviewExecutorModuleRoot -ModulePath ($first + [IO.Path]::PathSeparator + $first) | Should -BeExactly $expected
    }
    It 'reads signed edition-conditional manifest metadata without importing the selected root module' {
        $expected = New-ModuleFixture $first
        [IO.File]::WriteAllText((Join-Path $expected 'ExchangeOnlineManagement.psd1'), @'
@{
    ModuleVersion = '3.10.1'
    RootModule = if ($PSEdition -eq 'Core') { 'ExchangeOnlineManagement.psm1' } else { 'unused.psm1' }
}
'@)
        Resolve-PurviewExecutorModuleRoot -ModulePath $searchPath | Should -BeExactly $expected
    }
    It 'ignores other version directories when locating the required exact version' {
        $other = New-ModuleFixture $first '3.9.0'
        Move-Item -LiteralPath $other -Destination (Join-Path (Split-Path $other) '3.9.0')
        $expected = New-ModuleFixture $second
        Resolve-PurviewExecutorModuleRoot -ModulePath $searchPath | Should -BeExactly $expected
    }
    It 'fails closed when the pinned directory contains a mismatched manifest version' {
        $null = New-ModuleFixture $first '3.9.0'
        $null = New-ModuleFixture $second
        { Resolve-PurviewExecutorModuleRoot -ModulePath $searchPath } | Should -Throw '*3.10.1 exactly*'
    }
    It 'does not skip a shadowing exact-version directory with a missing manifest' {
        $bad = New-ModuleFixture $first
        Remove-Item -LiteralPath (Join-Path $bad 'ExchangeOnlineManagement.psd1')
        $null = New-ModuleFixture $second
        { Resolve-PurviewExecutorModuleRoot -ModulePath $searchPath } | Should -Throw '*manifest*'
    }
    It 'does not skip a malformed shadowing manifest' {
        $bad = New-ModuleFixture $first
        [IO.File]::WriteAllText((Join-Path $bad 'ExchangeOnlineManagement.psd1'), '@{ broken')
        $null = New-ModuleFixture $second
        { Resolve-PurviewExecutorModuleRoot -ModulePath $searchPath } | Should -Throw
    }
    It 'rejects ambiguous versioned and unversioned installations in one search root' {
        $null = New-ModuleFixture $first
        $null = New-ModuleFixture $first -Unversioned
        $null = New-ModuleFixture $second
        { Resolve-PurviewExecutorModuleRoot -ModulePath $searchPath } | Should -Throw '*ambiguous*'
    }
    It 'never falls back past a rejected signature: <Status> / <Subject>' -ForEach @(
        @{ Status = 'NotSigned'; Subject = '' }
        @{ Status = 'HashMismatch'; Subject = 'CN=Microsoft Corporation' }
        @{ Status = 'Valid'; Subject = 'CN=Not Microsoft Corporation' }
    ) {
        $null = New-ModuleFixture $first
        $null = New-ModuleFixture $second
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = $Status; SignerCertificate = [pscustomobject]@{ Subject = $Subject } }
        }
        { Resolve-PurviewExecutorModuleRoot -ModulePath $searchPath } | Should -Throw '*valid Microsoft signature*'
        Should -Invoke Get-AuthenticodeSignature -Times 1 -Exactly
    }
    It 'rejects a missing exact module and a relative search path' {
        { Resolve-PurviewExecutorModuleRoot -ModulePath $searchPath } | Should -Throw '*3.10.1*required*'
        { Resolve-PurviewExecutorModuleRoot -ModulePath './relative' } | Should -Throw '*absolute*'
    }
    It 'rejects a junction in the chosen dependency tree before signature verification' -Skip:(-not $IsWindows) {
        $bad = New-ModuleFixture $first
        $target = New-ModuleFixture $second
        $link = Join-Path $bad 'linked'
        $null = New-Item -ItemType Junction -Path $link -Target $target
        try {
            { Resolve-PurviewExecutorModuleRoot -ModulePath $searchPath } | Should -Throw '*reparse*'
            Should -Invoke Get-AuthenticodeSignature -Times 0 -Exactly
        } finally { [IO.Directory]::Delete($link) }
    }
    It 'rejects a junction at the selected <Location> before signature verification' -Skip:(-not $IsWindows) -ForEach @(
        @{ Location = 'root' }, @{ Location = 'ancestor' }
    ) {
        $target = New-ModuleFixture $second
        $link = Join-Path $first 'ExchangeOnlineManagement'
        if ($Location -eq 'root') { $link = Join-Path $link '3.10.1' }
        else { $target = Split-Path $target }
        [IO.Directory]::CreateDirectory((Split-Path $link)) | Out-Null
        $null = New-Item -ItemType Junction -Path $link -Target $target
        try {
            { Resolve-PurviewExecutorModuleRoot -ModulePath $searchPath } | Should -Throw '*reparse*'
            Should -Invoke Get-AuthenticodeSignature -Times 0 -Exactly
        } finally { [IO.Directory]::Delete($link) }
    }
}
