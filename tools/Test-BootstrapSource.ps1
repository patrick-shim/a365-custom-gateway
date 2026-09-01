#Requires -Version 7.0

<#+
.SYNOPSIS
    Runs the cross-platform, non-mutating bootstrap source gate.

.DESCRIPTION
    Parses every bootstrap PowerShell source file, validates the checked-in JSON
    artifacts, optionally runs the isolated Pester suite, and optionally compiles
    every Bicep template and parameter file. It performs no Azure sign-in and no
    resource mutation.
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

function Resolve-GatewayBicepCompilerCommand {
    [CmdletBinding()]
    param(
        [string]$AzureCliPath = '',

        [Nullable[bool]]$WindowsPlatform = $null
    )

    $effectiveWindowsPlatform = if ($null -eq $WindowsPlatform) {
        [bool]$IsWindows
    }
    else {
        [bool]$WindowsPlatform
    }
    $resolvedAzureCliPath = $AzureCliPath
    if ([string]::IsNullOrWhiteSpace($resolvedAzureCliPath)) {
        # PATH can expose more than one az application, because the Azure CLI MSI
        # installs az.cmd and an extensionless bash shim in the same wbin
        # directory. Bind exactly one command source so the resolved path is never
        # a space-joined concatenation of several candidates.
        $azCommand = @(Get-Command az -CommandType Application -ErrorAction Stop) |
            Select-Object -First 1
        $resolvedAzureCliPath = [string]$azCommand.Source
    }
    if ([string]::IsNullOrWhiteSpace($resolvedAzureCliPath)) {
        throw 'Azure CLI could not be resolved to an executable process boundary.'
    }

    if (-not $effectiveWindowsPlatform) {
        return [pscustomobject]@{
            FileName = $resolvedAzureCliPath
            PrefixArguments = @()
        }
    }

    $extension = [IO.Path]::GetExtension($resolvedAzureCliPath)
    if (-not ($extension.Equals('.exe', [StringComparison]::OrdinalIgnoreCase) -or
            $extension.Equals('.cmd', [StringComparison]::OrdinalIgnoreCase))) {
        # The Azure CLI MSI installs an extensionless bash shim beside az.cmd, and
        # PowerShell can resolve that shim. It is not a Windows executable process
        # boundary, so promote it to a supported sibling launcher in the same
        # directory instead of running it. Anything else still fails closed.
        $commandDirectory = Split-Path -Parent $resolvedAzureCliPath
        $baseName = [IO.Path]::GetFileNameWithoutExtension($resolvedAzureCliPath)
        $promoted = @('.exe', '.cmd') |
            ForEach-Object { Join-Path $commandDirectory ($baseName + $_) } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($promoted)) {
            throw 'Azure CLI could not be resolved to a supported Windows executable process boundary.'
        }
        $resolvedAzureCliPath = [string]$promoted
        $extension = [IO.Path]::GetExtension($resolvedAzureCliPath)
    }
    if ($extension.Equals('.exe', [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            FileName = $resolvedAzureCliPath
            PrefixArguments = @()
        }
    }

    $pythonPath = [IO.Path]::GetFullPath((Join-Path (
        Split-Path -Parent $resolvedAzureCliPath) '..\python.exe'))
    if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
        throw 'The Windows Azure CLI launcher could not be mapped to its bundled Python executable.'
    }

    return [pscustomobject]@{
        FileName = $pythonPath
        PrefixArguments = @('-IBm', 'azure.cli')
    }
}

function New-GatewayBicepCompilerStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Command,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [hashtable]$EnvironmentOverrides = @{}
    )

    $fileName = [string]$Command.FileName
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        throw 'The Azure CLI compiler command has no executable file name.'
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $fileName
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($prefixArgument in @($Command.PrefixArguments)) {
        [void]$startInfo.ArgumentList.Add([string]$prefixArgument)
    }
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    foreach ($environmentName in $EnvironmentOverrides.Keys) {
        $startInfo.Environment[[string]$environmentName] = [string]$EnvironmentOverrides[$environmentName]
    }

    return $startInfo
}

