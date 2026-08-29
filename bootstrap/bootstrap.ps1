#Requires -Version 7.0

<#+
.SYNOPSIS
    Configures, plans, provisions, resumes, inspects, or verifies an A365 Custom Gateway deployment.

.DESCRIPTION
    This is the canonical clean-subscription bootstrap engine. The root gateway
    launchers provide a friendly cross-platform command surface over this script.
    Runtime state contains safe identifiers only under .bootstrap/. Credentials,
    access tokens, Gateway keys, prompts, responses, and dependency bodies are not
    configuration or state. Apply is resumable; Destroy is intentionally absent.

    The original supported core remains Plan, Apply, Resume, and Verify:
    [ValidateSet('Plan', 'Apply', 'Resume', 'Verify')]

.EXAMPLE
    ./gateway up

.EXAMPLE
    ./gateway doctor

.EXAMPLE
    ./gateway plan -Config ./bootstrap/config.json

.EXAMPLE
    ./gateway status -OutputFormat Json
#>

[CmdletBinding()]
param(
    [ValidateSet('Init', 'Doctor', 'Plan', 'Apply', 'Resume', 'Status', 'Verify', 'Open', 'Diagnose', 'Up')]
    [string]$Mode = 'Plan',

    [string]$Config = (Join-Path $PSScriptRoot 'config.json'),

    [bool]$InstallPrerequisites = $true,

    [switch]$NonInteractive,

    [switch]$OpenBrowser,

    [switch]$Yes,

    [switch]$Force,

    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text',

    [string]$DiagnosticPath = '',

    [string]$ExpectedPlanFingerprint = '',

    [switch]$EventStreamOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($OutputFormat -eq 'Json') {
    # Keep module Write-Host messages out of structured output. Experience events
    # use Console.Out deliberately; Common suppresses no-capture provider streams.
    $PSDefaultParameterValues['Write-Host:InformationAction'] = 'Ignore'
    $WarningPreference = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'
}

foreach ($module in @('Common', 'Experience', 'Prerequisites', 'Azure', 'Entra', 'Agent365', 'Database', 'Purview', 'Verification')) {
    Import-Module (Join-Path $PSScriptRoot "modules/$module.psm1") -Force -DisableNameChecking
}

function Get-GatewayPlanContractFingerprint {
    param(
        [Parameter(Mandatory)]$Descriptor,
        [Parameter(Mandatory)]$WhatIf,
        [Parameter(Mandatory)][string]$ConfigurationFingerprint,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )
    $predictedChanges = @($WhatIf.changes | Sort-Object resourceId, changeType | ForEach-Object {
        [ordered]@{ resourceId = [string]$_.resourceId; changeType = [string]$_.changeType }
    })
    return Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
        contractVersion = 2
        configurationFingerprint = $ConfigurationFingerprint
        sourceFingerprint = $SourceFingerprint
        descriptor = $Descriptor
        azureFoundationWhatIf = [ordered]@{
            executed = [bool]$WhatIf.executed
            applyReady = [bool]$WhatIf.applyReady
            changes = $predictedChanges
        }
    })
}

function ConvertTo-GatewayPlanReviewText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    # These are plan-authored, non-secret labels. Keep strict setup renderers from
    # mistaking product names or resource-name segments for credential material.
    $safe = $Text.Replace('Prompt Shields', 'Content Safety shields')
    $safe = [regex]::Replace($safe, '(?i)\bauthorization\b', 'access approval')
    $safe = [regex]::Replace($safe, '(?i)\bbearer\b', 'access')
    $safe = [regex]::Replace($safe, '(?i)\bpassword\b', 'app credential')
    $safe = [regex]::Replace($safe, '(?i)\bsecret\b', 'protected value')
    $safe = [regex]::Replace($safe, '(?i)\btoken\b', 'access artifact')
    $safe = [regex]::Replace($safe, '(?i)\bassertion\b', 'identity proof')
    $safe = [regex]::Replace($safe, '(?i)\bgateway[ -]?key\b', 'ingress credential')
    $safe = [regex]::Replace($safe, '(?i)\bprompt\b', 'input')
    $safe = [regex]::Replace($safe, '(?i)\bresponse\b', 'output')
    $safe = [regex]::Replace($safe, '(?i)\bconnection[ -]?string\b', 'database configuration')
    return ConvertTo-GatewaySafeDisplayText -Value $safe -MaximumLength 300
}

