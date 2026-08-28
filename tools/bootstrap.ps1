#Requires -Version 7.0

<#
.SYNOPSIS
    Legacy partial environment helper. Use bootstrap/bootstrap.ps1 for a clean subscription.

.DESCRIPTION
    This predates workflow v3 and does not provision the complete current system.
    The supported resumable first-deployment tool is ../bootstrap/bootstrap.ps1.
    This legacy helper calls older sub-scripts in dependency order:

    1. Entra ID app registration (setup-entra.ps1)
    2. Azure infrastructure via Bicep (deploy-infra.ps1)
    3. Docker build + ACR push (build-and-push.ps1)
    4. EF Core database migrations (apply-migrations.ps1)
    5. Local development config generation (generate-local-config.ps1)

    Each step can be skipped individually. The script auto-discovers the caller's
    identity and wires the environment variables required by the Bicep parameter
    files. Azure SQL uses Entra-only administration; no SQL login password is
    generated.

.PARAMETER Environment
    Target environment. Must be one of: dev, staging, prod.

.PARAMETER ResourceGroup
    Azure resource group name. Default: rg-agent-gateway.

.PARAMETER SubscriptionId
    Azure subscription ID. Default: 95bedc30-f6ac-481b-a3a6-588d2883c216.

.PARAMETER Location
    Azure region. Default: koreacentral.

.PARAMETER AlertEmail
    Email for Azure Monitor alert notifications.

.PARAMETER SkipEntra
    Skip Entra ID app registration.

.PARAMETER SkipInfra
    Skip infrastructure deployment.

.PARAMETER SkipBuild
    Skip Docker build and push.

.PARAMETER SkipMigrations
    Skip EF Core database migrations.

.PARAMETER SkipLocalConfig
    Skip local development config generation.

.EXAMPLE
    ./bootstrap.ps1 -Environment dev

.EXAMPLE
    ./bootstrap.ps1 -Environment dev -SkipBuild -SkipMigrations

.EXAMPLE
    ./bootstrap.ps1 -Environment staging -AlertEmail ops@contoso.com
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

    [Parameter(Mandatory = $false)]
    [string]$AlertEmail,

    [switch]$SkipEntra,
    [switch]$SkipInfra,
    [switch]$SkipBuild,
    [switch]$SkipMigrations,
    [switch]$SkipLocalConfig
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
Write-Warn 'This is the legacy partial bootstrap. Use bootstrap/bootstrap.ps1 for a complete clean-subscription deployment.'

