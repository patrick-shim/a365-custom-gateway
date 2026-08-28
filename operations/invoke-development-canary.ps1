#Requires -Version 7.0

<#
.SYNOPSIS
    Controls the bounded workflow-v3 development canary gates.

.DESCRIPTION
    This script is intentionally fixed to the approved development API, the new
    VNet worker, and the workflow-v3 queue. Arm deploys and verifies the worker
    before updating the API, while keeping API admission closed. OpenAdmission
    sets an API-enforced UTC expiry that includes a bounded revision-rollout
    allowance plus an operator window of at most five minutes, with a hard
    combined ceiling of ten minutes. It also closes admission in a local
    finally block.
    Deactivate closes the API first and then returns the worker to its inert state.

    Activation requires immutable two-pass prepare provenance plus fresh, read-only
    live-state and recovery evidence, explicit confirmation of contained SQL access
    and an empty provisioning outbox, exact queue-scoped Service Bus data roles,
    immutable image digests, current Graph/OBO preflight, an empty workflow-v3
    queue, the exact retained workflow-v2 DLQ evidence, and historical-worker queue
    isolation. The v2 queue is evidence-only and never becomes a receiver target.
    The script never grants roles, reads credentials, receives, peeks, settles,
    replays, or purges messages, changes SQL, or touches either retained worker.

    Any failure after resource validation attempts the same fail-closed sequence:
    API admission off first, then worker processing/provisioning/Registry off.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Status', 'Arm', 'OpenAdmission', 'OpenDelegatedCompletion', 'Deactivate')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [guid]$ExpectedSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ApiImage,

    [Parameter(Mandatory = $false)]
    [string]$WorkerImage,

    [Parameter(Mandatory = $false)]
    [guid[]]$ExpectedManagerApplicationIds = @(),

    [Parameter(Mandatory = $false)]
    [string]$AuthorizedExternalAgentId = '',

    [Parameter(Mandatory = $false)]
    [guid]$AuthorizedRetryAgentId = [guid]::Empty,

    [Parameter(Mandatory = $false)]
    [guid]$AuthorizedOperationId = [guid]::Empty,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedGatewayApiFederatedCredentialName = 'a365gw-api-obo-dev',

    [Parameter(Mandatory = $false)]
    [string]$LivePrepareEvidencePath,

    [Parameter(Mandatory = $false)]
    [string]$LiveStateEvidencePath,

    [Parameter(Mandatory = $false)]
    [string]$LiveFinalizeEvidencePath,

    [Parameter(Mandatory = $false)]
    [string]$RecoveryBaselineEvidencePath,

    [Parameter(Mandatory = $false)]
    [Alias('ReviewedCanaryFailureEvidencePath')]
    [string[]]$ReviewedCanaryFailureEvidencePaths = @(),

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 1000)]
    [long]$ExpectedWorkflowV2DeadLetterCount = 0,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 8)]
    [long]$ExpectedWorkflowV3DeadLetterCount = 0,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 8)]
    [long]$ExpectedRetainedManualWorkflowV3JobCount = 0,

    [Parameter(Mandatory = $false)]
    [guid]$ReviewedWorkflowV3ManualOperationId = [guid]::Empty,

    [Parameter(Mandatory = $false)]
    [guid]$ReviewedWorkflowV3BlueprintReadbackOperationId = [guid]::Empty,

    [Parameter(Mandatory = $false)]
    [guid]$ReviewedWorkflowV3PrincipalReadbackOperationId = [guid]::Empty,

    [Parameter(Mandatory = $false)]
    [guid]$ReviewedWorkflowV3AgentIdentityReadbackOperationId = [guid]::Empty,

    [Parameter(Mandatory = $false)]
    [guid]$ReviewedWorkflowV3Agent365AccessOperationId = [guid]::Empty,

    [Parameter(Mandatory = $false)]
    [guid]$ReviewedWorkflowV3FinalVerificationOperationId = [guid]::Empty,

    [Parameter(Mandatory = $false)]
    [guid]$ReviewedWorkflowV3RetryGuardOperationId = [guid]::Empty,

    [Parameter(Mandatory = $false)]
    [guid]$ReviewedWorkflowV3TokenProofOperationId = [guid]::Empty,

    [Parameter(Mandatory = $false)]
    [guid]$ReviewedWorkflowV3TokenAudienceOperationId = [guid]::Empty,

    [Parameter(Mandatory = $false)]
    [datetimeoffset]$ProvisioningOutboxVerifiedAtUtc = [datetimeoffset]::MinValue,

    [Parameter(Mandatory = $false)]
    [ValidateRange(5, 60)]
    [int]$MaximumOutboxEvidenceAgeMinutes = 15,

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 2880)]
    [int]$MaximumDatabaseEvidenceAgeMinutes = 720,

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 300)]
    [int]$AdmissionDurationSeconds = 120,

    [Parameter(Mandatory = $false)]
    [ValidateRange(60, 300)]
    [int]$RevisionDeploymentAllowanceSeconds = 300,

    [switch]$PendingProvisioningOutboxVerifiedEmpty,

    [switch]$ContainedSqlAccessVerified,

    [switch]$ManagerApplicationsPreflightConfirmed,

    [switch]$WhatIfOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$EnvironmentName = 'dev'
$ProjectName = 'a365gw'
$ResourceGroup = 'rg-agent-gateway'
$ContainerAppsEnvironmentName = 'cae-a365gw-dev-vnet'
$ApiContainerAppName = 'ca-gateway-api-dev'
$WorkerContainerAppName = 'ca-gateway-worker-dev-vnet'
$HistoricalWorkerContainerAppName = 'ca-gateway-worker-dev'
$ServiceBusNamespaceName = 'sb-a365gw-dev'
$WorkflowV3QueueName = 'gateway-provisioning-v3'
$WorkflowV2QueueName = 'gateway-provisioning-v2'
$HistoricalQueueName = 'gateway-provisioning'
$ExpectedHistoricalDeadLetterCount = 2L
$SqlServerFqdn = 'sql-a365gw-dev.database.windows.net'
$SqlDatabaseName = 'GatewayDb'
$ServiceBusDataSenderRoleId = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
$ServiceBusDataReceiverRoleId = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
$ServiceBusDataOwnerRoleId = '090c5cfd-751d-490a-894a-3ce6f1109419'
$PreflightScript = Join-Path $PSScriptRoot 'test-provisioning-prerequisites.ps1'
$SqlScriptDirectory = Join-Path $PSScriptRoot '..\infrastructure\sql'
$ManagerApplicationSettingPrefix = 'Agent365__ManagerApplicationIds__'
$AdmissionExpirySettingName = 'Provisioning__AdmissionExpiresAtUtc'
$RequireExactAdmissionBindingSettingName = 'Provisioning__RequireExactAdmissionBinding'
$AuthorizedExternalAgentIdSettingName = 'Provisioning__AuthorizedExternalAgentId'
$AuthorizedRetryAgentIdSettingName = 'Provisioning__AuthorizedRetryAgentId'
$RequireExactDelegatedActionBindingSettingName = 'Agent365__DelegatedRegistry__RequireExactActionBinding'
$DelegatedRegistryActionExpirySettingName = 'Agent365__DelegatedRegistry__ActionExpiresAtUtc'
$DelegatedRegistryAuthorizedOperationIdSettingName = 'Agent365__DelegatedRegistry__AuthorizedOperationId'
$MaximumAdmissionExposureSeconds = 600
$ResourcesValidated = $false
$HistoricalWorkerSignature = $null
$CurrentTenantId = [guid]::Empty

function Write-Stage {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n[STAGE] $Message" -ForegroundColor Cyan
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Note {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[NOTE] $Message" -ForegroundColor White
}

function ConvertFrom-JsonElementPreservingStrings {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.Json.JsonElement]$Element
    )

    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $properties = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                $properties[$property.Name] =
                    ConvertFrom-JsonElementPreservingStrings -Element $property.Value
            }
            return [pscustomobject]$properties
        }
        ([System.Text.Json.JsonValueKind]::Array) {
            $values = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) {
                $value = ConvertFrom-JsonElementPreservingStrings -Element $item
                $values.Add($value)
            }
            return ,($values.ToArray())
        }
        ([System.Text.Json.JsonValueKind]::String) {
            return $Element.GetString()
        }
        ([System.Text.Json.JsonValueKind]::Number) {
            $integerValue = 0L
            if ($Element.TryGetInt64([ref]$integerValue)) {
                return $integerValue
            }

            $decimalValue = 0D
            if ($Element.TryGetDecimal([ref]$decimalValue)) {
                return $decimalValue
            }

            return $Element.GetDouble()
        }
        ([System.Text.Json.JsonValueKind]::True) {
            return $true
        }
        ([System.Text.Json.JsonValueKind]::False) {
            return $false
        }
        ([System.Text.Json.JsonValueKind]::Null) {
            return $null
        }
        default {
            throw "Unsupported JSON value kind '$($Element.ValueKind)'."
        }
    }
}

function ConvertFrom-AzJsonPreservingStrings {
    param([Parameter(Mandatory = $true)][string]$RawJson)

    $convertFromJson = Get-Command ConvertFrom-Json -CommandType Cmdlet
    if ($convertFromJson.Parameters.ContainsKey('DateKind')) {
        return $RawJson | ConvertFrom-Json -Depth 100 -DateKind String
    }

    # PowerShell 7 releases before -DateKind cannot opt out of automatic date
    # conversion. System.Text.Json keeps every JSON string lexically intact, so
    # strict callers can still require an RFC 3339 UTC value ending in literal Z.
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 100
    $document = [System.Text.Json.JsonDocument]::Parse($RawJson, $options)
    try {
        return ConvertFrom-JsonElementPreservingStrings -Element $document.RootElement
    }
    finally {
        $document.Dispose()
    }
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
        return ConvertFrom-AzJsonPreservingStrings -RawJson $json
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

function Get-PrimaryContainer {
    param([Parameter(Mandatory = $true)][object]$ContainerApp)

    $containers = @($ContainerApp.properties.template.containers)
    if ($containers.Count -ne 1) {
        throw "Container App '$($ContainerApp.name)' must have exactly one container for this scoped canary."
    }

    return $containers[0]
}

function Get-EnvironmentValue {
    param(
        [Parameter(Mandatory = $true)][object]$ContainerApp,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$AllowMissing
    )

    $container = Get-PrimaryContainer -ContainerApp $ContainerApp
    $entry = @($container.env | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
    if ($null -eq $entry) {
        if ($AllowMissing) {
            return $null
        }
        throw "Container App '$($ContainerApp.name)' is missing required setting '$Name'."
    }
    $secretReferenceProperty = $entry.PSObject.Properties['secretRef']
    if ($null -ne $secretReferenceProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$secretReferenceProperty.Value)) {
        throw "Refusing to inspect secret-backed setting '$Name'."
    }

    $valueProperty = $entry.PSObject.Properties['value']
    if ($null -eq $valueProperty) {
        return $null
    }
    return [string]$valueProperty.Value
}

function Assert-EnvironmentValue {
    param(
        [Parameter(Mandatory = $true)][object]$ContainerApp,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $actual = Get-EnvironmentValue -ContainerApp $ContainerApp -Name $Name
    if (-not [string]::Equals(
        $actual,
        $Expected,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Container App '$($ContainerApp.name)' setting '$Name' does not match the required canary boundary."
    }
}

function Get-ManagerApplicationEnvironmentEntries {
    param([Parameter(Mandatory = $true)][object]$ContainerApp)

    $container = Get-PrimaryContainer -ContainerApp $ContainerApp
    return @($container.env | Where-Object {
        $_.name.StartsWith(
            $ManagerApplicationSettingPrefix,
            [System.StringComparison]::OrdinalIgnoreCase)
    })
}

function ConvertTo-NormalizedManagerApplicationIds {
    param(
        [AllowEmptyCollection()][string[]]$Values = @(),
        [switch]$RequireNonEmpty,
        [string]$InputLabel = 'manager application ID input'
    )

    if ($Values.Count -gt 10) {
        throw "The $InputLabel must contain no more than ten IDs."
    }

    $normalized = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $Values) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($value, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
            throw "Every $InputLabel value must be a valid non-empty GUID."
        }

        $normalizedValue = $parsed.ToString('D')
        if (-not $seen.Add($normalizedValue)) {
            throw "The $InputLabel must not contain duplicate manager application IDs."
        }
        $normalized.Add($normalizedValue)
    }

    if ($RequireNonEmpty -and $normalized.Count -eq 0) {
        throw 'At least one independently verified manager application ID is required for activation.'
    }

    return @($normalized | Sort-Object)
}

function Get-ValidatedManagerApplicationIds {
    param([Parameter(Mandatory = $true)][object]$ContainerApp)

    $entries = @(Get-ManagerApplicationEnvironmentEntries -ContainerApp $ContainerApp)
    if ($entries.Count -gt 10) {
        throw "Container App '$($ContainerApp.name)' contains more than ten manager application IDs."
    }

    $values = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $expectedName = "$ManagerApplicationSettingPrefix$index"
        $matchingEntries = @($entries | Where-Object {
            [string]::Equals(
                [string]$_.name,
                $expectedName,
                [System.StringComparison]::Ordinal)
        })
        if ($matchingEntries.Count -ne 1) {
            throw "Container App '$($ContainerApp.name)' manager application settings are not an exact contiguous indexed collection."
        }

        $entry = $matchingEntries[0]
        $secretReferenceProperty = $entry.PSObject.Properties['secretRef']
        $valueProperty = $entry.PSObject.Properties['value']
        if (($null -ne $secretReferenceProperty -and
             -not [string]::IsNullOrWhiteSpace([string]$secretReferenceProperty.Value)) -or
            $null -eq $valueProperty -or
            [string]::IsNullOrWhiteSpace([string]$valueProperty.Value)) {
            throw "Container App '$($ContainerApp.name)' contains an empty or secret-backed manager application ID."
        }
        $values.Add([string]$valueProperty.Value)
    }

    return @(ConvertTo-NormalizedManagerApplicationIds `
        -Values $values.ToArray() `
        -InputLabel "deployed manager application ID collection on '$($ContainerApp.name)'")
}

