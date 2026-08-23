#Requires -Version 7.0

<#
.SYNOPSIS
    Deployment orchestrator for the A365 Custom Gateway.

.DESCRIPTION
    Orchestrates a full deployment of the A365 Custom Gateway to Azure Container Apps.
    Performs pre-flight validation, deploys Bicep infrastructure, configures SQL users
    for managed identities, and runs health checks against the deployed API.

    This script assumes the caller is already authenticated with Azure CLI (az login)
    and has sufficient permissions on the target subscription and resource group.

.PARAMETER Environment
    Target deployment environment. Must be one of: dev, staging, prod.

.PARAMETER ResourceGroup
    Name of the Azure resource group. Default: rg-agent-gateway.

.PARAMETER SubscriptionId
    Azure subscription ID. Default: 95bedc30-f6ac-481b-a3a6-588d2883c216.

.PARAMETER ApiImage
    Full ACR image path for the Gateway API container (e.g., myacr.azurecr.io/gateway-api:abc1234).
    When omitted, the Bicep parameter file default is used.

.PARAMETER WorkerImage
    Full ACR image path for the Provisioning Worker container (e.g., myacr.azurecr.io/gateway-worker:abc1234).
    When omitted, the Bicep parameter file default is used.

.PARAMETER SkipInfra
    Skip the Bicep infrastructure deployment step.

.PARAMETER SkipSqlSetup
    Skip the SQL managed-identity user creation step.

.EXAMPLE
    ./deploy.ps1 -Environment dev

.EXAMPLE
    ./deploy.ps1 -Environment staging -ApiImage myacr.azurecr.io/gateway-api:v1.2.3 -WorkerImage myacr.azurecr.io/gateway-worker:v1.2.3

.EXAMPLE
    ./deploy.ps1 -Environment prod -SkipInfra -SkipSqlSetup
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
    [string]$ApiImage,

    [Parameter(Mandatory = $false)]
    [string]$WorkerImage,

    [switch]$SkipInfra,

    [switch]$SkipSqlSetup
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Constants
# ============================================================================

$ScriptDir = $PSScriptRoot
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
$BicepDir = Join-Path $RepoRoot 'deploy' 'bicep'
$TemplateFile = Join-Path $BicepDir 'main.bicep'
$ParameterFile = Join-Path $BicepDir 'parameters' "$Environment.bicepparam"
$SetupSqlScript = Join-Path $ScriptDir 'setup-sql-user.ps1'
$DeploymentName = "a365gw-$Environment-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$RequiredProviders = @(
    'Microsoft.App',
    'Microsoft.ContainerRegistry',
    'Microsoft.Sql',
    'Microsoft.ServiceBus',
    'Microsoft.KeyVault',
    'Microsoft.OperationalInsights',
    'Microsoft.Insights',
    'Microsoft.Storage'
)

$HealthCheckMaxRetries = 10
$HealthCheckDelaySeconds = 15

# ============================================================================
# Helper Functions
# ============================================================================

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

