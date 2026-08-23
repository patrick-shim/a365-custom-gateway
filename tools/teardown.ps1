#Requires -Version 7.0

<#
.SYNOPSIS
    Tears down all Azure resources for the A365 Custom Gateway.

.DESCRIPTION
    Deletes the resource group (and all resources within it) and optionally
    the Entra ID app registration. Removes local appsettings.Local.json files.

.PARAMETER Environment
    Target environment. Must be one of: dev, staging, prod.

.PARAMETER ResourceGroup
    Name of the Azure resource group. Default: rg-agent-gateway.

.PARAMETER DeleteEntraApp
    Also delete the Entra ID app registration for this environment.

.PARAMETER Force
    Skip confirmation prompts. For prod, a second confirmation is still required
    unless -Force is specified twice (not supported — prod always confirms once).

.EXAMPLE
    ./teardown.ps1 -Environment dev -DeleteEntraApp -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = 'rg-agent-gateway',

    [switch]$DeleteEntraApp,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

try {
    Write-StepHeader "Teardown: $Environment"

    Assert-AzLogin | Out-Null

    # Confirmation
    if (-not $Force) {
        Write-Warn "This will DELETE all resources in resource group '$ResourceGroup'."
        if ($DeleteEntraApp) {
            Write-Warn "This will also DELETE the Entra app registration 'A365 Gateway - $Environment'."
        }
        $confirm = Read-Host "Type 'yes' to confirm"
        if ($confirm -ne 'yes') {
            Write-Info 'Teardown cancelled.'
            exit 0
        }
    }

    if ($Environment -eq 'prod' -and -not $Force) {
        Write-Warn 'PRODUCTION teardown requested. This is irreversible.'
        $confirm2 = Read-Host "Type the resource group name '$ResourceGroup' to confirm"
        if ($confirm2 -ne $ResourceGroup) {
            Write-Info 'Teardown cancelled (resource group name did not match).'
            exit 0
        }
    }

    # Delete resource group
    Write-StepHeader 'Deleting Resource Group'
    $rgExists = az group exists --name $ResourceGroup 2>&1
    if ($rgExists -eq 'true') {
        Write-Info "Deleting resource group '$ResourceGroup' (async)..."
        Invoke-AzCommand -Arguments @('group', 'delete', '--name', $ResourceGroup, '--yes', '--no-wait') `
            -ErrorMessage "Failed to delete resource group '$ResourceGroup'."
        Write-Success "Resource group deletion initiated (running in background)."
        Write-Info "Check status: az group show --name $ResourceGroup --query properties.provisioningState -o tsv"
    }
    else {
        Write-Warn "Resource group '$ResourceGroup' does not exist. Skipping."
    }

    # Delete Entra app registration
    if ($DeleteEntraApp) {
        Write-StepHeader 'Deleting Entra App Registration'
        $displayName = "A365 Gateway - $Environment"
        $appId = (Invoke-AzCommand -Arguments @(
                'ad', 'app', 'list',
                '--display-name', $displayName,
                '--query', '[0].appId', '-o', 'tsv'
            ) -ErrorMessage 'Failed to query Entra app.' | Out-String).Trim()

        if ($appId -and $appId -ne '') {
            Write-Info "Deleting Entra app '$displayName' (appId: $appId)..."
            Invoke-AzCommand -Arguments @('ad', 'app', 'delete', '--id', $appId) `
                -ErrorMessage "Failed to delete Entra app '$appId'."
            Write-Success "Deleted Entra app registration: $appId"
        }
        else {
            Write-Warn "No Entra app found with display name '$displayName'. Skipping."
        }
    }

    # Clean up local config files
    Write-StepHeader 'Cleaning Up Local Config'
    $localConfigs = @(
        (Join-Path $RepoRoot 'src' 'Gateway.Api' 'appsettings.Local.json'),
        (Join-Path $RepoRoot 'src' 'Gateway.Provisioning.Worker' 'appsettings.Local.json')
    )
    foreach ($f in $localConfigs) {
        if (Test-Path $f) {
            Remove-Item $f -Force
            Write-Info "Removed $f"
        }
    }

    Write-Host ''
    Write-Success 'Teardown complete.'
    exit 0
}
catch {
    Write-Failure "Teardown failed: $($_.Exception.Message)"
    exit 1
}