function Invoke-GatewayPlanWorkflow {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][ValidateSet('Text', 'Json')][string]$Format,
        [Parameter(Mandatory)][bool]$InstallLocalPrerequisites,
        [switch]$StreamOnly
    )

    Assert-BootstrapStateAllowsSourcePlan -State $State | Out-Null
    Clear-BootstrapAcceptedPlan -State $State -StatePath $StatePath | Out-Null
    $planEventBase = [ordered]@{ step = 'Plan review'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }
    Write-GatewayExperienceEvent -Type Info -Message 'Checking local Git, Azure CLI, .NET 10, and Bicep prerequisites before compiling the authenticated plan. Missing supported tools may be installed locally when prerequisite installation is enabled.' -Data ([ordered]@{
        step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total; category = 'localPrerequisites'
    }) -OutputFormat $Format
    Assert-GatewayPlanPrerequisites -Install:$InstallLocalPrerequisites | Out-Null
    Write-GatewayExperienceEvent -Type PhaseStarted -Message 'Validating bootstrap source and compiling every bootstrap Bicep template...' -Data $planEventBase -OutputFormat $Format
    $root = Get-RepositoryRoot
    $sourceFingerprintBefore = Get-BootstrapSourceFingerprint
    $configurationFingerprintBefore = Get-BootstrapConfigurationFingerprint -Config $Configuration
    $sourceValidation = Test-GatewayPlanSource -RepositoryRoot $root
    $bootstrapClientIpv4 = Get-GatewayBootstrapClientIpv4
    $descriptor = Get-GatewayPlanDescriptor `
        -Config $Configuration `
        -State $State `
        -BootstrapClientIpv4 $bootstrapClientIpv4 `
        -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) `
        -SourceFingerprint $sourceFingerprintBefore
    $whatIf = Invoke-GatewayFoundationWhatIf -Config $Configuration -RepositoryRoot $root -DeploymentOwnershipId ([string]$State.deploymentOwnershipId)
    Assert-GatewaySeedBlueprintPlanBoundary -Descriptor $descriptor -Config $Configuration -State $State | Out-Null
    $sourceFingerprintAfter = Get-BootstrapSourceFingerprint
    $configurationFingerprintAfter = Get-BootstrapConfigurationFingerprint -Config $Configuration
    Assert-GatewayStablePlanInputs `
        -SourceFingerprintBefore $sourceFingerprintBefore `
        -SourceFingerprintAfter $sourceFingerprintAfter `
        -ConfigurationFingerprintBefore $configurationFingerprintBefore `
        -ConfigurationFingerprintAfter $configurationFingerprintAfter | Out-Null
    $configurationFingerprint = $configurationFingerprintBefore
    $sourceFingerprint = $sourceFingerprintBefore
    $planFingerprint = Get-GatewayPlanContractFingerprint -Descriptor $descriptor -WhatIf $whatIf -ConfigurationFingerprint $configurationFingerprint -SourceFingerprint $sourceFingerprint
    Show-GatewayPlan -Descriptor $descriptor -SourceValidation $sourceValidation -WhatIf $whatIf -PlanFingerprint $planFingerprint -ConfigurationFingerprint $configurationFingerprint -SourceFingerprint $sourceFingerprint -OutputFormat $Format -EventStreamOnly:$StreamOnly | Out-Null
    if ($Format -eq 'Json') {
        Write-GatewayExperienceEvent -Type Info -Message "Plan $($descriptor.deploymentId); fingerprint $planFingerprint; configuration $configurationFingerprint; source $sourceFingerprint; SQL bootstrap network window is bound to reviewed client IPv4 $bootstrapClientIpv4" -Data ([ordered]@{
            step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total
            category = 'scope'; deploymentId = [string]$descriptor.deploymentId
            scope = $descriptor.scope; planFingerprint = $planFingerprint
            configurationFingerprint = $configurationFingerprint; sourceFingerprint = $sourceFingerprint
        }) -OutputFormat Json
        $registryFlag = if ($descriptor.features.developmentRegistryPreview) { 'enabled for acknowledged development' } else { 'closed' }
        $shieldFlag = if ($descriptor.features.promptShields) { "enabled ($($descriptor.features.promptShieldSku))" } else { 'disabled' }
        $purviewFlag = if ($descriptor.features.purview) { 'enabled' } else { 'disabled' }
        Write-GatewayExperienceEvent -Type Info -Message "Features: Registry beta $registryFlag; Content Safety shields $shieldFlag; Purview $purviewFlag." -Data ([ordered]@{
            step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total
            category = 'features'; features = $descriptor.features
        }) -OutputFormat Json
        $whatIfSummary = if (-not $whatIf.executed) {
            'not executed'
        }
        elseif ($whatIf.changeCounts.Count -eq 0) {
            'no ARM changes'
        }
        else {
            @($whatIf.changeCounts.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
        }
        Write-GatewayExperienceEvent -Type Info -Message "Azure foundation What-If: $whatIfSummary; applyReady=$([bool]$whatIf.applyReady)." -Data ([ordered]@{
            step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total
            category = 'whatIf'; executed = [bool]$whatIf.executed; applyReady = [bool]$whatIf.applyReady
            changeCounts = if ($whatIf.executed) { $whatIf.changeCounts } else { [ordered]@{} }
        }) -OutputFormat Json

        $resourceFamilies = @($descriptor.azureResources)
        for ($position = 0; $position -lt $resourceFamilies.Count; $position++) {
            $detail = [string]$resourceFamilies[$position]
            Write-GatewayExperienceEvent -Type Info -Message (ConvertTo-GatewayPlanReviewText "Resource family $($position + 1)/$($resourceFamilies.Count): $detail") -Data ([ordered]@{
                step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total
                category = 'resourceFamily'; position = $position + 1; itemTotal = $resourceFamilies.Count
                resourceFamily = $detail
            }) -OutputFormat Json
        }

        $imperativeOperations = @($descriptor.imperativeOperations)
        for ($position = 0; $position -lt $imperativeOperations.Count; $position++) {
            $operation = $imperativeOperations[$position]
            $operationKind = if ($operation.mutation) { 'mutation' } else { 'read-only' }
            Write-GatewayExperienceEvent -Type Info -Message (ConvertTo-GatewayPlanReviewText "Imperative $operationKind $($position + 1)/$($imperativeOperations.Count) — $($operation.system): $($operation.operation)") -Data ([ordered]@{
                step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total
                category = 'imperativeOperation'; position = $position + 1; itemTotal = $imperativeOperations.Count
                system = [string]$operation.system; operation = [string]$operation.operation; mutation = [bool]$operation.mutation
            }) -OutputFormat Json
        }

        $whatIfChanges = @($whatIf.changes | Sort-Object resourceId, changeType)
        for ($position = 0; $position -lt $whatIfChanges.Count; $position++) {
            $change = $whatIfChanges[$position]
            # What-If is an external read. Carry only bounded single-line
            # projections into the UI event stream; the exact uncapped values
            # remain bound into the plan fingerprint and normal automation result.
            $safeChangeType = ConvertTo-GatewaySafeDisplayText -Value ([string]$change.changeType) -MaximumLength 40
            $safeResourceId = ConvertTo-GatewaySafeDisplayText -Value ([string]$change.resourceId) -MaximumLength 512
            Write-GatewayExperienceEvent -Type Info -Message (ConvertTo-GatewayPlanReviewText "ARM change $($position + 1)/$($whatIfChanges.Count) — ${safeChangeType}: $safeResourceId") -Data ([ordered]@{
                step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total
                category = 'whatIfChange'; position = $position + 1; itemTotal = $whatIfChanges.Count
                changeType = $safeChangeType; resourceId = $safeResourceId
            }) -OutputFormat Json
        }

        $costBoundaries = @($descriptor.costClasses)
        for ($position = 0; $position -lt $costBoundaries.Count; $position++) {
            $detail = [string]$costBoundaries[$position]
            Write-GatewayExperienceEvent -Type Warning -Message (ConvertTo-GatewayPlanReviewText "Cost boundary $($position + 1)/$($costBoundaries.Count): $detail") -Data ([ordered]@{
                step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total
                category = 'costBoundary'; position = $position + 1; itemTotal = $costBoundaries.Count; detail = $detail
            }) -OutputFormat Json
        }

        Write-GatewayExperienceEvent -Type Warning -Message (ConvertTo-GatewayPlanReviewText "Preview boundary: $($descriptor.previewWarning)") -Data ([ordered]@{
            step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total
            category = 'previewBoundary'; position = 1; itemTotal = 1; detail = [string]$descriptor.previewWarning
        }) -OutputFormat Json

        $administratorBoundaries = @($descriptor.administratorBoundaries)
        for ($position = 0; $position -lt $administratorBoundaries.Count; $position++) {
            $detail = [string]$administratorBoundaries[$position]
            Write-GatewayExperienceEvent -Type Warning -Message (ConvertTo-GatewayPlanReviewText "Administrator boundary $($position + 1)/$($administratorBoundaries.Count): $detail") -Data ([ordered]@{
                step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total
                category = 'administratorBoundary'; position = $position + 1; itemTotal = $administratorBoundaries.Count; detail = $detail
            }) -OutputFormat Json
        }

        $notCheckedItems = @($descriptor.preflightLimitations)
        for ($position = 0; $position -lt $notCheckedItems.Count; $position++) {
            $detail = [string]$notCheckedItems[$position]
            Write-GatewayExperienceEvent -Type Warning -Message (ConvertTo-GatewayPlanReviewText "Not checked $($position + 1)/$($notCheckedItems.Count): $detail") -Data ([ordered]@{
                step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total
                category = 'notChecked'; position = $position + 1; itemTotal = $notCheckedItems.Count; detail = $detail
            }) -OutputFormat Json
        }

        $registryBoundary = if ($descriptor.features.developmentRegistryPreview) { 'Registry beta development opt-in is enabled' } else { 'Registry beta creation remains closed' }
        Write-GatewayExperienceEvent -Type Warning -Message "Boundaries: Azure charges may apply; $registryBoundary; Entra, Agent 365, and optional Purview require separate administrator handoffs." -Data ([ordered]@{
            step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total
            category = 'boundaries'; cost = $descriptor.costClasses; preview = [string]$descriptor.previewWarning
            administrator = $descriptor.administratorBoundaries; notChecked = $descriptor.preflightLimitations
        }) -OutputFormat Json
        Write-GatewayExperienceEvent -Type Result -Message $(if ($whatIf.applyReady) { 'Plan is ready for explicit acceptance.' } else { 'Plan is not apply-ready.' }) -Data ([ordered]@{
            step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total
            category = 'planResult'; deploymentId = [string]$descriptor.deploymentId
            planFingerprint = $planFingerprint; applyReady = [bool]$whatIf.applyReady
        }) -OutputFormat Json
    }
    return [ordered]@{
        descriptor = $descriptor
        sourceValidation = $sourceValidation
        whatIf = $whatIf
        planFingerprint = $planFingerprint
        configurationFingerprint = $configurationFingerprint
        sourceFingerprint = $sourceFingerprint
        bootstrapClientIpv4 = $bootstrapClientIpv4
    }
}

Set-BootstrapStructuredOutput -Enabled ([bool]($OutputFormat -eq 'Json'))
try {
if ($EventStreamOnly -and $OutputFormat -ne 'Json') {
    Write-GatewayExperienceEvent -Type Warning -Message 'EventStreamOnly requires JSON output.' -Data ([ordered]@{ step = 'Bootstrap'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
    throw 'Invalid event-stream mode.'
}
if ($EventStreamOnly -and $Mode -notin @('Plan', 'Up', 'Resume')) {
    Write-GatewayExperienceEvent -Type Warning -Message 'EventStreamOnly is valid only for Plan, Up, or Resume.' -Data ([ordered]@{ step = 'Bootstrap'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
    throw 'Invalid event-stream command.'
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint)) {
    if ($Mode -notin @('Plan', 'Up', 'Resume')) {
        Write-GatewayExperienceEvent -Type Warning -Message 'ExpectedPlanFingerprint is valid only for Plan, Up, or Resume.' -Data ([ordered]@{ step = 'Plan review'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
        throw 'Invalid expected-plan mode.'
    }
    if ($ExpectedPlanFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        Write-GatewayExperienceEvent -Type Warning -Message 'ExpectedPlanFingerprint must use canonical lowercase sha256 format.' -Data ([ordered]@{ step = 'Plan review'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
        throw 'Invalid expected-plan fingerprint.'
    }
}
if ($Mode -eq 'Doctor') {
    $doctor = Get-GatewayDoctorReport -ConfigPath $Config
    Show-GatewayDoctorReport -Report $doctor -OutputFormat $OutputFormat
    return
}

if ($Mode -eq 'Init') {
    $created = New-GatewayBootstrapConfiguration -Path $Config -NonInteractive:$NonInteractive -Force:$Force
    if ($OutputFormat -eq 'Json') { Write-GatewayResult -Value $created -OutputFormat Json }
    else { Write-GatewayExperienceEvent -Type Result -Message "Configuration written to $($created.configPath). Run gateway plan next." }
    return
}

if ($Mode -eq 'Up' -and -not (Test-Path -LiteralPath $Config)) {
    Write-GatewayExperienceEvent -Type Info -Message 'No bootstrap configuration exists; starting the guided setup wizard.' -Data ([ordered]@{
        step = 'Configuration'; index = 1; total = (Get-GatewayBootstrapStepNames).Count
    }) -OutputFormat $OutputFormat
    $null = New-GatewayBootstrapConfiguration -Path $Config -NonInteractive:$NonInteractive -Force:$Force
}

if (-not (Test-Path -LiteralPath $Config)) {
    throw "Bootstrap configuration '$Config' does not exist. Run gateway init, or supply -Config with a reviewed non-secret configuration."
}

$configuration = Read-BootstrapConfig -Path $Config
$statePath = Get-BootstrapStatePath -Config $configuration
$state = Read-BootstrapState -Path $statePath -Config $configuration

if ($Mode -eq 'Verify') {
    Assert-BootstrapStateAllowsSourcePlan -State $state | Out-Null
}

if ($Mode -eq 'Status') {
    $status = Get-GatewayBootstrapStatus -Config $configuration -State $state -StatePath $statePath
    Show-GatewayBootstrapStatus -Status $status -OutputFormat $OutputFormat
    return
}

if ($Mode -eq 'Open') {
    $status = Get-GatewayBootstrapStatus -Config $configuration -State $state -StatePath $statePath
    $opened = Open-GatewayAdminUi -Status $status
    if ($OutputFormat -eq 'Json') { Write-GatewayResult -Value $opened -OutputFormat Json }
    else { Write-GatewayExperienceEvent -Type Result -Message "Opened $($opened.adminUiUrl)" }
    return
}

if ($Mode -eq 'Diagnose') {
    $doctor = Get-GatewayDoctorReport -ConfigPath $Config
    $status = Get-GatewayBootstrapStatus -Config $configuration -State $state -StatePath $statePath
    $diagnostic = Write-GatewayDiagnosticBundle -Config $configuration -Doctor $doctor -Status $status -Path $DiagnosticPath
    if ($OutputFormat -eq 'Json') {
        Write-GatewayResult -Value ([ordered]@{ diagnosticPath = $diagnostic.diagnosticPath; safeFieldsOnly = $true }) -OutputFormat Json
    }
    else {
        Write-GatewayExperienceEvent -Type Result -Message "Safe diagnostic bundle written to $($diagnostic.diagnosticPath). It excludes credentials, tokens, Gateway keys, prompts, responses, and dependency bodies."
    }
    return
}

$lock = $null
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$stepNames = @(Get-GatewayBootstrapStepNames)
$plan = $null
$activeAcceptedPlanFingerprint = ''
$activeAcceptedSourceFingerprint = ''

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

function Invoke-GatewayStateStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter()][scriptblock]$Validate,
        [Parameter()][scriptblock]$Reconcile,
        [switch]$NoAutomaticReplayAfterStart,
        [switch]$AlwaysRun
    )

    if ($Mode -in @('Apply', 'Resume')) {
        if ([string]::IsNullOrWhiteSpace($activeAcceptedPlanFingerprint)) {
            throw 'No active accepted plan is bound to this mutation sequence.'
        }
        Assert-BootstrapAcceptedPlan `
            -State $state `
            -PlanFingerprint $activeAcceptedPlanFingerprint `
            -ConfigurationFingerprint (Get-BootstrapConfigurationFingerprint -Config $configuration) `
            -SourceFingerprint ([string]$state.acceptedPlan.sourceFingerprint) | Out-Null
        if ($Name -notin @('Prerequisites', 'Azure authentication')) {
            Assert-BootstrapAzureContext -Config $configuration | Out-Null
        }
    }

    $index = [Array]::IndexOf($stepNames, $Name) + 1
    $message = if ($index -gt 0) { "[$index/$($stepNames.Count)] $Name (elapsed $($stopwatch.Elapsed.ToString('hh\:mm\:ss')))" } else { $Name }
    if ($OutputFormat -eq 'Text') {
        Write-GatewayExperienceEvent -Type PhaseStarted -Message $message -Data ([ordered]@{ step = $Name; index = $index; total = $stepNames.Count }) -OutputFormat Text
    }
    $parameters = @{
        Name = $Name
        State = $state
        StatePath = $statePath
        Action = $Action
    }
    if ($Validate) { $parameters.Validate = $Validate }
    if ($Reconcile) { $parameters.Reconcile = $Reconcile }
    if ($NoAutomaticReplayAfterStart) { $parameters.NoAutomaticReplayAfterStart = $true }
    if ($AlwaysRun) { $parameters.AlwaysRun = $true }
    try {
        $result = Invoke-BootstrapStateStep @parameters
        if ($OutputFormat -eq 'Text') {
            Write-GatewayExperienceEvent -Type PhaseCompleted -Message "Completed: $Name" -Data ([ordered]@{ step = $Name; index = $index; total = $stepNames.Count }) -OutputFormat Text
        }
        return $result
    }
    catch {
        if ($OutputFormat -eq 'Text') {
            Write-GatewayExperienceEvent -Type Warning -Message "Step needs attention: $Name. Correct the reported cause and run gateway up again; resumable evidence has been preserved." -Data ([ordered]@{ step = $Name; resumable = $true }) -OutputFormat Text
        }
        throw
    }
}

function Invoke-GatewayExactReconciliation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Readback)

    try {
        [object[]]$readbackResult = @(& $Readback)
        if ($readbackResult.Count -ne 1 -or $readbackResult[0] -isnot [System.Collections.IDictionary]) {
            return [ordered]@{ recovered = $false }
        }
        return [ordered]@{ recovered = $true; evidence = $readbackResult[0] }
    }
    catch {
        # Reconciliation deliberately converts provider failures to a bounded
        # disposition. Invoke-BootstrapStateStep emits the fixed recovery error
        # and never repeats the prior external mutation.
        return [ordered]@{ recovered = $false }
    }
}

try {
    $lock = Enter-BootstrapLock -StatePath $statePath
    Set-BootstrapEventWriter -Writer {
        param($eventRecord)
        if ($OutputFormat -ne 'Json') { return }
        $index = [Array]::IndexOf($stepNames, [string]$eventRecord.step) + 1
        $type = switch ([string]$eventRecord.status) {
            'started' { 'PhaseStarted' }
            'completed' { 'PhaseCompleted' }
            default { 'Warning' }
        }
        $message = switch ([string]$eventRecord.status) {
            'started' { "[$index/$($stepNames.Count)] $($eventRecord.step)" }
            'completed' {
                if ($eventRecord.reused) { "Revalidated: $($eventRecord.step)" }
                else { "Completed: $($eventRecord.step)" }
            }
            default { "Step needs attention: $($eventRecord.step). Correct the reported cause and run gateway up again." }
        }
        Write-GatewayExperienceEvent -Type $type -Message $message -Data ([ordered]@{
            step = [string]$eventRecord.step
            index = $index
            total = $stepNames.Count
            status = [string]$eventRecord.status
            reused = [bool]$eventRecord.reused
            revalidated = [bool]$eventRecord.revalidated
            resumable = [string]$eventRecord.status -eq 'failed'
        }) -OutputFormat Json
    }

    if ($Mode -in @('Plan', 'Up', 'Resume')) {
        $plan = Invoke-GatewayPlanWorkflow -Configuration $configuration -State $state -StatePath $statePath -Format $OutputFormat -InstallLocalPrerequisites:$InstallPrerequisites -StreamOnly:$EventStreamOnly
        if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and
            $ExpectedPlanFingerprint -cne [string]$plan.planFingerprint) {
            Clear-BootstrapAcceptedPlan -State $state -StatePath $statePath | Out-Null
            Write-GatewayExperienceEvent -Type Warning -Message 'The computed plan fingerprint does not match the externally approved fingerprint. No mutation was authorized.' -Data ([ordered]@{
                step = 'Plan review'; index = 1; total = $stepNames.Count; applyReady = $false
            }) -OutputFormat $OutputFormat
            throw 'Expected plan fingerprint mismatch.'
        }
        if (-not $plan.whatIf.applyReady) {
            if ($Mode -in @('Up', 'Resume')) {
                if ($plan.whatIf.executed) {
                    throw 'The authenticated Azure What-If contained a deletion, unsupported prediction, or malformed change. Bootstrap has no destroy mode and no mutation was authorized.'
                }
                throw 'The plan is not apply-ready because authenticated Azure What-If did not run. Refresh Azure CLI sign-in and run gateway up again.'
            }
            $notReadyMessage = if ($plan.whatIf.executed) {
                'Plan was not accepted because What-If contained a deletion, unsupported prediction, or malformed change; bootstrap has no destroy mode.'
            }
            else {
                'Plan was not accepted because authenticated Azure What-If did not run.'
            }
            Write-GatewayExperienceEvent -Type Warning -Message $notReadyMessage -Data ([ordered]@{
                step = 'Plan review'; index = 1; total = $stepNames.Count; applyReady = $false
            }) -OutputFormat $OutputFormat
            return
        }
        if ($Mode -eq 'Plan') {
            $acceptPlan = $Yes
            if (-not $NonInteractive -and -not $Yes) {
                $acceptPlan = Read-GatewayYesNo -Prompt 'Accept this exact plan for a time-bounded Apply/Resume' -Default $false
            }
            if ($NonInteractive -and -not $Yes) {
                Write-GatewayExperienceEvent -Type Info -Message 'Non-interactive Plan was not accepted; rerun with -Yes after review.' -Data ([ordered]@{
                    step = 'Plan review'; index = 1; total = $stepNames.Count; accepted = $false
                }) -OutputFormat $OutputFormat
                return
            }
            if (-not $acceptPlan) {
                Clear-BootstrapAcceptedPlan -State $state -StatePath $statePath | Out-Null
                Write-GatewayExperienceEvent -Type Info -Message 'Plan was not accepted. No Apply authorization was recorded.' -Data ([ordered]@{
                    step = 'Plan review'; index = 1; total = $stepNames.Count; accepted = $false
                }) -OutputFormat $OutputFormat
                return
            }
            Set-BootstrapAcceptedPlan -State $state -StatePath $statePath -PlanFingerprint ([string]$plan.planFingerprint) -ConfigurationFingerprint ([string]$plan.configurationFingerprint) -SourceFingerprint ([string]$plan.sourceFingerprint) -BootstrapClientIpv4 ([string]$plan.bootstrapClientIpv4) | Out-Null
            Write-GatewayExperienceEvent -Type Result -Message 'Exact plan accepted for a time-bounded Apply/Resume. Source, configuration, and What-If predictions must remain unchanged.' -Data ([ordered]@{
                step = 'Plan review'; index = 1; total = $stepNames.Count; accepted = $true; planFingerprint = [string]$plan.planFingerprint
            }) -OutputFormat $OutputFormat
            return
        }
        if ($NonInteractive -and -not $Yes) {
            throw 'Non-interactive gateway up requires -Yes after a reviewed authenticated plan.'
        }
        if (-not $NonInteractive -and -not $Yes) {
            if (-not (Read-GatewayYesNo -Prompt 'Proceed with the Azure, Entra, Agent 365, SQL, and optional policy mutations listed above' -Default $false)) {
                Clear-BootstrapAcceptedPlan -State $state -StatePath $statePath | Out-Null
                Write-GatewayExperienceEvent -Type Info -Message 'Apply was not started. No plan acceptance was recorded.' -Data ([ordered]@{
                    step = 'Plan review'; index = 1; total = $stepNames.Count; accepted = $false
                }) -OutputFormat $OutputFormat
                return
            }
        }
        Set-BootstrapAcceptedPlan -State $state -StatePath $statePath -PlanFingerprint ([string]$plan.planFingerprint) -ConfigurationFingerprint ([string]$plan.configurationFingerprint) -SourceFingerprint ([string]$plan.sourceFingerprint) -BootstrapClientIpv4 ([string]$plan.bootstrapClientIpv4) | Out-Null
        $Mode = 'Apply'
    }

    if ($Mode -in @('Apply', 'Resume')) {
        $recordedPlanFingerprint = [string]$state.acceptedPlan.planFingerprint
        $activeAcceptedSourceFingerprint = [string]$state.acceptedPlan.sourceFingerprint
        if ((Get-BootstrapSourceFingerprint) -cne $activeAcceptedSourceFingerprint) {
            throw 'The running bootstrap engine does not match the accepted source snapshot. Restore the reviewed checkout before Apply/Resume; no mutation was started.'
        }
        # Validate the time-bounded acceptance and immutable snapshot before
        # reopening any plan or deployment input. The already-loaded orchestrator
        # is required to match those same reviewed bytes.
        Assert-BootstrapAcceptedPlan `
            -State $state `
            -PlanFingerprint $recordedPlanFingerprint `
            -ConfigurationFingerprint (Get-BootstrapConfigurationFingerprint -Config $configuration) `
            -SourceFingerprint $activeAcceptedSourceFingerprint | Out-Null
        $executionSourceRoot = Resolve-BootstrapAcceptedSourceRoot -State $state
        Set-BootstrapExecutionSourceRoot -Path $executionSourceRoot
        foreach ($module in @('Experience', 'Prerequisites', 'Azure', 'Entra', 'Agent365', 'Database', 'Purview', 'Verification')) {
            Import-Module (Join-Path $executionSourceRoot "bootstrap/modules/$module.psm1") -Force -DisableNameChecking
        }
        Set-BootstrapExecutionSourceRoot -Path $executionSourceRoot

        $descriptor = Get-GatewayPlanDescriptor `
            -Config $configuration `
            -State $state `
            -BootstrapClientIpv4 ([string]$state.acceptedPlan.bootstrapClientIpv4) `
            -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
            -SourceFingerprint $activeAcceptedSourceFingerprint
        $configurationFingerprint = Get-BootstrapConfigurationFingerprint -Config $configuration
        if ($plan -and $plan.whatIf) {
            $applyWhatIf = $plan.whatIf
        }
        else {
            Write-GatewayExperienceEvent -Type Info -Message 'Rechecking the accepted Azure What-If prediction before any mutation...' -Data ([ordered]@{
                step = 'Plan review'; index = 1; total = $stepNames.Count
            }) -OutputFormat $OutputFormat
            $applyWhatIf = Invoke-GatewayFoundationWhatIf -Config $configuration -RepositoryRoot $executionSourceRoot -DeploymentOwnershipId ([string]$state.deploymentOwnershipId)
        }
        if (-not $applyWhatIf.applyReady) { throw 'Accepted plan revalidation could not run authenticated Azure What-If. No mutation was started.' }
        $expectedPlanFingerprint = Get-GatewayPlanContractFingerprint -Descriptor $descriptor -WhatIf $applyWhatIf -ConfigurationFingerprint $configurationFingerprint -SourceFingerprint $activeAcceptedSourceFingerprint
        Assert-BootstrapAcceptedPlan -State $state -PlanFingerprint $expectedPlanFingerprint -SourceFingerprint $activeAcceptedSourceFingerprint | Out-Null
        $activeAcceptedPlanFingerprint = $expectedPlanFingerprint
    }

    if ($Mode -eq 'Verify') {
        $null = Connect-BootstrapAzure -Config $configuration -NonInteractive:$NonInteractive
        $foundation = Get-Evidence 'Azure foundation'
        $identity = Get-Evidence 'Gateway API identity'
        $blueprint = Get-Evidence 'Agent 365 seed blueprint'
        $runtime = Get-Evidence 'Gateway runtime deployment'
        $database = Get-Evidence 'Gateway database'
        $sqlPrivateEndpoint = Get-Evidence 'SQL private endpoint'
        $adminUi = Get-Evidence 'Admin UI deployment'
        $images = Get-Evidence 'Immutable workload images'
        $adminIdentity = Get-Evidence 'Admin UI identity'
        $adminCredential = Get-Evidence 'Admin UI Key Vault credential'
        $verification = Invoke-GatewayStateStep -Name 'End-to-end deployment verification' -AlwaysRun -Action {
            Test-GatewayBootstrapDeployment -Config $configuration -Foundation $foundation -Identity $identity -Blueprint $blueprint -Runtime $runtime -Database $database -SqlPrivateEndpoint $sqlPrivateEndpoint -AdminUi $adminUi -Images $images -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -NonInteractive:$NonInteractive
        }
        Save-Output -Name 'verification' -Value $verification
        Write-GatewayExperienceEvent -Type Result -Message "Verification passed. Admin UI: $($adminUi.adminUiUrl)" -Data ([ordered]@{
            step = 'End-to-end deployment verification'; index = $stepNames.Count; total = $stepNames.Count
            category = 'deploymentVerified'; verified = $true; verificationMode = 'Verify'
            adminUiUrl = [string]$adminUi.adminUiUrl
        }) -OutputFormat $OutputFormat
        return
    }

    $prerequisites = Invoke-GatewayStateStep -Name 'Prerequisites' -AlwaysRun -Action {
        Assert-BootstrapPrerequisites -Install:$InstallPrerequisites -RequirePurview:($configuration.purview.enabled -eq $true)
    }
    $azureIdentity = Invoke-GatewayStateStep -Name 'Azure authentication' -AlwaysRun -Action {
        if (-not $NonInteractive) {
            Write-GatewayExperienceEvent -Type Info -Message 'Administrator handoff: Azure sign-in may open if the configured session needs refresh.' -Data ([ordered]@{
                step = 'Azure authentication'; index = 2; total = $stepNames.Count
            }) -OutputFormat $OutputFormat
        }
        Connect-BootstrapAzure -Config $configuration -NonInteractive:$NonInteractive
    }

    $resourceGroupExists = [string](Invoke-AzTsv -Arguments @('group', 'exists', '--name', [string]$configuration.resourceGroupName))
    if ($resourceGroupExists -notin @('true', 'false')) {
        throw 'Azure returned an invalid resource-group existence result; no resource mutation was attempted.'
    }
    if ($resourceGroupExists -eq 'true' -and -not $state.steps['Azure foundation']) {
        throw 'Clean bootstrap requires the target resource group to be absent. Refusing to adopt an existing unowned resource group or its deterministic resources.'
    }
    Assert-GatewayResourceGroupRecoveryBoundary `
        -ResourceGroupExists $resourceGroupExists `
        -FoundationStep $state.steps['Azure foundation'] | Out-Null

    Invoke-GatewayStateStep -Name 'Azure provider registration' -Validate {
        Test-GatewayResourceProviderEvidence
    } -Action {
        Register-BootstrapResourceProviders
    } | Out-Null

    $foundation = Invoke-GatewayStateStep -Name 'Azure foundation' -Validate {
        Test-GatewaySubscriptionDeploymentEvidence -Config $configuration -Evidence $state.steps['Azure foundation'].evidence -DeploymentOwnershipId ([string]$state.deploymentOwnershipId)
    } -Reconcile {
        Invoke-GatewayExactReconciliation -Readback {
            $recovered = Get-BootstrapFoundationEvidence -Config $configuration -DeploymentOwnershipId ([string]$state.deploymentOwnershipId)
            $null = Test-GatewaySubscriptionDeploymentEvidence -Config $configuration -Evidence $recovered -DeploymentOwnershipId ([string]$state.deploymentOwnershipId)
            return $recovered
        }
    } -NoAutomaticReplayAfterStart -Action {
        $created = Deploy-BootstrapFoundation -Config $configuration -DeploymentOwnershipId ([string]$state.deploymentOwnershipId)
        $null = Test-GatewaySubscriptionDeploymentEvidence -Config $configuration -Evidence $created -DeploymentOwnershipId ([string]$state.deploymentOwnershipId)
        return $created
    }

    $identity = Invoke-GatewayStateStep -Name 'Gateway API identity' -Validate {
        Test-GatewayApplicationEvidence -Config $configuration -Evidence $state.steps['Gateway API identity'].evidence -ObjectIdProperty 'gatewayApiApplicationObjectId' -ClientIdProperty 'gatewayApiClientId' -ApplicationKind GatewayApi
    } -Reconcile {
        Invoke-GatewayExactReconciliation -Readback {
            Ensure-GatewayApiApplication -Config $configuration -AzureIdentity $azureIdentity -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -ReconcileOnly
        }
    } -NoAutomaticReplayAfterStart -Action {
        Ensure-GatewayApiApplication -Config $configuration -AzureIdentity $azureIdentity -DeploymentOwnershipId ([string]$state.deploymentOwnershipId)
    }

    $images = Invoke-GatewayStateStep -Name 'Immutable workload images' -Validate {
        Test-GatewayImmutableImageEvidence -Evidence $state.steps['Immutable workload images'].evidence -SourceFingerprint $activeAcceptedSourceFingerprint -DeploymentOwnershipId ([string]$state.deploymentOwnershipId)
    } -Action {
        $partialImageEvidence = if ($state.steps['Immutable workload images'].Contains('evidence')) {
            $state.steps['Immutable workload images'].evidence
        }
        else { $null }
        Build-GatewayImages `
            -Config $configuration `
            -AcrLoginServer ([string]$foundation.acrLoginServer) `
            -SourceFingerprint $activeAcceptedSourceFingerprint `
            -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
            -RecoveredEvidence $partialImageEvidence `
            -Checkpoint {
                param($partialEvidence)
                $state.steps['Immutable workload images'].evidence = $partialEvidence
                Save-BootstrapState -State $state -Path $statePath
            }
    }

    $inert = Invoke-GatewayStateStep -Name 'Inert identity deployment' -Validate {
        $runtimeSupersededInert = $state.steps['Gateway runtime deployment'] -and [string]$state.steps['Gateway runtime deployment'].status -eq 'Completed'
        Test-GatewayGroupDeploymentEvidence -Config $configuration -Foundation $foundation -Identity $identity -Evidence $state.steps['Inert identity deployment'].evidence -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -AllowRuntimeSupersession:$runtimeSupersededInert
    } -Action {
        $created = Deploy-GatewayCore -Config $configuration -Foundation $foundation -Identity $identity -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -WorkerPrincipalId '' -ManagerApplicationIds @() -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint -Initial
        $null = Test-GatewayGroupDeploymentEvidence -Config $configuration -Foundation $foundation -Identity $identity -Evidence $created -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker)
        return $created
    }

    $blueprint = Invoke-GatewayStateStep -Name 'Agent 365 seed blueprint' -Validate {
        Test-GatewayBlueprintEvidence `
            -Config $configuration `
            -Evidence $state.steps['Agent 365 seed blueprint'].evidence `
            -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
            -SourceFingerprint $activeAcceptedSourceFingerprint `
            -SponsorObjectId ([string]$azureIdentity.userObjectId) `
            -GatewayManagedIdentityPrincipalId ([string]$inert.workerPrincipalId)
    } -Reconcile {
        Invoke-GatewayExactReconciliation -Readback {
            Ensure-Agent365SeedBlueprint `
                -Config $configuration `
                -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
                -SourceFingerprint $activeAcceptedSourceFingerprint `
                -SponsorObjectId ([string]$azureIdentity.userObjectId) `
                -NonInteractive `
                -ReconcileOnly
        }
    } -NoAutomaticReplayAfterStart -Action {
        if (-not $NonInteractive) {
            Write-GatewayExperienceEvent -Type Info -Message 'Administrator boundary: Microsoft Graph will create the exact reviewed blueprint with the authenticated administrator as sole owner and sponsor; no blueprint credential is created.' -Data ([ordered]@{
                step = 'Agent 365 seed blueprint'; index = 8; total = $stepNames.Count
            }) -OutputFormat $OutputFormat
        }
        Ensure-Agent365SeedBlueprint `
            -Config $configuration `
            -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
            -SourceFingerprint $activeAcceptedSourceFingerprint `
            -SponsorObjectId ([string]$azureIdentity.userObjectId) `
            -NonInteractive:$NonInteractive
    }

    $workloadIdentity = Invoke-GatewayStateStep -Name 'Workflow v3 Entra configuration' -Validate {
        Test-GatewayWorkflowIdentityEvidence -Config $configuration -Identity $identity -Inert $inert -Evidence $state.steps['Workflow v3 Entra configuration'].evidence
    } -Reconcile {
        Invoke-GatewayExactReconciliation -Readback {
            Get-GatewayWorkloadIdentityEvidence -Config $configuration -Identity $identity -ApiPrincipalId ([string]$inert.apiPrincipalId) -WorkerPrincipalId ([string]$inert.workerPrincipalId) -EnablePurview:($configuration.purview.enabled -eq $true)
        }
    } -NoAutomaticReplayAfterStart -Action {
        Configure-GatewayWorkloadIdentity -Config $configuration -Identity $identity -ApiPrincipalId ([string]$inert.apiPrincipalId) -WorkerPrincipalId ([string]$inert.workerPrincipalId) -EnablePurview:($configuration.purview.enabled -eq $true)
    }

    $sqlPrivateEndpoint = Invoke-GatewayStateStep -Name 'SQL private endpoint' -Validate {
        $evidence = $state.steps['SQL private endpoint'].evidence
        Test-GatewaySqlPrivateEndpointEvidence -Config $configuration -Foundation $foundation -SqlServerFqdn ([string]$inert.sqlServerFqdn) -Evidence $evidence -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint
    } -Action {
        $created = Deploy-SqlPrivateEndpoint -Config $configuration -Foundation $foundation -SqlServerFqdn ([string]$inert.sqlServerFqdn) -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint
        $null = Test-GatewaySqlPrivateEndpointEvidence -Config $configuration -Foundation $foundation -SqlServerFqdn ([string]$inert.sqlServerFqdn) -Evidence $created -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint
        return $created
    }

    $database = Invoke-GatewayStateStep -Name 'Gateway database' -Validate {
        Test-GatewayDatabaseEvidence -Config $configuration -Inert $inert -Evidence $state.steps['Gateway database'].evidence -StepRecord $state.steps['Gateway database'] -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint
    } -Action {
        Initialize-GatewayDatabase -Config $configuration -SqlServerFqdn ([string]$inert.sqlServerFqdn) -ApiPrincipalId ([string]$inert.apiPrincipalId) -WorkerPrincipalId ([string]$inert.workerPrincipalId) -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -BootstrapClientIpv4 ([string]$state.acceptedPlan.bootstrapClientIpv4)
    }

    $adminIdentity = Invoke-GatewayStateStep -Name 'Admin UI identity' -Validate {
        $expectedAdminUiUrl = if ($state.steps['Admin UI deployment'] -and [string]$state.steps['Admin UI deployment'].status -eq 'Completed') {
            [string]$state.steps['Admin UI deployment'].evidence.adminUiUrl
        }
        else { '' }
        Test-GatewayApplicationEvidence -Config $configuration -Evidence $state.steps['Admin UI identity'].evidence -ObjectIdProperty 'adminUiApplicationObjectId' -ClientIdProperty 'adminUiClientId' -ApplicationKind AdminUi -ExpectedAdminUiUrl $expectedAdminUiUrl
    } -Reconcile {
        Invoke-GatewayExactReconciliation -Readback {
            Ensure-AdminUiApplication -Config $configuration -Identity $identity -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -ReconcileOnly
        }
    } -NoAutomaticReplayAfterStart -Action {
        Ensure-AdminUiApplication -Config $configuration -Identity $identity -DeploymentOwnershipId ([string]$state.deploymentOwnershipId)
    }

    $adminCredential = Invoke-GatewayStateStep -Name 'Admin UI Key Vault credential' -Validate {
        Test-GatewayAdminCredentialEvidence -Config $configuration -AdminIdentity $adminIdentity -Inert $inert -Evidence $state.steps['Admin UI Key Vault credential'].evidence
    } -Reconcile {
        Invoke-GatewayExactReconciliation -Readback {
            Resolve-AdminUiCredentialAfterStartedOutcome -Config $configuration -AdminIdentity $adminIdentity -KeyVaultUri ([string]$inert.keyVaultUri) -UserObjectId ([string]$azureIdentity.userObjectId)
        }
    } -NoAutomaticReplayAfterStart -Action {
        New-AdminUiCredentialInKeyVault -Config $configuration -AdminIdentity $adminIdentity -KeyVaultUri ([string]$inert.keyVaultUri) -UserObjectId ([string]$azureIdentity.userObjectId)
    }

    if ($configuration.purview.enabled -eq $true -and -not $NonInteractive) {
        Write-GatewayExperienceEvent -Type Info -Message 'Administrator handoff: Purview policy review or setup requires an interactive compliance sign-in.' -Data ([ordered]@{
            step = 'Purview policies'; index = 14; total = $stepNames.Count
        }) -OutputFormat $OutputFormat
    }
    $purview = Invoke-GatewayStateStep -Name 'Purview policies' -Validate {
        Test-GatewayPurviewEvidence -Config $configuration -Blueprint $blueprint -Evidence $state.steps['Purview policies'].evidence -UserPrincipalName ([string]$azureIdentity.userPrincipalName) -NonInteractive:$NonInteractive
    } -Reconcile {
        Invoke-GatewayExactReconciliation -Readback {
            if ($NonInteractive) {
                throw 'Purview exact reconciliation requires interactive Security & Compliance authentication.'
            }
            $connectionId = ''
            try {
                $connectionId = Connect-BootstrapPurview -UserPrincipalName ([string]$azureIdentity.userPrincipalName) -TenantId ([string]$configuration.tenantId)
                Get-BootstrapPurviewPolicyEvidence -Config $configuration -Blueprint $blueprint -MaximumAttempts 1
            }
            finally {
                if (-not [string]::IsNullOrWhiteSpace($connectionId)) { Disconnect-BootstrapPurview -ConnectionId $connectionId }
            }
        }
    } -NoAutomaticReplayAfterStart:($configuration.purview.enabled -eq $true) -Action {
        # Interactive compliance connection setup can emit module objects. The
        # state contract stores only the provider's final non-secret evidence map.
        $created = @(Ensure-BootstrapPurviewPolicies -Config $configuration -Blueprint $blueprint -UserPrincipalName ([string]$azureIdentity.userPrincipalName) -NonInteractive:$NonInteractive)
        if ($created.Count -eq 0 -or $created[-1] -isnot [System.Collections.IDictionary]) {
            throw 'Purview policy setup did not return the required safe evidence shape.'
        }
        return $created[-1]
    }

    $developmentPreviewRequested = [string]$configuration.environment -eq 'dev' -and $configuration.agent365.allowDevelopmentRegistryPreview -eq $true
    # Policy-profile application/certificate/RBAC authority is deliberately not
    # mutated by clean bootstrap. Keep both worker execution and API admission
    # physically closed until the separate runbook proof exists.
    $enableProvisioning = $developmentPreviewRequested -and $configuration.purview.policyProvisioningEnabled -ne $true
    $runtime = Invoke-GatewayStateStep -Name 'Gateway runtime deployment' -Validate {
        Test-GatewayGroupDeploymentEvidence -Config $configuration -Foundation $foundation -Identity $identity -Evidence $state.steps['Gateway runtime deployment'].evidence -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -Database $database
    } -Action {
        $created = Deploy-GatewayCore -Config $configuration -Foundation $foundation -Identity $identity -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -WorkerPrincipalId ([string]$inert.workerPrincipalId) -ManagerApplicationIds @($blueprint.managerApplicationIds) -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint -Database $database -EnableWorkerProcessing -EnableProvisioning:$enableProvisioning -EnablePurview:($purview.enabled -eq $true)
        $null = Test-GatewayGroupDeploymentEvidence -Config $configuration -Foundation $foundation -Identity $identity -Evidence $created -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -Database $database
        return $created
    }

    $adminUi = Invoke-GatewayStateStep -Name 'Admin UI deployment' -Validate {
        Test-GatewayNamedGroupDeployment -Config $configuration -Foundation $foundation -Runtime $runtime -Identity $identity -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentName "a365gw-$($configuration.projectName)-bootstrap-admin-$($configuration.environment)" -Evidence $state.steps['Admin UI deployment'].evidence -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint -AdminUiImage ([string]$images.adminUi)
    } -Reconcile {
        Invoke-GatewayExactReconciliation -Readback {
            $recovered = Get-GatewayAdminUiDeploymentEvidence -Config $configuration -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint -AdminUiImage ([string]$images.adminUi)
            $null = Test-GatewayNamedGroupDeployment -Config $configuration -Foundation $foundation -Runtime $runtime -Identity $identity -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentName "a365gw-$($configuration.projectName)-bootstrap-admin-$($configuration.environment)" -Evidence $recovered -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint -AdminUiImage ([string]$images.adminUi)
            return $recovered
        }
    } -NoAutomaticReplayAfterStart -Action {
        $created = Deploy-GatewayAdminUi -Config $configuration -Foundation $foundation -Identity $identity -AdminIdentity $adminIdentity -AdminUiImage ([string]$images.adminUi) -AdminUiSecretUri ([string]$adminCredential.secretUri) -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint
        $null = Test-GatewayNamedGroupDeployment -Config $configuration -Foundation $foundation -Runtime $runtime -Identity $identity -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentName "a365gw-$($configuration.projectName)-bootstrap-admin-$($configuration.environment)" -Evidence $created -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeAcceptedSourceFingerprint -AdminUiImage ([string]$images.adminUi)
        return $created
    }

    Invoke-GatewayStateStep -Name 'Admin UI redirect URIs' -Validate {
        Test-GatewayAdminRedirectEvidence -AdminIdentity $adminIdentity -AdminUi $adminUi
    } -Action {
        $created = Set-AdminUiRedirectUris -AdminIdentity $adminIdentity -AdminUiFqdn ([string]$adminUi.adminUiFqdn)
        $null = Test-GatewayAdminRedirectEvidence -AdminIdentity $adminIdentity -AdminUi $adminUi
        return $created
    } | Out-Null

    Invoke-GatewayStateStep -Name 'Network hardening' -AlwaysRun -Action {
        Set-GatewayNetworkHardening -Config $configuration
    } | Out-Null

    $verification = Invoke-GatewayStateStep -Name 'End-to-end deployment verification' -AlwaysRun -Action {
        Test-GatewayBootstrapDeployment -Config $configuration -Foundation $foundation -Identity $identity -Blueprint $blueprint -Runtime $runtime -Database $database -SqlPrivateEndpoint $sqlPrivateEndpoint -AdminUi $adminUi -Images $images -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -NonInteractive:$NonInteractive
    }

    Save-Output -Name 'adminUiUrl' -Value ([string]$adminUi.adminUiUrl)
    Save-Output -Name 'apiUrl' -Value "https://$($runtime.apiFqdn)"
    Save-Output -Name 'seedBlueprint' -Value $blueprint
    Save-Output -Name 'verification' -Value $verification

    $provisioningAdmissionReady = $verification.provisioningAdmissionReady -eq $true
    $completionMessage = if ($provisioningAdmissionReady) {
        "Bootstrap completed and verified with development provisioning admission open in $($stopwatch.Elapsed.ToString('hh\:mm\:ss')). Admin UI: $($adminUi.adminUiUrl)"
    }
    else {
        "Gateway deployment completed and verified in $($stopwatch.Elapsed.ToString('hh\:mm\:ss')); provisioning admission remains closed. Admin UI: $($adminUi.adminUiUrl)"
    }
    Write-GatewayExperienceEvent -Type Result -Message $completionMessage -Data ([ordered]@{
        step = 'End-to-end deployment verification'
        index = $stepNames.Count
        total = $stepNames.Count
        deploymentId = "$($configuration.projectName)-$($configuration.environment)"
        category = 'deploymentVerified'
        verified = $true
        verificationMode = 'Apply'
        adminUiUrl = [string]$adminUi.adminUiUrl
        apiHealthUrl = "https://$($runtime.apiFqdn)/health/checks"
        statePath = $statePath
        readiness = if ($provisioningAdmissionReady) { @('InfrastructureReady', 'ControlPlaneReady', 'ProvisioningReady') } else { @('InfrastructureReady', 'ControlPlaneReady') }
        provisioningAdmission = if ($provisioningAdmissionReady) { 'OpenDevelopmentPreview' } else { [string]$verification.registrationMode }
        notProven = @('FirstAgentActive', 'CanaryProven')
    }) -OutputFormat $OutputFormat

    if (-not $provisioningAdmissionReady) {
        # Agent Registration is development-only while the Registry create API is beta.
        $closedReason = if ($developmentPreviewRequested -and $configuration.purview.policyProvisioningEnabled -eq $true) {
            'Agent creation remains closed because Purview protection-profile automation application/certificate binding and Security & Compliance RBAC are NotChecked; complete the runbook proof before opening admission.'
        }
        else { 'Agent creation remains closed because Registry create is unsupported for production outside the explicitly acknowledged development preview.' }
        Write-GatewayExperienceEvent -Type Warning -Message $closedReason -Data ([ordered]@{
            step = 'End-to-end deployment verification'; index = $stepNames.Count; total = $stepNames.Count
        }) -OutputFormat $OutputFormat
    }
    if ($OpenBrowser) {
        $status = Get-GatewayBootstrapStatus -Config $configuration -State $state -StatePath $statePath
        $null = Open-GatewayAdminUi -Status $status
    }
}
finally {
    Set-BootstrapEventWriter -Writer $null
    $stopwatch.Stop()
    if ($lock) { $lock.Dispose() }
}
}
catch {
    Write-GatewayExperienceEvent -Type Warning -Message 'Gateway bootstrap stopped safely. Dependency details were withheld. Review the last safe step, run gateway diagnose, and resume.' -Data ([ordered]@{
        step = 'Bootstrap'
        index = 1
        total = (Get-GatewayBootstrapStepNames).Count
        resumable = $true
    }) -OutputFormat $OutputFormat
    exit 1
}
finally {
    Set-BootstrapStructuredOutput -Enabled $false
}