function Write-Warning {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Failure {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor White
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

# ============================================================================
# Step 1: Pre-flight Checks
# ============================================================================

function Invoke-PreflightChecks {
    Write-StepHeader 'Step 1: Pre-flight Checks'

    # Verify Azure CLI is installed
    Write-Info 'Checking Azure CLI installation...'
    $azVersion = $null
    try {
        $azVersion = & az version --output json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw 'az CLI returned a non-zero exit code.'
        }
    }
    catch {
        Write-Failure 'Azure CLI (az) is not installed or not in PATH.'
        Write-Failure 'Install from: https://learn.microsoft.com/cli/azure/install-azure-cli'
        throw 'Pre-flight check failed: Azure CLI not found.'
    }
    Write-Success 'Azure CLI is installed.'

    # Set subscription
    Write-Info "Setting subscription to $SubscriptionId..."
    Invoke-AzCommand -Arguments @('account', 'set', '--subscription', $SubscriptionId) `
        -ErrorMessage "Failed to set subscription $SubscriptionId. Ensure you are logged in (az login) and have access."
    Write-Success "Subscription set to $SubscriptionId."

    # Verify resource group exists
    Write-Info "Verifying resource group '$ResourceGroup' exists..."
    try {
        Invoke-AzCommand -Arguments @('group', 'show', '--name', $ResourceGroup, '--output', 'none') `
            -ErrorMessage "Resource group '$ResourceGroup' not found."
    }
    catch {
        Write-Failure "Resource group '$ResourceGroup' does not exist."
        Write-Failure "Create it first: az group create --name $ResourceGroup --location koreacentral"
        throw
    }
    Write-Success "Resource group '$ResourceGroup' exists."

    # Verify Bicep files exist (unless skipping infra)
    if (-not $SkipInfra) {
        Write-Info 'Verifying Bicep template and parameter files...'
        if (-not (Test-Path $TemplateFile)) {
            throw "Bicep template not found: $TemplateFile"
        }
        if (-not (Test-Path $ParameterFile)) {
            throw "Parameter file not found: $ParameterFile"
        }
        Write-Success 'Bicep template and parameter files found.'
    }

    # Verify SQL setup script exists (unless skipping SQL)
    if (-not $SkipSqlSetup) {
        Write-Info 'Verifying SQL setup script...'
        if (-not (Test-Path $SetupSqlScript)) {
            throw "SQL setup script not found: $SetupSqlScript"
        }
        Write-Success 'SQL setup script found.'
    }

    # Register required resource providers
    Write-Info 'Registering required Azure resource providers...'
    foreach ($provider in $RequiredProviders) {
        Write-Info "  Registering $provider..."
        try {
            Invoke-AzCommand -Arguments @('provider', 'register', '--namespace', $provider, '--wait') `
                -ErrorMessage "Failed to register provider $provider."
        }
        catch {
            # Provider registration can fail for permissions but may already be registered.
            Write-Warning "Could not register $provider. It may already be registered or you may lack permissions."
        }
    }
    Write-Success 'Resource provider registration complete.'
}

# ============================================================================
# Step 2: Deploy Infrastructure
# ============================================================================

function Invoke-InfraDeployment {
    Write-StepHeader 'Step 2: Deploy Infrastructure (Bicep)'

    if ($SkipInfra) {
        Write-Warning 'Infrastructure deployment skipped (-SkipInfra).'
        return $null
    }

    # Build the deployment arguments
    $deployArgs = @(
        'deployment', 'group', 'create',
        '--resource-group', $ResourceGroup,
        '--name', $DeploymentName,
        '--template-file', $TemplateFile,
        '--parameters', $ParameterFile,
        '--output', 'json',
        '--no-prompt', 'true'
    )

    # Add image overrides if provided
    $overrides = @()
    if ($ApiImage) {
        $overrides += "apiContainerImage=$ApiImage"
        Write-Info "API image override: $ApiImage"
    }
    if ($WorkerImage) {
        $overrides += "workerContainerImage=$WorkerImage"
        Write-Info "Worker image override: $WorkerImage"
    }
    foreach ($override in $overrides) {
        $deployArgs += $override
    }

    Write-Info "Deployment name: $DeploymentName"
    Write-Info 'Running Bicep deployment (this may take several minutes)...'

    $rawOutput = Invoke-AzCommand -Arguments $deployArgs `
        -ErrorMessage 'Bicep deployment failed.'

    $deploymentResult = ($rawOutput | Out-String) | ConvertFrom-Json

    if ($deploymentResult.properties.provisioningState -ne 'Succeeded') {
        throw "Deployment did not succeed. State: $($deploymentResult.properties.provisioningState)"
    }

    Write-Success "Deployment '$DeploymentName' succeeded."

    # Extract outputs
    $outputs = $deploymentResult.properties.outputs
    return $outputs
}

# ============================================================================
# Step 3: Setup SQL Users
# ============================================================================

function Invoke-SqlUserSetup {
    param(
        [object]$DeploymentOutputs
    )

    Write-StepHeader 'Step 3: Setup SQL Managed Identity Users'

    if ($SkipSqlSetup) {
        Write-Warning 'SQL user setup skipped (-SkipSqlSetup).'
        return
    }

    # Determine SQL server FQDN and identity names.
    # These come from deployment outputs or conventional naming.
    $sqlFqdn = $null
    $apiIdentityName = "ca-gateway-api-$Environment"
    $workerIdentityName = "ca-gateway-worker-$Environment"

    if ($DeploymentOutputs -and $DeploymentOutputs.sqlServerFqdn) {
        $sqlFqdn = $DeploymentOutputs.sqlServerFqdn.value
    }
    else {
        # Query the SQL server from the resource group
        Write-Info 'Deployment outputs not available. Querying SQL server from resource group...'
        $sqlServers = Invoke-AzCommand -Arguments @(
            'sql', 'server', 'list',
            '--resource-group', $ResourceGroup,
            '--query', '[0].fullyQualifiedDomainName',
            '--output', 'tsv'
        ) -ErrorMessage 'Failed to query SQL servers in the resource group.'
        $sqlFqdn = ($sqlServers | Out-String).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($sqlFqdn)) {
        Write-Warning 'No SQL server found. Skipping SQL user setup.'
        return
    }

    Write-Info "SQL Server FQDN: $sqlFqdn"
    Write-Info "API identity name: $apiIdentityName"
    Write-Info "Worker identity name: $workerIdentityName"

    & $SetupSqlScript `
        -SqlServerFqdn $sqlFqdn `
        -DatabaseName 'GatewayDb' `
        -ApiManagedIdentityName $apiIdentityName `
        -WorkerManagedIdentityName $workerIdentityName

    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Failure 'SQL user setup returned a non-zero exit code.'
        throw 'SQL user setup failed.'
    }

    Write-Success 'SQL user setup complete.'
}

# ============================================================================
# Step 4: Health Check
# ============================================================================

function Invoke-HealthCheck {
    param(
        [object]$DeploymentOutputs
    )

    Write-StepHeader 'Step 4: Health Check'

    $apiFqdn = $null

    if ($DeploymentOutputs -and $DeploymentOutputs.apiFqdn) {
        $apiFqdn = $DeploymentOutputs.apiFqdn.value
    }
    else {
        # Try to get the FQDN from the container app
        Write-Info 'Deployment outputs not available. Querying API container app FQDN...'
        $appName = "ca-gateway-api-$Environment"
        try {
            $fqdnResult = Invoke-AzCommand -Arguments @(
                'containerapp', 'show',
                '--name', $appName,
                '--resource-group', $ResourceGroup,
                '--query', 'properties.configuration.ingress.fqdn',
                '--output', 'tsv'
            ) -ErrorMessage "Failed to query FQDN for container app '$appName'."
            $apiFqdn = ($fqdnResult | Out-String).Trim()
        }
        catch {
            Write-Warning "Could not determine API FQDN. Skipping health check."
            return
        }
    }

    if ([string]::IsNullOrWhiteSpace($apiFqdn)) {
        Write-Warning 'API FQDN not available. Skipping health check.'
        return
    }

    $healthUrl = "https://$apiFqdn/health/checks"
    Write-Info "Health endpoint: $healthUrl"
    Write-Info "Waiting for API to become healthy (max $HealthCheckMaxRetries retries, ${HealthCheckDelaySeconds}s interval)..."

    $healthy = $false
    for ($i = 1; $i -le $HealthCheckMaxRetries; $i++) {
        Write-Info "  Attempt $i of $HealthCheckMaxRetries..."
        try {
            $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                Write-Success "API is healthy (HTTP $($response.StatusCode))."
                $healthy = $true
                break
            }
            else {
                Write-Warning "API returned HTTP $($response.StatusCode). Retrying..."
            }
        }
        catch {
            Write-Warning "Health check failed: $($_.Exception.Message). Retrying..."
        }

        if ($i -lt $HealthCheckMaxRetries) {
            Start-Sleep -Seconds $HealthCheckDelaySeconds
        }
    }

    if (-not $healthy) {
        Write-Failure "API did not become healthy after $HealthCheckMaxRetries attempts."
        Write-Warning 'The deployment may still be starting up. Check container logs:'
        Write-Warning "  az containerapp logs show --name ca-gateway-api-$Environment --resource-group $ResourceGroup --follow"
    }
}

