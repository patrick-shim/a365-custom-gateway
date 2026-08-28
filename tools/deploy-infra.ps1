#Requires -Version 7.0

<#
.SYNOPSIS
    Creates the Azure resource group and deploys all Bicep infrastructure for the A365 Custom Gateway.

.DESCRIPTION
    A wrapper script that ensures the target Azure resource group exists and then
    delegates to operations/deploy.ps1 for the full Bicep infrastructure deployment.

    The script performs the following steps:
      1. Verifies Azure CLI login via Assert-AzLogin.
      2. Sets the active Azure subscription.
      3. Creates the resource group if it does not already exist (idempotent).
      4. Validates that all required environment variables are set.
      5. Forwards to operations/deploy.ps1 with the provided parameters.
      6. Captures and displays key deployment outputs (ACR, SQL, API FQDN, Key Vault).

    All helpers (Assert-AzLogin, Invoke-AzCommand, Get-DeploymentOutputs, etc.)
    are loaded from tools/_common.ps1.

.PARAMETER Environment
    Target deployment environment. Must be one of: dev, staging, prod.

.PARAMETER ResourceGroup
    Name of the Azure resource group. Default: rg-agent-gateway.

.PARAMETER SubscriptionId
    Azure subscription ID. Default: 95bedc30-f6ac-481b-a3a6-588d2883c216.

.PARAMETER Location
    Azure region for the resource group. Default: koreacentral.

.PARAMETER SkipSqlSetup
    When specified, the -SkipSqlSetup flag is forwarded to deploy.ps1, skipping
    SQL managed-identity user creation.

.EXAMPLE
    ./deploy-infra.ps1 -Environment dev

    Creates the resource group (if needed) and deploys dev infrastructure.

.EXAMPLE
    ./deploy-infra.ps1 -Environment staging -ResourceGroup rg-gateway-staging -Location westeurope

    Deploys staging infrastructure into a custom resource group and region.

.EXAMPLE
    ./deploy-infra.ps1 -Environment prod -SkipSqlSetup

    Deploys prod infrastructure, skipping the SQL managed-identity user setup.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = 'rg-agent-gateway',

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = '95bedc30-f6ac-481b-a3a6-588d2883c216',

    [Parameter(Mandatory = $false)]
    [string]$Location = 'koreacentral',

    [switch]$SkipSqlSetup
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_common.ps1')

# ============================================================================
# Required environment variables for Bicep deployment
# ============================================================================

$RequiredEnvVars = @(
    'ENTRA_CLIENT_ID',
    'ENTRA_AUDIENCE',
    'ENTRA_ADMIN_OBJECT_ID',
    'ENTRA_ADMIN_LOGIN',
    'ALERT_EMAIL'
)

# ============================================================================
# Main Execution
# ============================================================================

try {
    Write-Host ''
    Write-Host '  A365 Custom Gateway - Infrastructure Deployment' -ForegroundColor Cyan
    Write-Host "  Target: $Environment | Resource Group: $ResourceGroup | Location: $Location" -ForegroundColor Cyan
    Write-Host ''

    # ------------------------------------------------------------------
    # Step 1: Verify Azure CLI login
    # ------------------------------------------------------------------
    Write-StepHeader 'Step 1: Verify Azure CLI Login'
    Assert-AzLogin

    # ------------------------------------------------------------------
    # Step 2: Set subscription
    # ------------------------------------------------------------------
    Write-StepHeader 'Step 2: Set Azure Subscription'
    Write-Info "Setting subscription to $SubscriptionId..."
    Invoke-AzCommand -Arguments @('account', 'set', '--subscription', $SubscriptionId) `
        -ErrorMessage "Failed to set subscription $SubscriptionId. Ensure you have access."
    Write-Success "Subscription set to $SubscriptionId."

    # ------------------------------------------------------------------
    # Step 3: Create resource group (idempotent)
    # ------------------------------------------------------------------
    Write-StepHeader 'Step 3: Create Resource Group'
    Write-Info "Ensuring resource group '$ResourceGroup' exists in '$Location'..."
    Invoke-AzCommand -Arguments @(
        'group', 'create',
        '--name', $ResourceGroup,
        '--location', $Location,
        '--tags', "project=a365-gateway", "environment=$Environment"
    ) -ErrorMessage "Failed to create resource group '$ResourceGroup' in '$Location'."
    Write-Success "Resource group '$ResourceGroup' is ready."

    # ------------------------------------------------------------------
    # Step 4: Validate required environment variables
    # ------------------------------------------------------------------
    Write-StepHeader 'Step 4: Validate Environment Variables'
    $missingVars = @()
    foreach ($varName in $RequiredEnvVars) {
        $value = [System.Environment]::GetEnvironmentVariable($varName)
        if ([string]::IsNullOrWhiteSpace($value)) {
            $missingVars += $varName
            Write-Failure "  Missing: $varName"
        }
        else {
            Write-Success "  Set:     $varName"
        }
    }
    if ($missingVars.Count -gt 0) {
        throw "Required environment variables are not set: $($missingVars -join ', '). Set them before running this script."
    }
    Write-Success 'All required environment variables are set.'

    # ------------------------------------------------------------------
    # Step 5: Forward to deploy.ps1
    # ------------------------------------------------------------------
    Write-StepHeader 'Step 5: Run Infrastructure Deployment'
    $deployScript = Join-Path $RepoRoot 'operations' 'deploy.ps1'

    if (-not (Test-Path $deployScript)) {
        throw "Deploy script not found: $deployScript"
    }

    Write-Info "Invoking $deployScript..."

    $deployArgs = @{
        Environment    = $Environment
        ResourceGroup  = $ResourceGroup
        SubscriptionId = $SubscriptionId
    }
    if ($SkipSqlSetup) { $deployArgs['SkipSqlSetup'] = $true }

    & $deployScript @deployArgs

    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "deploy.ps1 exited with code $LASTEXITCODE."
    }

    Write-Success 'deploy.ps1 completed successfully.'

    # ------------------------------------------------------------------
    # Step 6: Capture and display deployment outputs
    # ------------------------------------------------------------------
    Write-StepHeader 'Step 6: Deployment Outputs'
    Write-Info 'Retrieving deployment outputs...'

    $outputs = Get-DeploymentOutputs -ResourceGroup $ResourceGroup

    $keyOutputs = @('acrLoginServer', 'sqlServerFqdn', 'apiFqdn', 'keyVaultUri')
    Write-Host ''
    foreach ($key in $keyOutputs) {
        $value = $outputs.$key.value
        if ($value) {
            Write-Host "  $($key): $value" -ForegroundColor White
        }
        else {
            Write-Warn "  $($key): (not found in deployment outputs)"
        }
    }
    Write-Host ''

    Write-Success 'Infrastructure deployment complete.'

    # Return the outputs object for programmatic consumption
    $outputs
    exit 0
}
catch {
    Write-Failure "Infrastructure deployment failed: $($_.Exception.Message)"
    Write-Failure "Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
