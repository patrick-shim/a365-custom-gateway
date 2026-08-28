#Requires -Version 7.0

<#
.SYNOPSIS
    Performs the one-shot inert development bootstrap for the blue/green worker.

.DESCRIPTION
    This orchestrator is deliberately fixed to the existing development resource
    group, approved VNet environment, Gateway API, and the newly named provisioning
    worker. It performs the repository preflight, Bicep validation, and an ARM
    ResourceIdOnly what-if before any mutation.

    If mutation is allowed, it first pins the API image and forces the registration
    gate off while preserving every other environment setting and the scale block.
    This API image/gate update is the sole allowed mutation to an existing shared
    workload configuration. The scoped template treats every other shared resource
    as read-only; it may create only the owned worker/vault resources, diagnostics,
    and the two narrowly scoped bootstrap role-assignment child resources.

    The script deploys only provisioning-bootstrap.bicep with a public placeholder,
    verifies that the worker is inert, and replaces the placeholder with the supplied
    digest-pinned worker image. This is not a resume or upgrade command: both the new
    worker and dedicated vault must be absent, including in WhatIfOnly mode.

    This script does not read a secrets file, run SQL setup, grant tenant/Graph,
    Service Bus, or Storage roles, alter the historical worker, or inspect/settle/
    replay/purge queue messages. It does not attempt an automatic rollback after a
    partial deployment because every intended intermediate state is fail closed.

.PARAMETER ApiImage
    Full ACR image reference pinned by sha256 digest.

.PARAMETER WorkerImage
    Full ACR image reference pinned by sha256 digest.

.PARAMETER ExpectedSubscriptionId
    Required safety assertion for the currently selected Azure subscription. The
    script never changes the Azure CLI account context.

.PARAMETER WhatIfOnly
    Stops after all read-only preflight, validation, and scoped what-if checks. The
    one-shot absence requirement still applies.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ApiImage,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkerImage,

    [Parameter(Mandatory = $true)]
    [guid]$ExpectedSubscriptionId,

    [switch]$WhatIfOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$EnvironmentName = 'dev'
$ProjectName = 'a365gw'
$ResourceGroup = 'rg-agent-gateway'
$ContainerAppsEnvironmentName = 'cae-a365gw-dev-vnet'
$ApiContainerAppName = 'ca-gateway-api-dev'
$NewWorkerContainerAppName = 'ca-gateway-worker-dev-vnet'
$HistoricalWorkerContainerAppName = 'ca-gateway-worker-dev'
$ProvisioningVaultName = 'kv-a365gw-dev-prov'
$ProvisioningVaultUri = 'https://kv-a365gw-dev-prov.vault.azure.net/'
$BootstrapImage = 'mcr.microsoft.com/dotnet/runtime:10.0'
$ApiRepositoryName = 'gateway-api'
$WorkerRepositoryName = 'gateway-worker'
$TemplateFile = Join-Path $PSScriptRoot '..\infrastructure\bicep\provisioning-bootstrap.bicep'
$PreflightScript = Join-Path $PSScriptRoot 'test-provisioning-prerequisites.ps1'
$ApprovedBicepSources = [ordered]@{
    '..\infrastructure\bicep\provisioning-bootstrap.bicep' = '739F22CB142A1B90AF2BC691C0733294486F8FBAD930FBF85E10929F15A9F5F1'
    '..\infrastructure\bicep\modules\container-app-worker.bicep' = '9EB7D46C9F5FC2DC4DAD09C1EC7EC83780A5A54E905B7A6E4A8F55AE184EE2E1'
    '..\infrastructure\bicep\modules\key-vault.bicep' = '431AF5568A7169860FD2C9FC2FFE10A1E236E43B68C39D035FE666B64D8B3136'
    '..\infrastructure\bicep\modules\role-assignments-worker-bootstrap.bicep' = '2729DB609C3EE25620374826B5A7FCFBFEB89DC346F1F78C152D07E3BF37EF2F'
}
$MutationBoundary = 'ReadOnly'
$CompiledTemplateFile = $null