function Invoke-GatewayBicepCompiler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$FailureMessage,

        [hashtable]$EnvironmentOverrides = @{}
    )

    $command = Resolve-GatewayBicepCompilerCommand
    $startInfo = New-GatewayBicepCompilerStartInfo `
        -Command $command `
        -Arguments $Arguments `
        -EnvironmentOverrides $EnvironmentOverrides

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw $FailureMessage
        }

        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [void]$standardOutput.GetAwaiter().GetResult()
        $errorText = $standardError.GetAwaiter().GetResult()

        # Azure CLI 2.89.1 can emit a Bicep ERROR diagnostic while returning
        # exit code zero. Treat either signal as a failed source gate.
        if ($process.ExitCode -ne 0 -or $errorText -match '(?mi)^\s*(ERROR|FATAL):') {
            $safeDiagnostic = $errorText.Trim()
            if ([string]::IsNullOrWhiteSpace($safeDiagnostic)) {
                throw $FailureMessage
            }

            throw "$FailureMessage`n$safeDiagnostic"
        }
    }
    finally {
        $process.Dispose()
    }
}

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
    'operations/FirstRegistrationVerificationState.psm1',
    'operations/verify-first-registration.ps1',
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
        (Join-Path $repositoryRoot 'tests/Gateway.Purview.Tests'),
        (Join-Path $repositoryRoot 'tests/Operations.Tests')
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
        $relativePath = [IO.Path]::GetRelativePath($repositoryRoot, $file.FullName)
        Invoke-GatewayBicepCompiler `
            -Arguments @('bicep', 'build', '--file', $file.FullName, '--stdout', '--only-show-errors') `
            -FailureMessage "Bicep compilation failed for '$relativePath'."
    }

    $bicepParameterFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'infrastructure/bicep/parameters') -Filter '*.bicepparam' -File
    ) | Sort-Object FullName -Unique
    $parameterCompileEnvironment = @{
        # The two checked-in runtime parameter files intentionally require
        # deployment-time values. Compile them against inert placeholders so
        # source validation never consumes a caller's live runtime settings.
        CONTAINER_APPS_ENVIRONMENT_ID = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-source-validation/providers/Microsoft.App/managedEnvironments/cae-source-validation'
        API_IMAGE = 'mcr.microsoft.com/dotnet/aspnet:10.0'
        WORKER_IMAGE = 'mcr.microsoft.com/dotnet/runtime:10.0'
        APPLICATIONINSIGHTS_CONNECTION_STRING = 'InstrumentationKey=00000000-0000-0000-0000-000000000000;IngestionEndpoint=https://example.invalid/'
        ALERT_EMAIL = 'source-validation@example.invalid'
        RUNTIME_IMAGE_PULL_IDENTITY_ID = ''
        RUNTIME_IMAGE_PULL_IDENTITY_PRINCIPAL_ID = ''
        RUNTIME_IMAGE_PULL_ACR_PULL_ROLE_ASSIGNMENT_ID = ''
    }
    foreach ($file in $bicepParameterFiles) {
        $relativePath = [IO.Path]::GetRelativePath($repositoryRoot, $file.FullName)
        Invoke-GatewayBicepCompiler `
            -Arguments @('bicep', 'build-params', '--file', $file.FullName, '--stdout', '--only-show-errors') `
            -FailureMessage "Bicep parameter compilation failed for '$relativePath'." `
            -EnvironmentOverrides $parameterCompileEnvironment
    }
}

Write-Host "Bootstrap source gate passed: $($powerShellFiles.Count) PowerShell files and 2 JSON files$(if ($CompileBicep) { ", with $($bicepFiles.Count) Bicep templates and $($bicepParameterFiles.Count) parameter files compiled" } else { '' })$(if ($RunPester) { ', with Pester behavior tests' } else { '' })."
