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

function Invoke-AzCommand {
    param(
        [string[]]$Arguments,
        [string]$ErrorMessage = 'Azure CLI command failed.'
    )
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errorDetail = ($output | Out-String).Trim()
        throw "$ErrorMessage`nExit code: $LASTEXITCODE`nOutput: $errorDetail"
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
        throw
    }
    Write-Success "Logged in as $($account.user.name) (tenant: $($account.tenantId))"
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

    return $json | ConvertFrom-Json
}

function Get-MyPublicIp {
    try {
        return (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).Trim()
    }
    catch {
        return (Invoke-RestMethod -Uri 'https://ifconfig.me/ip' -TimeoutSec 10).Trim()
    }
}