# ============================================================================
# Step 5: Summary
# ============================================================================

function Write-DeploymentSummary {
    param(
        [object]$DeploymentOutputs
    )

    Write-StepHeader 'Deployment Summary'

    Write-Host "  Environment:      $Environment" -ForegroundColor White
    Write-Host "  Resource Group:   $ResourceGroup" -ForegroundColor White
    Write-Host "  Subscription:     $SubscriptionId" -ForegroundColor White
    Write-Host "  Deployment:       $DeploymentName" -ForegroundColor White
    Write-Host ''

    if ($DeploymentOutputs) {
        Write-Host '  Deployment Outputs:' -ForegroundColor White
        $DeploymentOutputs.PSObject.Properties | ForEach-Object {
            $outputName = $_.Name
            $outputValue = $_.Value.value
            Write-Host "    $($outputName): $outputValue" -ForegroundColor Gray
        }
    }
    else {
        Write-Warning 'No deployment outputs available (infrastructure may have been skipped).'
    }

    Write-Host ''
    Write-Success 'Deployment orchestration complete.'
}

# ============================================================================
# Main Execution
# ============================================================================

try {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host ''
    Write-Host '  A365 Custom Gateway - Deployment Orchestrator' -ForegroundColor Cyan
    Write-Host "  Target: $Environment | Resource Group: $ResourceGroup" -ForegroundColor Cyan
    Write-Host ''

    # Step 1: Pre-flight
    Invoke-PreflightChecks

    # Step 2: Infrastructure
    $outputs = Invoke-InfraDeployment

    # Step 3: SQL Users
    Invoke-SqlUserSetup -DeploymentOutputs $outputs

    # Step 4: Health Check
    Invoke-HealthCheck -DeploymentOutputs $outputs

    # Step 5: Summary
    Write-DeploymentSummary -DeploymentOutputs $outputs

    $stopwatch.Stop()
    Write-Host ''
    Write-Success "Total elapsed time: $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))"
    exit 0
}
catch {
    Write-Failure "Deployment failed: $($_.Exception.Message)"
    Write-Failure "Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