try {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host ''
    Write-Host '  A365 Custom Gateway - Bootstrap' -ForegroundColor Cyan
    Write-Host "  Environment: $Environment | Resource Group: $ResourceGroup" -ForegroundColor Cyan
    Write-Host "  Location: $Location" -ForegroundColor Cyan
    Write-Host ''

    # ========================================================================
    # Pre-flight
    # ========================================================================

    Write-StepHeader 'Pre-flight Checks'

    Assert-Command 'az' 'https://learn.microsoft.com/cli/azure/install-azure-cli'

    if (-not $SkipBuild) {
        Assert-Command 'docker' 'https://docs.docker.com/get-docker/'
    }

    $account = Assert-AzLogin

    Write-Info "Setting subscription to $SubscriptionId..."
    Invoke-AzCommand -Arguments @('account', 'set', '--subscription', $SubscriptionId) `
        -ErrorMessage "Failed to set subscription."
    Write-Success "Subscription set."

    # ========================================================================
    # Auto-discover identity
    # ========================================================================

    Write-StepHeader 'Identity Discovery'

    $EntraAdminObjectId = Get-CurrentUserObjectId
    $EntraAdminLogin = Get-CurrentUserUpn
    Write-Success "User: $EntraAdminLogin (objectId: $EntraAdminObjectId)"

    # ========================================================================
    # Step 1: Entra ID
    # ========================================================================

    $EntraClientId = $null
    $EntraAudience = "api://a365-gateway-$Environment"

    if ($SkipEntra) {
        Write-StepHeader 'Step 1: Entra ID (SKIPPED)'
        $EntraClientId = $env:ENTRA_CLIENT_ID
        if (-not $EntraClientId) {
            Write-Info 'Looking up existing Entra app...'
            $EntraClientId = (Invoke-AzCommand -Arguments @(
                    'ad', 'app', 'list',
                    '--display-name', "A365 Gateway - $Environment",
                    '--query', '[0].appId', '-o', 'tsv'
                ) -ErrorMessage 'Failed to look up Entra app.' | Out-String).Trim()
        }
        if (-not $EntraClientId -or $EntraClientId -eq '') {
            Write-Warn 'No Entra app found. Set ENTRA_CLIENT_ID env var or remove -SkipEntra.'
            $EntraClientId = '00000000-0000-0000-0000-000000000000'
        }
    }
    else {
        Write-StepHeader 'Step 1: Entra ID App Registration'
        $entraScript = Join-Path $PSScriptRoot 'setup-entra.ps1'
        $entraResult = & $entraScript -Environment $Environment
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw 'Entra setup failed.'
        }
        $EntraClientId = $entraResult.ClientId
        $EntraAudience = $entraResult.Audience
        Write-Success "Entra app: $EntraClientId"
    }

    # ========================================================================
    # Set environment variables for Bicep
    # ========================================================================

    Write-StepHeader 'Setting Environment Variables'

    if (-not $AlertEmail) {
        $AlertEmail = "gateway-$Environment-alerts@contoso.com"
    }

    $env:ENTRA_CLIENT_ID = $EntraClientId
    $env:ENTRA_AUDIENCE = $EntraAudience
    $env:ENTRA_ADMIN_OBJECT_ID = $EntraAdminObjectId
    $env:ENTRA_ADMIN_LOGIN = $EntraAdminLogin
    $env:ALERT_EMAIL = $AlertEmail
    $env:API_IMAGE = 'mcr.microsoft.com/dotnet/aspnet:10.0'
    $env:WORKER_IMAGE = 'mcr.microsoft.com/dotnet/runtime:10.0'

    Write-Success 'All required environment variables set for Bicep deployment.'

    # ========================================================================
    # Step 2: Infrastructure
    # ========================================================================

    $deployOutputs = $null

    if ($SkipInfra) {
        Write-StepHeader 'Step 2: Infrastructure (SKIPPED)'
        try {
            $deployOutputs = Get-DeploymentOutputs -ResourceGroup $ResourceGroup
            Write-Info 'Retrieved existing deployment outputs.'
        }
        catch {
            Write-Warn 'Could not retrieve deployment outputs. Some subsequent steps may fail.'
        }
    }
    else {
        Write-StepHeader 'Step 2: Infrastructure Deployment'
        $infraScript = Join-Path $PSScriptRoot 'deploy-infra.ps1'
        & $infraScript -Environment $Environment -ResourceGroup $ResourceGroup `
            -SubscriptionId $SubscriptionId -Location $Location
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw 'Infrastructure deployment failed.'
        }
        $deployOutputs = Get-DeploymentOutputs -ResourceGroup $ResourceGroup
        Write-Success 'Infrastructure deployed.'
    }

    # Extract key outputs
    $acrLoginServer = $deployOutputs.acrLoginServer.value
    $sqlServerFqdn = $deployOutputs.sqlServerFqdn.value
    $apiFqdn = $deployOutputs.apiFqdn.value

    # ========================================================================
    # Step 3: Docker Build + Push
    # ========================================================================

    if ($SkipBuild) {
        Write-StepHeader 'Step 3: Docker Build + Push (SKIPPED)'
    }
    else {
        Write-StepHeader 'Step 3: Docker Build + Push'
        if (-not $acrLoginServer) {
            Write-Failure 'ACR login server not available from deployment outputs.'
            throw 'Cannot build images without ACR login server.'
        }
        $buildScript = Join-Path $PSScriptRoot 'build-and-push.ps1'
        & $buildScript -AcrLoginServer $acrLoginServer -Environment $Environment `
            -ResourceGroup $ResourceGroup
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw 'Docker build/push failed.'
        }
        Write-Success 'Images built and deployed.'
    }

    # ========================================================================
    # Step 4: EF Core Migrations
    # ========================================================================

    if ($SkipMigrations) {
        Write-StepHeader 'Step 4: EF Core Migrations (SKIPPED)'
    }
    else {
        Write-StepHeader 'Step 4: EF Core Migrations'
        if (-not $sqlServerFqdn) {
            Write-Failure 'SQL Server FQDN not available from deployment outputs.'
            throw 'Cannot apply migrations without SQL Server FQDN.'
        }
        $migrationsScript = Join-Path $PSScriptRoot 'apply-migrations.ps1'
        & $migrationsScript -SqlServerFqdn $sqlServerFqdn -ResourceGroup $ResourceGroup
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw 'Database migrations failed.'
        }
        Write-Success 'Migrations applied.'
    }

    # ========================================================================
    # Step 5: Local Config
    # ========================================================================

    if ($SkipLocalConfig) {
        Write-StepHeader 'Step 5: Local Config (SKIPPED)'
    }
    else {
        Write-StepHeader 'Step 5: Local Development Config'
        $localConfigScript = Join-Path $PSScriptRoot 'generate-local-config.ps1'
        & $localConfigScript -Environment $Environment -ResourceGroup $ResourceGroup
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Write-Warn 'Local config generation had issues (non-fatal).'
        }
        else {
            Write-Success 'Local config generated.'
        }
    }

    # ========================================================================
    # Summary
    # ========================================================================

    Write-StepHeader 'Bootstrap Complete'

    $stopwatch.Stop()

    Write-Host ''
    Write-Host '  Environment:      ' -NoNewline -ForegroundColor White
    Write-Host $Environment -ForegroundColor Green
    Write-Host '  Resource Group:   ' -NoNewline -ForegroundColor White
    Write-Host $ResourceGroup -ForegroundColor Green
    Write-Host '  Location:         ' -NoNewline -ForegroundColor White
    Write-Host $Location -ForegroundColor Green
    Write-Host ''

    if ($apiFqdn) {
        Write-Host '  API URL:          ' -NoNewline -ForegroundColor White
        Write-Host "https://$apiFqdn" -ForegroundColor Green
        Write-Host '  Health Check:     ' -NoNewline -ForegroundColor White
        Write-Host "https://$apiFqdn/health/checks" -ForegroundColor Green
    }
    if ($acrLoginServer) {
        Write-Host '  ACR:              ' -NoNewline -ForegroundColor White
        Write-Host $acrLoginServer -ForegroundColor Green
    }
    if ($sqlServerFqdn) {
        Write-Host '  SQL Server:       ' -NoNewline -ForegroundColor White
        Write-Host $sqlServerFqdn -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '  Local dev:' -ForegroundColor White
    Write-Host '    dotnet run --project src/Gateway.Api' -ForegroundColor Gray
    Write-Host '    dotnet run --project src/Gateway.AdminUi' -ForegroundColor Gray
    Write-Host '    dotnet run --project src/Gateway.Provisioning.Worker' -ForegroundColor Gray
    Write-Host ''

    Write-Host '  Teardown:' -ForegroundColor White
    Write-Host "    ./tools/teardown.ps1 -Environment $Environment -DeleteEntraApp" -ForegroundColor Gray
    Write-Host ''

    Write-Success "Total elapsed time: $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))"
    exit 0
}
catch {
    Write-Failure "Bootstrap failed: $($_.Exception.Message)"
    Write-Failure "Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
