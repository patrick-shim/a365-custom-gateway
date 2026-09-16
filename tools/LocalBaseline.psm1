#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LocalBaselineSourceFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.WorkingDirectory = $root
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    foreach ($argument in @('ls-files', '-z', '--cached', '--others', '--exclude-standard')) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            $null = $errors.GetAwaiter().GetResult()
            throw 'Local baseline requires a readable Git source checkout.'
        }
        $files = @($output.GetAwaiter().GetResult().Split(
            [char]0, [StringSplitOptions]::RemoveEmptyEntries) | Sort-Object -Unique)
    }
    finally { $process.Dispose() }
    if ($files.Count -eq 0) { throw 'Local baseline source inventory is empty.' }
    foreach ($relative in $files) {
        if ([IO.Path]::IsPathFullyQualified($relative) -or
            $relative -match '(^|/)\.\.?(/|$)' -or
            $relative -match '(^|/)(bin|obj|TestResults|node_modules|__pycache__|\.git|\.vs|\.test-work|\.bootstrap|\.maintenance|\.copilot-azure)(/|$)' -or
            $relative -ceq 'bootstrap/config.json') {
            throw "Generated, operational or unsafe source entry is not permitted: $relative"
        }
        $full = Join-Path $root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        Assert-LocalBaselineUnlinkedPath -Path $full -Root $root
        if (-not [IO.File]::Exists($full)) {
            throw "Authored source entry is absent: $relative"
        }
    }
    return $files
}

function Assert-LocalBaselineUnlinkedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)

    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath($Path)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $full.Equals($rootPath, $comparison) -and
        -not $full.StartsWith("$rootPath$([IO.Path]::DirectorySeparatorChar)", $comparison)) {
        throw 'Local baseline path escaped its source or work directory.'
    }
    $current = $full
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Local baseline does not follow linked source or work paths.'
            }
        }
        if ($current.Equals($rootPath, $comparison)) { break }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function New-LocalBaselineSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][string]$Destination)

    $files = @(Get-LocalBaselineSourceFiles -RepositoryRoot $RepositoryRoot)
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $target = [IO.Path]::GetFullPath($Destination)
    Assert-LocalBaselineUnlinkedPath -Path $target -Root $root
    if (Test-Path -LiteralPath $target) { throw 'Local baseline snapshot destination must be new.' }
    [IO.Directory]::CreateDirectory($target) | Out-Null
    $manifest = [Collections.Generic.List[object]]::new()
    foreach ($relative in $files) {
        $path = $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $source = Join-Path $root $path
        $copy = Join-Path $target $path
        $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($copy)) | Out-Null
        [IO.File]::Copy($source, $copy, $false)
        if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -cne $hash) {
            throw "Source changed while copying: $relative"
        }
        $manifest.Add([ordered]@{ path = $relative; sha256 = $hash.ToLowerInvariant() })
    }
    Assert-LocalBaselineSourceUnchanged -RepositoryRoot $root -Manifest @($manifest)
    return @($manifest)
}

function Assert-LocalBaselineSourceUnchanged {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][object[]]$Manifest)

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $actual = @(Get-LocalBaselineSourceFiles -RepositoryRoot $root)
    if (@(Compare-Object @($Manifest.path) $actual).Count -ne 0) {
        throw 'Authored source inventory changed during local validation.'
    }
    foreach ($entry in $Manifest) {
        $path = Join-Path $root ($entry.path.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256) {
            throw "Source changed during local validation: $($entry.path)"
        }
    }
}

function Test-LocalBaselinePowerShellSyntax {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][object[]]$Manifest)

    $count = 0
    foreach ($entry in $Manifest | Where-Object { $_.path -match '\.(ps1|psm1|psd1)$' }) {
        $path = Join-Path $SourceRoot ($entry.path.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -ne 0) {
            $locations = @($errors | ForEach-Object { "$($_.ErrorId):$($_.Extent.StartLineNumber)" }) -join ', '
            throw "PowerShell syntax failed for $($entry.path): $locations"
        }
        $count++
    }
    if ($count -eq 0) { throw 'No authored PowerShell source was parsed.' }
    return $count
}

function Remove-LocalBaselineWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace, [Parameter(Mandatory)][string]$RepositoryRoot)

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $full = [IO.Path]::GetFullPath($Workspace)
    $name = [IO.Path]::GetFileName($full)
    $expected = Join-Path (Join-Path $root '.test-work') $name
    if ($name -cnotmatch '^m1-[0-9a-f]{32}$' -or $full -cne $expected) {
        throw 'Cleanup refused: not an exact owned local-baseline run directory.'
    }
    Assert-LocalBaselineUnlinkedPath -Path $full -Root $root
    $marker = Join-Path $full '.local-baseline-owner'
    if (-not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne $name) {
        throw 'Cleanup refused: local-baseline ownership marker does not match.'
    }
    foreach ($item in Get-ChildItem -LiteralPath $full -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Cleanup refused: the local-baseline run contains a linked path.'
        }
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}

function Assert-LocalBaselineTestResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.File]::Exists($Path)) { throw 'Expected test result file was not produced.' }
    $document = [xml][IO.File]::ReadAllText($Path)
    $counters = $document.TestRun.ResultSummary.Counters
    if ([int]$counters.total -le 0 -or
        [int]$counters.executed -ne [int]$counters.total -or
        [int]$counters.passed -ne [int]$counters.total -or
        [int]$counters.failed -ne 0 -or [int]$counters.notExecuted -ne 0) {
        throw 'Local tests must all execute and pass; empty, skipped or partial runs are not acceptance.'
    }
    return [int]$counters.passed
}

function Get-LocalBaselineTestSelection {
    [CmdletBinding()]
    param([switch]$IncludeSql)

    foreach ($name in @(
        'Gateway.SourceTests', 'Gateway.UnitTests', 'Gateway.ObservabilityRuntime.Tests',
        'Gateway.AdminUi.Tests', 'Gateway.Setup.Tests', 'Gateway.Tooling.Tests'
    )) {
        [pscustomobject]@{ Name = $name; Sql = $false }
    }
    if ($IncludeSql) {
        [pscustomobject]@{ Name = 'Gateway.IntegrationTests'; Sql = $true }
    }
}

Export-ModuleMember -Function Get-LocalBaselineSourceFiles, Assert-LocalBaselineUnlinkedPath,
    New-LocalBaselineSnapshot, Test-LocalBaselinePowerShellSyntax, Remove-LocalBaselineWorkspace,
    Assert-LocalBaselineTestResult, Get-LocalBaselineTestSelection, Assert-LocalBaselineSourceUnchanged
