#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$IncludeSql,
    [switch]$KeepWorkDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalBaseline.psm1') -Force

$repository = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$runName = "m1-$([guid]::NewGuid().ToString('N'))"
$workspace = Join-Path (Join-Path $repository '.test-work') $runName
Assert-LocalBaselineUnlinkedPath -Path $workspace -Root $repository
[IO.Directory]::CreateDirectory($workspace) | Out-Null
[IO.File]::WriteAllText((Join-Path $workspace '.local-baseline-owner'), $runName)
$source = Join-Path $workspace 'source'
$environmentNames = @('DOTNET_CLI_UI_LANGUAGE', 'DOTNET_CLI_TELEMETRY_OPTOUT', 'DOTNET_NOLOGO')
$previousEnvironment = @{}
foreach ($name in $environmentNames) { $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
$oldLocation = Get-Location

function Invoke-LocalDotnet {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Local dotnet $($Arguments[0]) failed with exit code $LASTEXITCODE."
    }
}

function Invoke-LocalTests {
    param([Parameter(Mandatory)][string]$Project, [Parameter(Mandatory)][bool]$Sql)

    $filter = if ($Sql) { 'Category=SqlServer' } else { 'Category!=SqlServer' }
    $suffix = if ($Sql) { 'sql' } else { 'local' }
    $results = Join-Path $workspace 'results'
    $resultName = "$([IO.Path]::GetFileNameWithoutExtension($Project)).$suffix.trx"
    Invoke-LocalDotnet -Arguments @('test', $Project, '--configuration', 'Release',
        '--no-build', '--no-restore', '--filter', $filter,
        '--logger', "trx;LogFileName=$resultName", '--results-directory', $results)
    $passed = Assert-LocalBaselineTestResult -Path (Join-Path $results $resultName)
    Write-Host "Verified $resultName : $passed executed and passed, none skipped."
}

try {
    $env:DOTNET_CLI_UI_LANGUAGE = 'en'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    $manifest = @(New-LocalBaselineSnapshot -RepositoryRoot $repository -Destination $source)
    $syntaxCount = Test-LocalBaselinePowerShellSyntax -SourceRoot $source -Manifest $manifest
    Write-Host "PowerShell $($PSVersionTable.PSVersion): copied $($manifest.Count) authored files; parsed $syntaxCount PowerShell sources. No bin/obj or operational state copied."
    Set-Location -LiteralPath $source
    Invoke-LocalDotnet -Arguments @('--version')
    $solution = Join-Path $source 'src\A365Gateway.slnx'
    Invoke-LocalDotnet -Arguments @('restore', $solution, '--disable-parallel')
    Invoke-LocalDotnet -Arguments @('build', $solution, '--configuration', 'Release', '--no-restore', '--maxcpucount:1')

    foreach ($project in Get-LocalBaselineTestSelection -IncludeSql:$IncludeSql) {
        $path = Join-Path $source "tests\$($project.Name)\$($project.Name).csproj"
        if (-not [IO.File]::Exists($path)) { throw "Required baseline test project is absent: $($project.Name)" }
        Invoke-LocalTests -Project $path -Sql $project.Sql
    }
    if (-not $IncludeSql) {
        Write-Host 'Real SQL checks were not requested. Run with -IncludeSql to verify transactions; this run is not SQL acceptance.'
    }
    Import-Module Pester -RequiredVersion 5.6.1 -ErrorAction Stop
    $pesterResult = Invoke-Pester -Path (Join-Path $source 'tests\LocalBaseline.Tests') -Output Detailed -PassThru
    if ($pesterResult.FailedCount -ne 0 -or $pesterResult.PassedCount -eq 0 -or $pesterResult.SkippedCount -ne 0) {
        throw 'Local baseline PowerShell safety checks did not all execute successfully.'
    }
    $powerShell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    foreach ($script in @(
        'test-gateway-upgrade-packaging.ps1',
        'test-gateway-upgrade-abort.ps1',
        'test-purview-policy-metadata.ps1'
    )) {
        $output = @(& $powerShell -NoLogo -NoProfile -NonInteractive -File (Join-Path $source "operations\$script"))
        if ($LASTEXITCODE -ne 0 -or @($output | Where-Object { $_ -cmatch '^PASS: ' }).Count -ne 1) {
            throw "Portable source check did not produce its passing result: $script"
        }
        $output | ForEach-Object { Write-Host $_ }
    }
    Assert-LocalBaselineSourceUnchanged -RepositoryRoot $repository -Manifest $manifest
    Write-Host 'Local source/build/fixture validation completed. No deployment or live-provider behavior is claimed.'
}
finally {
    Set-Location -LiteralPath $oldLocation.Path
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name]) }
    if ($KeepWorkDirectory) { Write-Host "Local baseline work directory retained: $workspace" }
    else { Remove-LocalBaselineWorkspace -Workspace $workspace -RepositoryRoot $repository }
}