function Write-Stage {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n[STAGE] $Message" -ForegroundColor Cyan
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Remove-CompiledTemplate {
    if ([string]::IsNullOrWhiteSpace([string]$script:CompiledTemplateFile) -or
        -not (Test-Path -LiteralPath $script:CompiledTemplateFile -PathType Leaf)) {
        return
    }

    $resolvedFile = [System.IO.Path]::GetFullPath($script:CompiledTemplateFile)
    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $resolvedFile.StartsWith(
        $temporaryRoot,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a compiled template outside the system temporary directory.'
    }

    Remove-Item -LiteralPath $resolvedFile -Force
    $script:CompiledTemplateFile = $null
}

function Assert-ApprovedBicepSources {
    foreach ($source in $ApprovedBicepSources.GetEnumerator()) {
        $sourcePath = Join-Path $PSScriptRoot $source.Key
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Approved bootstrap source '$($source.Key)' is missing."
        }

        $actualHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        if (-not [string]::Equals(
            $actualHash,
            [string]$source.Value,
            [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Bootstrap source '$($source.Key)' differs from its reviewed SHA256 allowlist entry. Re-review the scoped template before changing the allowlist."
        }
    }

    Write-Pass 'All scoped Bicep sources match the reviewed SHA256 allowlist.'
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    $output = & az @Arguments --only-show-errors --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }

    $json = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    try {
        return $json | ConvertFrom-Json -Depth 100
    }
    catch {
        throw $FailureMessage
    }
}

function Invoke-AzNoOutput {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    & az @Arguments --only-show-errors --output none 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

function Get-ContainerApp {
    param([Parameter(Mandatory = $true)][string]$Name)

    return Invoke-AzJson -Arguments @(
        'containerapp', 'show',
        '--name', $Name,
        '--resource-group', $ResourceGroup
    ) -FailureMessage "Required development Container App '$Name' could not be read."
}

function Assert-OneShotTargetsAbsent {
    $existingWorkerResources = @(Invoke-AzJson -Arguments @(
        'resource', 'list',
        '--resource-group', $ResourceGroup,
        '--resource-type', 'Microsoft.App/containerApps'
    ) -FailureMessage 'Unable to establish that the one-shot worker target is absent.')
    if (@($existingWorkerResources | Where-Object {
        [string]::Equals(
            [string]$_.name,
            $NewWorkerContainerAppName,
            [System.StringComparison]::OrdinalIgnoreCase)
    }).Count -ne 0) {
        throw 'The one-shot worker target already exists. No worker/vault mutation is permitted; use the read-only preflight and an explicitly reviewed manual resume path.'
    }

    $existingVaultResources = @(Invoke-AzJson -Arguments @(
        'resource', 'list',
        '--resource-group', $ResourceGroup,
        '--resource-type', 'Microsoft.KeyVault/vaults'
    ) -FailureMessage 'Unable to establish that the one-shot provisioning vault target is absent.')
    if (@($existingVaultResources | Where-Object {
        [string]::Equals(
            [string]$_.name,
            $ProvisioningVaultName,
            [System.StringComparison]::OrdinalIgnoreCase)
    }).Count -ne 0) {
        throw 'The one-shot provisioning vault target already exists. No worker/vault mutation is permitted; use the read-only preflight and an explicitly reviewed manual resume path.'
    }

    Write-Pass 'The one-shot worker and dedicated vault targets are both absent.'
}

function Get-SingleContainer {
    param(
        [Parameter(Mandatory = $true)][object]$ContainerApp,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $containers = @($ContainerApp.properties.template.containers)
    if ($containers.Count -ne 1) {
        throw "$DisplayName must have exactly one container for this bounded bootstrap."
    }

    return $containers[0]
}

function Get-OptionalPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-EnvironmentEntries {
    param(
        [Parameter(Mandatory = $true)][object]$Container,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $entries = @(Get-OptionalPropertyValue -InputObject $Container -Name 'env')
    $duplicateNames = @($entries |
        Group-Object -Property name |
        Where-Object { $_.Count -ne 1 })
    if ($duplicateNames.Count -gt 0) {
        throw "$DisplayName contains duplicate environment-variable names. Refusing an ambiguous update."
    }

    return $entries
}

function Get-EnvironmentValue {
    param(
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$AllowMissing
    )

    $matches = @($Entries | Where-Object { $_.name -eq $Name })
    if ($matches.Count -eq 0) {
        if ($AllowMissing) {
            return $null
        }
        throw "Required deployed setting '$Name' is missing."
    }
    if ($matches.Count -ne 1) {
        throw "Required deployed setting '$Name' is ambiguous."
    }

    return [string](Get-OptionalPropertyValue -InputObject $matches[0] -Name 'value')
}

function Get-CanonicalHash {
    param([AllowNull()][object]$Value)

    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($sha256.ComputeHash($bytes))
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-EnvironmentHashExceptRegistrationGate {
    param([Parameter(Mandatory = $true)][object[]]$Entries)

    $safeSnapshot = @($Entries |
        Where-Object { $_.name -ne 'Provisioning__ExecutionEnabled' } |
        Sort-Object -Property name |
        ForEach-Object {
            [ordered]@{
                name = [string]$_.name
                value = [string](Get-OptionalPropertyValue -InputObject $_ -Name 'value')
                secretRef = [string](Get-OptionalPropertyValue -InputObject $_ -Name 'secretRef')
            }
        })
    return Get-CanonicalHash -Value $safeSnapshot
}

function Get-HistoricalWorkerHash {
    param([Parameter(Mandatory = $true)][object]$ContainerApp)

    # Hash configuration rather than printing it. This may include ordinary
    # deployment values, so the fingerprint itself is kept in memory only.
    $snapshot = [ordered]@{
        id = [string]$ContainerApp.id
        environmentId = [string]$ContainerApp.properties.environmentId
        identity = $ContainerApp.identity
        tags = $ContainerApp.tags
        configuration = $ContainerApp.properties.configuration
        template = $ContainerApp.properties.template
        latestRevisionName = [string]$ContainerApp.properties.latestRevisionName
    }
    return Get-CanonicalHash -Value $snapshot
}

function Assert-DigestImage {
    param(
        [Parameter(Mandatory = $true)][string]$Image,
        [Parameter(Mandatory = $true)][string]$ExpectedRegistry,
        [Parameter(Mandatory = $true)][string]$ExpectedRepository,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $pattern = '^(?<registry>[A-Za-z0-9.-]+)/(?<repository>[A-Za-z0-9._/-]+)@sha256:(?<digest>[A-Fa-f0-9]{64})$'
    $match = [regex]::Match($Image, $pattern)
    if (-not $match.Success) {
        throw "$DisplayName must be a full registry image reference pinned by a 64-character sha256 digest."
    }

    if (-not [string]::Equals(
        $match.Groups['registry'].Value,
        $ExpectedRegistry,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$DisplayName must come from the existing development Azure Container Registry."
    }

    if (-not [string]::Equals(
        $match.Groups['repository'].Value,
        $ExpectedRepository,
        [System.StringComparison]::Ordinal)) {
        throw "$DisplayName must use the approved '$ExpectedRepository' repository exactly."
    }

    return "$($match.Groups['repository'].Value)@sha256:$($match.Groups['digest'].Value.ToLowerInvariant())"
}

function Assert-WhatIfScope {
    param(
        [Parameter(Mandatory = $true)][object]$WhatIfResult,
        [Parameter(Mandatory = $true)][string]$ResourceGroupId,
        [Parameter(Mandatory = $true)][string]$ContainerRegistryId
    )

    if (-not [string]::Equals(
        [string]$WhatIfResult.status,
        'Succeeded',
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The ARM what-if operation did not complete successfully.'
    }

    $newWorkerId = "$ResourceGroupId/providers/Microsoft.App/containerApps/$NewWorkerContainerAppName"
    $vaultId = "$ResourceGroupId/providers/Microsoft.KeyVault/vaults/$ProvisioningVaultName"
    $diagnosticSettingsId = "$vaultId/providers/Microsoft.Insights/diagnosticSettings/$ProvisioningVaultName-diag"
    $allowedExactIds = @($newWorkerId, $vaultId, $diagnosticSettingsId)
    $roleAssignmentPrefixes = @(
        "$vaultId/providers/Microsoft.Authorization/roleAssignments/",
        "$ContainerRegistryId/providers/Microsoft.Authorization/roleAssignments/"
    )
    $ignoredChangeTypes = @('Ignore', 'NoChange')
    $whatIfChanges = @(Get-OptionalPropertyValue -InputObject $WhatIfResult -Name 'changes')
    $effectiveChanges = @($whatIfChanges | Where-Object {
        $ignoredChangeTypes -notcontains [string]$_.changeType
    })

    foreach ($change in $effectiveChanges) {
        $changeType = [string]$change.changeType
        $resourceId = [string]$change.resourceId
        $isExactCreateResource = @($allowedExactIds | Where-Object {
            [string]::Equals($_, $resourceId, [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        $isPinnedRoleAssignment = @($roleAssignmentPrefixes | Where-Object {
                $resourceId.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0

        if ($isExactCreateResource -and $changeType -ne 'Create') {
            throw "One-shot what-if returned disallowed change type '$changeType' for a concrete resource. Only Create is permitted."
        }
        if ($isPinnedRoleAssignment -and $changeType -ne 'Unsupported') {
            throw "One-shot what-if returned unexpected change type '$changeType' for a dynamic managed-identity role assignment."
        }
        if (-not $isExactCreateResource -and -not $isPinnedRoleAssignment) {
            throw 'Scoped what-if included a resource outside the new worker, dedicated vault, diagnostics, and bootstrap RBAC allowlist.'
        }
    }

    foreach ($expectedResourceId in $allowedExactIds) {
        if (@($effectiveChanges | Where-Object {
            [string]::Equals(
                [string]$_.resourceId,
                $expectedResourceId,
                [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -ne 1) {
            throw 'One-shot what-if did not contain each exact worker, vault, and diagnostic Create exactly once.'
        }
    }

    $vaultRoleChanges = @($effectiveChanges | Where-Object {
        ([string]$_.resourceId).StartsWith(
            "$vaultId/providers/Microsoft.Authorization/roleAssignments/",
            [System.StringComparison]::OrdinalIgnoreCase)
    })
    $acrRoleChanges = @($effectiveChanges | Where-Object {
        ([string]$_.resourceId).StartsWith(
            "$ContainerRegistryId/providers/Microsoft.Authorization/roleAssignments/",
            [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($vaultRoleChanges.Count -ne 1 -or $acrRoleChanges.Count -ne 1 -or
        $effectiveChanges.Count -ne 5) {
        throw 'One-shot what-if must contain exactly three Creates plus the two pinned dynamic role assignments.'
    }
    if (@($vaultRoleChanges | Where-Object { $_.changeType -ne 'Unsupported' }).Count -ne 0 -or
        @($acrRoleChanges | Where-Object { $_.changeType -ne 'Unsupported' }).Count -ne 0) {
        throw 'Only the two SHA256-pinned managed-identity role assignments may be reported as Unsupported.'
    }

    $summary = @($effectiveChanges | Group-Object -Property changeType | Sort-Object -Property Name |
        ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
    if ([string]::IsNullOrWhiteSpace($summary)) {
        $summary = 'no effective changes'
    }
    Write-Pass "ResourceIdOnly what-if contains exactly three Creates and the two reviewed dynamic role assignments ($summary)."
}

function Assert-InertWorker {
    param(
        [Parameter(Mandatory = $true)][object]$ContainerApp,
        [Parameter(Mandatory = $true)][string]$ExpectedImage,
        [Parameter(Mandatory = $true)][string]$ExpectedEnvironmentId,
        [Parameter(Mandatory = $true)][string]$ExpectedGatewayApiClientId,
        [Parameter(Mandatory = $false)][string]$ExpectedManagedIdentityPrincipalId
    )

    if (-not [string]::Equals(
        [string]$ContainerApp.name,
        $NewWorkerContainerAppName,
        [System.StringComparison]::Ordinal)) {
        throw 'The scoped deployment returned an unexpected worker name.'
    }
    if (-not [string]::Equals(
        [string]$ContainerApp.properties.environmentId,
        $ExpectedEnvironmentId,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The new worker is not attached to the approved VNet Container Apps environment.'
    }
    if ($ContainerApp.identity.type -notmatch 'SystemAssigned' -or
        [string]::IsNullOrWhiteSpace([string]$ContainerApp.identity.principalId)) {
        throw 'The new worker does not have the expected system-assigned managed identity.'
    }

    $container = Get-SingleContainer -ContainerApp $ContainerApp -DisplayName 'New worker'
    if (-not [string]::Equals(
        [string]$container.image,
        $ExpectedImage,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The new worker image does not match the expected immutable image reference.'
    }

    $entries = Get-EnvironmentEntries -Container $container -DisplayName 'New worker'
    $requiredSettings = [ordered]@{
        'OutboxRelay__Enabled' = 'false'
        'ProvisioningWorker__ProcessingEnabled' = 'false'
        'ProvisioningWorker__ProvisioningExecutionEnabled' = 'false'
        'ProvisioningWorker__MaxConcurrentCalls' = '1'
        'Agent365__RegistryProvider' = 'Disabled'
        'Agent365__DirectRegistryPreviewEnabled' = 'false'
        'Agent365__GatewayApiApplicationClientId' = $ExpectedGatewayApiClientId
        'Agent365__CredentialKeyVaultUri' = $ProvisioningVaultUri
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedManagedIdentityPrincipalId)) {
        $requiredSettings['Agent365__ProvisioningManagedIdentityPrincipalId'] =
            $ExpectedManagedIdentityPrincipalId
    }
    foreach ($setting in $requiredSettings.GetEnumerator()) {
        $actualValue = Get-EnvironmentValue -Entries $entries -Name $setting.Key
        if (-not [string]::Equals(
            $actualValue,
            [string]$setting.Value,
            [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "New worker setting '$($setting.Key)' is not at its fail-closed bootstrap value."
        }
    }

    if (@($entries | Where-Object {
        $_.name.StartsWith('Agent365__ManagerApplicationIds__', [System.StringComparison]::Ordinal)
    }).Count -ne 0) {
        throw 'The inert worker unexpectedly has manager application IDs configured.'
    }

    $scale = $ContainerApp.properties.template.scale
    if ([int]$scale.minReplicas -ne 0 -or [int]$scale.maxReplicas -ne 1) {
        throw 'The new worker must remain constrained to zero minimum and one maximum replica.'
    }
    $scaleRules = Get-OptionalPropertyValue -InputObject $scale -Name 'rules'
    if ($null -ne $scaleRules -and @($scaleRules).Count -ne 0) {
        throw 'The new worker must not have a KEDA scale rule during bootstrap.'
    }
}

function Assert-ApiPreservation {
    param(
        [Parameter(Mandatory = $true)][object]$Before,
        [Parameter(Mandatory = $true)][object]$After,
        [Parameter(Mandatory = $true)][string]$ExpectedImage
    )

    if (-not [string]::Equals(
        [string]$Before.properties.environmentId,
        [string]$After.properties.environmentId,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The API Container Apps environment changed unexpectedly.'
    }

    $beforeContainer = Get-SingleContainer -ContainerApp $Before -DisplayName 'Gateway API before update'
    $afterContainer = Get-SingleContainer -ContainerApp $After -DisplayName 'Gateway API after update'
    $beforeEntries = Get-EnvironmentEntries -Container $beforeContainer -DisplayName 'Gateway API before update'
    $afterEntries = Get-EnvironmentEntries -Container $afterContainer -DisplayName 'Gateway API after update'

    if ((Get-EnvironmentHashExceptRegistrationGate -Entries $beforeEntries) -ne
        (Get-EnvironmentHashExceptRegistrationGate -Entries $afterEntries)) {
        throw 'An API environment setting other than the registration gate changed unexpectedly.'
    }
    if ((Get-CanonicalHash -Value $Before.properties.template.scale) -ne
        (Get-CanonicalHash -Value $After.properties.template.scale)) {
        throw 'The API scale configuration changed unexpectedly.'
    }

    $registrationGate = Get-EnvironmentValue `
        -Entries $afterEntries `
        -Name 'Provisioning__ExecutionEnabled'
    if (-not [string]::Equals(
        $registrationGate,
        'false',
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The API registration gate is not fail closed.'
    }
    if (-not [string]::Equals(
        [string]$afterContainer.image,
        $ExpectedImage,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The API image does not match the expected immutable image reference.'
    }
}

function Assert-HistoricalWorkerUnchanged {
    param([Parameter(Mandatory = $true)][string]$BeforeHash)

    $current = Get-ContainerApp -Name $HistoricalWorkerContainerAppName
    if ((Get-HistoricalWorkerHash -ContainerApp $current) -ne $BeforeHash) {
        throw 'The historical worker configuration changed during the bootstrap window. Stop and investigate; no rollback was attempted.'
    }
    Write-Pass 'The historical worker configuration and revision are unchanged.'
}

function Wait-ApiHealth {
    param([Parameter(Mandatory = $true)][object]$ApiContainerApp)

    $fqdn = [string]$ApiContainerApp.properties.configuration.ingress.fqdn
    if ([string]::IsNullOrWhiteSpace($fqdn)) {
        throw 'The Gateway API has no HTTPS ingress FQDN.'
    }

    foreach ($path in @('/health', '/health/ready', '/health/checks')) {
        $healthy = $false
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            try {
                $response = Invoke-WebRequest `
                    -Uri "https://$fqdn$path" `
                    -Method Get `
                    -TimeoutSec 10 `
                    -SkipHttpErrorCheck
                if ($response.StatusCode -eq 200) {
                    $healthy = $true
                    break
                }
            }
            catch {
                # The next bounded attempt handles revision startup and transient DNS.
            }
            Start-Sleep -Seconds 5
        }

        if (-not $healthy) {
            throw "Gateway API health route '$path' did not return HTTP 200 within the bounded wait."
        }
        Write-Pass "Gateway API $path returned HTTP 200."
    }
}

try {
    Write-Host ''
    Write-Host 'A365 provisioning worker scoped development bootstrap' -ForegroundColor Cyan
    Write-Host 'Target: dev / approved VNet / inert blue-green worker' -ForegroundColor White
    Write-Host ''

    Write-Stage 'Local and Azure read-only prerequisites'

    if (-not (Test-Path -LiteralPath $TemplateFile -PathType Leaf)) {
        throw 'The scoped provisioning bootstrap template is missing.'
    }
    if (-not (Test-Path -LiteralPath $PreflightScript -PathType Leaf)) {
        throw 'The read-only provisioning preflight script is missing.'
    }
    Assert-ApprovedBicepSources
    if ($NewWorkerContainerAppName -eq $HistoricalWorkerContainerAppName) {
        throw 'The blue/green worker name must never equal the historical worker name.'
    }
    if ($null -eq (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required.'
    }

    $account = Invoke-AzJson -Arguments @('account', 'show') `
        -FailureMessage 'Unable to read the active Azure CLI account.'
    if (-not [string]::Equals(
        [string]$account.state,
        'Enabled',
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The active Azure subscription is not enabled.'
    }
    if ($ExpectedSubscriptionId -eq [guid]::Empty) {
        throw 'ExpectedSubscriptionId must be a non-empty GUID.'
    }
    if (-not [string]::Equals(
            $ExpectedSubscriptionId.ToString('D'),
            [string]$account.id,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The active Azure subscription does not match ExpectedSubscriptionId. The script did not change account context.'
    }

    $parsedTenantId = [guid]::Empty
    if (-not [guid]::TryParse([string]$account.tenantId, [ref]$parsedTenantId) -or
        $parsedTenantId -eq [guid]::Empty) {
        throw 'The active Azure account does not expose a valid tenant ID.'
    }
    $tenantId = $parsedTenantId.ToString('D')

    $resourceGroupResource = Invoke-AzJson -Arguments @(
        'group', 'show', '--name', $ResourceGroup
    ) -FailureMessage "Development resource group '$ResourceGroup' was not found."
    $resourceGroupId = [string]$resourceGroupResource.id
    Assert-OneShotTargetsAbsent

    $approvedEnvironment = Invoke-AzJson -Arguments @(
        'containerapp', 'env', 'show',
        '--name', $ContainerAppsEnvironmentName,
        '--resource-group', $ResourceGroup
    ) -FailureMessage 'The approved VNet Container Apps environment was not found.'
    $approvedEnvironmentId = [string]$approvedEnvironment.id

    $apiBefore = Get-ContainerApp -Name $ApiContainerAppName
    if (-not [string]::Equals(
        [string]$apiBefore.properties.environmentId,
        $approvedEnvironmentId,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Gateway API is not in the approved VNet Container Apps environment.'
    }
    $apiContainerBefore = Get-SingleContainer -ContainerApp $apiBefore -DisplayName 'Gateway API'
    $apiEntriesBefore = Get-EnvironmentEntries -Container $apiContainerBefore -DisplayName 'Gateway API'
    $apiClientIdValue = Get-EnvironmentValue -Entries $apiEntriesBefore -Name 'EntraId__ClientId'
    $parsedApiClientId = [guid]::Empty
    if (-not [guid]::TryParse($apiClientIdValue, [ref]$parsedApiClientId) -or
        $parsedApiClientId -eq [guid]::Empty) {
        throw 'The live Gateway API client ID is missing or invalid.'
    }
    $apiClientId = $parsedApiClientId.ToString('D')
    Write-Pass 'Read and validated the live Gateway API client ID without displaying it.'

    $currentApiImage = [string]$apiContainerBefore.image
    $currentImageMatch = [regex]::Match($currentApiImage, '^(?<registry>[A-Za-z0-9.-]+)/')
    if (-not $currentImageMatch.Success) {
        throw 'The deployed Gateway API image does not identify the expected Azure Container Registry.'
    }
    $currentRegistry = $currentImageMatch.Groups['registry'].Value
    if (-not $currentRegistry.EndsWith('.azurecr.io', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The deployed Gateway API is not using Azure Container Registry.'
    }
    $containerRegistryName = $currentRegistry.Split('.')[0]
    $containerRegistry = Invoke-AzJson -Arguments @(
        'acr', 'show',
        '--name', $containerRegistryName,
        '--resource-group', $ResourceGroup
    ) -FailureMessage 'The development Azure Container Registry could not be read.'
    if (-not [string]::Equals(
        [string]$containerRegistry.loginServer,
        $currentRegistry,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The live API registry does not match the development Azure Container Registry resource.'
    }

    $apiRepositoryDigest = Assert-DigestImage `
        -Image $ApiImage `
        -ExpectedRegistry ([string]$containerRegistry.loginServer) `
        -ExpectedRepository $ApiRepositoryName `
        -DisplayName 'ApiImage'
    $workerRepositoryDigest = Assert-DigestImage `
        -Image $WorkerImage `
        -ExpectedRegistry ([string]$containerRegistry.loginServer) `
        -ExpectedRepository $WorkerRepositoryName `
        -DisplayName 'WorkerImage'
    Invoke-AzNoOutput -Arguments @(
        'acr', 'repository', 'show',
        '--name', $containerRegistryName,
        '--image', $apiRepositoryDigest
    ) -FailureMessage 'The digest-pinned API artifact was not found in the development registry.'
    Invoke-AzNoOutput -Arguments @(
        'acr', 'repository', 'show',
        '--name', $containerRegistryName,
        '--image', $workerRepositoryDigest
    ) -FailureMessage 'The digest-pinned worker artifact was not found in the development registry.'
    Write-Pass 'Both immutable image digests exist in the development registry.'

    $historicalWorkerBefore = Get-ContainerApp -Name $HistoricalWorkerContainerAppName
    $historicalWorkerHash = Get-HistoricalWorkerHash -ContainerApp $historicalWorkerBefore

    $preflightParameters = @{
        Environment = $EnvironmentName
        ResourceGroup = $ResourceGroup
        ProjectName = $ProjectName
        ContainerAppsEnvironmentName = $ContainerAppsEnvironmentName
        WorkerContainerAppName = $NewWorkerContainerAppName
        WorkerProcessingEnabled = $false
        ExpectedGatewayApiApplicationClientId = $apiClientId
        ExpectedCredentialKeyVaultUri = $ProvisioningVaultUri
        RegistryProvider = 'Disabled'
        AllowMissingWorkloads = $true
    }
    & $PreflightScript @preflightParameters
    Write-Pass 'Repository provisioning preflight completed without mutation.'

    Write-Stage 'Bicep build and ARM validation'
    $CompiledTemplateFile = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        "a365-provisioning-bootstrap-$([guid]::NewGuid().ToString('N')).json"
    & az bicep build `
        --file $TemplateFile `
        --outfile $CompiledTemplateFile `
        --only-show-errors 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'The scoped provisioning bootstrap Bicep template did not compile.'
    }
    Write-Pass 'Scoped Bicep template compiled once to an ephemeral deployment artifact.'

    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $deploymentName = "provisioning-bootstrap-dev-$timestamp"
    $deploymentParameters = @(
        'environment=dev',
        'projectName=a365gw',
        "containerAppsEnvironmentName=$ContainerAppsEnvironmentName",
        "workerContainerAppName=$NewWorkerContainerAppName",
        "workerBootstrapImage=$BootstrapImage",
        "entraIdTenantId=$tenantId",
        "gatewayApiApplicationClientId=$apiClientId"
    )
    $deploymentBaseArguments = @(
        '--name', $deploymentName,
        '--resource-group', $ResourceGroup,
        '--template-file', $CompiledTemplateFile,
        '--parameters'
    ) + $deploymentParameters

    Invoke-AzNoOutput -Arguments (@(
        'deployment', 'group', 'validate'
    ) + $deploymentBaseArguments + @(
        '--mode', 'Incremental'
    )) `
        -FailureMessage 'ARM validation failed for the scoped provisioning bootstrap.'
    Write-Pass 'ARM validation passed without mutation.'

    Write-Stage 'ResourceIdOnly scoped what-if'
    $whatIf = Invoke-AzJson -Arguments (@(
        'deployment', 'group', 'what-if'
    ) + $deploymentBaseArguments + @(
        '--mode', 'Incremental',
        '--result-format', 'ResourceIdOnly',
        '--no-pretty-print',
        '--no-prompt'
    )) -FailureMessage 'ARM ResourceIdOnly what-if failed for the scoped provisioning bootstrap.'
    Assert-WhatIfScope `
        -WhatIfResult $whatIf `
        -ResourceGroupId $resourceGroupId `
        -ContainerRegistryId ([string]$containerRegistry.id)
    Assert-HistoricalWorkerUnchanged -BeforeHash $historicalWorkerHash

    if ($WhatIfOnly) {
        Remove-CompiledTemplate
        Write-Host ''
        Write-Pass 'WhatIfOnly completed. No Azure mutation was attempted.'
        exit 0
    }

    Assert-OneShotTargetsAbsent
    Write-Stage 'Force the API registration boundary off and pin its image'
    $MutationBoundary = 'ApiUpdateStarted'
    $currentRegistrationGate = Get-EnvironmentValue `
        -Entries $apiEntriesBefore `
        -Name 'Provisioning__ExecutionEnabled' `
        -AllowMissing
    $apiNeedsUpdate =
        -not [string]::Equals(
            $currentRegistrationGate,
            'false',
            [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            $currentApiImage,
            $ApiImage,
            [System.StringComparison]::OrdinalIgnoreCase)

    if ($apiNeedsUpdate) {
        Invoke-AzNoOutput -Arguments @(
            'containerapp', 'update',
            '--name', $ApiContainerAppName,
            '--resource-group', $ResourceGroup,
            '--image', $ApiImage,
            '--set-env-vars', 'Provisioning__ExecutionEnabled=false',
            '--revision-suffix', "gateoff-$timestamp"
        ) -FailureMessage 'The Gateway API fail-closed update did not complete.'
    }
    else {
        Write-Pass 'The Gateway API already uses the requested digest with registration disabled.'
    }

    $apiAfter = Get-ContainerApp -Name $ApiContainerAppName
    Assert-ApiPreservation -Before $apiBefore -After $apiAfter -ExpectedImage $ApiImage
    Wait-ApiHealth -ApiContainerApp $apiAfter
    $MutationBoundary = 'ApiGateVerifiedOff'
    Assert-HistoricalWorkerUnchanged -BeforeHash $historicalWorkerHash

    Assert-OneShotTargetsAbsent
    Write-Stage 'Deploy only the inert blue/green worker bootstrap'
    $MutationBoundary = 'ScopedBootstrapStarted'
    Invoke-AzNoOutput -Arguments (@(
        'deployment', 'group', 'create'
    ) + $deploymentBaseArguments + @(
        '--mode', 'Incremental'
    )) -FailureMessage 'The scoped inert-worker deployment did not complete.'

    $placeholderWorker = Get-ContainerApp -Name $NewWorkerContainerAppName
    Assert-InertWorker `
        -ContainerApp $placeholderWorker `
        -ExpectedImage $BootstrapImage `
        -ExpectedEnvironmentId $approvedEnvironmentId `
        -ExpectedGatewayApiClientId $apiClientId
    $MutationBoundary = 'InertPlaceholderVerified'
    Assert-HistoricalWorkerUnchanged -BeforeHash $historicalWorkerHash
    Write-Pass 'The scoped worker is inert on the public bootstrap image.'

    Write-Stage 'Replace the placeholder with the immutable worker image'
    $MutationBoundary = 'WorkerDigestUpdateStarted'
    Invoke-AzNoOutput -Arguments @(
        'containerapp', 'update',
        '--name', $NewWorkerContainerAppName,
        '--resource-group', $ResourceGroup,
        '--image', $WorkerImage,
        '--set-env-vars',
        "Agent365__ProvisioningManagedIdentityPrincipalId=$($placeholderWorker.identity.principalId)",
        '--revision-suffix', "inert-$timestamp"
    ) -FailureMessage 'The new inert worker image update did not complete.'

    $workerAfter = Get-ContainerApp -Name $NewWorkerContainerAppName
    Assert-InertWorker `
        -ContainerApp $workerAfter `
        -ExpectedImage $WorkerImage `
        -ExpectedEnvironmentId $approvedEnvironmentId `
        -ExpectedGatewayApiClientId $apiClientId `
        -ExpectedManagedIdentityPrincipalId ([string]$placeholderWorker.identity.principalId)
    if (-not [string]::Equals(
        [string]$workerAfter.properties.provisioningState,
        'Succeeded',
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The new inert worker resource has not reached the Succeeded provisioning state.'
    }
    $MutationBoundary = 'WorkerDigestVerifiedInert'

    Write-Stage 'Post-deployment read-only verification'
    $postflightParameters = @{
        Environment = $EnvironmentName
        ResourceGroup = $ResourceGroup
        ProjectName = $ProjectName
        ContainerAppsEnvironmentName = $ContainerAppsEnvironmentName
        WorkerContainerAppName = $NewWorkerContainerAppName
        WorkerProcessingEnabled = $false
        ExpectedGatewayApiApplicationClientId = $apiClientId
        ExpectedCredentialKeyVaultUri = $ProvisioningVaultUri
        RegistryProvider = 'Disabled'
        RequireDeployedConfigurationMatch = $true
    }
    & $PreflightScript @postflightParameters
    Assert-HistoricalWorkerUnchanged -BeforeHash $historicalWorkerHash

    $apiFinal = Get-ContainerApp -Name $ApiContainerAppName
    Assert-ApiPreservation -Before $apiBefore -After $apiFinal -ExpectedImage $ApiImage
    Wait-ApiHealth -ApiContainerApp $apiFinal

    $MutationBoundary = 'Complete'
    Remove-CompiledTemplate
    Write-Host ''
    Write-Pass 'Scoped development bootstrap completed and verified.'
    Write-Host 'The API registration gate is off. The new worker has zero replicas, no scaler,' -ForegroundColor White
    Write-Host 'all processing/execution relays off, Registry disabled, and immutable images.' -ForegroundColor White
    Write-Host 'No SQL, tenant/Graph, Service Bus, Storage, historical-worker, or DLQ action was performed.' -ForegroundColor White
    exit 0
}
catch {
    $failureMessage = $_.Exception.Message
    try {
        Remove-CompiledTemplate
    }
    catch {
        Write-Host '[BOUNDARY] The ephemeral compiled template could not be removed safely.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host "[STOP] Bootstrap stopped at boundary '$MutationBoundary': $failureMessage" -ForegroundColor Red

    switch ($MutationBoundary) {
        'ReadOnly' {
            Write-Host '[BOUNDARY] No Azure mutation was attempted.' -ForegroundColor Yellow
        }
        'ApiUpdateStarted' {
            Write-Host '[BOUNDARY] The API update may have applied. It only requested the immutable image and registration gate=false. The worker bootstrap was not started.' -ForegroundColor Yellow
        }
        'ApiGateVerifiedOff' {
            Write-Host '[BOUNDARY] The API is verified fail closed. The scoped worker bootstrap was not started or did not begin.' -ForegroundColor Yellow
        }
        'ScopedBootstrapStarted' {
            Write-Host '[BOUNDARY] The scoped deployment may have created/updated the inert worker, dedicated vault, diagnostics, AcrPull, and vault officer assignment. The worker digest update did not begin.' -ForegroundColor Yellow
        }
        'InertPlaceholderVerified' {
            Write-Host '[BOUNDARY] The public-image worker was verified inert. The immutable worker update was not started or did not begin.' -ForegroundColor Yellow
        }
        'WorkerDigestUpdateStarted' {
            Write-Host '[BOUNDARY] The new worker image update may have applied; post-update verification did not complete.' -ForegroundColor Yellow
        }
        'WorkerDigestVerifiedInert' {
            Write-Host '[BOUNDARY] The new worker was verified inert and digest-pinned; final read-only verification did not complete.' -ForegroundColor Yellow
        }
        default {
            Write-Host '[BOUNDARY] Inspect the fail-closed API and inert new worker read-only before resuming.' -ForegroundColor Yellow
        }
    }

    if ($MutationBoundary -ne 'ReadOnly') {
        try {
            Assert-HistoricalWorkerUnchanged -BeforeHash $historicalWorkerHash
        }
        catch {
            Write-Host '[BOUNDARY] The historical worker could not be proven unchanged. Stop and investigate without automatic rollback.' -ForegroundColor Red
        }
    }

    Write-Host '[BOUNDARY] No automatic rollback, SQL setup, privilege grant, queue operation, or worker activation was attempted.' -ForegroundColor Yellow
    exit 1
}
