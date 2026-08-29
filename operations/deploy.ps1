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
    Immutable ACR digest reference for the Gateway API container. Required unless
    SkipInfra is set and must use ExpectedContainerRegistryLoginServer.

.PARAMETER WorkerImage
    Immutable ACR digest reference for the Provisioning Worker container. Required
    unless SkipInfra is set and must use ExpectedContainerRegistryLoginServer.

.PARAMETER ContainerAppsEnvironmentName
    Approved existing VNet-integrated Container Apps environment shared by the API,
    worker, and Admin UI.

.PARAMETER RuntimeImagePullIdentityId
    Exact resource ID of the pre-authorized user-assigned identity used by the API
    and worker to pull from ACR. Supply this only with both matching receipt values.

.PARAMETER RuntimeImagePullIdentityPrincipalId
    Exact principal ID of RuntimeImagePullIdentityId.

.PARAMETER RuntimeImagePullAcrPullRoleAssignmentId
    Exact ACR-scoped AcrPull assignment resource ID for the pull identity.

.PARAMETER ExpectedContainerRegistryName
    Exact ACR name deployed by main.bicep and named in the runtime pull receipt.

.PARAMETER ExpectedContainerRegistryLoginServer
    Exact ACR login server hosting both immutable runtime image digests.

.PARAMETER HistoricalWorkerContainerAppName
    Existing worker retained during a blue/green migration. Provisioning-failure
    alerts continue to cover this app as well as WorkerContainerAppName.

.PARAMETER ServiceBusQueueName
    Queue used exclusively by the current N:N API and worker. Keep the historical
    worker on its legacy queue during the blue/green cutover.

.PARAMETER ApiContainerAppIsNew
    Explicit first-deployment acknowledgement for the API Container App. Omit for
    updates so the ARM deployment securely carries existing application secrets
    forward without printing them.

.PARAMETER WorkerProcessingEnabled
    Enables Service Bus processing on the current workflow worker. Defaults false
    for inert-first deployment; the bounded canary controller owns activation.

.PARAMETER EnableLegacyWorkerCredentialKeyVaultSecretsOfficer
    Explicitly retains the legacy worker Key Vault Secrets Officer role. Workflow
    v3 does not require it and the default is off.

.PARAMETER ProvisioningManagedIdentityPrincipalId
    Optional object/principal ID of the existing target worker managed identity.
    When omitted, the script resolves it read-only from the target Container App.

.PARAMETER EnableProvisioningExecution
    Enables Microsoft-side provisioning. Development only and blocked unless every
    read-only identity, permission, provider, network, and managerApplications gate
    passes. Omit for the safe default.

.PARAMETER EnableDelegatedRegistry
    Stages the development-only Gateway API OBO Registry completion capability.
    This must be combined with provisioning execution and the reviewed preview
    provider gates. API admission remains closed unless a separate bounded
    controller action supplies an expiry.

.PARAMETER SkipInfra
    Skip the Bicep infrastructure deployment step.

.PARAMETER SkipSqlSetup
    Skip the SQL managed-identity user creation step.

.EXAMPLE
    ./deploy.ps1 -Environment dev -ApiImage myacr.azurecr.io/gateway-api@sha256:<64-hex> -WorkerImage myacr.azurecr.io/gateway-worker@sha256:<64-hex> -ExpectedContainerRegistryName myacr -ExpectedContainerRegistryLoginServer myacr.azurecr.io

