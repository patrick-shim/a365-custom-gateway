#Requires -Version 7.0

# Shared helpers for A365 Gateway bootstrap tooling.
# Dot-source this file from any script: . (Join-Path $PSScriptRoot '_common.ps1')

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# ARM64 Windows workaround: NuGet crashes if ProgramFiles(x86) is unset.
if (-not [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) {
    [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', 'C:\Program Files (x86)')
}

function Write-StepHeader {
    param([string]$Message)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Failure {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor White
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Get-A365GatewayBootstrapSubscriptionId {
    [CmdletBinding()]
    param([switch]$Required)

    $raw = [Environment]::GetEnvironmentVariable('A365GW_BOOTSTRAP_SUBSCRIPTION_ID')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        if ($Required) {
            throw 'A365GW_BOOTSTRAP_SUBSCRIPTION_ID must be set by the verified bootstrap Azure login before this operation.'
        }
        return $null
    }

    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($raw, 'D', [ref]$parsed) -or
        $parsed -eq [guid]::Empty -or
        $raw -cne $parsed.ToString('D')) {
        throw 'A365GW_BOOTSTRAP_SUBSCRIPTION_ID must be one canonical, non-empty lowercase GUID.'
    }

    return $parsed.ToString('D')
}

function Add-A365GatewayAzureSubscriptionPin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,

        [switch]$Required
    )

    $subscriptionId = Get-A365GatewayBootstrapSubscriptionId -Required:$Required
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        return @($Arguments)
    }

    $explicitValues = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = [string]$Arguments[$index]
        if ($argument -ceq '--subscription') {
            if ($index + 1 -ge $Arguments.Count -or
                [string]::IsNullOrWhiteSpace([string]$Arguments[$index + 1])) {
                throw 'Azure CLI --subscription requires the exact pinned subscription ID.'
            }
            $explicitValues.Add([string]$Arguments[$index + 1])
        }
        elseif ($argument.StartsWith('--subscription=', [StringComparison]::Ordinal)) {
            $explicitValues.Add($argument.Substring('--subscription='.Length))
        }
    }

    if ($explicitValues.Count -gt 1) {
        throw 'Azure CLI arguments contain more than one explicit subscription target.'
    }
    if ($explicitValues.Count -eq 1) {
        if ($explicitValues[0] -cne $subscriptionId) {
            throw 'Azure CLI arguments do not match the exact bootstrap subscription pin.'
        }
        return @($Arguments)
    }

    return @($Arguments) + @('--subscription', $subscriptionId)
}

function Invoke-AzCommand {
    param(
        [string[]]$Arguments,
        [string]$ErrorMessage = 'Azure CLI command failed.'
    )

    $effectiveArguments = Add-A365GatewayAzureSubscriptionPin -Arguments $Arguments
    $output = & az @effectiveArguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$ErrorMessage Azure CLI category: command failed; exit code: $exitCode. Provider output was suppressed."
    }
    return $output
}

function Assert-AzLogin {
    Write-Info 'Verifying Azure CLI login...'
    try {
        $account = (Invoke-AzCommand -Arguments @('account', 'show', '--output', 'json') `
                -ErrorMessage 'Not logged in.') | Out-String | ConvertFrom-Json
    }
    catch {
        Write-Failure 'Not logged in to Azure CLI. Run: az login'
        throw 'Azure CLI authentication verification failed without rendering account or provider details.'
    }
    Write-Success 'Azure CLI authentication is available.'
    return $account
}

function Assert-Command {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Failure "'$Name' is not installed or not in PATH."
        if ($InstallHint) { Write-Info "Install: $InstallHint" }
        throw "Required tool '$Name' not found."
    }
}

function Get-CurrentUserObjectId {
    return (Invoke-AzCommand -Arguments @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv') `
            -ErrorMessage 'Failed to get current user object ID.' | Out-String).Trim()
}

function Get-CurrentUserUpn {
    return (Invoke-AzCommand -Arguments @('ad', 'signed-in-user', 'show', '--query', 'userPrincipalName', '-o', 'tsv') `
            -ErrorMessage 'Failed to get current user UPN.' | Out-String).Trim()
}

function Get-DeploymentOutputs {
    param(
        [string]$ResourceGroup
    )
    $name = (Invoke-AzCommand -Arguments @(
            'deployment', 'group', 'list',
            '--resource-group', $ResourceGroup,
            '--query', '[0].name', '-o', 'tsv'
        ) -ErrorMessage 'No deployments found.' | Out-String).Trim()

    $json = (Invoke-AzCommand -Arguments @(
            'deployment', 'group', 'show',
            '--resource-group', $ResourceGroup,
            '--name', $name,
            '--query', 'properties.outputs', '-o', 'json'
        ) -ErrorMessage 'Failed to get deployment outputs.' | Out-String)

    try {
        return $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'Azure deployment outputs were malformed; provider output was suppressed.'
    }
}
