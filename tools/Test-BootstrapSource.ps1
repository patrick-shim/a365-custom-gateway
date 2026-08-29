#Requires -Version 7.0

<#+
.SYNOPSIS
    Runs the cross-platform, non-mutating bootstrap source gate.

.DESCRIPTION
    Parses every bootstrap PowerShell source file, validates the checked-in JSON
    artifacts, optionally runs the isolated Pester suite, and optionally compiles
    every Bicep template. It performs no Azure sign-in and no resource mutation.
#>

[CmdletBinding()]
param(
    [switch]$RunPester,
    [switch]$CompileBicep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$bootstrapRoot = Join-Path $repositoryRoot 'bootstrap'

$powerShellFiles = @(
    Get-ChildItem -LiteralPath $bootstrapRoot -Recurse -File |
        Where-Object Extension -in @('.ps1', '.psm1')
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'src/Gateway.Purview/Automation') -Recurse -File |
        Where-Object Extension -in @('.ps1', '.psm1')
)
$transitiveRuntimeFiles = @(
    'tools/apply-migrations.ps1',
    'tools/_common.ps1',
    'tools/configure-workflow-v3-entra.ps1',
    'tools/generate-local-config.ps1',
    'operations/test-provisioning-prerequisites.ps1'
)
foreach ($relativePath in $transitiveRuntimeFiles) {
    $fullPath = Join-Path $repositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Required bootstrap-adjacent PowerShell source is missing: $relativePath"
    }
    $powerShellFiles += Get-Item -LiteralPath $fullPath
}
$rootGatewayScript = Join-Path $repositoryRoot 'gateway.ps1'
if (Test-Path -LiteralPath $rootGatewayScript) {
    $powerShellFiles += Get-Item -LiteralPath $rootGatewayScript
}
$powerShellFiles = @($powerShellFiles | Sort-Object FullName -Unique)

$parseFailures = [Collections.Generic.List[string]]::new()
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors)
    foreach ($parseError in @($errors)) {
        $relativePath = [IO.Path]::GetRelativePath($repositoryRoot, $file.FullName)
        $parseFailures.Add("${relativePath}:$($parseError.Extent.StartLineNumber): $($parseError.Message)")
    }
}
if ($parseFailures.Count -gt 0) {
    throw "Bootstrap PowerShell parsing failed:`n$($parseFailures -join "`n")"
}

foreach ($jsonPath in @(
    (Join-Path $bootstrapRoot 'config.example.json'),
    (Join-Path $bootstrapRoot 'config.schema.json')
)) {
    Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 100 | Out-Null
}

if ($RunPester) {
    $invokePester = Get-Command Invoke-Pester -ErrorAction SilentlyContinue
    if (-not $invokePester) {
        throw 'Invoke-Pester is unavailable. Install Pester 5.6.1 or later for the bootstrap behavior gate.'
    }
    $pesterPaths = @(
        (Join-Path $repositoryRoot 'tests/Bootstrap.Tests'),
        (Join-Path $repositoryRoot 'tests/Gateway.Purview.Tests')
    )
    foreach ($pesterPath in $pesterPaths) {
        if (-not (Test-Path -LiteralPath $pesterPath)) {
            throw "Required Pester tests are missing at '$pesterPath'."
        }
    }
    $result = Invoke-Pester -Path $pesterPaths -PassThru -Output Detailed
    $failedContainerCount = if ($result.PSObject.Properties.Name -contains 'FailedContainers') {
        @($result.FailedContainers).Count
    }
    else { 0 }
    if ($result.FailedCount -gt 0 -or $failedContainerCount -gt 0) {
        throw "Bootstrap/runtime Pester failed: $($result.FailedCount) failed test(s), $failedContainerCount failed container(s)."
    }
}

if ($CompileBicep) {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required to compile the Bicep source.'
    }
    $bicepFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'bootstrap/infra') -Filter '*.bicep' -Recurse -File
        Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'infrastructure/bicep') -Filter '*.bicep' -Recurse -File
    ) | Sort-Object FullName -Unique
    foreach ($file in $bicepFiles) {
        & az bicep build --file $file.FullName --stdout --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $relativePath = [IO.Path]::GetRelativePath($repositoryRoot, $file.FullName)
            throw "Bicep compilation failed for '$relativePath'."
        }
    }
}

Write-Host "Bootstrap source gate passed: $($powerShellFiles.Count) PowerShell files and 2 JSON files$(if ($CompileBicep) { ', with Bicep compilation' } else { '' })$(if ($RunPester) { ', with Pester behavior tests' } else { '' })."