.EXAMPLE
    ./deploy.ps1 -Environment staging -ApiImage myacr.azurecr.io/gateway-api@sha256:<64-hex> -WorkerImage myacr.azurecr.io/gateway-worker@sha256:<64-hex> -ExpectedContainerRegistryName myacr -ExpectedContainerRegistryLoginServer myacr.azurecr.io

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

    [Parameter(Mandatory = $false)]
    [string]$ContainerAppsEnvironmentName,

    [Parameter(Mandatory = $false)]
    [string]$RuntimeImagePullIdentityId = $env:RUNTIME_IMAGE_PULL_IDENTITY_ID,

    [Parameter(Mandatory = $false)]
    [string]$RuntimeImagePullIdentityPrincipalId = $env:RUNTIME_IMAGE_PULL_IDENTITY_PRINCIPAL_ID,

    [Parameter(Mandatory = $false)]
    [string]$RuntimeImagePullAcrPullRoleAssignmentId = $env:RUNTIME_IMAGE_PULL_ACR_PULL_ROLE_ASSIGNMENT_ID,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedContainerRegistryName = $env:ACR_NAME,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedContainerRegistryLoginServer = $env:ACR_LOGIN_SERVER,

    [Parameter(Mandatory = $false)]
    [string]$WorkerContainerAppName,

    [Parameter(Mandatory = $false)]
    [string]$HistoricalWorkerContainerAppName,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ServiceBusQueueName = 'gateway-provisioning-v3',

    [switch]$ApiContainerAppIsNew,

    [Parameter(Mandatory = $false)]
    [bool]$WorkerProcessingEnabled = $false,

    [switch]$EnableLegacyWorkerCredentialKeyVaultSecretsOfficer,

    [Parameter(Mandatory = $false)]
    [string]$ProvisioningManagedIdentityPrincipalId,

    [Parameter(Mandatory = $false)]
    [string]$GatewayApiApplicationClientId = $env:ENTRA_CLIENT_ID,

    [Parameter(Mandatory = $false)]
    [string[]]$Agent365ManagerApplicationIds = @(),

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$GatewayApiFederatedCredentialName = 'a365gw-api-obo-dev',

    [switch]$EnableProvisioningExecution,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Disabled', 'DirectRegistryPreview')]
    [string]$RegistryProvider = 'Disabled',

    [switch]$EnableDirectRegistryPreview,

    [switch]$EnableDelegatedRegistry,

    [switch]$ManagerApplicationsPreflightConfirmed,

    [switch]$SkipInfra,

    [switch]$SkipSqlSetup
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ContainerAppsEnvironmentName)) {
    $ContainerAppsEnvironmentName = "cae-a365gw-$Environment-vnet"
}
if ([string]::IsNullOrWhiteSpace($WorkerContainerAppName)) {
    $WorkerContainerAppName = "ca-gateway-worker-$Environment"
}
if ([string]::IsNullOrWhiteSpace($HistoricalWorkerContainerAppName)) {
    $HistoricalWorkerContainerAppName = "ca-gateway-worker-$Environment"
}

# ============================================================================
# Constants
# ============================================================================

$ScriptDir = $PSScriptRoot
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$BicepDir = Join-Path $RepoRoot 'infrastructure' 'bicep'
$TemplateFile = Join-Path $BicepDir 'main.bicep'
$ParameterFile = Join-Path $BicepDir 'parameters' "$Environment.bicepparam"
$SetupSqlScript = Join-Path $ScriptDir 'setup-sql-user.ps1'
$ProvisioningPreflightScript = Join-Path $ScriptDir 'test-provisioning-prerequisites.ps1'
$RuntimeImagePullModule = Join-Path $ScriptDir 'RuntimeImagePull.psm1'
$DeploymentName = "a365gw-$Environment-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

if (-not (Test-Path -LiteralPath $RuntimeImagePullModule -PathType Leaf)) {
    throw "Runtime image-pull validation module not found: $RuntimeImagePullModule"
}
Import-Module $RuntimeImagePullModule -Force -ErrorAction Stop

