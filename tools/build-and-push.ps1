#Requires -Version 7.0

<#
.SYNOPSIS
    Builds Docker images for the A365 Gateway API and Worker, pushes them to
    Azure Container Registry, and updates running Container Apps.

.DESCRIPTION
    This script builds the gateway-api and gateway-worker Docker images from the
    repository root context, authenticates to the specified Azure Container Registry,
    pushes the images, and updates the corresponding Azure Container Apps with the
    new image references.

    Use -SkipPush to build images locally without pushing or updating deployments.

.PARAMETER AcrLoginServer
    The fully qualified ACR login server (e.g. acra365gwdev123456.azurecr.io).

.PARAMETER Environment
    Target deployment environment. Determines the Container App name suffix.

.PARAMETER ResourceGroup
    Azure resource group containing the Container Apps. Defaults to rg-agent-gateway.

.PARAMETER Tag
    Docker image tag. Defaults to the first 7 characters of the current git HEAD SHA.

.PARAMETER SkipPush
    Build images only. Do not push to ACR or update Container Apps.

.EXAMPLE
    ./build-and-push.ps1 -AcrLoginServer acra365gwdev123456.azurecr.io -Environment dev

.EXAMPLE
    ./build-and-push.ps1 -AcrLoginServer acra365gwdev123456.azurecr.io -Environment staging -Tag v1.2.0

.EXAMPLE
    ./build-and-push.ps1 -AcrLoginServer acra365gwdev123456.azurecr.io -Environment dev -SkipPush
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AcrLoginServer,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [string]$ResourceGroup = 'rg-agent-gateway',

    [string]$Tag,

    [switch]$SkipPush
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_common.ps1')

try {
    # ── Prerequisites ────────────────────────────────────────────────────
    Write-StepHeader 'Checking prerequisites'
    Assert-Command 'docker' 'https://docs.docker.com/get-docker/'
    Write-Success 'Docker is available.'

    # ── Resolve tag ──────────────────────────────────────────────────────
    if (-not $Tag) {
        $Tag = (git rev-parse --short=7 HEAD).Trim()
        Write-Info "Tag resolved from git HEAD: $Tag"
    }
    else {
        Write-Info "Using provided tag: $Tag"
    }

    # ── Image names ──────────────────────────────────────────────────────
    $ApiImage    = "$AcrLoginServer/gateway-api:$Tag"
    $WorkerImage = "$AcrLoginServer/gateway-worker:$Tag"

    Write-Info "API image:    $ApiImage"
    Write-Info "Worker image: $WorkerImage"

    # ── Authenticate to ACR ──────────────────────────────────────────────
    Write-StepHeader 'Authenticating to Azure Container Registry'
    $RegistryName = $AcrLoginServer -replace '\.azurecr\.io$', ''
    Invoke-AzCommand -Arguments @('acr', 'login', '--name', $RegistryName) `
        -ErrorMessage "Failed to authenticate to ACR '$RegistryName'."
    Write-Success "Authenticated to $RegistryName."

    # ── Build images ─────────────────────────────────────────────────────
    Write-StepHeader 'Building Docker images'

    Write-Info "Building $ApiImage ..."
    & docker build -f "$RepoRoot/src/Gateway.Api/Dockerfile" -t $ApiImage $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw "Docker build failed for gateway-api (exit code $LASTEXITCODE)." }
    Write-Success "Built $ApiImage"

    Write-Info "Building $WorkerImage ..."
    & docker build -f "$RepoRoot/src/Gateway.Provisioning.Worker/Dockerfile" -t $WorkerImage $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw "Docker build failed for gateway-worker (exit code $LASTEXITCODE)." }
    Write-Success "Built $WorkerImage"

    # ── Push and update ──────────────────────────────────────────────────
    if ($SkipPush) {
        Write-Warn 'SkipPush specified — skipping push and Container App update.'
    }
    else {
        Write-StepHeader 'Pushing images to ACR'

        Write-Info "Pushing $ApiImage ..."
        & docker push $ApiImage
        if ($LASTEXITCODE -ne 0) { throw "Docker push failed for $ApiImage (exit code $LASTEXITCODE)." }
        Write-Success "Pushed $ApiImage"

        Write-Info "Pushing $WorkerImage ..."
        & docker push $WorkerImage
        if ($LASTEXITCODE -ne 0) { throw "Docker push failed for $WorkerImage (exit code $LASTEXITCODE)." }
        Write-Success "Pushed $WorkerImage"

        Write-StepHeader 'Updating Azure Container Apps'

        Write-Info "Updating ca-gateway-api-$Environment ..."
        Invoke-AzCommand -Arguments @(
            'containerapp', 'update',
            '--name', "ca-gateway-api-$Environment",
            '--resource-group', $ResourceGroup,
            '--image', $ApiImage
        ) -ErrorMessage "Failed to update Container App ca-gateway-api-$Environment."
        Write-Success "Updated ca-gateway-api-$Environment"

        Write-Info "Updating ca-gateway-worker-$Environment ..."
        Invoke-AzCommand -Arguments @(
            'containerapp', 'update',
            '--name', "ca-gateway-worker-$Environment",
            '--resource-group', $ResourceGroup,
            '--image', $WorkerImage
        ) -ErrorMessage "Failed to update Container App ca-gateway-worker-$Environment."
        Write-Success "Updated ca-gateway-worker-$Environment"
    }

    # ── Done ─────────────────────────────────────────────────────────────
    Write-StepHeader 'Build and push complete'
    Write-Success "API image:    $ApiImage"
    Write-Success "Worker image: $WorkerImage"

    return @{
        ApiImage    = $ApiImage
        WorkerImage = $WorkerImage
    }
}
catch {
    Write-Failure $_.Exception.Message
    exit 1
}

exit 0
