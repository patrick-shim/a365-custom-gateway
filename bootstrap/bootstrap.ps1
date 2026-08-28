#Requires -Version 7.0

<#+
.SYNOPSIS
    Plans, provisions, resumes, or verifies a complete A365 Custom Gateway deployment.

.DESCRIPTION
    This is the supported first-deployment entry point for a clean Azure subscription.
    It installs/checks prerequisites, creates the Azure foundation, configures Entra
    and Agent 365, builds immutable images, initializes SQL, optionally configures
    Purview, deploys the workloads, and runs fail-closed verification.

    Runtime state contains safe identifiers only and is stored under .bootstrap/.
    It never stores access tokens, client secrets, SQL passwords, Gateway keys, or
    prompt/response content. Apply is resumable. Destroy is intentionally not part
    of this tool.

.EXAMPLE
    ./bootstrap/bootstrap.ps1 -Mode Plan -Config ./bootstrap/config.json

.EXAMPLE
    ./bootstrap/bootstrap.ps1 -Mode Apply -Config ./bootstrap/config.json

.EXAMPLE
    ./bootstrap/bootstrap.ps1 -Mode Resume -Config ./bootstrap/config.json

.EXAMPLE
    ./bootstrap/bootstrap.ps1 -Mode Verify -Config ./bootstrap/config.json
#>