$RequiredProviders = @(
    'Microsoft.App',
    'Microsoft.ContainerRegistry',
    'Microsoft.Sql',
    'Microsoft.ServiceBus',
    'Microsoft.KeyVault',
    'Microsoft.OperationalInsights',
    'Microsoft.Insights',
    'Microsoft.Network',
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

    # The Windows Azure CLI launcher is a .cmd wrapper. Invoking the bundled
    # Python module directly preserves JSON, URLs, and Bicep inline parameters
    # as single arguments instead of letting cmd.exe reinterpret metacharacters.
    $azCommand = Get-Command az -ErrorAction Stop
    $azPython = if ($IsWindows -and $azCommand.Source.EndsWith(
            '.cmd',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        Join-Path (Split-Path $azCommand.Source -Parent) '..\python.exe'
    }
    else {
        $null
    }

    $output = if ($null -ne $azPython -and (Test-Path -LiteralPath $azPython)) {
        & $azPython -IBm azure.cli @Arguments 2>&1
    }
    else {
        & az @Arguments 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        $errorDetail = ($output | Out-String).Trim()
        throw "$ErrorMessage`nExit code: $LASTEXITCODE`nOutput: $errorDetail"
    }
    return $output
}

function Resolve-ProvisioningManagedIdentityPrincipalId {
    $configuredPrincipalId = [guid]::Empty
    if (-not [string]::IsNullOrWhiteSpace($ProvisioningManagedIdentityPrincipalId) -and
        (-not [guid]::TryParse(
            $ProvisioningManagedIdentityPrincipalId,
            [ref]$configuredPrincipalId) -or
         $configuredPrincipalId -eq [guid]::Empty)) {
        throw 'ProvisioningManagedIdentityPrincipalId must be a valid non-empty GUID.'
    }

    $resolvedValue = & az containerapp show `
        --name $WorkerContainerAppName `
        --resource-group $ResourceGroup `
        --query identity.principalId `
        --output tsv 2>$null
    $lookupSucceeded = $LASTEXITCODE -eq 0
    $resolvedText = if ($lookupSucceeded) {
        ($resolvedValue | Out-String).Trim()
    }
    else {
        ''
    }

    $resolvedPrincipalId = [guid]::Empty
    if (-not [string]::IsNullOrWhiteSpace($resolvedText) -and
        (-not [guid]::TryParse($resolvedText, [ref]$resolvedPrincipalId) -or
         $resolvedPrincipalId -eq [guid]::Empty)) {
        throw 'The target worker returned an invalid managed-identity principal ID.'
    }

    if ($configuredPrincipalId -ne [guid]::Empty -and
        $resolvedPrincipalId -ne [guid]::Empty -and
        $configuredPrincipalId -ne $resolvedPrincipalId) {
        throw 'The supplied provisioning managed-identity principal ID does not match the target worker.'
    }

    $effectivePrincipalId = if ($configuredPrincipalId -ne [guid]::Empty) {
        $configuredPrincipalId
    }
    else {
        $resolvedPrincipalId
    }

    if ($EnableProvisioningExecution -and $effectivePrincipalId -eq [guid]::Empty) {
        throw 'Provisioning cannot be enabled until the target worker managed identity exists and its principal ID is pinned.'
    }

    if ($effectivePrincipalId -eq [guid]::Empty) {
        return ''
    }

    return $effectivePrincipalId.ToString('D')
}

# ============================================================================
# Step 1: Pre-flight Checks
# ============================================================================

function Invoke-PreflightChecks {
    Write-StepHeader 'Step 1: Pre-flight Checks'

    if ($EnableProvisioningExecution) {
        if ($Environment -ne 'dev' -or
            $RegistryProvider -ne 'DirectRegistryPreview' -or
            -not $EnableDirectRegistryPreview -or
            -not $EnableDelegatedRegistry -or
            -not $ManagerApplicationsPreflightConfirmed) {
            throw 'Provisioning execution requires development, DirectRegistryPreview, both preview gates, delegated Registry, and managerApplications preflight confirmation.'
        }
    }
    elseif ($EnableDelegatedRegistry) {
        throw 'The delegated Registry gate cannot be staged without provisioning execution; deploy inert with both gates off.'
    }

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

    if ($SkipInfra) {
        $script:RuntimeImagePullIdentityContract = [pscustomobject]@{
            Mode = 'NotEvaluatedSkipInfra'
            IdentityId = ''
            PrincipalId = ''
            RoleAssignmentId = ''
            AllowLegacySystemAssignedImagePull = $false
        }
        $script:AllowLegacySystemAssignedImagePull = $false
        Write-Info 'Runtime image-pull deployment contract skipped because SkipInfra prevents any infrastructure mutation.'
    }
    else {
        if ([string]::IsNullOrWhiteSpace($ApiImage) -or
            [string]::IsNullOrWhiteSpace($WorkerImage) -or
            [string]::IsNullOrWhiteSpace($ExpectedContainerRegistryName) -or
            [string]::IsNullOrWhiteSpace($ExpectedContainerRegistryLoginServer)) {
            throw 'Infrastructure deployment requires both immutable runtime image digests plus the exact expected ACR name and login server.'
        }
        $script:RuntimeImagePullIdentityContract = Assert-GatewayRuntimeImagePullContract `
            -SubscriptionId $SubscriptionId `
            -ResourceGroup $ResourceGroup `
            -ApiContainerAppName "ca-gateway-api-$Environment" `
            -WorkerContainerAppName $WorkerContainerAppName `
            -RuntimeImagePullIdentityId $RuntimeImagePullIdentityId `
            -RuntimeImagePullIdentityPrincipalId $RuntimeImagePullIdentityPrincipalId `
            -RuntimeImagePullAcrPullRoleAssignmentId $RuntimeImagePullAcrPullRoleAssignmentId `
            -ExpectedAcrName $ExpectedContainerRegistryName `
            -ExpectedAcrLoginServer $ExpectedContainerRegistryLoginServer `
            -ApiContainerImage $ApiImage `
            -WorkerContainerImage $WorkerImage `
            -AllowExistingLegacySystemAssignedImagePull:(-not $ApiContainerAppIsNew.IsPresent) `
            -AllowFreshDedicatedImagePull:$ApiContainerAppIsNew.IsPresent
        $script:AllowLegacySystemAssignedImagePull =
            [bool]$RuntimeImagePullIdentityContract.AllowLegacySystemAssignedImagePull
        Write-Success "Runtime image-pull contract validated ($($RuntimeImagePullIdentityContract.Mode))."
    }

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

    Write-Info 'Verifying read-only provisioning preflight script...'
    if (-not (Test-Path $ProvisioningPreflightScript)) {
        throw "Provisioning preflight script not found: $ProvisioningPreflightScript"
    }
    Write-Success 'Provisioning preflight script found.'

}

function Initialize-ResourceProviders {
    Write-StepHeader 'Azure Resource Provider Readiness'

    # This is intentionally deferred until after the read-only topology and
    # identity preflight. Provider registration changes subscription state.
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

function Invoke-ProvisioningPreflight {
    param(
        [switch]$AllowMissingWorkloads,
        [switch]$RequireDeployedConfigurationMatch,
        [switch]$ExpectApiAdmissionClosed
    )

    Write-StepHeader 'Read-only Provisioning Preflight'

    & $ProvisioningPreflightScript `
        -Environment $Environment `
        -ResourceGroup $ResourceGroup `
        -ContainerAppsEnvironmentName $ContainerAppsEnvironmentName `
        -WorkerContainerAppName $WorkerContainerAppName `
        -ExpectedServiceBusQueueName $ServiceBusQueueName `
        -WorkerProcessingEnabled:$WorkerProcessingEnabled `
        -ExpectLegacyWorkerCredentialKeyVaultRole:$EnableLegacyWorkerCredentialKeyVaultSecretsOfficer.IsPresent `
        -ExpectedGatewayApiApplicationClientId $GatewayApiApplicationClientId `
        -ExpectedCredentialKeyVaultUri "https://kv-a365gw-$Environment-prov.vault.azure.net/" `
        -ExpectedManagerApplicationIds $Agent365ManagerApplicationIds `
        -ExpectedGatewayApiFederatedCredentialName $GatewayApiFederatedCredentialName `
        -RegistryProvider $RegistryProvider `
        -DirectRegistryPreviewEnabled:$EnableDirectRegistryPreview.IsPresent `
        -DelegatedRegistryEnabled:$EnableDelegatedRegistry.IsPresent `
        -RequireExecutionReady:$EnableProvisioningExecution.IsPresent `
        -ManagerApplicationsPreflightConfirmed:$ManagerApplicationsPreflightConfirmed.IsPresent `
        -AllowMissingWorkloads:$AllowMissingWorkloads.IsPresent `
        -RequireDeployedConfigurationMatch:$RequireDeployedConfigurationMatch.IsPresent `
        -ExpectApiAdmissionClosed:$ExpectApiAdmissionClosed.IsPresent
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
        '--parameters', $ParameterFile
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
    $overrides += "containerAppsEnvironmentName=$ContainerAppsEnvironmentName"
    $overrides += "workerContainerAppName=$WorkerContainerAppName"
    $overrides += "historicalWorkerContainerAppName=$HistoricalWorkerContainerAppName"
    $overrides += "serviceBusQueueName=$ServiceBusQueueName"
    $overrides += "runtimeImagePullIdentityId=$($RuntimeImagePullIdentityContract.IdentityId)"
    $overrides += "runtimeImagePullIdentityPrincipalId=$($RuntimeImagePullIdentityContract.PrincipalId)"
    $overrides += "runtimeImagePullAcrPullRoleAssignmentId=$($RuntimeImagePullIdentityContract.RoleAssignmentId)"
    $overrides += "allowLegacySystemAssignedImagePull=$($AllowLegacySystemAssignedImagePull.ToString().ToLowerInvariant())"
    $overrides += "preserveExistingApiSecrets=$((-not $ApiContainerAppIsNew.IsPresent).ToString().ToLowerInvariant())"
    $overrides += "workerProcessingEnabled=$($WorkerProcessingEnabled.ToString().ToLowerInvariant())"
    $overrides += "enableLegacyWorkerCredentialKeyVaultSecretsOfficer=$($EnableLegacyWorkerCredentialKeyVaultSecretsOfficer.IsPresent.ToString().ToLowerInvariant())"
    $overrides += "agent365ProvisioningManagedIdentityPrincipalId=$ResolvedProvisioningManagedIdentityPrincipalId"
    if (-not [string]::IsNullOrWhiteSpace($GatewayApiApplicationClientId)) {
        $overrides += "entraIdClientId=$GatewayApiApplicationClientId"
        $overrides += "entraIdAudience=$GatewayApiApplicationClientId"
    }
    $overrides += "provisioningExecutionEnabled=$($EnableProvisioningExecution.IsPresent.ToString().ToLowerInvariant())"
    $overrides += "agent365RegistryProvider=$RegistryProvider"
    $overrides += "agent365DirectRegistryPreviewEnabled=$($EnableDirectRegistryPreview.IsPresent.ToString().ToLowerInvariant())"
    $overrides += "agent365DelegatedRegistryEnabled=$($EnableDelegatedRegistry.IsPresent.ToString().ToLowerInvariant())"
    $overrides += "agent365ManagerApplicationsPreflightConfirmed=$($ManagerApplicationsPreflightConfirmed.IsPresent.ToString().ToLowerInvariant())"
    $managerApplicationIdsJson = ConvertTo-Json -InputObject @($Agent365ManagerApplicationIds) -Compress
    $overrides += "agent365ManagerApplicationIds=$managerApplicationIdsJson"
    foreach ($override in $overrides) {
        $deployArgs += $override
    }
    $deployArgs += @(
        '--output', 'json',
        '--no-prompt', 'true',
        '--only-show-errors'
    )

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
    $workerIdentityName = $WorkerContainerAppName

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
            $failureType = $_.Exception.GetType().Name
            Write-Warning "Health check attempt failed ($failureType). Retrying..."
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
    Write-Host "  Container Apps:    $ContainerAppsEnvironmentName" -ForegroundColor White
    Write-Host "  Historical worker: $HistoricalWorkerContainerAppName" -ForegroundColor White
    Write-Host "  Target worker:     $WorkerContainerAppName" -ForegroundColor White
    Write-Host "  Preserve API secrets: $(-not $ApiContainerAppIsNew.IsPresent)" -ForegroundColor White
    Write-Host "  Runtime image pull: $($RuntimeImagePullIdentityContract.Mode)" -ForegroundColor White
    Write-Host "  Shared processing: $WorkerProcessingEnabled" -ForegroundColor White
    Write-Host "  Legacy worker credential-vault role: $($EnableLegacyWorkerCredentialKeyVaultSecretsOfficer.IsPresent)" -ForegroundColor White
    Write-Host "  Worker identity pinned: $(-not [string]::IsNullOrWhiteSpace($ResolvedProvisioningManagedIdentityPrincipalId))" -ForegroundColor White
    Write-Host "  Provisioning:      $($EnableProvisioningExecution.IsPresent)" -ForegroundColor White
    Write-Host "  Registry provider: $RegistryProvider" -ForegroundColor White
    Write-Host "  Delegated Registry: $($EnableDelegatedRegistry.IsPresent)" -ForegroundColor White
    Write-Host ''

    if ($DeploymentOutputs) {
        Write-Host '  Deployment Outputs:' -ForegroundColor White
        $DeploymentOutputs.PSObject.Properties | Where-Object {
            $_.Name -notmatch '(?i)principalId|tenantId|clientId'
        } | ForEach-Object {
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

    # This preflight is read-only. It stops a deployment that targets the known
    # non-VNet worker or attempts to enable provisioning without tenant readiness.
    Invoke-ProvisioningPreflight `
        -AllowMissingWorkloads:(-not $SkipInfra) `
        -ExpectApiAdmissionClosed:$EnableProvisioningExecution.IsPresent

    # Resolve the existing system-assigned identity without printing it. A new
    # worker must be bootstrapped inert before a later activation deployment.
    $ResolvedProvisioningManagedIdentityPrincipalId =
        Resolve-ProvisioningManagedIdentityPrincipalId

    # Subscription mutation begins only after the read-only preflight passes.
    Initialize-ResourceProviders

    # Step 2: Infrastructure
    $outputs = Invoke-InfraDeployment

    # Recheck the deployed topology and permissions. No role is granted here.
    Invoke-ProvisioningPreflight `
        -RequireDeployedConfigurationMatch `
        -ExpectApiAdmissionClosed:$EnableProvisioningExecution.IsPresent

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