function Assert-ManagerApplications {
    param(
        [Parameter(Mandatory = $true)][object]$ContainerApp,
        [AllowEmptyCollection()][string[]]$ExpectedIds = @(),
        [switch]$RequireExpectedMatch
    )

    $actual = @(Get-ValidatedManagerApplicationIds -ContainerApp $ContainerApp)

    if ($RequireExpectedMatch) {
        $expected = @(ConvertTo-NormalizedManagerApplicationIds `
            -Values $ExpectedIds `
            -RequireNonEmpty `
            -InputLabel 'reviewed manager application ID input')
        if ([string]::Join('|', $expected) -ine [string]::Join('|', $actual)) {
            throw "Container App '$($ContainerApp.name)' manager application IDs do not match the reviewed canary input."
        }
    }
}

function Assert-DigestPinnedImageInput {
    param(
        [Parameter(Mandatory = $true)][string]$Image,
        [Parameter(Mandatory = $true)][ValidateSet('gateway-api', 'gateway-worker')]
        [string]$Repository
    )

    $escapedRepository = [regex]::Escape($Repository)
    $pattern = "^[a-z0-9][a-z0-9.-]*\.azurecr\.io/$escapedRepository@sha256:[a-f0-9]{64}$"
    if (-not [regex]::IsMatch(
        $Image,
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        throw "$Repository must be a full Azure Container Registry reference pinned by sha256 digest."
    }
}

function Assert-ContainerImage {
    param(
        [Parameter(Mandatory = $true)][object]$ContainerApp,
        [Parameter(Mandatory = $true)][string]$ExpectedImage
    )

    $container = Get-PrimaryContainer -ContainerApp $ContainerApp
    if (-not [string]::Equals(
        [string]$container.image,
        $ExpectedImage,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Container App '$($ContainerApp.name)' does not use the reviewed image digest."
    }
}

function Assert-Subscription {
    $account = Invoke-AzJson -Arguments @(
        'account', 'show'
    ) -FailureMessage 'Unable to read the current Azure CLI account.'

    $currentSubscriptionId = [guid]::Empty
    if (-not [guid]::TryParse([string]$account.id, [ref]$currentSubscriptionId) -or
        $currentSubscriptionId -ne $ExpectedSubscriptionId) {
        throw 'The current Azure CLI subscription does not match ExpectedSubscriptionId.'
    }
    if (-not [bool]$account.isDefault) {
        throw 'The expected subscription is not the current Azure CLI default context.'
    }
    $tenantId = [guid]::Empty
    if (-not [guid]::TryParse([string]$account.tenantId, [ref]$tenantId) -or
        $tenantId -eq [guid]::Empty) {
        throw 'The current Azure CLI account does not expose a valid tenant ID.'
    }
    $script:CurrentTenantId = $tenantId

    $null = Invoke-AzJson -Arguments @(
        'group', 'show',
        '--name', $ResourceGroup
    ) -FailureMessage "Required development resource group '$ResourceGroup' could not be read."
    Write-Pass 'Azure CLI subscription and fixed development resource group match.'
}

function Assert-ContainerAppTopology {
    param(
        [Parameter(Mandatory = $true)][object]$ContainerApp,
        [Parameter(Mandatory = $true)][string]$ExpectedEnvironmentId
    )

    if (-not [string]::Equals(
        [string]$ContainerApp.properties.environmentId,
        $ExpectedEnvironmentId,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Container App '$($ContainerApp.name)' is outside the approved VNet environment."
    }
    if (-not [string]::Equals(
        [string]$ContainerApp.properties.configuration.activeRevisionsMode,
        'Single',
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Container App '$($ContainerApp.name)' must use Single revision mode for this canary."
    }
    if (-not [string]::Equals(
        [string]$ContainerApp.properties.provisioningState,
        'Succeeded',
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Container App '$($ContainerApp.name)' has not reached Succeeded provisioning state."
    }

    $null = Get-PrimaryContainer -ContainerApp $ContainerApp
}

function Get-HistoricalWorkerSignature {
    param([Parameter(Mandatory = $true)][object]$Worker)

    $container = Get-PrimaryContainer -ContainerApp $Worker
    $signature = [ordered]@{
        Id = [string]$Worker.id
        EnvironmentId = [string]$Worker.properties.environmentId
        PrincipalId = [string]$Worker.identity.principalId
        Revision = [string]$Worker.properties.latestRevisionName
        Image = [string]$container.image
        ServiceBusQueue = Get-EnvironmentValue `
            -ContainerApp $Worker `
            -Name 'ServiceBus__QueueName'
        ProvisioningQueue = Get-EnvironmentValue `
            -ContainerApp $Worker `
            -Name 'ProvisioningWorker__QueueName' `
            -AllowMissing
        MinReplicas = [int]$Worker.properties.template.scale.minReplicas
        MaxReplicas = [int]$Worker.properties.template.scale.maxReplicas
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(
        ($signature | ConvertTo-Json -Compress -Depth 10))
    return ConvertTo-HexString -InputObject (
        [System.Security.Cryptography.SHA256]::HashData($bytes))
}

function ConvertTo-HexString {
    param([Parameter(Mandatory = $true)][byte[]]$InputObject)
    return [System.Convert]::ToHexString($InputObject)
}

function Assert-HistoricalWorkerIsolation {
    param([Parameter(Mandatory = $true)][object]$Worker)

    Assert-EnvironmentValue `
        -ContainerApp $Worker `
        -Name 'ServiceBus__QueueName' `
        -Expected $HistoricalQueueName
    $provisioningQueue = Get-EnvironmentValue `
        -ContainerApp $Worker `
        -Name 'ProvisioningWorker__QueueName' `
        -AllowMissing
    if (-not [string]::IsNullOrWhiteSpace($provisioningQueue) -and
        -not [string]::Equals(
            $provisioningQueue,
            $HistoricalQueueName,
            [System.StringComparison]::Ordinal)) {
        throw 'The historical worker is configured to receive outside its legacy queue.'
    }
}

function Assert-HistoricalWorkerUnchanged {
    if ([string]::IsNullOrWhiteSpace([string]$HistoricalWorkerSignature)) {
        return
    }

    $current = Get-ContainerApp -Name $HistoricalWorkerContainerAppName
    Assert-HistoricalWorkerIsolation -Worker $current
    $currentSignature = Get-HistoricalWorkerSignature -Worker $current
    if (-not [string]::Equals(
        $currentSignature,
        $HistoricalWorkerSignature,
        [System.StringComparison]::Ordinal)) {
        throw 'The historical worker changed during the scoped canary action.'
    }
    Write-Pass 'The historical worker remains unchanged on its legacy queue.'
}

function Get-DeploymentResources {
    $approvedEnvironment = Invoke-AzJson -Arguments @(
        'containerapp', 'env', 'show',
        '--name', $ContainerAppsEnvironmentName,
        '--resource-group', $ResourceGroup
    ) -FailureMessage 'The approved VNet-integrated Container Apps environment could not be read.'
    if ([string]::IsNullOrWhiteSpace(
        [string]$approvedEnvironment.properties.vnetConfiguration.infrastructureSubnetId)) {
        throw 'The approved Container Apps environment is not VNet integrated.'
    }

    $api = Get-ContainerApp -Name $ApiContainerAppName
    $worker = Get-ContainerApp -Name $WorkerContainerAppName
    $historical = Get-ContainerApp -Name $HistoricalWorkerContainerAppName

    Assert-ContainerAppTopology -ContainerApp $api -ExpectedEnvironmentId $approvedEnvironment.id
    Assert-ContainerAppTopology -ContainerApp $worker -ExpectedEnvironmentId $approvedEnvironment.id
    Assert-HistoricalWorkerIsolation -Worker $historical

    $principalIds = @(
        [string]$api.identity.principalId,
        [string]$worker.identity.principalId,
        [string]$historical.identity.principalId
    )
    if ($principalIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }) {
        throw 'Every scoped Container App must have a system-assigned managed identity.'
    }
    if (@($principalIds | Sort-Object -Unique).Count -ne 3) {
        throw 'The API, target worker, and historical worker must have distinct managed identities.'
    }

    $script:HistoricalWorkerSignature = Get-HistoricalWorkerSignature -Worker $historical
    $script:ResourcesValidated = $true
    Write-Pass 'Only the fixed development API and new VNet worker are eligible mutation targets.'

    return [pscustomobject]@{
        Api = $api
        Worker = $worker
        HistoricalWorker = $historical
        Environment = $approvedEnvironment
    }
}

function Get-QueueRuntime {
    return Invoke-AzJson -Arguments @(
        'servicebus', 'queue', 'show',
        '--resource-group', $ResourceGroup,
        '--namespace-name', $ServiceBusNamespaceName,
        '--name', $WorkflowV3QueueName
    ) -FailureMessage 'The workflow-v3 Service Bus queue could not be read.'
}

function Get-RetainedWorkflowV2QueueRuntime {
    return Invoke-AzJson -Arguments @(
        'servicebus', 'queue', 'show',
        '--resource-group', $ResourceGroup,
        '--namespace-name', $ServiceBusNamespaceName,
        '--name', $WorkflowV2QueueName
    ) -FailureMessage 'The retained workflow-v2 Service Bus queue could not be read.'
}

function Assert-QueueBaseline {
    $queue = Get-QueueRuntime
    if (-not [string]::Equals(
        [string]$queue.status,
        'Active',
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The workflow-v3 Service Bus queue is not Active.'
    }

    $active = [long]$queue.countDetails.activeMessageCount
    $scheduled = [long]$queue.countDetails.scheduledMessageCount
    $deadLettered = [long]$queue.countDetails.deadLetterMessageCount
    if ($active -ne 0 -or $scheduled -ne 0) {
        throw 'The workflow-v3 queue must have zero active and scheduled messages before activation or admission.'
    }
    if ($deadLettered -ne $ExpectedWorkflowV3DeadLetterCount) {
        throw "The workflow-v3 dead-letter count must exactly match the clean baseline of $ExpectedWorkflowV3DeadLetterCount."
    }
    Write-Pass 'The workflow-v3 queue is Active and empty before activation or admission.'
    return $queue
}

function Assert-RetainedWorkflowV2QueueBaseline {
    $queue = Get-RetainedWorkflowV2QueueRuntime
    if (-not [string]::Equals(
        [string]$queue.status,
        'Active',
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The retained workflow-v2 Service Bus queue is not Active.'
    }

    $active = [long]$queue.countDetails.activeMessageCount
    $scheduled = [long]$queue.countDetails.scheduledMessageCount
    $deadLettered = [long]$queue.countDetails.deadLetterMessageCount
    if ($active -ne 0 -or $scheduled -ne 0 -or
        $deadLettered -ne $ExpectedWorkflowV2DeadLetterCount) {
        throw "The retained workflow-v2 queue must remain 0 active, 0 scheduled, and exactly $ExpectedWorkflowV2DeadLetterCount dead-lettered messages."
    }

    Write-Pass "The retained workflow-v2 queue remains evidence-only at 0 active, 0 scheduled, and DLQ $ExpectedWorkflowV2DeadLetterCount."
    return $queue
}

function Get-RoleDefinitionGuid {
    param([Parameter(Mandatory = $true)][string]$RoleDefinitionId)
    return $RoleDefinitionId.Split('/')[-1]
}

function Assert-ExactQueueDataRoles {
    param(
        [Parameter(Mandatory = $true)][object]$Queue,
        [Parameter(Mandatory = $true)][object]$Api,
        [Parameter(Mandatory = $true)][object]$Worker
    )

    $assignments = Invoke-AzJson -Arguments @(
        'role', 'assignment', 'list',
        '--scope', [string]$Queue.id,
        '--include-inherited'
    ) -FailureMessage 'Unable to inspect Service Bus queue role assignments.'

    $apiPrincipalId = [string]$Api.identity.principalId
    $workerPrincipalId = [string]$Worker.identity.principalId
    $queueId = [string]$Queue.id
    $dataPlaneRoleIds = @(
        $ServiceBusDataSenderRoleId,
        $ServiceBusDataReceiverRoleId,
        $ServiceBusDataOwnerRoleId
    )
    $effectiveDataPlaneAssignments = @($assignments | Where-Object {
        $dataPlaneRoleIds -contains
            (Get-RoleDefinitionGuid -RoleDefinitionId ([string]$_.roleDefinitionId))
    })
    $approvedApiSenderAssignments = @($effectiveDataPlaneAssignments | Where-Object {
        (Get-RoleDefinitionGuid -RoleDefinitionId ([string]$_.roleDefinitionId)) -eq
            $ServiceBusDataSenderRoleId -and
        [string]::Equals(
            [string]$_.principalId,
            $apiPrincipalId,
            [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals(
            [string]$_.scope,
            $queueId,
            [System.StringComparison]::OrdinalIgnoreCase)
    })
    $approvedWorkerReceiverAssignments = @($effectiveDataPlaneAssignments | Where-Object {
        (Get-RoleDefinitionGuid -RoleDefinitionId ([string]$_.roleDefinitionId)) -eq
            $ServiceBusDataReceiverRoleId -and
        [string]::Equals(
            [string]$_.principalId,
            $workerPrincipalId,
            [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals(
            [string]$_.scope,
            $queueId,
            [System.StringComparison]::OrdinalIgnoreCase)
    })

    if ($approvedApiSenderAssignments.Count -ne 1 -or
        $approvedWorkerReceiverAssignments.Count -ne 1 -or
        $effectiveDataPlaneAssignments.Count -ne 2) {
        throw 'Workflow-v3 queue exclusivity requires exactly one queue-scoped API Sender and one queue-scoped current-worker Receiver, with no inherited, Data Owner, reversed, or third-party data-plane assignment.'
    }

    Write-Pass 'Every effective workflow-v3 queue data-plane assignment is exclusive: queue-scoped API Sender and current-worker Receiver only.'
}

function Read-Evidence {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label evidence file is required."
    }
    $rawJson = Get-Content -Raw -LiteralPath $Path
    return ConvertFrom-EvidenceJson -RawJson $rawJson -Label $Label
}

function ConvertFrom-EvidenceJson {
    param(
        [Parameter(Mandatory = $true)][string]$RawJson,
        [Parameter(Mandatory = $true)][string]$Label
    )

    try {
        return $RawJson | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "$Label evidence is not valid JSON."
    }
}

function Get-RequiredRawJsonString {
    param(
        [Parameter(Mandatory = $true)][string]$RawJson,
        [Parameter(Mandatory = $true)][string[]]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($RawJson)
        $element = $document.RootElement
        foreach ($segment in $Path) {
            $element = $element.GetProperty($segment)
        }
        if ($element.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
            throw "$Label must be a JSON string."
        }

        $value = $element.GetString()
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "$Label must not be empty."
        }
        return $value
    }
    catch {
        throw "Reviewed canary failure evidence is missing or invalid $Label."
    }
    finally {
        if ($null -ne $document) {
            $document.Dispose()
        }
    }
}

function Get-RequiredEvidenceValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "Reviewed canary failure evidence is missing $Label."
    }
    return $property.Value
}

function Get-RequiredEvidenceBoolean {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $value = Get-RequiredEvidenceValue -Object $Object -Name $Name -Label $Label
    if ($value -isnot [bool]) {
        throw "Reviewed canary failure evidence field $Label must be a JSON Boolean."
    }
    return [bool]$value
}

function Assert-ReviewedCanaryFailureEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Worker,
        [Parameter(Mandatory = $true)][object]$Queue
    )

    $paths = @($ReviewedCanaryFailureEvidencePaths | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    if ($ExpectedWorkflowV2DeadLetterCount -eq 0) {
        if ($paths.Count -ne 0) {
            throw 'Reviewed canary failure evidence may be supplied only with a non-zero expected workflow-v2 DLQ baseline.'
        }
        Write-Pass 'Strict workflow-v2 DLQ baseline remains zero; no failure-evidence exception is active.'
        return
    }

    if ($paths.Count -ne $ExpectedWorkflowV2DeadLetterCount) {
        throw 'Exactly one reviewed canary failure evidence file is required for every retained workflow-v2 DLQ message.'
    }

    $workerPrincipalId = [guid]::Empty
    if (-not [guid]::TryParse(
            [string]$Worker.identity.principalId,
            [ref]$workerPrincipalId) -or
        $workerPrincipalId -eq [guid]::Empty) {
        throw 'The reviewed worker does not expose a valid managed-identity principal ID.'
    }
    if ($CurrentTenantId -eq [guid]::Empty) {
        throw 'The reviewed Azure tenant ID is unavailable.'
    }

    if ([long]$Queue.countDetails.activeMessageCount -ne 0 -or
        [long]$Queue.countDetails.scheduledMessageCount -ne 0 -or
        [long]$Queue.countDetails.deadLetterMessageCount -ne
            $ExpectedWorkflowV2DeadLetterCount) {
        throw 'The live workflow-v2 queue does not match the reviewed failure-evidence baseline.'
    }

    $operationIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $messageIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $checkpointCaptureTimes = @{}
    $reconciledFederationExceptionCount = 0
    $retainedRegistryAmbiguityExceptionCount = 0
    $knownRegistryAmbiguityRegistrationId =
        [guid]'b23cb073-912e-4efa-8a01-88a46b2af5fb'
    $knownRegistryAmbiguityOperationId =
        [guid]'8ece1c62-df73-4185-8f73-7b27db080414'
    $knownRegistryAmbiguityMessageId =
        [guid]'e45814eb-276e-4c06-94c0-437c95bba083'
    $knownRegistryAmbiguityBlueprintId =
        [guid]'76d144d9-7b6c-4448-b43f-76c1ae12cde5'
    $knownRegistryAmbiguityChildId =
        [guid]'8e4859bd-477c-4133-adb1-9030ec13bf5c'
    $knownRegistryAmbiguityExternalAgentId =
        'agent-f3e843a9784f4700a6cb860c80286d67'
    $knownRegistryAmbiguityEvidenceSha256 =
        '591b78d783b7042c3af9addd5b48d1b847bff958203e59aa26d62496af772b71'
    $knownRegistryAmbiguityDeadLetterCheckpoint = 3L
    $canonicalGraphRequestPattern =
        '\A(?:GET|POST|PATCH|PUT|DELETE) https://graph\.microsoft\.com/(?:v1\.0|beta)/[A-Za-z0-9._~!$&()*+,;=:@%/?-]+\z'

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'Every reviewed canary failure evidence path must identify a file.'
        }
        $rawEvidence = Get-Content -Raw -LiteralPath $path
        if ($rawEvidence -match 'a365gw_v1_[0-9a-fA-F]{32}\.[A-Za-z0-9_-]{43}') {
            throw 'Reviewed canary failure evidence must never contain a clear Gateway key.'
        }
        $failure = ConvertFrom-EvidenceJson `
            -RawJson $rawEvidence `
            -Label 'Reviewed canary failure'

        if ([int](Get-RequiredEvidenceValue -Object $failure -Name 'schemaVersion' -Label 'schemaVersion') -ne 1 -or
            -not [string]::Equals(
                [string](Get-RequiredEvidenceValue -Object $failure -Name 'environment' -Label 'environment'),
                $EnvironmentName,
                [System.StringComparison]::Ordinal)) {
            throw 'Reviewed canary failure evidence has an unsupported schema or environment.'
        }

        $capturedAt = [datetimeoffset]::MinValue
        $capturedAtValue = Get-RequiredRawJsonString `
            -RawJson $rawEvidence `
            -Path @('capturedAtUtc') `
            -Label 'capturedAtUtc'
        if (-not $capturedAtValue.EndsWith('Z', [System.StringComparison]::Ordinal) -or
            -not [datetimeoffset]::TryParse(
            $capturedAtValue,
            [ref]$capturedAt) -or
            $capturedAt.ToUniversalTime() -gt [datetimeoffset]::UtcNow.AddMinutes(5)) {
            throw 'Reviewed canary failure evidence has an invalid or future-dated capture timestamp.'
        }

        $canary = Get-RequiredEvidenceValue -Object $failure -Name 'canary' -Label 'canary'
        $registrationId = [guid]::Empty
        $operationId = [guid]::Empty
        $messageId = [guid]::Empty
        $selectedBlueprintObjectId = [guid]::Empty
        $registrationIdValue = [string](Get-RequiredEvidenceValue `
            -Object $canary -Name 'agentRegistrationId' -Label 'canary.agentRegistrationId')
        $operationIdValue = [string](Get-RequiredEvidenceValue `
            -Object $canary -Name 'operationId' -Label 'canary.operationId')
        $messageIdValue = [string](Get-RequiredEvidenceValue `
            -Object $canary -Name 'serviceBusMessageId' -Label 'canary.serviceBusMessageId')
        $selectedBlueprintObjectIdValue = [string](Get-RequiredEvidenceValue `
            -Object $canary -Name 'selectedBlueprintObjectId' -Label 'canary.selectedBlueprintObjectId')
        if (-not [guid]::TryParse($registrationIdValue,
            [ref]$registrationId) -or
            $registrationId -eq [guid]::Empty -or
            -not [string]::Equals($registrationIdValue, $registrationId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [guid]::TryParse($operationIdValue,
            [ref]$operationId) -or
            $operationId -eq [guid]::Empty -or
            -not [string]::Equals($operationIdValue, $operationId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [guid]::TryParse($messageIdValue, [ref]$messageId) -or
            $messageId -eq [guid]::Empty -or
            -not [string]::Equals($messageIdValue, $messageId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [guid]::TryParse($selectedBlueprintObjectIdValue,
            [ref]$selectedBlueprintObjectId) -or
            $selectedBlueprintObjectId -eq [guid]::Empty -or
            -not [string]::Equals($selectedBlueprintObjectIdValue, $selectedBlueprintObjectId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase) -or
            -not $operationIds.Add($operationId.ToString('D')) -or
            -not $messageIds.Add($messageId.ToString('D'))) {
            throw 'Reviewed canary failure evidence must identify valid registration, operation, Service Bus message, and selected-blueprint GUIDs with unique operation/message IDs.'
        }

        $outcome = Get-RequiredEvidenceValue -Object $failure -Name 'outcome' -Label 'outcome'
        $terminalFailureStates = @('Failed', 'RequiresManualIntervention')
        $operationStatus = [string](Get-RequiredEvidenceValue `
            -Object $outcome -Name 'operationStatus' -Label 'outcome.operationStatus')
        $agentStatus = [string](Get-RequiredEvidenceValue `
            -Object $outcome -Name 'agentStatus' -Label 'outcome.agentStatus')
        $failedStep = [string](Get-RequiredEvidenceValue `
            -Object $outcome -Name 'failedStep' -Label 'outcome.failedStep')
        $errorCode = [string](Get-RequiredEvidenceValue `
            -Object $outcome -Name 'errorCode' -Label 'outcome.errorCode')
        if ($terminalFailureStates -notcontains $operationStatus -or
            $terminalFailureStates -notcontains $agentStatus -or
            [string]::IsNullOrWhiteSpace($failedStep) -or
            [string]::IsNullOrWhiteSpace($errorCode)) {
            throw 'Reviewed canary failure evidence must describe a terminal failed operation and agent.'
        }

        $resourcesCreated = Get-RequiredEvidenceBoolean `
            -Object $outcome `
            -Name 'microsoftResourcesCreated' `
            -Label 'outcome.microsoftResourcesCreated'
        $gatewayCredentialRevoked = Get-RequiredEvidenceBoolean `
            -Object $outcome `
            -Name 'gatewayCredentialRevoked' `
            -Label 'outcome.gatewayCredentialRevoked'

        $evidence = Get-RequiredEvidenceValue -Object $failure -Name 'evidence' -Label 'evidence'
        $terminalMessageState = [string](Get-RequiredEvidenceValue `
            -Object $evidence -Name 'terminalMessageState' -Label 'evidence.terminalMessageState')
        if (-not [string]::Equals(
            $terminalMessageState,
            'DeadLettered',
            [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Reviewed canary failure evidence must prove that the identified message is terminally dead-lettered.'
        }

        $keyIncluded = Get-RequiredEvidenceBoolean `
            -Object $evidence `
            -Name 'oneTimeGatewayApiKeyIncluded' `
            -Label 'evidence.oneTimeGatewayApiKeyIncluded'
        if ($keyIncluded) {
            throw 'Reviewed canary failure evidence must explicitly exclude the one-time Gateway key.'
        }

        if (-not (Get-RequiredEvidenceBoolean -Object $evidence -Name 'apiAdmissionClosed' -Label 'evidence.apiAdmissionClosed') -or
            (Get-RequiredEvidenceBoolean -Object $evidence -Name 'workerProcessingEnabled' -Label 'evidence.workerProcessingEnabled') -or
            (Get-RequiredEvidenceBoolean -Object $evidence -Name 'workerProvisioningExecutionEnabled' -Label 'evidence.workerProvisioningExecutionEnabled') -or
            (Get-RequiredEvidenceBoolean -Object $evidence -Name 'workerDirectRegistryPreviewEnabled' -Label 'evidence.workerDirectRegistryPreviewEnabled') -or
            (Get-RequiredEvidenceBoolean -Object $evidence -Name 'historicalQueueOrDeadLetterTouched' -Label 'evidence.historicalQueueOrDeadLetterTouched')) {
            throw 'Reviewed canary failure evidence must prove fail-closed API/worker gates and no historical queue access.'
        }

        $isRetainedRegistryAmbiguity =
            [bool]$resourcesCreated -and
            [string]::Equals(
                $failedStep,
                'RegisterAgent',
                [System.StringComparison]::Ordinal) -and
            [string]::Equals(
                $errorCode,
                'PROVISIONING_AMBIGUOUS_RESULT',
                [System.StringComparison]::Ordinal)
        $observedRequests = @()
        if (-not $isRetainedRegistryAmbiguity) {
            $observedRequests = @(Get-RequiredEvidenceValue `
                -Object $evidence `
                -Name 'workerLogMutationMethodsBeforeFailure' `
                -Label 'evidence.workerLogMutationMethodsBeforeFailure')
            if ($observedRequests.Count -eq 0) {
                throw 'Reviewed canary failure evidence must include the observed Microsoft request sequence.'
            }
            foreach ($request in $observedRequests) {
                if ($request -isnot [string] -or
                    [string]$request -cnotmatch $canonicalGraphRequestPattern) {
                    throw 'Every reviewed Microsoft request must be one canonical method plus an absolute Microsoft Graph v1.0/beta URI without control characters.'
                }
            }
        }
        $mutations = @($observedRequests | Where-Object {
            [string]$_ -cnotmatch '\AGET https://graph\.microsoft\.com/'
        })

        if (-not [bool]$resourcesCreated) {
            if ($mutations.Count -ne 0) {
                throw 'A no-resource failure may contain only read-only Microsoft requests.'
            }
        }
        elseif ($isRetainedRegistryAmbiguity) {
            $retainedRegistryAmbiguityExceptionCount++
            if ($retainedRegistryAmbiguityExceptionCount -gt 1) {
                throw 'At most one retained failure may use the exact historical Registry ambiguity exception.'
            }

            $normalizedEvidence = $rawEvidence.Replace("`r`n", "`n")
            $normalizedEvidenceBytes =
                [System.Text.Encoding]::UTF8.GetBytes($normalizedEvidence)
            $normalizedEvidenceSha256 = ConvertTo-HexString -InputObject (
                [System.Security.Cryptography.SHA256]::HashData($normalizedEvidenceBytes))
            if (-not [string]::Equals(
                    $normalizedEvidenceSha256,
                    $knownRegistryAmbiguityEvidenceSha256,
                    [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'The historical Registry ambiguity exception is restricted to the source-pinned normalized evidence artifact.'
            }

            $selectedBlueprintClientId = [guid]::Empty
            $createdAgentIdentityObjectId = [guid]::Empty
            $createdAgentIdentityClientId = [guid]::Empty
            $selectedBlueprintClientIdValue = [string](Get-RequiredEvidenceValue `
                -Object $canary `
                -Name 'selectedBlueprintClientId' `
                -Label 'canary.selectedBlueprintClientId')
            $createdAgentIdentityObjectIdValue = [string](Get-RequiredEvidenceValue `
                -Object $outcome `
                -Name 'createdAgentIdentityObjectId' `
                -Label 'outcome.createdAgentIdentityObjectId')
            $createdAgentIdentityClientIdValue = [string](Get-RequiredEvidenceValue `
                -Object $outcome `
                -Name 'createdAgentIdentityClientId' `
                -Label 'outcome.createdAgentIdentityClientId')
            if ($registrationId -ne $knownRegistryAmbiguityRegistrationId -or
                $operationId -ne $knownRegistryAmbiguityOperationId -or
                $messageId -ne $knownRegistryAmbiguityMessageId -or
                $selectedBlueprintObjectId -ne $knownRegistryAmbiguityBlueprintId -or
                -not [string]::Equals(
                    [string](Get-RequiredEvidenceValue -Object $canary -Name 'externalAgentId' -Label 'canary.externalAgentId'),
                    $knownRegistryAmbiguityExternalAgentId,
                    [System.StringComparison]::Ordinal) -or
                -not [guid]::TryParse(
                    $selectedBlueprintClientIdValue,
                    [ref]$selectedBlueprintClientId) -or
                -not [string]::Equals($selectedBlueprintClientIdValue, $selectedBlueprintClientId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase) -or
                $selectedBlueprintClientId -ne $knownRegistryAmbiguityBlueprintId -or
                -not [guid]::TryParse(
                    $createdAgentIdentityObjectIdValue,
                    [ref]$createdAgentIdentityObjectId) -or
                -not [string]::Equals($createdAgentIdentityObjectIdValue, $createdAgentIdentityObjectId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase) -or
                $createdAgentIdentityObjectId -ne $knownRegistryAmbiguityChildId -or
                -not [guid]::TryParse(
                    $createdAgentIdentityClientIdValue,
                    [ref]$createdAgentIdentityClientId) -or
                -not [string]::Equals($createdAgentIdentityClientIdValue, $createdAgentIdentityClientId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase) -or
                $createdAgentIdentityClientId -ne $knownRegistryAmbiguityChildId) {
                throw 'Registry ambiguity evidence does not identify the exact retained historical registration, operation, message, blueprint, and child Agent ID.'
            }

            if (-not [string]::Equals($operationStatus, 'RequiresManualIntervention', [System.StringComparison]::Ordinal) -or
                -not [string]::Equals($agentStatus, 'RequiresManualIntervention', [System.StringComparison]::Ordinal) -or
                [long](Get-RequiredEvidenceValue -Object $outcome -Name 'progressPercent' -Label 'outcome.progressPercent') -ne 71 -or
                -not (Get-RequiredEvidenceBoolean -Object $outcome -Name 'agent365ObservabilityRoleAssigned' -Label 'outcome.agent365ObservabilityRoleAssigned') -or
                -not [string]::Equals(
                    [string](Get-RequiredEvidenceValue -Object $outcome -Name 'agent365RegistrationOutcome' -Label 'outcome.agent365RegistrationOutcome'),
                    'Unknown',
                    [System.StringComparison]::Ordinal) -or
                (Get-RequiredEvidenceBoolean -Object $outcome -Name 'agent365RegistrationIdAvailable' -Label 'outcome.agent365RegistrationIdAvailable') -or
                $gatewayCredentialRevoked) {
                throw 'Registry ambiguity evidence must preserve the exact 71-percent manual outcome, assigned access, unknown Registry result, absent Registry ID, and unrevoked one-time Gateway credential state.'
            }

            $completedStages = @(Get-RequiredEvidenceValue `
                -Object $evidence -Name 'completedStages' -Label 'evidence.completedStages')
            $expectedCompletedStages = @(
                'ResolveBlueprint',
                'EnsureBlueprintPrincipal',
                'ConfigureGatewayFederation',
                'CreateAgentIdentity',
                'AssignAgent365Access'
            )
            if ($completedStages.Count -ne $expectedCompletedStages.Count) {
                throw 'Registry ambiguity evidence must preserve the exact completed workflow prefix.'
            }
            for ($stageIndex = 0; $stageIndex -lt $expectedCompletedStages.Count; $stageIndex++) {
                if (-not [string]::Equals(
                        [string]$completedStages[$stageIndex],
                        [string]$expectedCompletedStages[$stageIndex],
                        [System.StringComparison]::Ordinal)) {
                    throw 'Registry ambiguity evidence must preserve the exact completed workflow prefix.'
                }
            }
            $pendingStages = @(Get-RequiredEvidenceValue `
                -Object $evidence -Name 'pendingStages' -Label 'evidence.pendingStages')
            if ($pendingStages.Count -ne 1 -or
                -not [string]::Equals(
                    [string]$pendingStages[0],
                    'VerifyAgent365Connection',
                    [System.StringComparison]::Ordinal) -or
                [long](Get-RequiredEvidenceValue -Object $evidence -Name 'federatedIdentityCredentialPostCount' -Label 'evidence.federatedIdentityCredentialPostCount') -ne 0 -or
                -not (Get-RequiredEvidenceBoolean -Object $evidence -Name 'existingFederatedIdentityCredentialReusedByGet' -Label 'evidence.existingFederatedIdentityCredentialReusedByGet') -or
                [long](Get-RequiredEvidenceValue -Object $evidence -Name 'agentIdentityCreatePostCount' -Label 'evidence.agentIdentityCreatePostCount') -ne 1 -or
                [long](Get-RequiredEvidenceValue -Object $evidence -Name 'agentIdentityCreateHttpStatus' -Label 'evidence.agentIdentityCreateHttpStatus') -ne 201 -or
                -not (Get-RequiredEvidenceBoolean -Object $evidence -Name 'agentIdentityReadBackVerified' -Label 'evidence.agentIdentityReadBackVerified') -or
                [long](Get-RequiredEvidenceValue -Object $evidence -Name 'agent365RoleAssignmentPostCount' -Label 'evidence.agent365RoleAssignmentPostCount') -ne 1 -or
                [long](Get-RequiredEvidenceValue -Object $evidence -Name 'agent365RoleAssignmentHttpStatus' -Label 'evidence.agent365RoleAssignmentHttpStatus') -ne 201 -or
                -not (Get-RequiredEvidenceBoolean -Object $evidence -Name 'agent365RoleAssignmentReadBackVerified' -Label 'evidence.agent365RoleAssignmentReadBackVerified') -or
                [long](Get-RequiredEvidenceValue -Object $evidence -Name 'agentRegistrationPostCount' -Label 'evidence.agentRegistrationPostCount') -ne 1 -or
                [long](Get-RequiredEvidenceValue -Object $evidence -Name 'agentRegistrationPostHttpStatus' -Label 'evidence.agentRegistrationPostHttpStatus') -ne 500 -or
                [long](Get-RequiredEvidenceValue -Object $evidence -Name 'agentRegistrationKnownIdGetCount' -Label 'evidence.agentRegistrationKnownIdGetCount') -ne 0) {
                throw 'Registry ambiguity evidence must prove one child create, one role assignment, one HTTP 500 Registry POST, no Registry retry/GET, and no pending stage except verification.'
            }

            $historicalQueueEvidence = Get-RequiredEvidenceValue `
                -Object $evidence `
                -Name 'historicalQueueAfterFailClosed' `
                -Label 'evidence.historicalQueueAfterFailClosed'
            $recoveryDecision = Get-RequiredEvidenceValue `
                -Object $failure `
                -Name 'recoveryDecision' `
                -Label 'recoveryDecision'
            if (-not [string]::Equals(
                    [string](Get-RequiredEvidenceValue -Object $historicalQueueEvidence -Name 'queueName' -Label 'evidence.historicalQueueAfterFailClosed.queueName'),
                    $HistoricalQueueName,
                    [System.StringComparison]::Ordinal) -or
                [long](Get-RequiredEvidenceValue -Object $historicalQueueEvidence -Name 'active' -Label 'evidence.historicalQueueAfterFailClosed.active') -ne 0 -or
                [long](Get-RequiredEvidenceValue -Object $historicalQueueEvidence -Name 'scheduled' -Label 'evidence.historicalQueueAfterFailClosed.scheduled') -ne 0 -or
                [long](Get-RequiredEvidenceValue -Object $historicalQueueEvidence -Name 'deadLetter' -Label 'evidence.historicalQueueAfterFailClosed.deadLetter') -ne $ExpectedHistoricalDeadLetterCount -or
                (Get-RequiredEvidenceBoolean -Object $recoveryDecision -Name 'registrationReplayAllowed' -Label 'recoveryDecision.registrationReplayAllowed') -or
                (Get-RequiredEvidenceBoolean -Object $recoveryDecision -Name 'newRegistrationAllowedBeforeReconciliation' -Label 'recoveryDecision.newRegistrationAllowedBeforeReconciliation') -or
                -not [string]::Equals(
                    [string](Get-RequiredEvidenceValue -Object $recoveryDecision -Name 'deadLetterDisposition' -Label 'recoveryDecision.deadLetterDisposition'),
                    'Retain the identified workflow-v2 message without receiving, peeking, settling, replaying, or purging it.',
                    [System.StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string](Get-RequiredEvidenceValue -Object $recoveryDecision -Name 'requiredNextAction' -Label 'recoveryDecision.requiredNextAction'),
                    'Reconcile the exact canary in the tenant Agent 365 inventory or with Microsoft support. If and only if a durable Registry ID is found and all properties match, implement and review a known-ID attachment path before completing stage 7. Do not issue another Registry create call for this registration.',
                    [System.StringComparison]::Ordinal)) {
                throw 'Registry ambiguity evidence must retain both queues and the exact no-replay, no-second-POST recovery decision.'
            }
        }
        else {
            $reconciledFederationExceptionCount++
            if ($reconciledFederationExceptionCount -gt 1) {
                throw 'At most one retained failure may use the reviewed reconciled federation exception.'
            }
            if (-not [string]::Equals(
                    $failedStep,
                    'ConfigureGatewayFederation',
                    [System.StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    $errorCode,
                    'PROVISIONING_AMBIGUOUS_RESULT',
                    [System.StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string](Get-RequiredEvidenceValue -Object $outcome -Name 'createdMicrosoftResourceType' -Label 'outcome.createdMicrosoftResourceType'),
                    'BlueprintFederatedIdentityCredential',
                    [System.StringComparison]::Ordinal) -or
                $selectedBlueprintObjectId -eq [guid]::Empty) {
                throw 'The only permitted reconciled Microsoft mutation is the known Gateway federation create failure.'
            }

            $expectedPost = "POST https://graph.microsoft.com/v1.0/applications/$($selectedBlueprintObjectId.ToString('D'))/federatedIdentityCredentials"
            if ($mutations.Count -ne 1 -or
                -not [string]::Equals(
                    [string]$mutations[0],
                    $expectedPost,
                    [System.StringComparison]::OrdinalIgnoreCase) -or
                [long](Get-RequiredEvidenceValue -Object $evidence -Name 'workerLogMutationCount' -Label 'evidence.workerLogMutationCount') -ne 1 -or
                [long](Get-RequiredEvidenceValue -Object $evidence -Name 'workerLogSubsequentAgentIdentityMutationCount' -Label 'evidence.workerLogSubsequentAgentIdentityMutationCount') -ne 0 -or
                [long](Get-RequiredEvidenceValue -Object $evidence -Name 'workerLogSubsequentRegistryMutationCount' -Label 'evidence.workerLogSubsequentRegistryMutationCount') -ne 0) {
                throw 'Reconciled federation evidence must prove exactly one FIC POST and no later Microsoft mutation.'
            }

            $reconciliation = Get-RequiredEvidenceValue `
                -Object $failure -Name 'reconciliation' -Label 'reconciliation'
            $ficId = [guid]::Empty
            $verifiedAt = [datetimeoffset]::MinValue
            $mutationObservedAt = [datetimeoffset]::MinValue
            $reconciledBlueprintObjectId = [guid]::Empty
            $expectedName = "a365-gateway-$($workerPrincipalId.ToString('N'))"
            $expectedIssuer = "https://login.microsoftonline.com/$($CurrentTenantId.ToString('D'))/v2.0"
            $audiences = @(Get-RequiredEvidenceValue `
                -Object $reconciliation -Name 'audiences' -Label 'reconciliation.audiences')
            $agentIdentityCreated = Get-RequiredEvidenceBoolean `
                -Object $reconciliation `
                -Name 'agentIdentityCreated' `
                -Label 'reconciliation.agentIdentityCreated'
            $agent365RegistrationCreated = Get-RequiredEvidenceBoolean `
                -Object $reconciliation `
                -Name 'agent365RegistrationCreated' `
                -Label 'reconciliation.agent365RegistrationCreated'
            $mutationObservedAtValue = Get-RequiredRawJsonString `
                -RawJson $rawEvidence `
                -Path @('outcome', 'mutationObservedAtUtc') `
                -Label 'outcome.mutationObservedAtUtc'
            $verifiedAtValue = Get-RequiredRawJsonString `
                -RawJson $rawEvidence `
                -Path @('reconciliation', 'readOnlyVerifiedAtUtc') `
                -Label 'reconciliation.readOnlyVerifiedAtUtc'
            $reconciledBlueprintObjectIdValue = [string](Get-RequiredEvidenceValue `
                -Object $reconciliation -Name 'blueprintObjectId' -Label 'reconciliation.blueprintObjectId')
            $ficIdValue = [string](Get-RequiredEvidenceValue `
                -Object $reconciliation -Name 'federatedCredentialId' -Label 'reconciliation.federatedCredentialId')
            if (-not $mutationObservedAtValue.EndsWith('Z', [System.StringComparison]::Ordinal) -or
                -not $verifiedAtValue.EndsWith('Z', [System.StringComparison]::Ordinal) -or
                -not [datetimeoffset]::TryParse(
                    $mutationObservedAtValue,
                    [ref]$mutationObservedAt) -or
                -not [datetimeoffset]::TryParse(
                    $verifiedAtValue,
                    [ref]$verifiedAt) -or
                $mutationObservedAt.ToUniversalTime() -gt $verifiedAt.ToUniversalTime() -or
                $verifiedAt.ToUniversalTime() -gt $capturedAt.ToUniversalTime() -or
                $capturedAt.ToUniversalTime() -gt [datetimeoffset]::UtcNow.AddMinutes(5) -or
                [long](Get-RequiredEvidenceValue -Object $reconciliation -Name 'exactMatchCount' -Label 'reconciliation.exactMatchCount') -ne 1 -or
                -not [guid]::TryParse(
                    $reconciledBlueprintObjectIdValue,
                    [ref]$reconciledBlueprintObjectId) -or
                -not [string]::Equals($reconciledBlueprintObjectIdValue, $reconciledBlueprintObjectId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase) -or
                $reconciledBlueprintObjectId -ne $selectedBlueprintObjectId -or
                -not [guid]::TryParse(
                    $ficIdValue,
                    [ref]$ficId) -or
                $ficId -eq [guid]::Empty -or
                -not [string]::Equals($ficIdValue, $ficId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals(
                    [string](Get-RequiredEvidenceValue -Object $reconciliation -Name 'name' -Label 'reconciliation.name'),
                    $expectedName,
                    [System.StringComparison]::Ordinal) -or
                -not [string]::Equals(
                    [string](Get-RequiredEvidenceValue -Object $reconciliation -Name 'issuer' -Label 'reconciliation.issuer'),
                    $expectedIssuer,
                    [System.StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals(
                    [string](Get-RequiredEvidenceValue -Object $reconciliation -Name 'subject' -Label 'reconciliation.subject'),
                    $workerPrincipalId.ToString('D'),
                    [System.StringComparison]::OrdinalIgnoreCase) -or
                $audiences.Count -ne 1 -or
                -not [string]::Equals(
                    [string]$audiences[0],
                    'api://AzureADTokenExchange',
                    [System.StringComparison]::Ordinal) -or
                $agentIdentityCreated -or
                $agent365RegistrationCreated -or
                -not [string]::Equals(
                    [string](Get-RequiredEvidenceValue -Object $reconciliation -Name 'safeDisposition' -Label 'reconciliation.safeDisposition'),
                    'RetainAndReuseVerifiedFederation',
                    [System.StringComparison]::Ordinal)) {
                throw 'Reconciled federation evidence does not prove one exact reusable Gateway FIC and no later resource.'
            }

            $expectedReadOnlyVerificationRequest =
                "GET https://graph.microsoft.com/v1.0/applications/$($selectedBlueprintObjectId.ToString('D'))/federatedIdentityCredentials/$($ficId.ToString('D'))"
            if (-not [string]::Equals(
                    [string](Get-RequiredEvidenceValue -Object $reconciliation -Name 'readOnlyVerificationRequest' -Label 'reconciliation.readOnlyVerificationRequest'),
                    $expectedReadOnlyVerificationRequest,
                    [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'Reconciled federation evidence is not scoped to the selected blueprint and exact FIC GET route.'
            }

            $liveFic = Invoke-AzJson -Arguments @(
                'rest',
                '--method', 'GET',
                '--uri', $expectedReadOnlyVerificationRequest.Substring(4)
            ) -FailureMessage 'The reconciled Gateway FIC could not be read from the selected blueprint.'
            $liveAudiences = @($liveFic.audiences)
            if (-not [string]::Equals([string]$liveFic.id, $ficId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([string]$liveFic.name, $expectedName, [System.StringComparison]::Ordinal) -or
                -not [string]::Equals([string]$liveFic.issuer, $expectedIssuer, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([string]$liveFic.subject, $workerPrincipalId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase) -or
                $liveAudiences.Count -ne 1 -or
                -not [string]::Equals([string]$liveAudiences[0], 'api://AzureADTokenExchange', [System.StringComparison]::Ordinal)) {
                throw 'The live selected-blueprint FIC no longer matches the reviewed reconciled resource.'
            }
        }

        $queueEvidence = Get-RequiredEvidenceValue `
            -Object $evidence `
            -Name 'workflowV2QueueAfterFailClosed' `
            -Label 'evidence.workflowV2QueueAfterFailClosed'
        $recordedDeadLetterCount = [long](Get-RequiredEvidenceValue `
            -Object $queueEvidence -Name 'deadLetter' -Label 'evidence.workflowV2QueueAfterFailClosed.deadLetter')
        if (-not [string]::Equals(
                [string](Get-RequiredEvidenceValue -Object $queueEvidence -Name 'queueName' -Label 'evidence.workflowV2QueueAfterFailClosed.queueName'),
                $WorkflowV2QueueName,
                [System.StringComparison]::Ordinal) -or
            [long](Get-RequiredEvidenceValue -Object $queueEvidence -Name 'active' -Label 'evidence.workflowV2QueueAfterFailClosed.active') -ne 0 -or
            [long](Get-RequiredEvidenceValue -Object $queueEvidence -Name 'scheduled' -Label 'evidence.workflowV2QueueAfterFailClosed.scheduled') -ne 0 -or
            $recordedDeadLetterCount -lt 1 -or
            $recordedDeadLetterCount -gt $ExpectedWorkflowV2DeadLetterCount) {
            throw 'Reviewed canary failure evidence does not match the fixed workflow-v2 queue history.'
        }
        if ($isRetainedRegistryAmbiguity -and
            $recordedDeadLetterCount -ne $knownRegistryAmbiguityDeadLetterCheckpoint) {
            throw 'The historical Registry ambiguity artifact must remain bound to workflow-v2 DLQ checkpoint three.'
        }
        if ($checkpointCaptureTimes.ContainsKey($recordedDeadLetterCount)) {
            throw 'Reviewed canary failure evidence contains a duplicate workflow-v2 DLQ checkpoint.'
        }
        $checkpointCaptureTimes[$recordedDeadLetterCount] = $capturedAt.ToUniversalTime()
    }

    $previousCaptureTime = [datetimeoffset]::MinValue
    for ($checkpoint = 1L; $checkpoint -le $ExpectedWorkflowV2DeadLetterCount; $checkpoint++) {
        if (-not $checkpointCaptureTimes.ContainsKey($checkpoint)) {
            throw 'Reviewed canary failure evidence must contain each unique cumulative DLQ checkpoint from one through the current exact count.'
        }
        $captureTime = [datetimeoffset]$checkpointCaptureTimes[$checkpoint]
        if ($captureTime -le $previousCaptureTime) {
            throw 'Reviewed canary failure evidence capture timestamps must increase with each cumulative DLQ checkpoint.'
        }
        $previousCaptureTime = $captureTime
    }

    if ($ExpectedWorkflowV2DeadLetterCount -ge 3 -and
        $retainedRegistryAmbiguityExceptionCount -ne 1) {
        throw 'The retained workflow-v2 history at DLQ checkpoint three or later must include exactly one fingerprinted historical Registry ambiguity.'
    }

    Write-Pass "Reviewed terminal canary failure evidence accounts for each of the exact $ExpectedWorkflowV2DeadLetterCount workflow-v2 DLQ checkpoints, with at most one reconciled reusable FIC exception and exactly one fingerprinted historical Registry ambiguity when checkpoint three is retained; the live FIC is re-read and no message is received, peeked, settled, replayed, or purged."
}

function Assert-EvidenceFresh {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $verifiedAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse(
        [string]$Evidence.VerifiedAtUtc,
        [ref]$verifiedAt)) {
        throw "$Label evidence has no valid UTC verification timestamp."
    }
    $age = [datetimeoffset]::UtcNow - $verifiedAt.ToUniversalTime()
    if ($age -lt [timespan]::FromMinutes(-5) -or
        $age -gt [timespan]::FromMinutes($MaximumDatabaseEvidenceAgeMinutes)) {
        throw "$Label evidence is outside the permitted freshness window."
    }
}

function Assert-EvidenceTimestampValid {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $verifiedAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse(
        [string]$Evidence.VerifiedAtUtc,
        [ref]$verifiedAt)) {
        throw "$Label evidence has no valid UTC verification timestamp."
    }
    if ($verifiedAt.ToUniversalTime() -gt [datetimeoffset]::UtcNow.AddMinutes(5)) {
        throw "$Label evidence is future-dated."
    }
}

function Assert-ScriptEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ExpectedScripts,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $actualScripts = @($Evidence.Scripts)
    if ($actualScripts.Count -ne $ExpectedScripts.Count) {
        throw "$Label evidence does not contain the exact reviewed SQL script set."
    }

    foreach ($scriptName in $ExpectedScripts) {
        $entry = @($actualScripts | Where-Object { $_.Name -eq $scriptName })
        $scriptPath = Join-Path $SqlScriptDirectory $scriptName
        if ($entry.Count -ne 1 -or
            -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw "$Label evidence is missing one reviewed SQL script."
        }
        $expectedHash = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash
        if (-not [string]::Equals(
            [string]$entry[0].Sha256,
            $expectedHash,
            [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label evidence does not match the current reviewed SQL source."
        }
    }
}

function Assert-DatabaseEvidence {
    $prepare = Read-Evidence -Path $LivePrepareEvidencePath -Label 'Live prepare'
    $liveState = Read-Evidence -Path $LiveStateEvidencePath -Label 'Live state'
    $recovery = Read-Evidence -Path $RecoveryBaselineEvidencePath -Label 'Recovery baseline'

    # Prepare evidence is immutable provenance for the already-applied, reviewed
    # scripts. Its age is intentionally not refreshed by rerunning live DDL.
    Assert-EvidenceTimestampValid -Evidence $prepare -Label 'Live prepare'
    Assert-EvidenceFresh -Evidence $liveState -Label 'Live state'
    Assert-EvidenceFresh -Evidence $recovery -Label 'Recovery baseline'

    if (-not [string]::IsNullOrWhiteSpace($LiveFinalizeEvidencePath)) {
        throw 'The live finalize phase must remain unapplied until the bounded canary and old-API zero-traffic checks pass.'
    }
    if (-not [string]::Equals(
            [string]$prepare.Server,
            $SqlServerFqdn,
            [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            [string]$prepare.Database,
            $SqlDatabaseName,
            [System.StringComparison]::Ordinal)) {
        throw 'Live SQL evidence does not identify the fixed development database.'
    }
    if ($prepare.Verification.WorkflowV2Ready -ne $true) {
        throw 'Live prepare provenance does not prove the workflow-v2 schema.'
    }

    if ([string]$prepare.Phase -ne 'prepare' -or [int]$prepare.Repeat -ne 2 -or
        [int]$prepare.Verification.LegacyGlobalIdempotencyUniqueIndexCount -ne 1) {
        throw 'Live prepare evidence must prove two passes before the idempotency finalize boundary.'
    }
    if (-not [string]::Equals(
            [string]$liveState.Server,
            $SqlServerFqdn,
            [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            [string]$liveState.Database,
            $SqlDatabaseName,
            [System.StringComparison]::Ordinal) -or
        [string]$liveState.Phase -ne 'verify' -or
        [int]$liveState.Repeat -ne 1 -or
        $liveState.Verification.WorkflowV2Ready -ne $true -or
        [int]$liveState.Verification.LegacyGlobalIdempotencyUniqueIndexCount -ne 1 -or
        [long]$liveState.Verification.PublishableOutboxMessageCount -ne 0 -or
        [long]$liveState.Verification.ActiveWorkflowV3JobCount -ne
            $ExpectedRetainedManualWorkflowV3JobCount -or
        [long]$liveState.Verification.AwaitingAdministratorActionWorkflowV3JobCount -ne 0) {
        throw 'Fresh live-state evidence must prove the fixed development database, workflow-v2 schema, retained legacy index, an empty publishable outbox, the exact reviewed retained manual workflow-v3 count, and zero awaiting-administrator workflow-v3 jobs before admission.'
    }
    $knownRetainedManualWorkflowV3OperationId =
        [guid]'5c4ba41d-24e5-473c-9126-f89f37f7bb18'
    $knownBlueprintReadbackWorkflowV3OperationId =
        [guid]'e6bde0e5-a211-42a2-96c6-a5c016cdb693'
    $knownPrincipalReadbackWorkflowV3OperationId =
        [guid]'3c3c86cb-d67b-4868-a9be-19d96b804edf'
    $knownAgentIdentityReadbackWorkflowV3OperationId =
        [guid]'4fe1ddf7-ca27-4ce6-bb1d-3f86b4a8f6a7'
    $knownAgent365AccessWorkflowV3OperationId =
        [guid]'52a94d15-b292-4920-838a-f5aaf0333991'
    $knownFinalVerificationWorkflowV3OperationId =
        [guid]'2edeee16-c101-4aee-b2b7-eff62fbfa466'
    $knownRetryGuardWorkflowV3OperationId =
        [guid]'70154357-c58c-4f95-853b-d95dde67d791'
    $knownTokenProofWorkflowV3OperationId =
        [guid]'990dfe57-4330-457f-a4bd-4968a9f41766'
    $knownTokenAudienceWorkflowV3OperationId =
        [guid]'b735a36d-07fc-4219-9dc3-b371964e748c'
    if ($ExpectedRetainedManualWorkflowV3JobCount -eq 0) {
        if ($ReviewedWorkflowV3ManualOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3BlueprintReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3PrincipalReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3AgentIdentityReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3Agent365AccessOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3FinalVerificationOperationId -ne [guid]::Empty) {
            throw 'Reviewed workflow-v3 manual operation IDs are valid only when retained manual workflow-v3 jobs are expected.'
        }
    }
    elseif ($ExpectedRetainedManualWorkflowV3JobCount -eq 1) {
        if ($ReviewedWorkflowV3ManualOperationId -ne
            $knownRetainedManualWorkflowV3OperationId -or
            $ReviewedWorkflowV3BlueprintReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3PrincipalReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3AgentIdentityReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3Agent365AccessOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3FinalVerificationOperationId -ne [guid]::Empty) {
            throw 'The single retained workflow-v3 exception must bind to the exact preserved Registry-ambiguous operation.'
        }
    }
    elseif ($ExpectedRetainedManualWorkflowV3JobCount -eq 2) {
        if ($ReviewedWorkflowV3ManualOperationId -ne
            $knownRetainedManualWorkflowV3OperationId -or
            $ReviewedWorkflowV3BlueprintReadbackOperationId -ne
                $knownBlueprintReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3PrincipalReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3AgentIdentityReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3Agent365AccessOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3FinalVerificationOperationId -ne [guid]::Empty) {
            throw 'The two retained workflow-v3 exceptions must bind to the exact preserved Registry ambiguity and blueprint readback failure.'
        }
    }
    elseif ($ExpectedRetainedManualWorkflowV3JobCount -eq 3) {
        if ($ReviewedWorkflowV3ManualOperationId -ne
                $knownRetainedManualWorkflowV3OperationId -or
            $ReviewedWorkflowV3BlueprintReadbackOperationId -ne
                $knownBlueprintReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3PrincipalReadbackOperationId -ne
                $knownPrincipalReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3AgentIdentityReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3Agent365AccessOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3FinalVerificationOperationId -ne [guid]::Empty) {
            throw 'The three retained workflow-v3 exceptions must bind to the exact preserved Registry ambiguity, blueprint readback failure, and blueprint-principal readback failure.'
        }
    }
    elseif ($ExpectedRetainedManualWorkflowV3JobCount -eq 4) {
        if ($ReviewedWorkflowV3ManualOperationId -ne
            $knownRetainedManualWorkflowV3OperationId -or
            $ReviewedWorkflowV3BlueprintReadbackOperationId -ne
            $knownBlueprintReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3PrincipalReadbackOperationId -ne
            $knownPrincipalReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3AgentIdentityReadbackOperationId -ne
            $knownAgentIdentityReadbackWorkflowV3OperationId -or
            ($ExpectedWorkflowV3DeadLetterCount -eq 4 -and
                $ReviewedWorkflowV3Agent365AccessOperationId -ne
                    $knownAgent365AccessWorkflowV3OperationId) -or
            ($ExpectedWorkflowV3DeadLetterCount -ne 4 -and
                $ReviewedWorkflowV3Agent365AccessOperationId -ne [guid]::Empty) -or
            $ReviewedWorkflowV3FinalVerificationOperationId -ne [guid]::Empty) {
        throw 'The four retained workflow-v3 exceptions must bind to the exact preserved Registry ambiguity and three propagation readback failures.'
        }
    }
    elseif ($ReviewedWorkflowV3ManualOperationId -ne
            $knownRetainedManualWorkflowV3OperationId -or
        $ReviewedWorkflowV3BlueprintReadbackOperationId -ne
            $knownBlueprintReadbackWorkflowV3OperationId -or
        $ReviewedWorkflowV3PrincipalReadbackOperationId -ne
            $knownPrincipalReadbackWorkflowV3OperationId -or
        $ReviewedWorkflowV3AgentIdentityReadbackOperationId -ne
            $knownAgentIdentityReadbackWorkflowV3OperationId -or
        $ReviewedWorkflowV3Agent365AccessOperationId -ne
            $knownAgent365AccessWorkflowV3OperationId -or
        $ReviewedWorkflowV3FinalVerificationOperationId -ne
            $knownFinalVerificationWorkflowV3OperationId) {
        throw 'The five retained workflow-v3 jobs and their dead-letter lineage must bind to the exact preserved Registry ambiguity, propagation failures, and final verification failure.'
    }
    if ($ExpectedRetainedManualWorkflowV3JobCount -ge 6) {
        if ($ReviewedWorkflowV3RetryGuardOperationId -ne
            $knownRetryGuardWorkflowV3OperationId) {
            throw 'The sixth retained workflow-v3 job must bind to the exact reviewed retry-guard failure.'
        }
    }
    elseif ($ReviewedWorkflowV3RetryGuardOperationId -ne [guid]::Empty) {
        throw 'The reviewed retry-guard operation ID is valid only when at least six retained workflow-v3 jobs are expected.'
    }
    if ($ExpectedRetainedManualWorkflowV3JobCount -ge 7) {
        if ($ReviewedWorkflowV3TokenProofOperationId -ne
            $knownTokenProofWorkflowV3OperationId) {
            throw 'The seventh retained workflow-v3 job must bind to the exact reviewed token-proof failure.'
        }
    }
    elseif ($ReviewedWorkflowV3TokenProofOperationId -ne [guid]::Empty) {
        throw 'The reviewed token-proof operation ID is valid only when at least seven retained workflow-v3 jobs are expected.'
    }
    if ($ExpectedRetainedManualWorkflowV3JobCount -eq 8) {
        if ($ReviewedWorkflowV3TokenAudienceOperationId -ne
            $knownTokenAudienceWorkflowV3OperationId) {
            throw 'The eighth retained workflow-v3 job must bind to the exact reviewed token-audience failure.'
        }
    }
    elseif ($ReviewedWorkflowV3TokenAudienceOperationId -ne [guid]::Empty) {
        throw 'The reviewed token-audience operation ID is valid only when eight retained workflow-v3 jobs are expected.'
    }
    if ($ExpectedWorkflowV3DeadLetterCount -eq 0) {
        if ($ReviewedWorkflowV3BlueprintReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3PrincipalReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3AgentIdentityReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3Agent365AccessOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3FinalVerificationOperationId -ne [guid]::Empty) {
            throw 'Reviewed workflow-v3 readback operation IDs require the retained workflow-v3 dead-letter count.'
        }
    }
    elseif ($ExpectedWorkflowV3DeadLetterCount -eq 1) {
        if ($ReviewedWorkflowV3BlueprintReadbackOperationId -ne
                $knownBlueprintReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3PrincipalReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3AgentIdentityReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3Agent365AccessOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3FinalVerificationOperationId -ne [guid]::Empty) {
            throw 'The retained workflow-v3 dead-letter exception must bind to the exact preserved blueprint readback failure.'
        }
    }
    elseif ($ExpectedWorkflowV3DeadLetterCount -eq 2) {
        if ($ReviewedWorkflowV3BlueprintReadbackOperationId -ne
                $knownBlueprintReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3PrincipalReadbackOperationId -ne
                $knownPrincipalReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3AgentIdentityReadbackOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3Agent365AccessOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3FinalVerificationOperationId -ne [guid]::Empty) {
            throw 'The retained workflow-v3 dead-letter exceptions must bind to the exact blueprint and blueprint-principal readback failures.'
        }
    }
    elseif ($ExpectedWorkflowV3DeadLetterCount -eq 3) {
        if ($ReviewedWorkflowV3BlueprintReadbackOperationId -ne
            $knownBlueprintReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3PrincipalReadbackOperationId -ne
            $knownPrincipalReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3AgentIdentityReadbackOperationId -ne
            $knownAgentIdentityReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3Agent365AccessOperationId -ne [guid]::Empty -or
            $ReviewedWorkflowV3FinalVerificationOperationId -ne [guid]::Empty) {
        throw 'The retained workflow-v3 dead-letter exceptions must bind to the exact blueprint, blueprint-principal, and Agent Identity readback failures.'
        }
    }
    elseif ($ExpectedWorkflowV3DeadLetterCount -eq 4) {
        if ($ReviewedWorkflowV3BlueprintReadbackOperationId -ne
            $knownBlueprintReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3PrincipalReadbackOperationId -ne
            $knownPrincipalReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3AgentIdentityReadbackOperationId -ne
            $knownAgentIdentityReadbackWorkflowV3OperationId -or
            $ReviewedWorkflowV3Agent365AccessOperationId -ne
            $knownAgent365AccessWorkflowV3OperationId -or
            $ReviewedWorkflowV3FinalVerificationOperationId -ne [guid]::Empty) {
        throw 'The retained workflow-v3 dead-letter exceptions must bind to the exact blueprint, principal, Agent Identity, and Agent 365 access propagation failures.'
        }
    }
    elseif ($ReviewedWorkflowV3BlueprintReadbackOperationId -ne
            $knownBlueprintReadbackWorkflowV3OperationId -or
        $ReviewedWorkflowV3PrincipalReadbackOperationId -ne
            $knownPrincipalReadbackWorkflowV3OperationId -or
        $ReviewedWorkflowV3AgentIdentityReadbackOperationId -ne
            $knownAgentIdentityReadbackWorkflowV3OperationId -or
        $ReviewedWorkflowV3Agent365AccessOperationId -ne
            $knownAgent365AccessWorkflowV3OperationId -or
        $ReviewedWorkflowV3FinalVerificationOperationId -ne
            $knownFinalVerificationWorkflowV3OperationId) {
        throw 'The retained workflow-v3 dead-letter exceptions must bind to the exact four propagation failures and final verification failure.'
    }
    if ($ExpectedWorkflowV3DeadLetterCount -ge 6) {
        if ($ReviewedWorkflowV3RetryGuardOperationId -ne
            $knownRetryGuardWorkflowV3OperationId) {
            throw 'The sixth workflow-v3 dead-letter must bind to the exact reviewed retry-guard failure.'
        }
    }
    elseif ($ReviewedWorkflowV3RetryGuardOperationId -ne [guid]::Empty) {
        throw 'The reviewed retry-guard operation ID requires at least six workflow-v3 dead-letters.'
    }
    if ($ExpectedWorkflowV3DeadLetterCount -ge 7) {
        if ($ReviewedWorkflowV3TokenProofOperationId -ne
            $knownTokenProofWorkflowV3OperationId) {
            throw 'The seventh workflow-v3 dead-letter must bind to the exact reviewed token-proof failure.'
        }
    }
    elseif ($ReviewedWorkflowV3TokenProofOperationId -ne [guid]::Empty) {
        throw 'The reviewed token-proof operation ID requires at least seven workflow-v3 dead-letters.'
    }
    if ($ExpectedWorkflowV3DeadLetterCount -eq 8) {
        if ($ReviewedWorkflowV3TokenAudienceOperationId -ne
            $knownTokenAudienceWorkflowV3OperationId) {
            throw 'The eighth workflow-v3 dead-letter must bind to the exact reviewed token-audience failure.'
        }
    }
    elseif ($ReviewedWorkflowV3TokenAudienceOperationId -ne [guid]::Empty) {
        throw 'The reviewed token-audience operation ID requires the eighth workflow-v3 dead-letter.'
    }
    if (-not [string]::Equals(
            [string]$recovery.Server,
            $SqlServerFqdn,
            [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals(
            [string]$recovery.Database,
            $SqlDatabaseName,
            [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]$recovery.Phase -ne 'baseline' -or
        $recovery.Verification.WorkflowV2Ready -ne $false -or
        [int]$recovery.Verification.LegacyGlobalIdempotencyUniqueIndexCount -ne 1) {
        throw 'Recovery evidence must identify a distinct pre-upgrade database copy with the legacy schema boundary.'
    }

    Assert-ScriptEvidence -Evidence $prepare -ExpectedScripts @(
        '20260824_agent_identity_workflow_v2.sql',
        '20260825_agent_ingress_credentials.sql',
        '20260825_scoped_idempotency.sql',
        '20260825_ingress_rate_limit_buckets.sql'
    ) -Label 'Live prepare'
    Assert-ScriptEvidence -Evidence $liveState -ExpectedScripts @() -Label 'Live state'

    # ConvertFrom-Json may materialize an ISO-8601 value as DateTime. Casting that
    # value to string first would drop sub-second precision under some cultures and
    # break the exact outbox-evidence binding.
    $liveStateVerifiedAt = ([datetimeoffset]$liveState.VerifiedAtUtc).ToUniversalTime()
    Write-Pass "Immutable prepare provenance and fresh read-only live/recovery evidence match the reviewed SQL; the publishable outbox is empty, workflow-v3 awaiting is zero, the retained manual count is exactly $ExpectedRetainedManualWorkflowV3JobCount, and live finalize remains deferred."
    return $liveStateVerifiedAt
}

function Assert-OperationalConfirmations {
    param(
        [Parameter(Mandatory = $true)]
        [datetimeoffset]$ExpectedOutboxVerifiedAtUtc
    )

    if (-not $PendingProvisioningOutboxVerifiedEmpty) {
        throw 'Activation requires explicit confirmation that no pending or due provisioning outbox row exists.'
    }
    if (-not $ContainedSqlAccessVerified) {
        throw 'Activation requires a current contained-SQL-access proof for the API and new worker identities.'
    }
    if (-not $ManagerApplicationsPreflightConfirmed) {
        throw 'Activation requires independent managerApplications confirmation.'
    }

    if ($ProvisioningOutboxVerifiedAtUtc -eq [datetimeoffset]::MinValue) {
        throw 'ProvisioningOutboxVerifiedAtUtc is required for the empty-outbox confirmation.'
    }
    if ($ProvisioningOutboxVerifiedAtUtc.ToUniversalTime() -ne
        $ExpectedOutboxVerifiedAtUtc.ToUniversalTime()) {
        throw 'ProvisioningOutboxVerifiedAtUtc must exactly match the fresh live-state evidence timestamp.'
    }
    $outboxEvidenceAge =
        [datetimeoffset]::UtcNow - $ProvisioningOutboxVerifiedAtUtc.ToUniversalTime()
    if ($outboxEvidenceAge -lt [timespan]::FromMinutes(-2) -or
        $outboxEvidenceAge -gt [timespan]::FromMinutes($MaximumOutboxEvidenceAgeMinutes)) {
        throw 'The empty provisioning-outbox confirmation is stale or future-dated.'
    }

    Write-Pass 'Contained SQL access and a fresh empty provisioning outbox are explicitly confirmed.'
}

function Assert-NoContainerCommandOverride {
    param([Parameter(Mandatory = $true)][object]$ContainerApp)

    $container = Get-PrimaryContainer -ContainerApp $ContainerApp
    $commandProperty = $container.PSObject.Properties['command']
    $argumentsProperty = $container.PSObject.Properties['args']
    # The outer array expression is required under StrictMode. An `if` branch that
    # emits @() assigns $null, and `$null.Count` then fails before the canary can
    # evaluate its remaining read-only prerequisites.
    $commands = @(
        if ($null -ne $commandProperty -and $null -ne $commandProperty.Value) {
            $commandProperty.Value
        }
    )
    $arguments = @(
        if ($null -ne $argumentsProperty -and $null -ne $argumentsProperty.Value) {
            $argumentsProperty.Value
        }
    )
    if ($commands.Count -gt 0 -or $arguments.Count -gt 0) {
        throw "Container App '$($ContainerApp.name)' retains a command/argument override and is not safe for canary activation."
    }
}

function Assert-NoMigrationRunnerConfiguration {
    param([Parameter(Mandatory = $true)][object]$ContainerApp)

    $container = Get-PrimaryContainer -ContainerApp $ContainerApp
    $migrationEntries = @($container.env | Where-Object {
        $_.name.StartsWith(
            'DATABASE_MIGRATOR_',
            [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($migrationEntries.Count -ne 0) {
        throw "Container App '$($ContainerApp.name)' still contains database-migrator settings and is not a clean runtime template."
    }
}

function Assert-RequiredEnvironmentSettings {
    param(
        [Parameter(Mandatory = $true)][object]$ContainerApp,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        $value = Get-EnvironmentValue -ContainerApp $ContainerApp -Name $name
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Container App '$($ContainerApp.name)' has an empty required runtime setting '$name'."
        }
    }
}

function Assert-ApiState {
    param(
        [Parameter(Mandatory = $true)][object]$Api,
        [Parameter(Mandatory = $true)][bool]$AdmissionEnabled,
        [bool]$DelegatedActionEnabled = $false,
        [string]$ExpectedImage,
        [AllowEmptyCollection()][string[]]$ManagerApplicationIds = @(),
        [Nullable[datetimeoffset]]$ExpectedAdmissionExpiresAtUtc,
        [string]$ExpectedAuthorizedExternalAgentId = '',
        [string]$ExpectedAuthorizedRetryAgentId = '',
        [Nullable[datetimeoffset]]$ExpectedDelegatedActionExpiresAtUtc,
        [Nullable[guid]]$ExpectedAuthorizedOperationId,
        [switch]$RequireExpectedManagerApplications,
        [switch]$RequireCanaryScale,
        [switch]$AllowLegacyClosedConfiguration
    )

    Assert-EnvironmentValue `
        -ContainerApp $Api `
        -Name 'ServiceBus__QueueName' `
        -Expected $WorkflowV3QueueName
    Assert-EnvironmentValue `
        -ContainerApp $Api `
        -Name 'Provisioning__ExecutionEnabled' `
        -Expected $AdmissionEnabled.ToString().ToLowerInvariant()
    Assert-EnvironmentValue `
        -ContainerApp $Api `
        -Name 'Agent365__DelegatedRegistry__Enabled' `
        -Expected $DelegatedActionEnabled.ToString().ToLowerInvariant()
    if (-not $AllowLegacyClosedConfiguration) {
        Assert-EnvironmentValue `
            -ContainerApp $Api `
            -Name $RequireExactAdmissionBindingSettingName `
            -Expected 'true'
        Assert-EnvironmentValue `
            -ContainerApp $Api `
            -Name $RequireExactDelegatedActionBindingSettingName `
            -Expected 'true'
    }
    elseif ($AdmissionEnabled -or $DelegatedActionEnabled) {
        throw 'Legacy API configuration is accepted only as a closed pre-rollout boundary.'
    }
    if ($AdmissionEnabled -and $DelegatedActionEnabled) {
        throw 'Registration/retry admission and delegated Registry completion must never be open together.'
    }
    Assert-EnvironmentValue `
        -ContainerApp $Api `
        -Name 'EntraId__ClientCredentials__0__SourceType' `
        -Expected 'SignedAssertionFromManagedIdentity'
    Assert-EnvironmentValue `
        -ContainerApp $Api `
        -Name 'EntraId__ClientCredentials__0__TokenExchangeUrl' `
        -Expected 'api://AzureADTokenExchange'
    Assert-EnvironmentValue `
        -ContainerApp $Api `
        -Name 'Agent365__DelegatedRegistry__Scopes__0' `
        -Expected 'https://graph.microsoft.com/AgentRegistration.ReadWrite.All'
    Assert-EnvironmentValue `
        -ContainerApp $Api `
        -Name 'Agent365__DelegatedRegistry__Scopes__1' `
        -Expected 'https://graph.microsoft.com/AgentRegistration.Read.All'
    $admissionExpiryValue = Get-EnvironmentValue `
        -ContainerApp $Api `
        -Name $AdmissionExpirySettingName `
        -AllowMissing
    $authorizedExternalAgentId = Get-EnvironmentValue `
        -ContainerApp $Api `
        -Name $AuthorizedExternalAgentIdSettingName `
        -AllowMissing
    $authorizedRetryAgentId = Get-EnvironmentValue `
        -ContainerApp $Api `
        -Name $AuthorizedRetryAgentIdSettingName `
        -AllowMissing
    if ($AdmissionEnabled) {
        $parsedExpiry = [datetimeoffset]::MinValue
        if ([string]::IsNullOrWhiteSpace($admissionExpiryValue) -or
            -not $admissionExpiryValue.EndsWith('Z', [System.StringComparison]::Ordinal) -or
            -not [datetimeoffset]::TryParse($admissionExpiryValue, [ref]$parsedExpiry) -or
            $parsedExpiry.ToUniversalTime() -le [datetimeoffset]::UtcNow) {
            throw 'Enabled API admission must carry a valid future API-enforced UTC expiry.'
        }
        if ($null -ne $ExpectedAdmissionExpiresAtUtc -and
            [math]::Abs(
                ($parsedExpiry.ToUniversalTime() -
                 $ExpectedAdmissionExpiresAtUtc.ToUniversalTime()).TotalSeconds) -gt 1) {
            throw 'The deployed API admission expiry does not match the reviewed bounded window.'
        }
        if (-not [string]::Equals(
                [string]$authorizedExternalAgentId,
                $ExpectedAuthorizedExternalAgentId,
                [System.StringComparison]::Ordinal) -or
            -not [string]::Equals(
                [string]$authorizedRetryAgentId,
                $ExpectedAuthorizedRetryAgentId,
                [System.StringComparison]::OrdinalIgnoreCase) -or
            ([string]::IsNullOrWhiteSpace($ExpectedAuthorizedExternalAgentId) -eq
             [string]::IsNullOrWhiteSpace($ExpectedAuthorizedRetryAgentId))) {
            throw 'Enabled API admission must bind exactly one reviewed external registration or retry registration.'
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($admissionExpiryValue) -or
            -not [string]::IsNullOrWhiteSpace($authorizedExternalAgentId) -or
            -not [string]::IsNullOrWhiteSpace($authorizedRetryAgentId)) {
        throw 'Closed API admission must not retain an expiry, external-agent binding, or retry binding.'
    }

    $delegatedActionExpiryValue = Get-EnvironmentValue `
        -ContainerApp $Api `
        -Name $DelegatedRegistryActionExpirySettingName `
        -AllowMissing
    $delegatedAuthorizedOperationId = Get-EnvironmentValue `
        -ContainerApp $Api `
        -Name $DelegatedRegistryAuthorizedOperationIdSettingName `
        -AllowMissing
    if ($DelegatedActionEnabled) {
        $parsedDelegatedExpiry = [datetimeoffset]::MinValue
        $parsedOperationId = [guid]::Empty
        if ([string]::IsNullOrWhiteSpace($delegatedActionExpiryValue) -or
            -not $delegatedActionExpiryValue.EndsWith('Z', [System.StringComparison]::Ordinal) -or
            -not [datetimeoffset]::TryParse(
                $delegatedActionExpiryValue,
                [ref]$parsedDelegatedExpiry) -or
            $parsedDelegatedExpiry.ToUniversalTime() -le [datetimeoffset]::UtcNow -or
            -not [guid]::TryParse($delegatedAuthorizedOperationId, [ref]$parsedOperationId) -or
            $parsedOperationId -eq [guid]::Empty) {
            throw 'Enabled delegated Registry completion must carry its own future UTC expiry and exact operation binding.'
        }
        if (($null -ne $ExpectedDelegatedActionExpiresAtUtc -and
             [math]::Abs(
                ($parsedDelegatedExpiry.ToUniversalTime() -
                 $ExpectedDelegatedActionExpiresAtUtc.ToUniversalTime()).TotalSeconds) -gt 1) -or
            ($null -ne $ExpectedAuthorizedOperationId -and
             $parsedOperationId -ne [guid]$ExpectedAuthorizedOperationId)) {
            throw 'The deployed delegated Registry expiry or operation binding does not match the reviewed window.'
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($delegatedActionExpiryValue) -or
            -not [string]::IsNullOrWhiteSpace($delegatedAuthorizedOperationId)) {
        throw 'Closed delegated Registry completion must not retain an expiry or operation binding.'
    }
    $outboxRelay = Get-EnvironmentValue `
        -ContainerApp $Api `
        -Name 'OutboxRelay__Enabled' `
        -AllowMissing
    if (-not [string]::IsNullOrWhiteSpace($outboxRelay) -and
        -not [string]::Equals(
            $outboxRelay,
            'true',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The API outbox relay must remain the workflow-v3 publisher.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedImage)) {
        Assert-ContainerImage -ContainerApp $Api -ExpectedImage $ExpectedImage
    }
    Assert-ManagerApplications `
        -ContainerApp $Api `
        -ExpectedIds $ManagerApplicationIds `
        -RequireExpectedMatch:$RequireExpectedManagerApplications
    if ($RequireCanaryScale -and
        ([int]$Api.properties.template.scale.minReplicas -ne 1 -or
         [int]$Api.properties.template.scale.maxReplicas -ne 1)) {
        throw 'The API must be constrained to exactly one replica for the development canary.'
    }
    Assert-NoContainerCommandOverride -ContainerApp $Api
    Assert-NoMigrationRunnerConfiguration -ContainerApp $Api
    Assert-RequiredEnvironmentSettings -ContainerApp $Api -Names @(
        'ConnectionStrings__GatewayDb',
        'ServiceBus__FullyQualifiedNamespace',
        'BlobStorage__ServiceUri',
        'BlobStorage__ContainerName',
        'EntraId__TenantId',
        'EntraId__ClientId',
        'EntraId__Audience',
        'EntraId__ClientCredentials__0__SourceType',
        'EntraId__ClientCredentials__0__TokenExchangeUrl',
        'KeyVault__VaultUri',
        'Agent365__TenantId',
        'ASPNETCORE_ENVIRONMENT'
    )
}

function Assert-WorkerState {
    param(
        [Parameter(Mandatory = $true)][object]$Worker,
        [Parameter(Mandatory = $true)][ValidateSet('Armed', 'Inert')]
        [string]$State,
        [string]$ExpectedImage,
        [switch]$RequireExactScale
    )

    $armed = $State -eq 'Armed'
    Assert-EnvironmentValue `
        -ContainerApp $Worker `
        -Name 'ServiceBus__QueueName' `
        -Expected $WorkflowV3QueueName
    Assert-EnvironmentValue `
        -ContainerApp $Worker `
        -Name 'ProvisioningWorker__QueueName' `
        -Expected $WorkflowV3QueueName
    Assert-EnvironmentValue `
        -ContainerApp $Worker `
        -Name 'OutboxRelay__Enabled' `
        -Expected 'false'
    Assert-EnvironmentValue `
        -ContainerApp $Worker `
        -Name 'ProvisioningWorker__ProcessingEnabled' `
        -Expected $armed.ToString().ToLowerInvariant()
    Assert-EnvironmentValue `
        -ContainerApp $Worker `
        -Name 'ProvisioningWorker__ProvisioningExecutionEnabled' `
        -Expected $armed.ToString().ToLowerInvariant()
    Assert-EnvironmentValue `
        -ContainerApp $Worker `
        -Name 'Agent365__RegistryProvider' `
        -Expected $(if ($armed) { 'DirectRegistryPreview' } else { 'Disabled' })
    Assert-EnvironmentValue `
        -ContainerApp $Worker `
        -Name 'Agent365__DirectRegistryPreviewEnabled' `
        -Expected $armed.ToString().ToLowerInvariant()

    $pinnedPrincipalId = Get-EnvironmentValue `
        -ContainerApp $Worker `
        -Name 'Agent365__ProvisioningManagedIdentityPrincipalId'
    if (-not [string]::Equals(
        $pinnedPrincipalId,
        [string]$Worker.identity.principalId,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The new worker does not pin its own managed-identity principal ID.'
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedImage)) {
        Assert-ContainerImage -ContainerApp $Worker -ExpectedImage $ExpectedImage
    }
    $reviewedManagerApplicationIds = @($ExpectedManagerApplicationIds |
        ForEach-Object { $_.ToString('D') })
    Assert-ManagerApplications `
        -ContainerApp $Worker `
        -ExpectedIds $reviewedManagerApplicationIds `
        -RequireExpectedMatch:$armed
    Assert-NoContainerCommandOverride -ContainerApp $Worker
    Assert-NoMigrationRunnerConfiguration -ContainerApp $Worker
    Assert-RequiredEnvironmentSettings -ContainerApp $Worker -Names @(
        'ConnectionStrings__GatewayDb',
        'ServiceBus__FullyQualifiedNamespace',
        'Agent365__TenantId',
        'Agent365__GatewayApiApplicationClientId',
        'Agent365__GatewayApiAudience',
        'Agent365__GatewayApiBaseUrl',
        'Agent365__ObservabilityServerAddress',
        'DOTNET_ENVIRONMENT'
    )

    $scale = $Worker.properties.template.scale
    $expectedMinReplicas = if ($armed) { 1 } else { 0 }
    if ($RequireExactScale -and
        ([int]$scale.minReplicas -ne $expectedMinReplicas -or
         [int]$scale.maxReplicas -ne 1)) {
        throw "The new worker does not have the exact $State canary replica boundary."
    }
    $rulesProperty = $scale.PSObject.Properties['rules']
    $rules = @(
        if ($null -ne $rulesProperty -and $null -ne $rulesProperty.Value) {
            $rulesProperty.Value
        }
    )
    if ($rules.Count -ne 0) {
        throw 'The bounded canary worker must not retain a KEDA scaler.'
    }
    if ($RequireExactScale) {
        Assert-EnvironmentValue `
            -ContainerApp $Worker `
            -Name 'ProvisioningWorker__MaxConcurrentCalls' `
            -Expected '1'
    }
}

function Test-RevisionReadyRunningState {
    param(
        [Parameter(Mandatory = $true)][object]$Revision,
        [Parameter(Mandatory = $true)][ValidateRange(0, 1)]
        [int]$ExpectedMinimumReplicas
    )

    $runningStateProperty = $Revision.properties.PSObject.Properties['runningState']
    if ($null -eq $runningStateProperty -or
        [string]::IsNullOrWhiteSpace([string]$runningStateProperty.Value)) {
        throw 'The new revision did not report a running state.'
    }

    $runningState = [string]$runningStateProperty.Value
    $healthStateProperty = $Revision.properties.PSObject.Properties['healthState']
    if ($null -ne $healthStateProperty -and
        [string]::Equals(
            [string]$healthStateProperty.Value,
            'Unhealthy',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "The new revision reported an unhealthy state while '$runningState'."
    }

    if ($runningState -in @(
            'ActivationFailed',
            'Degraded',
            'Failed',
            'ProvisioningFailed',
            'Stopped',
            'Unknown'
        )) {
        throw "The new revision entered unsafe running state '$runningState'."
    }

    if ($runningState -in @('Running', 'RunningAtMaxScale')) {
        return $true
    }

    if ([string]::Equals(
            $runningState,
            'ScaleToZero',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        $replicasProperty = $Revision.properties.PSObject.Properties['replicas']
        if ($ExpectedMinimumReplicas -ne 0 -or
            $null -eq $replicasProperty -or
            [int]$replicasProperty.Value -ne 0) {
            throw 'ScaleToZero is valid only for an expected zero-minimum revision that reports zero replicas.'
        }

        return $true
    }

    return $false
}

function Wait-ForRevision {
    param(
        [Parameter(Mandatory = $true)][string]$ContainerAppName,
        [Parameter(Mandatory = $true)][string]$PreviousRevisionName,
        [Parameter(Mandatory = $true)][string]$ExpectedImage,
        [Parameter(Mandatory = $true)][ValidateRange(0, 1)]
        [int]$ExpectedMinimumReplicas
    )

    $deadline = [datetimeoffset]::UtcNow.AddMinutes(3)
    $lastObservation = 'The new revision has not yet become active and ready.'
    do {
        $app = Get-ContainerApp -Name $ContainerAppName
        $latestRevisionName = [string]$app.properties.latestRevisionName
        $latestReadyRevisionName = [string]$app.properties.latestReadyRevisionName
        if (-not [string]::IsNullOrWhiteSpace($latestRevisionName) -and
            -not [string]::Equals(
                $latestRevisionName,
                $PreviousRevisionName,
                [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals(
                $latestRevisionName,
                $latestReadyRevisionName,
                [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals(
                [string]$app.properties.provisioningState,
                'Succeeded',
                [System.StringComparison]::OrdinalIgnoreCase)) {
            Assert-ContainerImage -ContainerApp $app -ExpectedImage $ExpectedImage
            $revision = Invoke-AzJson -Arguments @(
                'containerapp', 'revision', 'show',
                '--name', $ContainerAppName,
                '--resource-group', $ResourceGroup,
                '--revision', $latestRevisionName
            ) -FailureMessage "Unable to inspect the new revision for '$ContainerAppName'."
            if ([bool]$revision.properties.active -and
                (Test-RevisionReadyRunningState `
                    -Revision $revision `
                    -ExpectedMinimumReplicas $ExpectedMinimumReplicas)) {
                $activeRevisions = Invoke-AzJson -Arguments @(
                    'containerapp', 'revision', 'list',
                    '--name', $ContainerAppName,
                    '--resource-group', $ResourceGroup
                ) -FailureMessage "Unable to enumerate revisions for '$ContainerAppName'."
                $activeRevisionCount = @(
                    $activeRevisions |
                        Where-Object { [bool]$_.properties.active }
                ).Count
                if ($activeRevisionCount -eq 1) {
                    Write-Pass "Container App '$ContainerAppName' has one active, ready digest-pinned revision."
                    return $app
                }

                # Single-revision mode can briefly report both the outgoing and
                # incoming revisions as active. Keep that convergence observation
                # inside the same bounded wait instead of treating it as failure.
                $lastObservation =
                    "The new revision is ready, but $activeRevisionCount active revisions were reported during single-revision convergence."
            }
        }

        Start-Sleep -Seconds 5
    } while ([datetimeoffset]::UtcNow -lt $deadline)

    throw "Container App '$ContainerAppName' did not reach one active ready revision within three minutes. Last observation: $lastObservation"
}

function Wait-ApiHealth {
    param([Parameter(Mandatory = $true)][object]$Api)

    $fqdn = [string]$Api.properties.configuration.ingress.fqdn
    if ([string]::IsNullOrWhiteSpace($fqdn)) {
        throw 'The Gateway API has no external HTTPS ingress FQDN.'
    }

    foreach ($path in @('/health/checks', '/health/ready')) {
        $healthy = $false
        for ($attempt = 1; $attempt -le 24; $attempt++) {
            try {
                $response = Invoke-WebRequest `
                    -Uri "https://$fqdn$path" `
                    -Method Get `
                    -TimeoutSec 10 `
                    -SkipHttpErrorCheck
                if ([int]$response.StatusCode -eq 200) {
                    $healthy = $true
                    break
                }
            }
            catch {
                # The next bounded attempt covers DNS and revision-start transients.
            }
            Start-Sleep -Seconds 5
        }
        if (-not $healthy) {
            throw "Gateway API endpoint '$path' did not return HTTP 200 within the bounded wait."
        }
    }
    Write-Pass 'Gateway API health and readiness endpoints returned HTTP 200.'
}

function Set-WorkerMode {
    param(
        [Parameter(Mandatory = $true)][bool]$Armed,
        [Parameter(Mandatory = $true)][string]$Image,
        [Parameter(Mandatory = $true)][string]$RevisionSuffix
    )

    $current = Get-ContainerApp -Name $WorkerContainerAppName
    $previousRevision = [string]$current.properties.latestRevisionName
    $registryProvider = if ($Armed) { 'DirectRegistryPreview' } else { 'Disabled' }
    $gate = $Armed.ToString().ToLowerInvariant()
    $minimumReplicas = if ($Armed) { '1' } else { '0' }

    Invoke-AzNoOutput -Arguments @(
        'containerapp', 'update',
        '--name', $WorkerContainerAppName,
        '--resource-group', $ResourceGroup,
        '--image', $Image,
        '--min-replicas', $minimumReplicas,
        '--max-replicas', '1',
        '--set-env-vars',
        "ServiceBus__QueueName=$WorkflowV3QueueName",
        "ProvisioningWorker__QueueName=$WorkflowV3QueueName",
        'ProvisioningWorker__MaxConcurrentCalls=1',
        'OutboxRelay__Enabled=false',
        "ProvisioningWorker__ProcessingEnabled=$gate",
        "ProvisioningWorker__ProvisioningExecutionEnabled=$gate",
        "Agent365__RegistryProvider=$registryProvider",
        "Agent365__DirectRegistryPreviewEnabled=$gate",
        '--revision-suffix', $RevisionSuffix
    ) -FailureMessage 'The scoped new-worker revision update failed.'

    return Wait-ForRevision `
        -ContainerAppName $WorkerContainerAppName `
        -PreviousRevisionName $previousRevision `
        -ExpectedImage $Image `
        -ExpectedMinimumReplicas ([int]$minimumReplicas)
}

function Set-ApiAdmission {
    param(
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [bool]$DelegatedActionEnabled = $false,
        [Parameter(Mandatory = $true)][string]$Image,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()][string[]]$ManagerApplicationIds,
        [Parameter(Mandatory = $true)][string]$RevisionSuffix,
        [Parameter(Mandatory = $false)]
        [Nullable[datetimeoffset]]$AdmissionExpiresAtUtc,
        [string]$AuthorizedExternalAgentId = '',
        [string]$AuthorizedRetryAgentId = '',
        [Parameter(Mandatory = $false)]
        [Nullable[datetimeoffset]]$DelegatedActionExpiresAtUtc,
        [Parameter(Mandatory = $false)]
        [Nullable[guid]]$AuthorizedOperationId
    )

    $current = Get-ContainerApp -Name $ApiContainerAppName
    $previousRevision = [string]$current.properties.latestRevisionName
    if ($Enabled -and $DelegatedActionEnabled) {
        throw 'Registration/retry admission and delegated Registry completion must never be open together.'
    }

    $normalizedManagerApplicationIds = @(ConvertTo-NormalizedManagerApplicationIds `
        -Values $ManagerApplicationIds `
        -RequireNonEmpty:($Enabled -or $DelegatedActionEnabled) `
        -InputLabel 'API revision manager application ID input')

    $expectedSettingNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    $managerEnvironmentArguments = @(
        for ($index = 0; $index -lt $normalizedManagerApplicationIds.Count; $index++) {
            $settingName = "$ManagerApplicationSettingPrefix$index"
            $null = $expectedSettingNames.Add($settingName)
            "$settingName=$($normalizedManagerApplicationIds[$index])"
        }
    )
    $staleSettingNames = @(Get-ManagerApplicationEnvironmentEntries -ContainerApp $current |
        ForEach-Object { [string]$_.name } |
        Where-Object { -not $expectedSettingNames.Contains($_) } |
        Sort-Object -Unique)

    if ($Enabled) {
        if ($null -eq $AdmissionExpiresAtUtc -or
            $AdmissionExpiresAtUtc.ToUniversalTime() -le [datetimeoffset]::UtcNow) {
            throw 'Opening API admission requires a future API-enforced UTC expiry.'
        }
        if ([string]::IsNullOrWhiteSpace($AuthorizedExternalAgentId) -eq
            [string]::IsNullOrWhiteSpace($AuthorizedRetryAgentId)) {
            throw 'Opening API admission requires exactly one external-registration or retry binding.'
        }
        if ($null -ne $DelegatedActionExpiresAtUtc -or
            $null -ne $AuthorizedOperationId) {
            throw 'Registration/retry admission cannot carry delegated Registry action inputs.'
        }
    }
    elseif ($null -ne $AdmissionExpiresAtUtc -or
            -not [string]::IsNullOrWhiteSpace($AuthorizedExternalAgentId) -or
            -not [string]::IsNullOrWhiteSpace($AuthorizedRetryAgentId)) {
        throw 'Closed API admission must not carry an expiry or registration/retry binding.'
    }

    if ($DelegatedActionEnabled) {
        if ($null -eq $DelegatedActionExpiresAtUtc -or
            $DelegatedActionExpiresAtUtc.ToUniversalTime() -le [datetimeoffset]::UtcNow -or
            $null -eq $AuthorizedOperationId -or
            [guid]$AuthorizedOperationId -eq [guid]::Empty) {
            throw 'Opening delegated Registry completion requires a future UTC expiry and one exact operation binding.'
        }
    }
    elseif ($null -ne $DelegatedActionExpiresAtUtc -or
            $null -ne $AuthorizedOperationId) {
        throw 'Closed delegated Registry completion must not carry an expiry or operation binding.'
    }

    $currentEnvironmentNames = @((Get-PrimaryContainer -ContainerApp $current).env |
        ForEach-Object { [string]$_.name })
    $settingsToRemove = @($staleSettingNames)
    $desiredDynamicSettingNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    if ($Enabled) {
        $null = $desiredDynamicSettingNames.Add($AdmissionExpirySettingName)
        if (-not [string]::IsNullOrWhiteSpace($AuthorizedExternalAgentId)) {
            $null = $desiredDynamicSettingNames.Add($AuthorizedExternalAgentIdSettingName)
        }
        if (-not [string]::IsNullOrWhiteSpace($AuthorizedRetryAgentId)) {
            $null = $desiredDynamicSettingNames.Add($AuthorizedRetryAgentIdSettingName)
        }
    }
    if ($DelegatedActionEnabled) {
        $null = $desiredDynamicSettingNames.Add($DelegatedRegistryActionExpirySettingName)
        $null = $desiredDynamicSettingNames.Add(
            $DelegatedRegistryAuthorizedOperationIdSettingName)
    }
    foreach ($dynamicSettingName in @(
            $AdmissionExpirySettingName,
            $AuthorizedExternalAgentIdSettingName,
            $AuthorizedRetryAgentIdSettingName,
            $DelegatedRegistryActionExpirySettingName,
            $DelegatedRegistryAuthorizedOperationIdSettingName)) {
        if ($currentEnvironmentNames -contains $dynamicSettingName -and
            -not $desiredDynamicSettingNames.Contains($dynamicSettingName)) {
            $settingsToRemove += $dynamicSettingName
        }
    }
    $settingsToRemove = @($settingsToRemove | Sort-Object -Unique)

    $arguments = @(
        'containerapp', 'update',
        '--name', $ApiContainerAppName,
        '--resource-group', $ResourceGroup,
        '--image', $Image,
        '--min-replicas', '1',
        '--max-replicas', '1'
    )
    if ($settingsToRemove.Count -gt 0) {
        $arguments += '--remove-env-vars'
        $arguments += $settingsToRemove
    }
    $arguments += @(
        '--set-env-vars',
        "ServiceBus__QueueName=$WorkflowV3QueueName",
        "Provisioning__ExecutionEnabled=$($Enabled.ToString().ToLowerInvariant())",
        "$RequireExactAdmissionBindingSettingName=true",
        "Agent365__DelegatedRegistry__Enabled=$($DelegatedActionEnabled.ToString().ToLowerInvariant())",
        "$RequireExactDelegatedActionBindingSettingName=true",
        'EntraId__ClientCredentials__0__SourceType=SignedAssertionFromManagedIdentity',
        'EntraId__ClientCredentials__0__TokenExchangeUrl=api://AzureADTokenExchange',
        'Agent365__DelegatedRegistry__Scopes__0=https://graph.microsoft.com/AgentRegistration.ReadWrite.All',
        'Agent365__DelegatedRegistry__Scopes__1=https://graph.microsoft.com/AgentRegistration.Read.All'
    )
    if ($Enabled) {
        $expiryValue = $AdmissionExpiresAtUtc.ToUniversalTime().ToString(
            'yyyy-MM-ddTHH:mm:ss.fffffffZ',
            [System.Globalization.CultureInfo]::InvariantCulture)
        $arguments += "$AdmissionExpirySettingName=$expiryValue"
        if (-not [string]::IsNullOrWhiteSpace($AuthorizedExternalAgentId)) {
            $arguments += "$AuthorizedExternalAgentIdSettingName=$AuthorizedExternalAgentId"
        }
        if (-not [string]::IsNullOrWhiteSpace($AuthorizedRetryAgentId)) {
            $arguments += "$AuthorizedRetryAgentIdSettingName=$AuthorizedRetryAgentId"
        }
    }
    if ($DelegatedActionEnabled) {
        $delegatedExpiryValue = $DelegatedActionExpiresAtUtc.ToUniversalTime().ToString(
            'yyyy-MM-ddTHH:mm:ss.fffffffZ',
            [System.Globalization.CultureInfo]::InvariantCulture)
        $arguments += "$DelegatedRegistryActionExpirySettingName=$delegatedExpiryValue"
        $arguments += "$DelegatedRegistryAuthorizedOperationIdSettingName=$(([guid]$AuthorizedOperationId).ToString('D'))"
    }
    $arguments += $managerEnvironmentArguments
    $arguments += @(
        '--revision-suffix', $RevisionSuffix
    )

    Invoke-AzNoOutput `
        -Arguments $arguments `
        -FailureMessage 'The scoped API revision update failed.'

    return Wait-ForRevision `
        -ContainerAppName $ApiContainerAppName `
        -PreviousRevisionName $previousRevision `
        -ExpectedImage $Image `
        -ExpectedMinimumReplicas 1
}

function Invoke-ExecutionPreflight {
    param(
        [Parameter(Mandatory = $true)][object]$Api,
        [switch]$RequireConfigurationMatch,
        [switch]$ExpectApiClosed,
        [switch]$ExpectDelegatedActionOpen,
        [string]$ExpectedAdmissionExpiresAtUtc = '',
        [string]$ExpectedAuthorizedExternalAgentId = '',
        [string]$ExpectedAuthorizedRetryAgentId = '',
        [string]$ExpectedDelegatedActionExpiresAtUtc = '',
        [string]$ExpectedAuthorizedOperationId = ''
    )

    $gatewayApiClientId = Get-EnvironmentValue `
        -ContainerApp $Api `
        -Name 'EntraId__ClientId'
    $parsedClientId = [guid]::Empty
    if (-not [guid]::TryParse($gatewayApiClientId, [ref]$parsedClientId) -or
        $parsedClientId -eq [guid]::Empty) {
        throw 'The deployed API application/client ID is missing or invalid.'
    }

    $parameters = @{
        Environment = $EnvironmentName
        ResourceGroup = $ResourceGroup
        ProjectName = $ProjectName
        ContainerAppsEnvironmentName = $ContainerAppsEnvironmentName
        WorkerContainerAppName = $WorkerContainerAppName
        ExpectedServiceBusQueueName = $WorkflowV3QueueName
        WorkerProcessingEnabled = $true
        ExpectedGatewayApiApplicationClientId = $parsedClientId.ToString('D')
        ExpectedManagerApplicationIds = @($ExpectedManagerApplicationIds |
            ForEach-Object { $_.ToString('D') })
        ExpectedGatewayApiFederatedCredentialName = $ExpectedGatewayApiFederatedCredentialName
        RegistryProvider = 'DirectRegistryPreview'
        DirectRegistryPreviewEnabled = $true
        DelegatedRegistryEnabled = $true
        RequireExecutionReady = $true
        ManagerApplicationsPreflightConfirmed = $true
        RequireDeployedConfigurationMatch = $RequireConfigurationMatch.IsPresent
        ExpectApiAdmissionClosed = $ExpectApiClosed.IsPresent
        ExpectDelegatedRegistryActionOpen = $ExpectDelegatedActionOpen.IsPresent
        ExpectedProvisioningAuthorizedExternalAgentId = $ExpectedAuthorizedExternalAgentId
        ExpectedProvisioningAuthorizedRetryAgentId = $ExpectedAuthorizedRetryAgentId
        ExpectedProvisioningAdmissionExpiresAtUtc = $ExpectedAdmissionExpiresAtUtc
        ExpectedDelegatedRegistryActionExpiresAtUtc = $ExpectedDelegatedActionExpiresAtUtc
        ExpectedDelegatedRegistryAuthorizedOperationId = $ExpectedAuthorizedOperationId
    }
    & $PreflightScript @parameters
}

function Assert-ActivationInputs {
    param([switch]$RequireInitialAdmissionDatabaseState)

    Assert-DigestPinnedImageInput -Image $ApiImage -Repository 'gateway-api'
    Assert-DigestPinnedImageInput -Image $WorkerImage -Repository 'gateway-worker'
    $null = @(ConvertTo-NormalizedManagerApplicationIds `
        -Values @($ExpectedManagerApplicationIds | ForEach-Object { $_.ToString('D') }) `
        -RequireNonEmpty `
        -InputLabel 'reviewed manager application ID input')
    $apiRegistry = $ApiImage.Split('/')[0]
    $workerRegistry = $WorkerImage.Split('/')[0]
    if (-not [string]::Equals(
        $apiRegistry,
        $workerRegistry,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'API and worker images must come from the same reviewed Azure Container Registry.'
    }

    if ($RequireInitialAdmissionDatabaseState) {
        $liveStateVerifiedAtUtc = Assert-DatabaseEvidence
        Assert-OperationalConfirmations `
            -ExpectedOutboxVerifiedAtUtc $liveStateVerifiedAtUtc
    }
}

function Assert-ActivationPrerequisites {
    param(
        [Parameter(Mandatory = $true)][object]$Resources,
        [Parameter(Mandatory = $true)][ValidateSet('Inert', 'Armed')]
        [string]$WorkerState,
        [switch]$RequireApiManagerConfiguration
    )

    $reviewedManagerApplicationIds = @($ExpectedManagerApplicationIds |
        ForEach-Object { $_.ToString('D') })
    Assert-ApiState `
        -Api $Resources.Api `
        -AdmissionEnabled $false `
        -ManagerApplicationIds $reviewedManagerApplicationIds `
        -RequireExpectedManagerApplications:$RequireApiManagerConfiguration `
        -AllowLegacyClosedConfiguration:($WorkerState -eq 'Inert' -and
            -not $RequireApiManagerConfiguration)
    Assert-WorkerState -Worker $Resources.Worker -State $WorkerState
    Assert-ManagerApplications `
        -ContainerApp $Resources.Worker `
        -ExpectedIds $reviewedManagerApplicationIds `
        -RequireExpectedMatch
    $queue = Assert-QueueBaseline
    $retainedWorkflowV2Queue = Assert-RetainedWorkflowV2QueueBaseline
    Assert-ReviewedCanaryFailureEvidence `
        -Worker $Resources.Worker `
        -Queue $retainedWorkflowV2Queue
    Assert-ExactQueueDataRoles `
        -Queue $queue `
        -Api $Resources.Api `
        -Worker $Resources.Worker
    Invoke-ExecutionPreflight `
        -Api $Resources.Api `
        -RequireConfigurationMatch:$RequireApiManagerConfiguration `
        -ExpectApiClosed
    Assert-HistoricalWorkerUnchanged
}

function Invoke-FailClosedRecovery {
    param([Parameter(Mandatory = $true)][string]$Reason)

    Write-Host "`n[RECOVERY] $Reason" -ForegroundColor Yellow
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $recoveryFailures = [System.Collections.Generic.List[string]]::new()

    try {
        $api = Get-ContainerApp -Name $ApiContainerAppName
        $apiImage = [string](Get-PrimaryContainer -ContainerApp $api).image
        $managerApplicationIds = @(
            if ($ExpectedManagerApplicationIds.Count -gt 0) {
                ConvertTo-NormalizedManagerApplicationIds `
                    -Values @($ExpectedManagerApplicationIds | ForEach-Object { $_.ToString('D') }) `
                    -InputLabel 'reviewed manager application ID input'
            }
            else {
                Get-ValidatedManagerApplicationIds -ContainerApp $api
            }
        )
        $closedApi = Set-ApiAdmission `
            -Enabled $false `
            -Image $apiImage `
            -ManagerApplicationIds $managerApplicationIds `
            -RevisionSuffix "failclosed-$timestamp"
        Assert-ApiState `
            -Api $closedApi `
            -AdmissionEnabled $false `
            -ExpectedImage $apiImage `
            -ManagerApplicationIds $managerApplicationIds `
            -RequireExpectedManagerApplications:($managerApplicationIds.Count -gt 0) `
            -RequireCanaryScale
        Wait-ApiHealth -Api $closedApi
    }
    catch {
        $recoveryFailures.Add('API admission could not be proven closed.')
    }

    try {
        $worker = Get-ContainerApp -Name $WorkerContainerAppName
        $workerImage = [string](Get-PrimaryContainer -ContainerApp $worker).image
        $inertWorker = Set-WorkerMode `
            -Armed $false `
            -Image $workerImage `
            -RevisionSuffix "inert-$timestamp"
        Assert-WorkerState `
            -Worker $inertWorker `
            -State 'Inert' `
            -ExpectedImage $workerImage `
            -RequireExactScale
    }
    catch {
        $recoveryFailures.Add('The new worker could not be proven inert.')
    }

    try {
        Assert-HistoricalWorkerUnchanged
    }
    catch {
        $recoveryFailures.Add('The historical worker could not be proven unchanged.')
    }

    if ($recoveryFailures.Count -gt 0) {
        foreach ($failure in $recoveryFailures) {
            Write-Host "[RECOVERY-FAIL] $failure" -ForegroundColor Red
        }
        throw 'Fail-closed recovery did not complete. Stop all canary work and inspect the fixed API/new worker read-only.'
    }

    Write-Pass 'API admission is closed and the new worker is inert.'
}

function Show-Status {
    $resources = Get-DeploymentResources
    $queue = Get-QueueRuntime
    $retainedWorkflowV2Queue = Get-RetainedWorkflowV2QueueRuntime
    $apiGate = Get-EnvironmentValue `
        -ContainerApp $resources.Api `
        -Name 'Provisioning__ExecutionEnabled'
    $workerProcessing = Get-EnvironmentValue `
        -ContainerApp $resources.Worker `
        -Name 'ProvisioningWorker__ProcessingEnabled'
    $workerExecution = Get-EnvironmentValue `
        -ContainerApp $resources.Worker `
        -Name 'ProvisioningWorker__ProvisioningExecutionEnabled'
    $registryProvider = Get-EnvironmentValue `
        -ContainerApp $resources.Worker `
        -Name 'Agent365__RegistryProvider'
    $delegatedRegistryGate = Get-EnvironmentValue `
        -ContainerApp $resources.Api `
        -Name 'Agent365__DelegatedRegistry__Enabled' `
        -AllowMissing
    $apiAdmissionExpiry = Get-EnvironmentValue `
        -ContainerApp $resources.Api `
        -Name $AdmissionExpirySettingName `
        -AllowMissing
    $authorizedExternalId = Get-EnvironmentValue `
        -ContainerApp $resources.Api `
        -Name $AuthorizedExternalAgentIdSettingName `
        -AllowMissing
    $authorizedRetryId = Get-EnvironmentValue `
        -ContainerApp $resources.Api `
        -Name $AuthorizedRetryAgentIdSettingName `
        -AllowMissing
    $delegatedActionExpiry = Get-EnvironmentValue `
        -ContainerApp $resources.Api `
        -Name $DelegatedRegistryActionExpirySettingName `
        -AllowMissing
    $delegatedOperationId = Get-EnvironmentValue `
        -ContainerApp $resources.Api `
        -Name $DelegatedRegistryAuthorizedOperationIdSettingName `
        -AllowMissing
    $apiDigestPinned = [string](Get-PrimaryContainer -ContainerApp $resources.Api).image -match '@sha256:[a-f0-9]{64}$'
    $workerDigestPinned = [string](Get-PrimaryContainer -ContainerApp $resources.Worker).image -match '@sha256:[a-f0-9]{64}$'

    Write-Host ''
    Write-Host 'Scoped development canary status (read-only)' -ForegroundColor Cyan
    Write-Host "API admission: $apiGate" -ForegroundColor White
    Write-Host "API admission expiry (UTC): $(if ([string]::IsNullOrWhiteSpace($apiAdmissionExpiry)) { 'none' } else { $apiAdmissionExpiry })" -ForegroundColor White
    Write-Host "API external-ID binding: $(if ([string]::IsNullOrWhiteSpace($authorizedExternalId)) { 'none' } else { $authorizedExternalId })" -ForegroundColor White
    Write-Host "API retry binding: $(if ([string]::IsNullOrWhiteSpace($authorizedRetryId)) { 'none' } else { $authorizedRetryId })" -ForegroundColor White
    Write-Host "Worker processing: $workerProcessing" -ForegroundColor White
    Write-Host "Worker provisioning: $workerExecution" -ForegroundColor White
    Write-Host "Registry provider: $registryProvider" -ForegroundColor White
    Write-Host "Delegated Registry action: $delegatedRegistryGate" -ForegroundColor White
    Write-Host "Delegated action expiry (UTC): $(if ([string]::IsNullOrWhiteSpace($delegatedActionExpiry)) { 'none' } else { $delegatedActionExpiry })" -ForegroundColor White
    Write-Host "Delegated operation binding: $(if ([string]::IsNullOrWhiteSpace($delegatedOperationId)) { 'none' } else { $delegatedOperationId })" -ForegroundColor White
    Write-Host "API digest pinned: $apiDigestPinned" -ForegroundColor White
    Write-Host "Worker digest pinned: $workerDigestPinned" -ForegroundColor White
    Write-Host "V3 queue active: $([long]$queue.countDetails.activeMessageCount)" -ForegroundColor White
    Write-Host "V3 queue scheduled: $([long]$queue.countDetails.scheduledMessageCount)" -ForegroundColor White
    Write-Host "V3 queue dead-lettered: $([long]$queue.countDetails.deadLetterMessageCount)" -ForegroundColor White
    Write-Host "Retained V2 queue active: $([long]$retainedWorkflowV2Queue.countDetails.activeMessageCount)" -ForegroundColor White
    Write-Host "Retained V2 queue scheduled: $([long]$retainedWorkflowV2Queue.countDetails.scheduledMessageCount)" -ForegroundColor White
    Write-Host "Retained V2 queue dead-lettered: $([long]$retainedWorkflowV2Queue.countDetails.deadLetterMessageCount)" -ForegroundColor White
    Write-Pass 'Historical worker remains on the legacy queue.'
}

try {
    Write-Stage 'Fixed development scope and Azure account'
    Assert-Subscription

    if ($Action -eq 'Status') {
        Show-Status
        exit 0
    }

    if ($Action -eq 'OpenAdmission') {
        $hasExternalBinding = -not [string]::IsNullOrWhiteSpace($AuthorizedExternalAgentId)
        $hasRetryBinding = $AuthorizedRetryAgentId -ne [guid]::Empty
        if ($hasExternalBinding -eq $hasRetryBinding) {
            throw 'OpenAdmission requires exactly one external-registration or retry registration binding.'
        }
        if ($hasExternalBinding -and
            $AuthorizedExternalAgentId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{2,127}$') {
            throw 'The external registration binding must match the public Gateway identifier contract.'
        }
        if ($AuthorizedOperationId -ne [guid]::Empty) {
            throw 'OpenAdmission cannot accept a delegated Registry operation binding.'
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($AuthorizedExternalAgentId) -or
        $AuthorizedRetryAgentId -ne [guid]::Empty) {
        throw 'Registration and retry bindings are valid only for OpenAdmission.'
    }

    if ($Action -eq 'OpenDelegatedCompletion') {
        if ($AuthorizedOperationId -eq [guid]::Empty) {
            throw 'OpenDelegatedCompletion requires one exact non-empty operation ID.'
        }
    }
    elseif ($AuthorizedOperationId -ne [guid]::Empty) {
        throw 'AuthorizedOperationId is valid only for OpenDelegatedCompletion.'
    }

    $resources = Get-DeploymentResources

    if ($Action -in @('Arm', 'OpenAdmission', 'OpenDelegatedCompletion')) {
        Write-Stage 'Activation evidence and immutable artifacts'
        Assert-ActivationInputs `
            -RequireInitialAdmissionDatabaseState:($Action -in @('Arm', 'OpenAdmission'))

        Write-Stage 'Read-only activation prerequisites'
        Assert-ActivationPrerequisites `
            -Resources $resources `
            -WorkerState $(if ($Action -eq 'Arm') { 'Inert' } else { 'Armed' }) `
            -RequireApiManagerConfiguration:($Action -ne 'Arm')
    }

    if ($WhatIfOnly) {
        Write-Host ''
        if ($Action -eq 'Arm') {
            Write-Note 'WhatIfOnly: the new worker would be deployed/armed first; the API would then be deployed with admission still closed.'
        }
        elseif ($Action -eq 'OpenAdmission') {
            $maximumExposureSeconds = [math]::Min(
                $MaximumAdmissionExposureSeconds,
                $RevisionDeploymentAllowanceSeconds + $AdmissionDurationSeconds)
            Write-Note "WhatIfOnly: API admission would receive a $RevisionDeploymentAllowanceSeconds-second revision-rollout allowance, then remain operator-open for at most $AdmissionDurationSeconds seconds; the API-enforced hard deadline is no more than $maximumExposureSeconds seconds from the update request."
        }
        elseif ($Action -eq 'OpenDelegatedCompletion') {
            Write-Note 'WhatIfOnly: registration admission would remain closed while delegated Registry completion opens for only the exact reviewed operation ID and a bounded independent expiry.'
        }
        else {
            Write-Note 'WhatIfOnly: API admission would close first; the new worker would then return inert.'
        }
        Write-Pass 'WhatIfOnly completed without Azure mutation.'
        exit 0
    }

    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    switch ($Action) {
        'Arm' {
            $reviewedManagerApplicationIds = @($ExpectedManagerApplicationIds |
                ForEach-Object { $_.ToString('D') } |
                Sort-Object)
            Write-Stage 'Deploy and arm the new worker while API admission remains closed'
            $armedWorker = Set-WorkerMode `
                -Armed $true `
                -Image $WorkerImage `
                -RevisionSuffix "canary-$timestamp"
            Assert-WorkerState `
                -Worker $armedWorker `
                -State 'Armed' `
                -ExpectedImage $WorkerImage `
                -RequireExactScale

            $apiStillClosed = Get-ContainerApp -Name $ApiContainerAppName
            Assert-ApiState `
                -Api $apiStillClosed `
                -AdmissionEnabled $false `
                -AllowLegacyClosedConfiguration
            Assert-HistoricalWorkerUnchanged

            Write-Stage 'Deploy the API after the worker, with admission still closed'
            $closedApi = Set-ApiAdmission `
                -Enabled $false `
                -Image $ApiImage `
                -ManagerApplicationIds $reviewedManagerApplicationIds `
                -RevisionSuffix "canaryclosed-$timestamp"
            Assert-ApiState `
                -Api $closedApi `
                -AdmissionEnabled $false `
                -ExpectedImage $ApiImage `
                -ManagerApplicationIds $reviewedManagerApplicationIds `
                -RequireExpectedManagerApplications `
                -RequireCanaryScale
            Wait-ApiHealth -Api $closedApi
            Invoke-ExecutionPreflight `
                -Api $closedApi `
                -RequireConfigurationMatch `
                -ExpectApiClosed
            $null = Assert-QueueBaseline
            $null = Assert-RetainedWorkflowV2QueueBaseline
            Assert-HistoricalWorkerUnchanged

            Write-Host ''
            Write-Pass 'Worker-first arm completed. API admission remains closed.'
            Write-Note 'Run OpenAdmission explicitly for the bounded registration window.'
        }

        'OpenAdmission' {
            $reviewedManagerApplicationIds = @($ExpectedManagerApplicationIds |
                ForEach-Object { $_.ToString('D') } |
                Sort-Object)
            Assert-ApiState `
                -Api $resources.Api `
                -AdmissionEnabled $false `
                -ExpectedImage $ApiImage `
                -ManagerApplicationIds $reviewedManagerApplicationIds `
                -RequireExpectedManagerApplications `
                -RequireCanaryScale
            Assert-WorkerState `
                -Worker $resources.Worker `
                -State 'Armed' `
                -ExpectedImage $WorkerImage `
                -RequireExactScale
            Invoke-ExecutionPreflight `
                -Api $resources.Api `
                -RequireConfigurationMatch `
                -ExpectApiClosed

            Write-Stage 'Open the explicitly bounded API admission window'
            $openedApi = $null
            $maximumExposureSeconds = [math]::Min(
                $MaximumAdmissionExposureSeconds,
                $RevisionDeploymentAllowanceSeconds + $AdmissionDurationSeconds)
            $admissionExpiresAtUtc = [datetimeoffset]::UtcNow.AddSeconds(
                $maximumExposureSeconds)
            $admissionExpiryValue = $admissionExpiresAtUtc.ToUniversalTime().ToString(
                'yyyy-MM-ddTHH:mm:ss.fffffffZ',
                [System.Globalization.CultureInfo]::InvariantCulture)
            try {
                $openedApi = Set-ApiAdmission `
                    -Enabled $true `
                    -Image $ApiImage `
                    -ManagerApplicationIds $reviewedManagerApplicationIds `
                    -RevisionSuffix "canaryopen-$timestamp" `
                    -AdmissionExpiresAtUtc $admissionExpiresAtUtc `
                    -AuthorizedExternalAgentId $AuthorizedExternalAgentId `
                    -AuthorizedRetryAgentId $(if ($AuthorizedRetryAgentId -eq [guid]::Empty) { '' } else { $AuthorizedRetryAgentId.ToString('D') })
                Assert-ApiState `
                    -Api $openedApi `
                    -AdmissionEnabled $true `
                    -ExpectedImage $ApiImage `
                    -ManagerApplicationIds $reviewedManagerApplicationIds `
                    -ExpectedAdmissionExpiresAtUtc $admissionExpiresAtUtc `
                    -ExpectedAuthorizedExternalAgentId $AuthorizedExternalAgentId `
                    -ExpectedAuthorizedRetryAgentId $(if ($AuthorizedRetryAgentId -eq [guid]::Empty) { '' } else { $AuthorizedRetryAgentId.ToString('D') }) `
                    -RequireExpectedManagerApplications `
                    -RequireCanaryScale
                Wait-ApiHealth -Api $openedApi
                Invoke-ExecutionPreflight `
                    -Api $openedApi `
                    -RequireConfigurationMatch `
                    -ExpectedAdmissionExpiresAtUtc $admissionExpiryValue `
                    -ExpectedAuthorizedExternalAgentId $AuthorizedExternalAgentId `
                    -ExpectedAuthorizedRetryAgentId $(if ($AuthorizedRetryAgentId -eq [guid]::Empty) { '' } else { $AuthorizedRetryAgentId.ToString('D') })

                $operatorDeadline = [datetimeoffset]::UtcNow.AddSeconds(
                    $AdmissionDurationSeconds)
                $deadline = if ($operatorDeadline -lt $admissionExpiresAtUtc) {
                    $operatorDeadline
                }
                else {
                    $admissionExpiresAtUtc
                }
                if ($deadline -le [datetimeoffset]::UtcNow) {
                    throw 'The API-enforced admission deadline was consumed before the operator window could begin.'
                }

                Write-Host "[WINDOW] Operator admission closes no later than $($deadline.ToString('O')); the API-enforced crash deadline is $($admissionExpiresAtUtc.ToString('O'))." -ForegroundColor Yellow
                while ([datetimeoffset]::UtcNow -lt $deadline) {
                    $remaining = [math]::Ceiling(
                        ($deadline - [datetimeoffset]::UtcNow).TotalSeconds)
                    Write-Progress `
                        -Activity 'Bounded development registration window' `
                        -Status "$remaining second(s) remaining" `
                        -PercentComplete (
                            100 - (($remaining / $AdmissionDurationSeconds) * 100))
                    Start-Sleep -Seconds ([math]::Min(5, [math]::Max(1, $remaining)))
                }
            }
            finally {
                Write-Progress -Activity 'Bounded development registration window' -Completed
                $apiForClose = Get-ContainerApp -Name $ApiContainerAppName
                $apiImageForClose = [string](Get-PrimaryContainer -ContainerApp $apiForClose).image
                $closedApi = Set-ApiAdmission `
                    -Enabled $false `
                    -Image $apiImageForClose `
                    -ManagerApplicationIds $reviewedManagerApplicationIds `
                    -RevisionSuffix "canaryclosed-$timestamp"
                Assert-ApiState `
                    -Api $closedApi `
                    -AdmissionEnabled $false `
                    -ExpectedImage $apiImageForClose `
                    -ManagerApplicationIds $reviewedManagerApplicationIds `
                    -RequireExpectedManagerApplications `
                    -RequireCanaryScale
                Wait-ApiHealth -Api $closedApi
            }

            $queueAfter = Get-QueueRuntime
            if ([long]$queueAfter.countDetails.deadLetterMessageCount -ne
                $ExpectedWorkflowV3DeadLetterCount) {
                throw "The workflow-v3 dead-letter count changed during the admission window; expected the clean baseline of $ExpectedWorkflowV3DeadLetterCount."
            }
            $null = Assert-RetainedWorkflowV2QueueBaseline
            Assert-HistoricalWorkerUnchanged
            Write-Host ''
            Write-Pass 'The bounded admission window closed and API admission is verified off.'
            Write-Note 'Leave the worker armed only while observing the one canary; run Deactivate afterward.'
        }

        'OpenDelegatedCompletion' {
            $reviewedManagerApplicationIds = @($ExpectedManagerApplicationIds |
                ForEach-Object { $_.ToString('D') } |
                Sort-Object)
            Assert-ApiState `
                -Api $resources.Api `
                -AdmissionEnabled $false `
                -ExpectedImage $ApiImage `
                -ManagerApplicationIds $reviewedManagerApplicationIds `
                -RequireExpectedManagerApplications `
                -RequireCanaryScale
            Assert-WorkerState `
                -Worker $resources.Worker `
                -State 'Armed' `
                -ExpectedImage $WorkerImage `
                -RequireExactScale
            Invoke-ExecutionPreflight `
                -Api $resources.Api `
                -RequireConfigurationMatch `
                -ExpectApiClosed

            Write-Stage 'Open the independently bounded delegated Registry completion window'
            $maximumExposureSeconds = [math]::Min(
                $MaximumAdmissionExposureSeconds,
                $RevisionDeploymentAllowanceSeconds + $AdmissionDurationSeconds)
            $delegatedActionExpiresAtUtc = [datetimeoffset]::UtcNow.AddSeconds(
                $maximumExposureSeconds)
            $delegatedActionExpiryValue =
                $delegatedActionExpiresAtUtc.ToUniversalTime().ToString(
                    'yyyy-MM-ddTHH:mm:ss.fffffffZ',
                    [System.Globalization.CultureInfo]::InvariantCulture)
            $authorizedOperationIdValue = $AuthorizedOperationId.ToString('D')
            try {
                $openedApi = Set-ApiAdmission `
                    -Enabled $false `
                    -DelegatedActionEnabled $true `
                    -Image $ApiImage `
                    -ManagerApplicationIds $reviewedManagerApplicationIds `
                    -RevisionSuffix "delegatedopen-$timestamp" `
                    -DelegatedActionExpiresAtUtc $delegatedActionExpiresAtUtc `
                    -AuthorizedOperationId $AuthorizedOperationId
                Assert-ApiState `
                    -Api $openedApi `
                    -AdmissionEnabled $false `
                    -DelegatedActionEnabled $true `
                    -ExpectedImage $ApiImage `
                    -ManagerApplicationIds $reviewedManagerApplicationIds `
                    -ExpectedDelegatedActionExpiresAtUtc $delegatedActionExpiresAtUtc `
                    -ExpectedAuthorizedOperationId $AuthorizedOperationId `
                    -RequireExpectedManagerApplications `
                    -RequireCanaryScale
                Wait-ApiHealth -Api $openedApi
                Invoke-ExecutionPreflight `
                    -Api $openedApi `
                    -RequireConfigurationMatch `
                    -ExpectApiClosed `
                    -ExpectDelegatedActionOpen `
                    -ExpectedDelegatedActionExpiresAtUtc $delegatedActionExpiryValue `
                    -ExpectedAuthorizedOperationId $authorizedOperationIdValue

                $operatorDeadline = [datetimeoffset]::UtcNow.AddSeconds(
                    $AdmissionDurationSeconds)
                $deadline = if ($operatorDeadline -lt $delegatedActionExpiresAtUtc) {
                    $operatorDeadline
                }
                else {
                    $delegatedActionExpiresAtUtc
                }
                if ($deadline -le [datetimeoffset]::UtcNow) {
                    throw 'The delegated action deadline was consumed before the operator window could begin.'
                }

                Write-Host "[WINDOW] Delegated completion closes no later than $($deadline.ToString('O')); the API-enforced crash deadline is $($delegatedActionExpiresAtUtc.ToString('O'))." -ForegroundColor Yellow
                while ([datetimeoffset]::UtcNow -lt $deadline) {
                    $remaining = [math]::Ceiling(
                        ($deadline - [datetimeoffset]::UtcNow).TotalSeconds)
                    Write-Progress `
                        -Activity 'Bounded delegated Registry completion window' `
                        -Status "$remaining second(s) remaining" `
                        -PercentComplete (
                            100 - (($remaining / $AdmissionDurationSeconds) * 100))
                    Start-Sleep -Seconds ([math]::Min(5, [math]::Max(1, $remaining)))
                }
            }
            finally {
                Write-Progress `
                    -Activity 'Bounded delegated Registry completion window' `
                    -Completed
                $apiForClose = Get-ContainerApp -Name $ApiContainerAppName
                $apiImageForClose =
                    [string](Get-PrimaryContainer -ContainerApp $apiForClose).image
                $closedApi = Set-ApiAdmission `
                    -Enabled $false `
                    -Image $apiImageForClose `
                    -ManagerApplicationIds $reviewedManagerApplicationIds `
                    -RevisionSuffix "delegatedclosed-$timestamp"
                Assert-ApiState `
                    -Api $closedApi `
                    -AdmissionEnabled $false `
                    -ExpectedImage $apiImageForClose `
                    -ManagerApplicationIds $reviewedManagerApplicationIds `
                    -RequireExpectedManagerApplications `
                    -RequireCanaryScale
                Wait-ApiHealth -Api $closedApi
            }

            $queueAfter = Get-QueueRuntime
            if ([long]$queueAfter.countDetails.deadLetterMessageCount -ne
                $ExpectedWorkflowV3DeadLetterCount) {
                throw "The workflow-v3 dead-letter count changed during the delegated action window; expected $ExpectedWorkflowV3DeadLetterCount."
            }
            $null = Assert-RetainedWorkflowV2QueueBaseline
            Assert-HistoricalWorkerUnchanged
            Write-Host ''
            Write-Pass 'The delegated completion window closed; registration and delegated API gates are verified off.'
            Write-Note 'Keep the worker armed only for final verification, then run Deactivate.'
        }

        'Deactivate' {
            Write-Stage 'Close API admission before stopping the new worker'
            $apiImageForClose = [string](Get-PrimaryContainer -ContainerApp $resources.Api).image
            $deployedManagerApplicationIds = @(
                Get-ValidatedManagerApplicationIds -ContainerApp $resources.Api)
            $closedApi = Set-ApiAdmission `
                -Enabled $false `
                -Image $apiImageForClose `
                -ManagerApplicationIds $deployedManagerApplicationIds `
                -RevisionSuffix "canaryclosed-$timestamp"
            Assert-ApiState `
                -Api $closedApi `
                -AdmissionEnabled $false `
                -ExpectedImage $apiImageForClose `
                -ManagerApplicationIds $deployedManagerApplicationIds `
                -RequireExpectedManagerApplications:($deployedManagerApplicationIds.Count -gt 0) `
                -RequireCanaryScale
            Wait-ApiHealth -Api $closedApi

            Write-Stage 'Return the new worker to its inert boundary'
            $workerImageForClose = [string](Get-PrimaryContainer -ContainerApp $resources.Worker).image
            $inertWorker = Set-WorkerMode `
                -Armed $false `
                -Image $workerImageForClose `
                -RevisionSuffix "inert-$timestamp"
            Assert-WorkerState `
                -Worker $inertWorker `
                -State 'Inert' `
                -ExpectedImage $workerImageForClose `
                -RequireExactScale
            Assert-HistoricalWorkerUnchanged

            Write-Host ''
            Write-Pass 'API admission is closed and the new worker is inert.'
        }
    }
}
catch {
    $failureType = $_.Exception.GetType().Name
    Write-Host "`n[STOP] $Action failed ($failureType). Review the secured command transcript and correlation evidence." -ForegroundColor Red

    if ($ResourcesValidated -and -not $WhatIfOnly -and $Action -ne 'Status') {
        try {
            Invoke-FailClosedRecovery -Reason 'A canary action failed after fixed-resource validation.'
        }
        catch {
            $recoveryFailureType = $_.Exception.GetType().Name
            Write-Host "[STOP] Fail-closed recovery also failed ($recoveryFailureType). Inspect the deployment state before any further action." -ForegroundColor Red
        }
    }
    else {
        Write-Host '[BOUNDARY] No Azure mutation was attempted.' -ForegroundColor Yellow
    }

    exit 1
}