[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Apply', 'Resume', 'Verify')]
    [string]$Mode = 'Plan',

    [string]$Config = (Join-Path $PSScriptRoot 'config.json'),

    [bool]$InstallPrerequisites = $true,

    [switch]$NonInteractive,

    [switch]$OpenBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

foreach ($module in @('Common', 'Prerequisites', 'Azure', 'Entra', 'Agent365', 'Database', 'Purview', 'Verification')) {
    Import-Module (Join-Path $PSScriptRoot "modules/$module.psm1") -Force -DisableNameChecking
}

$configuration = Read-BootstrapConfig -Path $Config
$statePath = Get-BootstrapStatePath -Config $configuration
$state = Read-BootstrapState -Path $statePath -Config $configuration
$lock = Enter-BootstrapLock -StatePath $statePath

function Get-Evidence {
    param([string]$Step)
    $record = $state.steps[$Step]
    if (-not $record -or $record.status -ne 'Completed') { throw "Required bootstrap step '$Step' is not complete." }
    return $record.evidence
}

function Save-Output {
    param([string]$Name, $Value)
    $state.outputs[$Name] = $Value
    Save-BootstrapState -State $state -Path $statePath
}

try {
    if ($Mode -eq 'Plan') {
        Write-BootstrapStep 'Validating bootstrap source'
        $root = Get-RepositoryRoot
        $required = @(
            'bootstrap/infra/subscription.bicep',
            'bootstrap/infra/foundation.bicep',
            'bootstrap/infra/sql-private-endpoint.bicep',
            'deploy/bicep/main.bicep',
            'deploy/bicep/admin-ui.bicep',
            'tools/configure-workflow-v3-entra.ps1',
            'deploy/scripts/test-provisioning-prerequisites.ps1'
        )
        foreach ($path in $required) { if (-not (Test-Path (Join-Path $root $path))) { throw "Required file is missing: $path" } }
        if (Get-Command az -ErrorAction SilentlyContinue) {
            foreach ($template in @('subscription.bicep', 'foundation.bicep', 'sql-private-endpoint.bicep')) {
                Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('bicep', 'build', '--file', (Join-Path $root "bootstrap/infra/$template"), '--stdout') | Out-Null
            }
        }
        Write-Host @"

Plan validated. Apply will perform these resumable phases:
  1. Install/verify PowerShell 7 launcher, Git, Azure CLI, Bicep, .NET 10, Agent 365 CLI,
     and ExchangeOnlineManagement when Purview is enabled.
  2. Authenticate to the exact tenant/subscription and register Azure providers.
  3. Create the resource group, VNet, subnets, Log Analytics, and Container Apps environment.
  4. Create/adopt the Gateway API app and build digest-pinned images in the foundation ACR.
  5. Deploy API/worker inert to obtain identities, using the real current images.
  6. Create/adopt a typed Agent ID seed blueprint and read its managerApplications.
  7. Configure exact workflow-v3 Graph roles, delegated Registry consent, and OBO FIC.
  8. Add private SQL access, initialize an empty database, and create runtime principals.
  9. Create the Admin UI app/credential, storing the credential directly in Key Vault.
 10. Optionally create blueprint-scoped Purview collection and inline DLP policies.
 11. Deploy the final runtime, Admin UI, redirects, and close SQL/Key Vault public access.
 12. Run health, private-network, identity, permission, and provisioning preflight checks.

Important: full automatic Agent Registration is development-only because the Microsoft
Registry create API used by this repository is beta and unsupported for production.
Staging/prod remain fail-closed at that boundary.
"@
        exit 0
    }

    if ($Mode -eq 'Verify') {
        $null = Connect-BootstrapAzure -Config $configuration -NonInteractive:$NonInteractive
        $foundation = Get-Evidence 'Azure foundation'
        $identity = Get-Evidence 'Gateway API identity'
        $blueprint = Get-Evidence 'Agent 365 seed blueprint'
        $runtime = Get-Evidence 'Gateway runtime deployment'
        $adminUi = Get-Evidence 'Admin UI deployment'
        $images = Get-Evidence 'Immutable workload images'
        $adminIdentity = Get-Evidence 'Admin UI identity'
        $verification = Test-GatewayBootstrapDeployment -Config $configuration -Foundation $foundation -Identity $identity -Blueprint $blueprint -Runtime $runtime -AdminUi $adminUi -Images $images -AdminIdentity $adminIdentity
        Save-Output -Name 'verification' -Value $verification
        Write-BootstrapSuccess "Verification passed. Admin UI: $($adminUi.adminUiUrl)"
        exit 0
    }

    $prerequisites = Invoke-BootstrapStateStep -Name 'Prerequisites' -State $state -StatePath $statePath -AlwaysRun -Action {
        Assert-BootstrapPrerequisites -Install:$InstallPrerequisites -RequirePurview:($configuration.purview.enabled -eq $true)
    }
    $azureIdentity = Invoke-BootstrapStateStep -Name 'Azure authentication' -State $state -StatePath $statePath -AlwaysRun -Action {
        Connect-BootstrapAzure -Config $configuration -NonInteractive:$NonInteractive
    }
    $resourceGroupExists = [string](Invoke-AzTsv -Arguments @('group', 'exists', '--name', [string]$configuration.resourceGroupName))
    if ($resourceGroupExists -ne 'true' -and $state.steps['Azure foundation'] -and $state.steps['Azure foundation'].status -eq 'Completed') {
        Write-Warning "Recorded resource group '$($configuration.resourceGroupName)' no longer exists. Clearing dependent safe state so Apply/Resume can rebuild it."
        foreach ($stepName in @($state.steps.Keys)) {
            if ($stepName -notin @('Prerequisites', 'Azure authentication')) { $state.steps.Remove($stepName) }
        }
        $state.outputs.Clear()
        Save-BootstrapState -State $state -Path $statePath
    }
    Invoke-BootstrapStateStep -Name 'Azure provider registration' -State $state -StatePath $statePath -Action {
        Register-BootstrapResourceProviders
    } | Out-Null
    $foundation = Invoke-BootstrapStateStep -Name 'Azure foundation' -State $state -StatePath $statePath -Action {
        Deploy-BootstrapFoundation -Config $configuration
    }
    $identity = Invoke-BootstrapStateStep -Name 'Gateway API identity' -State $state -StatePath $statePath -Action {
        Ensure-GatewayApiApplication -Config $configuration -AzureIdentity $azureIdentity
    }
    $images = Invoke-BootstrapStateStep -Name 'Immutable workload images' -State $state -StatePath $statePath -Action {
        Build-GatewayImages -Config $configuration -AcrLoginServer ([string]$foundation.acrLoginServer)
    }
    $inert = Invoke-BootstrapStateStep -Name 'Inert identity deployment' -State $state -StatePath $statePath -Action {
        Deploy-GatewayCore -Config $configuration -Foundation $foundation -Identity $identity -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -WorkerPrincipalId '' -ManagerApplicationIds @() -Initial
    }
    $blueprint = Invoke-BootstrapStateStep -Name 'Agent 365 seed blueprint' -State $state -StatePath $statePath -Action {
        Ensure-Agent365SeedBlueprint -Config $configuration -NonInteractive:$NonInteractive
    }
    $workloadIdentity = Invoke-BootstrapStateStep -Name 'Workflow v3 Entra configuration' -State $state -StatePath $statePath -Action {
        Configure-GatewayWorkloadIdentity -Config $configuration -Identity $identity -ApiPrincipalId ([string]$inert.apiPrincipalId) -WorkerPrincipalId ([string]$inert.workerPrincipalId) -EnablePurview:($configuration.purview.enabled -eq $true)
    }
    Invoke-BootstrapStateStep -Name 'SQL private endpoint' -State $state -StatePath $statePath -Action {
        Deploy-SqlPrivateEndpoint -Config $configuration -Foundation $foundation -SqlServerFqdn ([string]$inert.sqlServerFqdn)
    } | Out-Null
    Invoke-BootstrapStateStep -Name 'Gateway database' -State $state -StatePath $statePath -Action {
        Initialize-GatewayDatabase -Config $configuration -SqlServerFqdn ([string]$inert.sqlServerFqdn) -ApiPrincipalId ([string]$inert.apiPrincipalId) -WorkerPrincipalId ([string]$inert.workerPrincipalId)
    } | Out-Null
    $adminIdentity = Invoke-BootstrapStateStep -Name 'Admin UI identity' -State $state -StatePath $statePath -Action {
        Ensure-AdminUiApplication -Config $configuration -Identity $identity
    }
    $adminCredential = Invoke-BootstrapStateStep -Name 'Admin UI Key Vault credential' -State $state -StatePath $statePath -Action {
        New-AdminUiCredentialInKeyVault -Config $configuration -AdminIdentity $adminIdentity -KeyVaultUri ([string]$inert.keyVaultUri) -UserObjectId ([string]$azureIdentity.userObjectId)
    }
    $purview = Invoke-BootstrapStateStep -Name 'Purview policies' -State $state -StatePath $statePath -Action {
        Ensure-BootstrapPurviewPolicies -Config $configuration -Blueprint $blueprint -UserPrincipalName ([string]$azureIdentity.userPrincipalName) -NonInteractive:$NonInteractive
    }

    $enableProvisioning = [string]$configuration.environment -eq 'dev' -and $configuration.agent365.allowDevelopmentRegistryPreview -eq $true
    $runtime = Invoke-BootstrapStateStep -Name 'Gateway runtime deployment' -State $state -StatePath $statePath -Action {
        Deploy-GatewayCore -Config $configuration -Foundation $foundation -Identity $identity -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -WorkerPrincipalId ([string]$inert.workerPrincipalId) -ManagerApplicationIds @($blueprint.managerApplicationIds) -EnableWorkerProcessing -EnableProvisioning:$enableProvisioning -EnablePurview:($purview.enabled -eq $true)
    }
    $adminUi = Invoke-BootstrapStateStep -Name 'Admin UI deployment' -State $state -StatePath $statePath -Action {
        Deploy-GatewayAdminUi -Config $configuration -Foundation $foundation -Identity $identity -AdminIdentity $adminIdentity -AdminUiImage ([string]$images.adminUi) -AdminUiSecretUri ([string]$adminCredential.secretUri)
    }
    Invoke-BootstrapStateStep -Name 'Admin UI redirect URIs' -State $state -StatePath $statePath -Action {
        Set-AdminUiRedirectUris -AdminIdentity $adminIdentity -AdminUiFqdn ([string]$adminUi.adminUiFqdn)
    } | Out-Null
    Invoke-BootstrapStateStep -Name 'Network hardening' -State $state -StatePath $statePath -AlwaysRun -Action {
        Set-GatewayNetworkHardening -Config $configuration
    } | Out-Null
    $verification = Invoke-BootstrapStateStep -Name 'End-to-end deployment verification' -State $state -StatePath $statePath -AlwaysRun -Action {
        Test-GatewayBootstrapDeployment -Config $configuration -Foundation $foundation -Identity $identity -Blueprint $blueprint -Runtime $runtime -AdminUi $adminUi -Images $images -AdminIdentity $adminIdentity
    }

    Save-Output -Name 'adminUiUrl' -Value ([string]$adminUi.adminUiUrl)
    Save-Output -Name 'apiUrl' -Value "https://$($runtime.apiFqdn)"
    Save-Output -Name 'seedBlueprint' -Value $blueprint
    Save-Output -Name 'verification' -Value $verification

    Write-Host "`nBootstrap completed and verified." -ForegroundColor Green
    Write-Host "Admin UI: $($adminUi.adminUiUrl)"
    Write-Host "Gateway API health: https://$($runtime.apiFqdn)/health/checks"
    Write-Host "Safe resumable state: $statePath"
    if (-not $enableProvisioning) {
        Write-Warning 'Agent creation remains closed because Registry create is unsupported for production outside the dev preview contract.'
    }
    if ($OpenBrowser) { Start-Process ([string]$adminUi.adminUiUrl) }
}
finally {
    if ($lock) { $lock.Dispose() }
}
