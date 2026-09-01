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
    [ValidateSet('Init', 'Doctor', 'Plan', 'Apply', 'Resume', 'Status', 'Verify', 'Open', 'Diagnose', 'Up', 'RecoverDatabase', 'RepairDatabase')]
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

    [string]$ExpectedResumeAuthorizationFingerprint = '',

    [string]$ExpectedConfigurationFileFingerprint = '',

    [switch]$EventStreamOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$expectedConfigurationFileFingerprintSupplied =
    $PSBoundParameters.ContainsKey('ExpectedConfigurationFileFingerprint')
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
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter()][string]$DeploymentSourceFingerprint = ''
    )
    if ([string]::IsNullOrWhiteSpace($DeploymentSourceFingerprint)) { $DeploymentSourceFingerprint = $SourceFingerprint }
    $predictedChanges = @($WhatIf.changes | Sort-Object resourceId, changeType | ForEach-Object {
        [ordered]@{ resourceId = [string]$_.resourceId; changeType = [string]$_.changeType }
    })
    return Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
        contractVersion = 3
        configurationFingerprint = $ConfigurationFingerprint
        sourceFingerprint = $SourceFingerprint
        deploymentSourceFingerprint = $DeploymentSourceFingerprint
        descriptor = $Descriptor
        azureFoundationWhatIf = [ordered]@{
            executed = [bool]$WhatIf.executed
            applyReady = [bool]$WhatIf.applyReady
            changes = $predictedChanges
            recoveryIgnoreBoundary = $WhatIf.recoveryIgnoreBoundary
        }
    })
}

function Get-GatewayDatabaseRecoveryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )

    if (-not $State.Contains('acceptedPlan') -or $State.acceptedPlan -isnot [System.Collections.IDictionary]) {
        throw 'Database recovery requires the preserved original accepted deployment plan.'
    }
    $databaseStep = $State.steps['Gateway database']
    if ($databaseStep -isnot [System.Collections.IDictionary] -or
        [string]$databaseStep.status -cne 'Failed' -or
        ($databaseStep.Contains('evidence') -and $null -ne $databaseStep.evidence)) {
        throw 'Database recovery is allowed only for the exact failed Gateway database step before any completed database evidence was recorded.'
    }
    $previousRecoveryPlan = $null
    $priorFailedRecovery = $null
    $attemptNumber = 1
    if ($State.Contains('databaseRecoveryPlan')) {
        if ($State.databaseRecoveryPlan -isnot [System.Collections.IDictionary] -or
            (Get-BootstrapDatabaseRecoveryAttemptNumber -Plan $State.databaseRecoveryPlan) -ne 1 -or
            [string]$State.databaseRecoveryPlan.status -cne 'Running') {
            throw 'Only the exact terminally failed first database recovery attempt may produce a continuation plan.'
        }
        Assert-BootstrapDatabaseRecoveryHistory -State $State -CurrentPlan $State.databaseRecoveryPlan | Out-Null
        $null = Resolve-BootstrapDatabaseRecoveryPlanSourceRoot -State $State -Plan $State.databaseRecoveryPlan
        $previousRecoveryPlan = ConvertTo-BootstrapCanonicalValue -Value $State.databaseRecoveryPlan
        $attemptNumber = 2
    }
    $originalSourceFingerprint = [string]$State.acceptedPlan.sourceFingerprint
    $correctedSourceFingerprint = Get-BootstrapSourceFingerprint
    Assert-BootstrapFingerprintValue -Value $originalSourceFingerprint -Label 'Original accepted source fingerprint'
    Assert-BootstrapFingerprintValue -Value $correctedSourceFingerprint -Label 'Corrected recovery source fingerprint'
    if ($correctedSourceFingerprint -ceq $originalSourceFingerprint -or
        ($attemptNumber -eq 2 -and $correctedSourceFingerprint -ceq [string]$previousRecoveryPlan.correctedSourceFingerprint)) {
        throw 'Database recovery requires a newly corrected source generation distinct from every failed source generation.'
    }
    $null = Resolve-BootstrapAcceptedSourceRoot -State $State
    $configurationFingerprint = Get-BootstrapConfigurationFingerprint -Config $Configuration
    $ownershipId = ([guid][string]$State.deploymentOwnershipId).ToString('D')
    $foundation = $State.steps['Azure foundation'].evidence
    $identity = $State.steps['Gateway API identity'].evidence
    $images = $State.steps['Immutable workload images'].evidence
    $inert = $State.steps['Inert identity deployment'].evidence
    $sqlPrivateEndpoint = $State.steps['SQL private endpoint'].evidence
    foreach ($required in @($foundation, $identity, $images, $inert, $sqlPrivateEndpoint)) {
        if ($required -isnot [System.Collections.IDictionary]) {
            throw 'Database recovery requires completed foundation, identity, image, inert-runtime, and SQL private-endpoint evidence.'
        }
    }
    $apiPrincipal = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inert.apiPrincipalId)
    $workerPrincipal = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inert.workerPrincipalId)
    $failedJob = Get-GatewayFailedDatabaseBootstrapBoundary `
        -Config $Configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
        -SqlServerFqdn ([string]$inert.sqlServerFqdn) -OriginalJobImage ([string]$images.databaseMigrator) `
        -DeploymentOwnershipId $ownershipId -OriginalSourceFingerprint $originalSourceFingerprint `
        -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
        -OriginalAdministratorObjectId ([string]$identity.userObjectId) `
        -OriginalAdministratorLogin ([string]$identity.userPrincipalName)
    if ($attemptNumber -eq 2) {
        $priorFailedRecovery = Get-GatewayFailedDatabaseRecoveryBoundary `
            -Config $Configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
            -SqlServerFqdn ([string]$inert.sqlServerFqdn) -RecoveryPlan $previousRecoveryPlan `
            -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
            -OriginalAdministratorObjectId ([string]$identity.userObjectId) `
            -OriginalAdministratorLogin ([string]$identity.userPrincipalName)
    }
    $priorBoundaryMaterial = if ($null -ne $priorFailedRecovery) { "|$($priorFailedRecovery.boundaryFingerprint)" } else { '' }
    $imageIntentId = Get-BootstrapDeterministicGuid -Material "$ownershipId|$originalSourceFingerprint|$correctedSourceFingerprint|$($failedJob.boundaryFingerprint)$priorBoundaryMaterial|database-recovery-image-attempt-$attemptNumber"
    $executionIntentId = Get-BootstrapDeterministicGuid -Material "$ownershipId|$originalSourceFingerprint|$correctedSourceFingerprint|$($failedJob.boundaryFingerprint)$priorBoundaryMaterial|database-recovery-execution-attempt-$attemptNumber"
    $imageTag = Get-BootstrapImageBuildIntentTag -DeploymentOwnershipId $ownershipId -SourceFingerprint $correctedSourceFingerprint -IntentId $imageIntentId
    $recoveryContract = Get-GatewayDatabaseRecoveryAttemptContract -Config $Configuration -AttemptNumber $attemptNumber
    $jobName = [string]$recoveryContract.jobName
    $planCore = [ordered]@{
        schemaVersion = if ($attemptNumber -eq 2) { 2 } else { 1 }
        configurationFingerprint = $configurationFingerprint
        deploymentOwnershipId = $ownershipId
        originalSourceFingerprint = $originalSourceFingerprint
        correctedSourceFingerprint = $correctedSourceFingerprint
        originalAcceptedPlan = ConvertTo-BootstrapCanonicalValue -Value $State.acceptedPlan
        failedJob = $failedJob
        correctedImage = [ordered]@{
            component = 'databaseMigratorRecovery'
            repository = 'gateway-db-migrator'
            dockerfile = 'tools/Gateway.DatabaseMigrator/Dockerfile'
            intentId = $imageIntentId
            tag = $imageTag
            state = 'Planned'
        }
        recoveryJob = [ordered]@{
            name = $jobName
            executionIntentId = $executionIntentId
            recoveryMode = 'ResumeAfterSchemaCompleted'
            replicaRetryLimit = 0
            maximumExecutions = 1
        }
        expectedWhatIf = [ordered]@{
            changeType = 'Create'
            resourceId = ("/subscriptions/$($Configuration.subscriptionId)/resourceGroups/$($Configuration.resourceGroupName)/providers/Microsoft.App/jobs/$jobName").ToLowerInvariant()
        }
    }
    if ($attemptNumber -eq 2) {
        $planCore.Insert(1, 'attemptNumber', 2)
        $planCore.Insert(8, 'previousRecoveryPlanFingerprint', [string]$previousRecoveryPlan.planFingerprint)
        $planCore.Insert(9, 'previousRecoveryPlan', $previousRecoveryPlan)
        $planCore.Insert(10, 'priorFailedRecovery', $priorFailedRecovery)
    }
    $planFingerprint = Get-BootstrapObjectFingerprint -InputObject $planCore
    $originalDigest = ([string]$images.databaseMigrator).Split('@')[-1]
    $whatIf = Invoke-GatewayDatabaseRecoveryWhatIf `
        -Config $Configuration -Foundation $foundation -RepositoryRoot (Get-RepositoryRoot) `
        -SqlServerFqdn ([string]$inert.sqlServerFqdn) `
        -ExpectedPrivateEndpointIpv4Address ([string]$sqlPrivateEndpoint.privateEndpointIpv4Address) `
        -DatabaseMigratorImageDigest $originalDigest -DeploymentOwnershipId $ownershipId `
        -OriginalAcceptedSourceFingerprint $originalSourceFingerprint `
        -RecoverySourceFingerprint $correctedSourceFingerprint -RecoveryPlanFingerprint $planFingerprint `
        -RecoveryExecutionIntentId $executionIntentId -RecoveryAttemptNumber $attemptNumber `
        -OriginalFailedDatabaseBoundaryFingerprint ([string]$failedJob.boundaryFingerprint) `
        -PriorFailedRecoveryBoundaryFingerprint $(if ($null -ne $priorFailedRecovery) { [string]$priorFailedRecovery.boundaryFingerprint } else { '' }) `
        -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal
    $plan = ConvertTo-BootstrapCanonicalValue -Value $planCore
    $plan['planFingerprint'] = $planFingerprint
    $plan['whatIf'] = $whatIf
    return $plan
}

function Get-GatewayManualDatabaseRepairPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )

    Assert-BootstrapManualDatabaseRepairPrerequisite -State $State | Out-Null
    if ($State.Contains('manualDatabaseRepairPlan')) {
        throw 'The one-shot manual database repair plan already exists and cannot be replaced.'
    }
    $recovery = $State.databaseRecoveryPlan
    $originalSourceFingerprint = [string]$State.acceptedPlan.sourceFingerprint
    $repairSourceFingerprint = Get-BootstrapSourceFingerprint
    Assert-BootstrapFingerprintValue -Value $originalSourceFingerprint -Label 'Original accepted source fingerprint'
    Assert-BootstrapFingerprintValue -Value $repairSourceFingerprint -Label 'Manual database repair source fingerprint'
    $null = Resolve-BootstrapAcceptedSourceRoot -State $State
    $foundation = $State.steps['Azure foundation'].evidence
    $identity = $State.steps['Gateway API identity'].evidence
    $images = $State.steps['Immutable workload images'].evidence
    $inert = $State.steps['Inert identity deployment'].evidence
    $sqlPrivateEndpoint = $State.steps['SQL private endpoint'].evidence
    foreach ($required in @($foundation, $identity, $images, $inert, $sqlPrivateEndpoint)) {
        if ($required -isnot [System.Collections.IDictionary]) {
            throw 'Manual database repair requires completed foundation, identity, image, inert-runtime, and SQL private-endpoint evidence.'
        }
    }
    $apiPrincipal = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inert.apiPrincipalId)
    $workerPrincipal = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inert.workerPrincipalId)
    $originalFailure = Get-GatewayFailedDatabaseBootstrapBoundary `
        -Config $Configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
        -SqlServerFqdn ([string]$inert.sqlServerFqdn) -OriginalJobImage ([string]$images.databaseMigrator) `
        -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) `
        -OriginalSourceFingerprint $originalSourceFingerprint -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
        -OriginalAdministratorObjectId ([string]$identity.userObjectId) `
        -OriginalAdministratorLogin ([string]$identity.userPrincipalName)
    $firstFailure = Get-GatewayFailedDatabaseRecoveryBoundary `
        -Config $Configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
        -SqlServerFqdn ([string]$inert.sqlServerFqdn) -RecoveryPlan $recovery.previousRecoveryPlan `
        -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
        -OriginalAdministratorObjectId ([string]$identity.userObjectId) `
        -OriginalAdministratorLogin ([string]$identity.userPrincipalName)
    $secondFailure = Get-GatewayFailedDatabaseRecoveryBoundary `
        -Config $Configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
        -SqlServerFqdn ([string]$inert.sqlServerFqdn) -RecoveryPlan $recovery `
        -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
        -OriginalAdministratorObjectId ([string]$identity.userObjectId) `
        -OriginalAdministratorLogin ([string]$identity.userPrincipalName)
    if ([string]$originalFailure.boundaryFingerprint -cne [string]$recovery.failedJob.boundaryFingerprint -or
        [string]$firstFailure.boundaryFingerprint -cne [string]$recovery.priorFailedRecovery.boundaryFingerprint -or
        [string]$secondFailure.boundaryFingerprint -cne [string]$recovery.failedRecovery.boundaryFingerprint) {
        throw 'The live original/attempt-one/attempt-two failure chain no longer matches the terminal automatic recovery state.'
    }
    $ownershipId = ([guid][string]$State.deploymentOwnershipId).ToString('D')
    $boundaryMaterial = "$($originalFailure.boundaryFingerprint)|$($firstFailure.boundaryFingerprint)|$($secondFailure.boundaryFingerprint)"
    $imageIntentId = Get-BootstrapDeterministicGuid -Material "$ownershipId|$repairSourceFingerprint|$boundaryMaterial|manual-database-repair-image"
    $executionIntentId = Get-BootstrapDeterministicGuid -Material "$ownershipId|$repairSourceFingerprint|$boundaryMaterial|manual-database-repair-execution"
    $contract = Get-GatewayManualDatabaseRepairContract -Config $Configuration
    $planCore = [ordered]@{
        schemaVersion = 1
        configurationFingerprint = Get-BootstrapConfigurationFingerprint -Config $Configuration
        deploymentOwnershipId = $ownershipId
        originalSourceFingerprint = $originalSourceFingerprint
        repairSourceFingerprint = $repairSourceFingerprint
        originalAcceptedPlan = ConvertTo-BootstrapCanonicalValue -Value $State.acceptedPlan
        exhaustedRecoveryPlanFingerprint = [string]$recovery.planFingerprint
        exhaustedRecoveryPlan = ConvertTo-BootstrapCanonicalValue -Value $recovery
        originalFailedJob = $originalFailure
        firstFailedRecovery = $firstFailure
        secondFailedRecovery = $secondFailure
        correctedImage = [ordered]@{
            component = 'databaseMigratorRecovery'
            repository = 'gateway-db-migrator'
            dockerfile = 'tools/Gateway.DatabaseMigrator/Dockerfile'
            intentId = $imageIntentId
            tag = Get-BootstrapImageBuildIntentTag -DeploymentOwnershipId $ownershipId -SourceFingerprint $repairSourceFingerprint -IntentId $imageIntentId
            state = 'Planned'
        }
        repairJob = [ordered]@{
            name = [string]$contract.jobName
            executionIntentId = $executionIntentId
            imageIntentId = $imageIntentId
            repairMode = 'ResumeAfterSchemaCompleted'
            replicaRetryLimit = 0
            maximumExecutions = 1
        }
    }
    $plan = ConvertTo-BootstrapCanonicalValue -Value $planCore
    $plan['planFingerprint'] = Get-BootstrapObjectFingerprint -InputObject $planCore
    return $plan
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

    $script:GatewayFailureStage = 'Plan review'
    $script:GatewayFailureCode = 'plan_state'
    if ($State.Contains('steps') -and
        $State.steps -is [System.Collections.IDictionary] -and
        $State.steps.Count -gt 0) {
        $script:GatewayFailureStage = 'Resume required'
        $script:GatewayFailureCode = 'resume_required'
        throw 'This deployment already has persisted checkpoints. The accepted plan was preserved; run gateway resume so every completed step is revalidated before any remaining mutation.'
    }
    Set-BootstrapPreInertSourceCorrectionPlan -State $State -StatePath $StatePath | Out-Null
    Assert-BootstrapStateAllowsSourcePlan -State $State | Out-Null
    Clear-BootstrapAcceptedPlan -State $State -StatePath $StatePath | Out-Null
    $planEventBase = [ordered]@{ step = 'Plan review'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }
    if ($State.Contains('preInertSourceCorrectionPlan')) {
        Write-GatewayExperienceEvent -Type Info -Message 'Resume is reviewing the exact pre-inert template correction. Completed foundation and immutable-image evidence will be revalidated and reused; no completed deployment step is replayed.' -Data ([ordered]@{
            step = $planEventBase.step; category = 'preInertSourceCorrection'; reuseThroughStep = 6
        }) -OutputFormat $Format
    }
    Write-GatewayExperienceEvent -Type Info -Message 'Checking local Git, Azure CLI, .NET 10, and Bicep prerequisites before compiling the authenticated plan. Missing supported tools may be installed locally when prerequisite installation is enabled.' -Data ([ordered]@{
        step = $planEventBase.step; category = 'localPrerequisites'
    }) -OutputFormat $Format
    $script:GatewayFailureCode = 'plan_prerequisites'
    Assert-GatewayPlanPrerequisites -Install:$InstallLocalPrerequisites | Out-Null
    Write-GatewayExperienceEvent -Type PhaseStarted -Message 'Validating bootstrap source and compiling every bootstrap Bicep template...' -Data $planEventBase -OutputFormat $Format
    $script:GatewayFailureCode = 'plan_source'
    $root = Get-RepositoryRoot
    $sourceFingerprintBefore = Get-BootstrapSourceFingerprint
    $deploymentSourceFingerprint = Get-BootstrapEffectiveDeploymentSourceFingerprint -State $State -ExecutionSourceFingerprint $sourceFingerprintBefore
    $configurationFingerprintBefore = Get-BootstrapConfigurationFingerprint -Config $Configuration
    $sourceValidation = Test-GatewayPlanSource -RepositoryRoot $root
    $bootstrapClientIpv4 = Get-GatewayBootstrapClientIpv4
    $descriptor = Get-GatewayPlanDescriptor `
        -Config $Configuration `
        -State $State `
        -BootstrapClientIpv4 $bootstrapClientIpv4 `
        -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) `
        -SourceFingerprint $deploymentSourceFingerprint
    # Plan is read-only, but its ARM What-If and Graph collision checks must use
    # the same exact subscription/tenant boundary as Apply. Without this context,
    # the in-process Graph client correctly refuses token acquisition.
    $script:GatewayFailureCode = 'plan_account'
    Clear-BootstrapAzureSubscriptionContext
    Set-BootstrapAzureSubscriptionContext `
        -SubscriptionId ([string]$Configuration.subscriptionId) `
        -TenantId ([string]$Configuration.tenantId)
    $script:GatewayFailureCode = 'plan_what_if'
    $whatIf = Invoke-GatewayFoundationWhatIf -Config $Configuration -RepositoryRoot $root -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) -SourceFingerprint $deploymentSourceFingerprint -ExecutionSourceFingerprint $sourceFingerprintBefore -State $State
    $script:GatewayFailureCode = 'plan_blueprint'
    Assert-GatewaySeedBlueprintPlanBoundary -Descriptor $descriptor -Config $Configuration -State $State | Out-Null
    $script:GatewayFailureCode = 'plan_stable_inputs'
    $sourceFingerprintAfter = Get-BootstrapSourceFingerprint
    $configurationFingerprintAfter = Get-BootstrapConfigurationFingerprint -Config $Configuration
    Assert-GatewayStablePlanInputs `
        -SourceFingerprintBefore $sourceFingerprintBefore `
        -SourceFingerprintAfter $sourceFingerprintAfter `
        -ConfigurationFingerprintBefore $configurationFingerprintBefore `
        -ConfigurationFingerprintAfter $configurationFingerprintAfter | Out-Null
    $configurationFingerprint = $configurationFingerprintBefore
    $sourceFingerprint = $sourceFingerprintBefore
    $planFingerprint = Get-GatewayPlanContractFingerprint -Descriptor $descriptor -WhatIf $whatIf -ConfigurationFingerprint $configurationFingerprint -SourceFingerprint $sourceFingerprint -DeploymentSourceFingerprint $deploymentSourceFingerprint
    Show-GatewayPlan -Descriptor $descriptor -SourceValidation $sourceValidation -WhatIf $whatIf -PlanFingerprint $planFingerprint -ConfigurationFingerprint $configurationFingerprint -SourceFingerprint $sourceFingerprint -OutputFormat $Format -EventStreamOnly:$StreamOnly | Out-Null
    if ($Format -eq 'Json') {
        Write-GatewayExperienceEvent -Type Info -Message "Plan $($descriptor.deploymentId); fingerprint $planFingerprint; configuration $configurationFingerprint; source $sourceFingerprint; SQL bootstrap uses the VNet-private, retry-disabled database job and restores the original Entra administrator" -Data ([ordered]@{
            step = $planEventBase.step; index = $planEventBase.index; total = $planEventBase.total
            category = 'scope'; deploymentId = [string]$descriptor.deploymentId
            scope = $descriptor.scope; planFingerprint = $planFingerprint
            configurationFingerprint = $configurationFingerprint; sourceFingerprint = $sourceFingerprint
        }) -OutputFormat Json
        $registryFlag = if ($descriptor.features.developmentRegistryPreview) { 'enabled for acknowledged development' } else { 'closed' }
        $shieldFlag = if ($descriptor.features.promptShields) { "enabled ($($descriptor.features.promptShieldSku))" } else { 'disabled' }
        $purviewFlag = if ($descriptor.features.purview) { 'policy authoring requested; runtime disabled' } else { 'not requested' }
        Write-GatewayExperienceEvent -Type Info -Message "Features: Registry preview $registryFlag; Content Safety shields $shieldFlag; Purview $purviewFlag." -Data ([ordered]@{
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

        $registryBoundary = if ($descriptor.features.developmentRegistryPreview) { 'Registry preview development opt-in is enabled' } else { 'Registry preview creation remains closed' }
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
        deploymentSourceFingerprint = $deploymentSourceFingerprint
        bootstrapClientIpv4 = $bootstrapClientIpv4
    }
}

function Invoke-GatewayResumePreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][ValidateSet('Text', 'Json')][string]$Format,
        [Parameter(Mandatory)][bool]$InstallLocalPrerequisites,
        [switch]$NonInteractive,
        [switch]$ExplicitlyAuthorized,
        [Parameter()][string]$ExpectedAcceptedPlanFingerprint = '',
        [Parameter()][string]$ExpectedResumeAuthorizationFingerprint = ''
    )

    $script:GatewayFailureStage = 'Resume preflight'
    $script:GatewayFailureCode = 'resume_preflight'
    $eventBase = [ordered]@{
        step = 'Resume preflight'
        index = 1
        total = (Get-GatewayBootstrapStepNames).Count
    }
    $invokeStage = {
        param(
            [Parameter(Mandatory)][string]$Code,
            [Parameter(Mandatory)][string]$Label,
            [Parameter(Mandatory)][scriptblock]$Action
        )

        try {
            $result = & $Action
        }
        catch {
            Write-GatewayExperienceEvent -Type Warning -Message "Resume preflight stopped at $Code. $Label could not be independently verified; no deployment mutation was started." -Data ([ordered]@{
                step = $eventBase.step; index = $eventBase.index; total = $eventBase.total
                category = 'resumePreflight'; stageCode = $Code; passed = $false
            }) -OutputFormat $Format
            throw [InvalidOperationException]::new("Resume preflight stopped at $Code.")
        }
        Write-GatewayExperienceEvent -Type Info -Message "Resume preflight passed ${Code}: $Label." -Data ([ordered]@{
            step = $eventBase.step; index = $eventBase.index; total = $eventBase.total
            category = 'resumePreflight'; stageCode = $Code; passed = $true
        }) -OutputFormat $Format
        return $result
    }
    $invokeBooleanStage = {
        param(
            [Parameter(Mandatory)][string]$Code,
            [Parameter(Mandatory)][string]$Label,
            [Parameter(Mandatory)][scriptblock]$Action
        )
        & $invokeStage -Code $Code -Label $Label -Action {
            [object[]]$values = @(& $Action)
            if ($values.Count -ne 1 -or $values[0] -isnot [bool] -or $values[0] -ne $true) {
                throw 'Exact read-only validator did not return one true Boolean result.'
            }
        } | Out-Null
    }

    [object[]]$bindingResults = @(& $invokeStage `
        -Code 'RP00_ACCEPTED_AUTHORIZATION' `
        -Label 'immutable accepted source, configuration, ownership, and original authorization' `
        -Action {
            if (-not $State.Contains('acceptedPlan') -or
                $State.acceptedPlan -isnot [System.Collections.IDictionary]) {
                throw 'No accepted plan exists.'
            }
            $recordedPlanFingerprint = [string]$State.acceptedPlan.planFingerprint
            $acceptedSourceFingerprint = [string]$State.acceptedPlan.sourceFingerprint
            $configurationFingerprint = Get-BootstrapConfigurationFingerprint -Config $Configuration
            if (-not [string]::IsNullOrWhiteSpace($ExpectedAcceptedPlanFingerprint) -and
                $ExpectedAcceptedPlanFingerprint -cne $recordedPlanFingerprint) {
                throw 'Expected accepted plan mismatch.'
            }
            # The original Apply window guarded the first mutation. Resume is a
            # new explicit authorization over the same immutable plan and source,
            # so its current confirmation replaces plan age without replacing the
            # preserved accepted-plan identity.
            Assert-BootstrapAcceptedPlan `
                -State $State `
                -PlanFingerprint $recordedPlanFingerprint `
                -ConfigurationFingerprint $configurationFingerprint `
                -SourceFingerprint $acceptedSourceFingerprint `
                -MaximumAge ([TimeSpan]::MaxValue) | Out-Null
            Assert-BootstrapStateAllowsSourcePlan -State $State | Out-Null
            if ((Get-BootstrapSourceFingerprint) -cne $acceptedSourceFingerprint) {
                throw 'Current source differs from accepted source.'
            }
            $executionSourceRoot = Resolve-BootstrapAcceptedSourceRoot -State $State
            Set-BootstrapExecutionSourceRoot -Path $executionSourceRoot
            foreach ($module in @('Experience', 'Prerequisites', 'Azure', 'Entra', 'Agent365', 'Database', 'Purview', 'Verification')) {
                Import-Module (Join-Path $executionSourceRoot "bootstrap/modules/$module.psm1") -Force -DisableNameChecking
            }
            Set-BootstrapExecutionSourceRoot -Path $executionSourceRoot
            $canonicalOwnershipId = ([guid][string]$State.deploymentOwnershipId).ToString('D')
            if ([string]$State.deploymentOwnershipId -cne $canonicalOwnershipId) {
                throw 'Deployment ownership is not canonical.'
            }
            return [ordered]@{
                acceptedPlanFingerprint = $recordedPlanFingerprint
                acceptedSourceFingerprint = $acceptedSourceFingerprint
                deploymentSourceFingerprint = Get-BootstrapEffectiveDeploymentSourceFingerprint `
                    -State $State -ExecutionSourceFingerprint $acceptedSourceFingerprint
                configurationFingerprint = $configurationFingerprint
                deploymentOwnershipId = $canonicalOwnershipId
                executionSourceRoot = $executionSourceRoot
            }
        })
    if ($bindingResults.Count -ne 1 -or $bindingResults[0] -isnot [System.Collections.IDictionary]) {
        throw 'Resume preflight stopped at RP00_ACCEPTED_AUTHORIZATION.'
    }
    $binding = $bindingResults[0]

    [object[]]$checkpointResults = @(& $invokeStage `
        -Code 'RP01_CHECKPOINT_CONTIGUITY' `
        -Label 'contiguous completed prefix and remaining step boundary' `
        -Action {
            Get-GatewayResumeCheckpointContext `
                -State $State `
                -Config $Configuration `
                -DeploymentOwnershipId ([string]$binding.deploymentOwnershipId) `
                -ExecutionSourceFingerprint ([string]$binding.acceptedSourceFingerprint) `
                -DeploymentSourceFingerprint ([string]$binding.deploymentSourceFingerprint)
        })
    if ($checkpointResults.Count -ne 1 -or $checkpointResults[0] -isnot [System.Collections.IDictionary]) {
        throw 'Resume preflight stopped at RP01_CHECKPOINT_CONTIGUITY.'
    }
    $checkpoint = $checkpointResults[0]

    & $invokeStage -Code 'RP02_LOCAL_PREREQUISITES' -Label 'current local prerequisite boundary' -Action {
        Assert-BootstrapPrerequisites `
            -Install:$InstallLocalPrerequisites `
            -RequirePurview:($Configuration.purview.enabled -eq $true) | Out-Null
    } | Out-Null

    [object[]]$azureIdentityResults = @(& $invokeStage `
        -Code 'RP03_AZURE_SESSION' `
        -Label 'configured tenant, subscription, and signed-in administrator' `
        -Action { Connect-BootstrapAzure -Config $Configuration -NonInteractive:$NonInteractive })
    if ($azureIdentityResults.Count -ne 1 -or
        $azureIdentityResults[0] -isnot [System.Collections.IDictionary]) {
        throw 'Resume preflight stopped at RP03_AZURE_SESSION.'
    }
    $azureIdentity = $azureIdentityResults[0]

    $completed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($stepName in @($checkpoint.completedSteps)) { $null = $completed.Add([string]$stepName) }
    $foundation = if ($completed.Contains('Azure foundation')) { $State.steps['Azure foundation'].evidence } else { $null }
    $identity = if ($completed.Contains('Gateway API identity')) { $State.steps['Gateway API identity'].evidence } else { $null }
    $images = if ($completed.Contains('Immutable workload images')) { $State.steps['Immutable workload images'].evidence } else { $null }
    $inert = if ($completed.Contains('Inert identity deployment')) { $State.steps['Inert identity deployment'].evidence } else { $null }
    $blueprint = if ($completed.Contains('Agent 365 seed blueprint')) { $State.steps['Agent 365 seed blueprint'].evidence } else { $null }
    $sqlPrivateEndpoint = if ($completed.Contains('SQL private endpoint')) { $State.steps['SQL private endpoint'].evidence } else { $null }
    $database = if ($completed.Contains('Gateway database')) { $State.steps['Gateway database'].evidence } else { $null }
    $adminIdentity = if ($completed.Contains('Admin UI identity')) { $State.steps['Admin UI identity'].evidence } else { $null }
    $adminCredential = if ($completed.Contains('Admin UI Key Vault credential')) { $State.steps['Admin UI Key Vault credential'].evidence } else { $null }
    $purview = if ($completed.Contains('Purview policies')) { $State.steps['Purview policies'].evidence } else { $null }
    $runtime = if ($completed.Contains('Gateway runtime deployment')) { $State.steps['Gateway runtime deployment'].evidence } else { $null }
    $adminUi = if ($completed.Contains('Admin UI deployment')) { $State.steps['Admin UI deployment'].evidence } else { $null }
    $databaseValidationPlans = Get-BootstrapCompletedDatabaseValidationPlans -State $State

    foreach ($stepName in @($checkpoint.completedSteps)) {
        switch -CaseSensitive ($stepName) {
            'Prerequisites' {
                # RP02 already reran this exact local check.
            }
            'Azure authentication' {
                & $invokeBooleanStage -Code 'RP04_AZURE_AUTHENTICATION' -Label 'persisted Azure authentication checkpoint' -Action {
                    $evidence = $State.steps['Azure authentication'].evidence
                    return $evidence -is [System.Collections.IDictionary] -and
                        [string]$evidence.subscriptionId -ceq [string]$Configuration.subscriptionId -and
                        [string]$evidence.tenantId -ceq [string]$Configuration.tenantId -and
                        [string]$evidence.userObjectId -ceq [string]$azureIdentity.userObjectId
                }
            }
            'Azure provider registration' {
                & $invokeBooleanStage -Code 'RP05_AZURE_PROVIDER_REGISTRATION' -Label 'required Azure resource providers' -Action {
                    Test-GatewayResourceProviderEvidence
                }
            }
            'Azure foundation' {
                & $invokeBooleanStage -Code 'RP06_AZURE_FOUNDATION' -Label 'subscription deployment and foundation resources' -Action {
                    Test-GatewaySubscriptionDeploymentEvidence -Config $Configuration -Evidence $foundation `
                        -DeploymentOwnershipId ([string]$binding.deploymentOwnershipId) `
                        -SourceFingerprint ([string]$binding.deploymentSourceFingerprint)
                }
            }
            'Gateway API identity' {
                & $invokeBooleanStage -Code 'RP07_GATEWAY_API_IDENTITY' -Label 'Gateway API application' -Action {
                    Test-GatewayApplicationEvidence -Config $Configuration -Evidence $identity `
                        -ObjectIdProperty 'gatewayApiApplicationObjectId' -ClientIdProperty 'gatewayApiClientId' `
                        -ApplicationKind GatewayApi
                }
            }
            'Immutable workload images' {
                & $invokeBooleanStage -Code 'RP08_IMMUTABLE_IMAGES' -Label 'immutable workload image digests' -Action {
                    Test-GatewayImmutableImageEvidence -Evidence $images `
                        -SourceFingerprint ([string]$binding.deploymentSourceFingerprint) `
                        -DeploymentOwnershipId ([string]$binding.deploymentOwnershipId)
                }
            }
            'Inert identity deployment' {
                & $invokeBooleanStage -Code 'RP09_INERT_IDENTITY_DEPLOYMENT' -Label 'inert API and worker deployment' -Action {
                    Test-GatewayGroupDeploymentEvidence -Config $Configuration -Foundation $foundation -Identity $identity `
                        -Evidence $inert -DeploymentOwnershipId ([string]$binding.deploymentOwnershipId) `
                        -SourceFingerprint ([string]$binding.deploymentSourceFingerprint) `
                        -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) `
                        -AllowRuntimeSupersession:($completed.Contains('Gateway runtime deployment'))
                }
            }
            'Agent 365 seed blueprint' {
                & $invokeBooleanStage -Code 'RP10_AGENT365_BLUEPRINT' -Label 'seed Agent ID blueprint' -Action {
                    Test-GatewayBlueprintEvidence -Config $Configuration -Evidence $blueprint `
                        -DeploymentOwnershipId ([string]$binding.deploymentOwnershipId) `
                        -SourceFingerprint ([string]$binding.deploymentSourceFingerprint) `
                        -SponsorObjectId ([string]$azureIdentity.userObjectId) `
                        -GatewayManagedIdentityPrincipalId ([string]$inert.workerPrincipalId)
                }
            }
            'Workflow v3 Entra configuration' {
                & $invokeBooleanStage -Code 'RP11_WORKFLOW_V3_ENTRA' -Label 'workflow-v3 Entra configuration' -Action {
                    Test-GatewayWorkflowIdentityEvidence -Config $Configuration -Identity $identity -Inert $inert `
                        -Evidence $State.steps['Workflow v3 Entra configuration'].evidence
                }
            }
            'SQL private endpoint' {
                & $invokeBooleanStage -Code 'RP12_SQL_PRIVATE_ENDPOINT' -Label 'SQL private endpoint and DNS tuple' -Action {
                    Test-GatewaySqlPrivateEndpointEvidence -Config $Configuration -Foundation $foundation `
                        -SqlServerFqdn ([string]$inert.sqlServerFqdn) -Evidence $sqlPrivateEndpoint `
                        -DeploymentOwnershipId ([string]$binding.deploymentOwnershipId) `
                        -SourceFingerprint ([string]$binding.deploymentSourceFingerprint)
                }
            }
            'Gateway database' {
                & $invokeBooleanStage -Code 'RP13_GATEWAY_DATABASE_JOB_RECEIPT' -Label 'database receipt, persistent Job, one execution, schema, and administrator restoration' -Action {
                    Test-GatewayDatabaseEvidence -Config $Configuration -Foundation $foundation -Inert $inert `
                        -Evidence $database -StepRecord $State.steps['Gateway database'] `
                        -DeploymentOwnershipId ([string]$binding.deploymentOwnershipId) `
                        -SourceFingerprint ([string]$binding.deploymentSourceFingerprint) `
                        -DatabaseMigratorImage ([string]$images.databaseMigrator) `
                        -DatabaseRecoveryPlan $databaseValidationPlans.databaseRecoveryPlan `
                        -ManualDatabaseRepairPlan $databaseValidationPlans.manualDatabaseRepairPlan
                }
            }
            'Admin UI identity' {
                & $invokeBooleanStage -Code 'RP14_ADMIN_UI_IDENTITY' -Label 'Admin UI application' -Action {
                    $expectedAdminUiUrl = if ($null -ne $adminUi) { [string]$adminUi.adminUiUrl } else { '' }
                    Test-GatewayApplicationEvidence -Config $Configuration -Evidence $adminIdentity `
                        -ObjectIdProperty 'adminUiApplicationObjectId' -ClientIdProperty 'adminUiClientId' `
                        -ApplicationKind AdminUi -ExpectedAdminUiUrl $expectedAdminUiUrl
                }
            }
            'Admin UI Key Vault credential' {
                & $invokeBooleanStage -Code 'RP15_ADMIN_UI_CREDENTIAL' -Label 'Admin UI credential and management-plane vault metadata' -Action {
                    Test-GatewayAdminCredentialEvidence -Config $Configuration -AdminIdentity $adminIdentity `
                        -Inert $inert -Evidence $adminCredential `
                        -DeploymentOwnershipId ([string]$binding.deploymentOwnershipId) `
                        -SourceFingerprint ([string]$binding.deploymentSourceFingerprint)
                }
            }
            'Purview policies' {
                & $invokeBooleanStage -Code 'RP16_PURVIEW_POLICIES' -Label 'optional Purview policy evidence' -Action {
                    Test-GatewayPurviewEvidence -Config $Configuration -Blueprint $blueprint -Evidence $purview `
                        -UserPrincipalName ([string]$azureIdentity.userPrincipalName) -NonInteractive:$NonInteractive
                }
            }
            'Gateway runtime deployment' {
                & $invokeBooleanStage -Code 'RP17_GATEWAY_RUNTIME' -Label 'runtime API and worker deployment' -Action {
                    Test-GatewayGroupDeploymentEvidence -Config $Configuration -Foundation $foundation -Identity $identity `
                        -Evidence $runtime -DeploymentOwnershipId ([string]$binding.deploymentOwnershipId) `
                        -SourceFingerprint ([string]$binding.deploymentSourceFingerprint) `
                        -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -Database $database
                }
            }
            'Admin UI deployment' {
                & $invokeBooleanStage -Code 'RP18_ADMIN_UI_DEPLOYMENT' -Label 'Admin UI deployment' -Action {
                    Test-GatewayNamedGroupDeployment -Config $Configuration -Foundation $foundation -Runtime $runtime `
                        -Identity $identity -AdminIdentity $adminIdentity -AdminCredential $adminCredential `
                        -DeploymentName "a365gw-$($Configuration.projectName)-bootstrap-admin-$($Configuration.environment)" `
                        -Evidence $adminUi -DeploymentOwnershipId ([string]$binding.deploymentOwnershipId) `
                        -SourceFingerprint ([string]$binding.deploymentSourceFingerprint) `
                        -AdminUiImage ([string]$images.adminUi)
                }
            }
            'Admin UI redirect URIs' {
                & $invokeBooleanStage -Code 'RP19_ADMIN_UI_REDIRECTS' -Label 'Admin UI redirect URI surface' -Action {
                    Test-GatewayAdminRedirectEvidence -AdminIdentity $adminIdentity -AdminUi $adminUi
                }
            }
            'Network hardening' {
                & $invokeBooleanStage -Code 'RP20_NETWORK_HARDENING' -Label 'post-deployment network hardening' -Action {
                    Test-GatewayNetworkHardeningEvidence -Config $Configuration `
                        -Evidence $State.steps['Network hardening'].evidence
                }
            }
            'End-to-end deployment verification' {
                & $invokeStage -Code 'RP21_END_TO_END_VERIFICATION' -Label 'current end-to-end deployment verification' -Action {
                    Test-GatewayBootstrapDeployment -Config $Configuration -Foundation $foundation -Identity $identity `
                        -Blueprint $blueprint -Runtime $runtime -Database $database `
                        -SqlPrivateEndpoint $sqlPrivateEndpoint -AdminUi $adminUi -Images $images `
                        -AdminIdentity $adminIdentity -AdminCredential $adminCredential `
                        -DeploymentOwnershipId ([string]$binding.deploymentOwnershipId) `
                        -DatabaseRecoveryPlan $databaseValidationPlans.databaseRecoveryPlan `
                        -ManualDatabaseRepairPlan $databaseValidationPlans.manualDatabaseRepairPlan `
                        -State $State -NonInteractive:$NonInteractive | Out-Null
                } | Out-Null
            }
        }
    }

    $resumeAuthorizationFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
        schemaVersion = 2
        acceptedPlanFingerprint = [string]$binding.acceptedPlanFingerprint
        configurationFingerprint = [string]$binding.configurationFingerprint
        acceptedSourceFingerprint = [string]$binding.acceptedSourceFingerprint
        deploymentSourceFingerprint = [string]$binding.deploymentSourceFingerprint
        deploymentOwnershipId = [string]$binding.deploymentOwnershipId
        checkpointFingerprint = [string]$checkpoint.checkpointFingerprint
        remainingSteps = @($checkpoint.remainingSteps)
    })
    Write-GatewayExperienceEvent -Type Result -Message "Resume preflight validated $(@($checkpoint.completedSteps).Count) completed checkpoints. Remaining work starts at '$($checkpoint.currentStep)'." -Data ([ordered]@{
        step = $eventBase.step; index = $eventBase.index; total = $eventBase.total
        category = 'resumeReview'; completedCount = @($checkpoint.completedSteps).Count
        remainingCount = @($checkpoint.remainingSteps).Count; currentStep = [string]$checkpoint.currentStep
        acceptedPlanFingerprint = [string]$binding.acceptedPlanFingerprint
        checkpointFingerprint = [string]$checkpoint.checkpointFingerprint
        resumeAuthorizationFingerprint = $resumeAuthorizationFingerprint; authorized = $false
    }) -OutputFormat $Format

    if ($NonInteractive -and -not $ExplicitlyAuthorized) {
        return [ordered]@{
            acceptedPlanFingerprint = [string]$binding.acceptedPlanFingerprint
            acceptedSourceFingerprint = [string]$binding.acceptedSourceFingerprint
            deploymentSourceFingerprint = [string]$binding.deploymentSourceFingerprint
            deploymentOwnershipId = [string]$binding.deploymentOwnershipId
            executionSourceRoot = [string]$binding.executionSourceRoot
            checkpoint = $checkpoint
            resumeAuthorizationFingerprint = $resumeAuthorizationFingerprint
            explicitlyAuthorized = $false
            reviewOnly = $true
        }
    }

    $authorized = [bool]$ExplicitlyAuthorized
    if ($NonInteractive) {
        if (-not $authorized -or
            [string]::IsNullOrWhiteSpace($ExpectedAcceptedPlanFingerprint) -or
            [string]::IsNullOrWhiteSpace($ExpectedResumeAuthorizationFingerprint) -or
            $ExpectedResumeAuthorizationFingerprint -cne $resumeAuthorizationFingerprint) {
            $authorized = $false
        }
    }
    elseif (-not $NonInteractive -and -not $ExplicitlyAuthorized) {
        $authorized = Read-GatewayYesNo -Prompt "Authorize Resume from '$($checkpoint.currentStep)' using the preserved accepted plan" -Default $false
    }
    if (-not $authorized) {
        & $invokeStage -Code 'RP22_EXPLICIT_AUTHORIZATION' -Label 'current explicit Resume authorization' -Action {
            throw 'Resume was not explicitly authorized.'
        } | Out-Null
    }
    Write-GatewayExperienceEvent -Type Result -Message 'Checkpoint-aware Resume is explicitly authorized. Only the validated remaining step sequence may execute.' -Data ([ordered]@{
        step = $eventBase.step; index = $eventBase.index; total = $eventBase.total
        category = 'resumeAuthorization'; stageCode = 'RP22_EXPLICIT_AUTHORIZATION'; authorized = $true
        resumeAuthorizationFingerprint = $resumeAuthorizationFingerprint
    }) -OutputFormat $Format

    return [ordered]@{
        acceptedPlanFingerprint = [string]$binding.acceptedPlanFingerprint
        acceptedSourceFingerprint = [string]$binding.acceptedSourceFingerprint
        deploymentSourceFingerprint = [string]$binding.deploymentSourceFingerprint
        deploymentOwnershipId = [string]$binding.deploymentOwnershipId
        executionSourceRoot = [string]$binding.executionSourceRoot
        checkpoint = $checkpoint
        resumeAuthorizationFingerprint = $resumeAuthorizationFingerprint
        explicitlyAuthorized = $true
        reviewOnly = $false
    }
}

function Get-GatewaySafeFailureEvent {
    param(
        [Parameter(Mandatory)][string]$FailureCode,
        [Parameter(Mandatory)][string]$FailureStage,
        [Parameter(Mandatory)][string]$CommandMode,
        [Parameter()][AllowNull()][Exception]$Exception
    )

    $effectiveFailureCode = $FailureCode
    if ($FailureCode -ceq 'plan_what_if' -and $null -ne $Exception) {
        $typedFailureCode = $Exception.Data['GatewaySafeFailureCode']
        if ($typedFailureCode -is [string] -and $typedFailureCode -ceq 'sql_regional_availability') {
            $effectiveFailureCode = 'plan_sql_availability'
        }
    }

    $message = switch ($effectiveFailureCode) {
        'configuration' { 'Bootstrap configuration could not be loaded. Run gateway doctor, then reopen Setup or run Plan again.' }
        'state' { 'Bootstrap state could not be loaded safely. Keep .bootstrap intact, run gateway diagnose, then retry the same command.' }
        'diagnose' { 'Diagnose could not write its safe bundle. Run gateway doctor and review local file access.' }
        'plan_state' { 'The preserved bootstrap state does not allow a new Plan. Keep .bootstrap intact and run gateway diagnose.' }
        'plan_prerequisites' { 'Local prerequisite validation failed. Run gateway doctor, correct its failed item, then run Plan again.' }
        'plan_source' { 'Repository or Bicep validation failed. Run gateway doctor, correct the reported tool or source issue, then run Plan again.' }
        'plan_account' { 'The configured Azure tenant and subscription could not be selected. Run az login, verify the active subscription, then run Plan again.' }
        'plan_sql_availability' { 'Azure SQL regional availability could not be verified for the selected region and SKU. Confirm the Azure session and subscription access, or choose another listed region, then run Plan again.' }
        'plan_what_if' { 'Azure What-If could not produce a reviewable result. Check the Azure session, subscription access, required providers, policy, region, and quota, then run Plan again.' }
        'plan_blueprint' { 'The Agent ID blueprint boundary check did not complete. Confirm tenant eligibility and Graph access, then run Plan again.' }
        'plan_stable_inputs' { 'Source or configuration changed while Plan was running. Stop edits and run Plan again.' }
        'plan_acceptance' { 'Plan could not be accepted because its reviewed fingerprint or apply-ready result did not match. Run Plan again.' }
        'resume_required' { 'This deployment has already started. Its accepted plan was preserved; run gateway resume so completed checkpoints are revalidated before remaining work continues.' }
        'resume_preflight' { 'Resume preflight could not verify the preserved authorization and completed checkpoint prefix. Keep .bootstrap intact, run gateway diagnose, then retry Resume.' }
        'status' { 'Bootstrap status could not be calculated from the preserved local checkpoints. Keep .bootstrap intact and run gateway diagnose.' }
        'open' { 'The verified Admin UI endpoint could not be opened. Run gateway verify, then run gateway open again.' }
        'verification' { 'Deployment verification stopped before it could prove the current live boundary. Keep .bootstrap intact and run gateway diagnose.' }
        'deployment' { 'Deployment stopped at a persisted checkpoint. Keep .bootstrap intact, run gateway diagnose, then Resume.' }
        default {
            if ($CommandMode -eq 'Plan') {
                'Plan stopped before approval. Run gateway doctor, correct the reported failure, then run Plan again.'
            }
            else {
                'Gateway bootstrap stopped safely. Keep .bootstrap intact and run gateway diagnose before retrying.'
            }
        }
    }
    $isPlanFailure = $effectiveFailureCode.StartsWith('plan_', [StringComparison]::Ordinal)
    return [ordered]@{
        message = $message
        data = [ordered]@{
            step = $FailureStage
            category = if ($isPlanFailure) { 'planFailure' } else { 'bootstrapFailure' }
            failureCode = $effectiveFailureCode
            resumable = [bool]($effectiveFailureCode -eq 'deployment')
        }
    }
}

Set-BootstrapStructuredOutput -Enabled ([bool]($OutputFormat -eq 'Json'))
$script:GatewayFailureStage = 'Bootstrap'
$script:GatewayFailureCode = 'bootstrap'
try {
if ($EventStreamOnly -and $OutputFormat -ne 'Json') {
    Write-GatewayExperienceEvent -Type Warning -Message 'EventStreamOnly requires JSON output.' -Data ([ordered]@{ step = 'Bootstrap'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
    throw 'Invalid event-stream mode.'
}
if ($EventStreamOnly -and $Mode -notin @('Plan', 'Up', 'Resume')) {
    Write-GatewayExperienceEvent -Type Warning -Message 'EventStreamOnly is valid only for Plan, Up, or Resume.' -Data ([ordered]@{ step = 'Bootstrap'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
    throw 'Invalid event-stream command.'
}
if ($expectedConfigurationFileFingerprintSupplied) {
    if ($Mode -cne 'Plan') {
        Write-GatewayExperienceEvent -Type Warning -Message 'ExpectedConfigurationFileFingerprint is valid only for Plan.' -Data ([ordered]@{ step = 'Configuration'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
        throw 'Invalid expected-configuration-file mode.'
    }
    if ($ExpectedConfigurationFileFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        Write-GatewayExperienceEvent -Type Warning -Message 'ExpectedConfigurationFileFingerprint must use canonical lowercase sha256 format.' -Data ([ordered]@{ step = 'Configuration'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
        throw 'Invalid expected-configuration-file fingerprint.'
    }
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint)) {
    if ($Mode -notin @('Plan', 'Apply', 'Up', 'Resume', 'RecoverDatabase')) {
        Write-GatewayExperienceEvent -Type Warning -Message 'ExpectedPlanFingerprint is valid only for Plan, Apply, Up, Resume, or RecoverDatabase.' -Data ([ordered]@{ step = 'Plan review'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
        throw 'Invalid expected-plan mode.'
    }
    if ($ExpectedPlanFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        Write-GatewayExperienceEvent -Type Warning -Message 'ExpectedPlanFingerprint must use canonical lowercase sha256 format.' -Data ([ordered]@{ step = 'Plan review'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
        throw 'Invalid expected-plan fingerprint.'
    }
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedResumeAuthorizationFingerprint)) {
    if ($Mode -cne 'Resume') {
        Write-GatewayExperienceEvent -Type Warning -Message 'ExpectedResumeAuthorizationFingerprint is valid only for Resume.' -Data ([ordered]@{ step = 'Resume preflight'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
        throw 'Invalid expected-Resume-authorization mode.'
    }
    if ($ExpectedResumeAuthorizationFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$') {
        Write-GatewayExperienceEvent -Type Warning -Message 'ExpectedResumeAuthorizationFingerprint must use canonical lowercase sha256 format.' -Data ([ordered]@{ step = 'Resume preflight'; index = 1; total = (Get-GatewayBootstrapStepNames).Count }) -OutputFormat $OutputFormat
        throw 'Invalid expected-Resume-authorization fingerprint.'
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

if ($Mode -eq 'Diagnose') {
    $script:GatewayFailureStage = 'Diagnostics'
    $script:GatewayFailureCode = 'diagnose'
    $doctor = Get-GatewayDoctorReport -ConfigPath $Config
    $configuration = $null
    $status = $null
    $configurationStatus = if (Test-Path -LiteralPath $Config) { 'Invalid' } else { 'Missing' }
    if (Test-Path -LiteralPath $Config) {
        try {
            $configuration = Read-BootstrapConfig -Path $Config
            $configurationStatus = 'Validated'
        }
        catch {
            $configuration = $null
            $configurationStatus = 'Invalid'
        }
        if ($null -ne $configuration) {
            try {
                $statePath = Get-BootstrapStatePath -Config $configuration
                $state = Read-BootstrapState -Path $statePath -Config $configuration
                $status = Get-GatewayBootstrapStatus -Config $configuration -State $state -StatePath $statePath
            }
            catch {
                $status = $null
                $configurationStatus = 'StateUnavailable'
            }
        }
    }
    $diagnostic = Write-GatewayDiagnosticBundle -Config $configuration -Doctor $doctor -Status $status -ConfigurationStatus $configurationStatus -Path $DiagnosticPath
    if ($OutputFormat -eq 'Json') {
        Write-GatewayResult -Value ([ordered]@{ diagnosticPath = $diagnostic.diagnosticPath; safeFieldsOnly = $true }) -OutputFormat Json
    }
    else {
        Write-GatewayExperienceEvent -Type Result -Message "Safe diagnostic bundle written to $($diagnostic.diagnosticPath). It excludes credentials, tokens, Gateway keys, prompts, responses, and dependency bodies."
    }
    return
}

if ($Mode -eq 'Up' -and -not (Test-Path -LiteralPath $Config)) {
    Write-GatewayExperienceEvent -Type Info -Message 'No bootstrap configuration exists; starting the guided setup wizard.' -Data ([ordered]@{
        step = 'Configuration'; index = 1; total = (Get-GatewayBootstrapStepNames).Count
    }) -OutputFormat $OutputFormat
    $null = New-GatewayBootstrapConfiguration -Path $Config -NonInteractive:$NonInteractive -Force:$Force
}

$script:GatewayFailureStage = 'Configuration'
$script:GatewayFailureCode = 'configuration'
if (-not (Test-Path -LiteralPath $Config)) {
    throw "Bootstrap configuration '$Config' does not exist. Run gateway init, or supply -Config with a reviewed non-secret configuration."
}

$configuration = if ($expectedConfigurationFileFingerprintSupplied) {
    Read-BootstrapConfig `
        -Path $Config `
        -ExpectedConfigurationFileFingerprint $ExpectedConfigurationFileFingerprint
}
else {
    Read-BootstrapConfig -Path $Config
}
if ($configuration.purview.enabled -eq $true -and
    $Mode -in @('Apply', 'Resume', 'Up', 'Verify') -and
    -not (Test-BootstrapSecurityCompliancePlatformSupported)) {
    throw 'Purview-enabled deployment and verification require Windows because Microsoft does not support Security & Compliance PowerShell for this workflow on macOS or Linux. Run this command from Windows, or keep Purview policy authoring off on this computer.'
}

$script:GatewayFailureStage = 'Bootstrap state'
$script:GatewayFailureCode = 'state'
$statePath = Get-BootstrapStatePath -Config $configuration
$state = Read-BootstrapState -Path $statePath -Config $configuration

if ($Mode -eq 'Status') {
    $script:GatewayFailureStage = 'Status'
    $script:GatewayFailureCode = 'status'
    $status = Get-GatewayBootstrapStatus -Config $configuration -State $state -StatePath $statePath
    Show-GatewayBootstrapStatus -Status $status -OutputFormat $OutputFormat
    return
}

if ($Mode -eq 'Open') {
    $script:GatewayFailureStage = 'Open Admin UI'
    $script:GatewayFailureCode = 'open'
    $status = Get-GatewayBootstrapStatus -Config $configuration -State $state -StatePath $statePath
    $opened = Open-GatewayAdminUi -Status $status
    if ($OutputFormat -eq 'Json') { Write-GatewayResult -Value $opened -OutputFormat Json }
    else { Write-GatewayExperienceEvent -Type Result -Message "Opened $($opened.adminUiUrl)" }
    return
}

$lock = $null
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$stepNames = @(Get-GatewayBootstrapStepNames)
$plan = $null
$resumePreflight = $null
$activeAcceptedPlanFingerprint = ''
$activeAcceptedSourceFingerprint = ''
$activeDeploymentSourceFingerprint = ''

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
        $acceptedPlanMaximumAge = if ($Mode -eq 'Resume') {
            # Dedicated Resume preflight obtained a new explicit confirmation over
            # the immutable accepted authorization before any mutation step. At
            # this point the accepted-plan assertion is provenance-only; the
            # process-local Resume fingerprint is the current authorization.
            [TimeSpan]::MaxValue
        }
        else { [TimeSpan]::FromMinutes(60) }
        Assert-BootstrapAcceptedPlan `
            -State $state `
            -PlanFingerprint $activeAcceptedPlanFingerprint `
            -ConfigurationFingerprint (Get-BootstrapConfigurationFingerprint -Config $configuration) `
            -SourceFingerprint ([string]$state.acceptedPlan.sourceFingerprint) `
            -MaximumAge $acceptedPlanMaximumAge | Out-Null
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
    $preservePreInertPrefix = $state.Contains('preInertSourceCorrectionPlan') -and
        $state.preInertSourceCorrectionPlan -is [System.Collections.IDictionary] -and
        [string]$state.preInertSourceCorrectionPlan.status -cin @('Accepted', 'Completed') -and
        $Name -cin @(
            'Azure provider registration',
            'Azure foundation',
            'Gateway API identity',
            'Immutable workload images'
        )
    if ($preservePreInertPrefix) { $parameters.ValidateAndReuseOnly = $true }
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
    # Every command that can mutate state or depend on a stable checkpoint view
    # refreshes the state only after holding the per-deployment lock. The earlier
    # read exists solely for the lock-free Status/Open paths above.
    $state = Read-BootstrapState -Path $statePath -Config $configuration
    $hasStartedCheckpoint = (
        $state.Contains('steps') -and
        $state.steps -is [System.Collections.IDictionary] -and
        $state.steps.Count -gt 0
    )
    if ($hasStartedCheckpoint -and $Mode -eq 'Plan') {
        $script:GatewayFailureStage = 'Resume required'
        $script:GatewayFailureCode = 'resume_required'
        throw 'This deployment already has persisted checkpoints. The accepted plan was preserved; run gateway resume instead of creating a new plan.'
    }
    if ($hasStartedCheckpoint -and $Mode -in @('Apply', 'Up')) {
        $routedFrom = $Mode
        Write-GatewayExperienceEvent -Type Info -Message "A persisted deployment checkpoint exists. Gateway $routedFrom is continuing through the dedicated Resume preflight; it will not create or clear a fresh plan." -Data ([ordered]@{
            step = 'Resume preflight'; index = 1; total = $stepNames.Count; routedFrom = $routedFrom
        }) -OutputFormat $OutputFormat
        $Mode = 'Resume'
    }
    if ($Mode -eq 'Verify') {
        $script:GatewayFailureStage = 'Verification'
        $script:GatewayFailureCode = 'verification'
        Assert-BootstrapStateAllowsSourcePlan -State $state | Out-Null
    }

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

    if ($Mode -eq 'RepairDatabase') {
        if ($EventStreamOnly) { throw 'RepairDatabase does not support EventStreamOnly.' }
        if (-not $Yes) { throw 'RepairDatabase is a direct one-shot operation and requires --yes. It has no Plan or What-If mode.' }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint)) {
            throw 'RepairDatabase does not accept an expected Plan fingerprint because it has no Plan or What-If mode.'
        }
        Assert-GatewayPlanPrerequisites -Install:$InstallPrerequisites | Out-Null
        $null = Connect-BootstrapAzure -Config $configuration -NonInteractive:$NonInteractive
        Assert-BootstrapManualDatabaseRepairPrerequisite -State $state | Out-Null

        if ($state.Contains('manualDatabaseRepairPlan') -and
            $state.manualDatabaseRepairPlan -is [System.Collections.IDictionary] -and
            [string]$state.manualDatabaseRepairPlan.status -ceq 'Completed') {
            Assert-BootstrapAcceptedManualDatabaseRepairPlan `
                -State $state -PlanFingerprint ([string]$state.manualDatabaseRepairPlan.planFingerprint) -AllowCompleted | Out-Null
            Write-GatewayExperienceEvent -Type Result -Message 'The one-shot manual database repair is already complete. The two automatic recovery failures remain preserved; run gateway resume.' -Data ([ordered]@{
                step = 'Gateway database'; index = 11; total = $stepNames.Count
                manualDatabaseRepairPlanFingerprint = [string]$state.manualDatabaseRepairPlan.planFingerprint
                repaired = $true; runOnce = $true
            }) -OutputFormat $OutputFormat
            return
        }
        if ($state.Contains('manualDatabaseRepairPlan') -and
            $state.manualDatabaseRepairPlan -is [System.Collections.IDictionary] -and
            [string]$state.manualDatabaseRepairPlan.status -ceq 'Failed') {
            throw 'The one authorized manual database repair execution failed. It is preserved and cannot be replaced, restarted, or deleted.'
        }

        $plan = if ($state.Contains('manualDatabaseRepairPlan')) {
            Assert-BootstrapAcceptedManualDatabaseRepairPlan `
                -State $state -PlanFingerprint ([string]$state.manualDatabaseRepairPlan.planFingerprint) | Out-Null
            $state.manualDatabaseRepairPlan
        }
        else {
            $candidate = Get-GatewayManualDatabaseRepairPlan -Configuration $configuration -State $state
            Set-BootstrapAcceptedManualDatabaseRepairPlan -State $state -StatePath $statePath -Plan $candidate
        }
        $planFingerprint = [string]$plan.planFingerprint
        Assert-BootstrapAcceptedManualDatabaseRepairPlan -State $state -PlanFingerprint $planFingerprint | Out-Null
        $repairSourceRoot = Resolve-BootstrapManualDatabaseRepairPlanSourceRoot -State $state -Plan $state.manualDatabaseRepairPlan
        Set-BootstrapExecutionSourceRoot -Path $repairSourceRoot
        foreach ($module in @('Experience', 'Prerequisites', 'Azure', 'Entra', 'Agent365', 'Database', 'Purview', 'Verification')) {
            Import-Module (Join-Path $repairSourceRoot "bootstrap/modules/$module.psm1") -Force -DisableNameChecking
        }
        Set-BootstrapExecutionSourceRoot -Path $repairSourceRoot

        $foundation = $state.steps['Azure foundation'].evidence
        $identity = $state.steps['Gateway API identity'].evidence
        $inert = $state.steps['Inert identity deployment'].evidence
        $sqlPrivateEndpoint = $state.steps['SQL private endpoint'].evidence
        $apiPrincipal = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inert.apiPrincipalId)
        $workerPrincipal = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inert.workerPrincipalId)
        $liveOriginalFailure = Get-GatewayFailedDatabaseBootstrapBoundary `
            -Config $configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
            -SqlServerFqdn ([string]$inert.sqlServerFqdn) -OriginalJobImage ([string]$plan.originalFailedJob.jobImage) `
            -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
            -OriginalSourceFingerprint ([string]$plan.originalSourceFingerprint) `
            -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
            -OriginalAdministratorObjectId ([string]$identity.userObjectId) `
            -OriginalAdministratorLogin ([string]$identity.userPrincipalName)
        $liveFirstFailure = Get-GatewayFailedDatabaseRecoveryBoundary `
            -Config $configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
            -SqlServerFqdn ([string]$inert.sqlServerFqdn) -RecoveryPlan $plan.exhaustedRecoveryPlan.previousRecoveryPlan `
            -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
            -OriginalAdministratorObjectId ([string]$identity.userObjectId) `
            -OriginalAdministratorLogin ([string]$identity.userPrincipalName)
        $liveSecondFailure = Get-GatewayFailedDatabaseRecoveryBoundary `
            -Config $configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
            -SqlServerFqdn ([string]$inert.sqlServerFqdn) -RecoveryPlan $plan.exhaustedRecoveryPlan `
            -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
            -OriginalAdministratorObjectId ([string]$identity.userObjectId) `
            -OriginalAdministratorLogin ([string]$identity.userPrincipalName)
        if ([string]$liveOriginalFailure.boundaryFingerprint -cne [string]$plan.originalFailedJob.boundaryFingerprint -or
            [string]$liveFirstFailure.boundaryFingerprint -cne [string]$plan.firstFailedRecovery.boundaryFingerprint -or
            [string]$liveSecondFailure.boundaryFingerprint -cne [string]$plan.secondFailedRecovery.boundaryFingerprint) {
            throw 'The exact original/attempt-one/attempt-two failure chain changed after manual repair acceptance. No repair mutation was started.'
        }

        $null = Start-BootstrapManualDatabaseRepairPlan -State $state -StatePath $statePath -PlanFingerprint $planFingerprint
        $repairImage = Build-GatewayDatabaseRecoveryImage `
            -Config $configuration -AcrLoginServer ([string]$foundation.acrLoginServer) `
            -SourceFingerprint ([string]$plan.repairSourceFingerprint) `
            -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
            -RecoveryPlanFingerprint $planFingerprint `
            -BuildIntent $state.manualDatabaseRepairPlan.correctedImage `
            -Checkpoint {
                param($imageEvidence)
                $state.manualDatabaseRepairPlan.correctedImage = ConvertTo-BootstrapCanonicalValue -Value $imageEvidence
                Save-BootstrapState -State $state -Path $statePath
            }
        $database = $null
        $databaseFailure = $null
        try {
            $database = Initialize-GatewayDatabase `
                -Config $configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
                -SqlServerFqdn ([string]$inert.sqlServerFqdn) `
                -ApiPrincipalId ([string]$inert.apiPrincipalId) -WorkerPrincipalId ([string]$inert.workerPrincipalId) `
                -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
                -DatabaseMigratorImage ([string]$repairImage.image) `
                -OriginalEntraAdministratorObjectId ([string]$identity.userObjectId) `
                -OriginalEntraAdministratorLogin ([string]$identity.userPrincipalName) `
                -BootstrapClientIpv4 ([string]$state.acceptedPlan.bootstrapClientIpv4) `
                -ManualRepairPlan $state.manualDatabaseRepairPlan
        }
        catch { $databaseFailure = $_ }
        if ($null -ne $databaseFailure) {
            $failedRepair = $null
            try {
                $failedRepair = Get-GatewayFailedManualDatabaseRepairBoundary `
                    -Config $configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
                    -SqlServerFqdn ([string]$inert.sqlServerFqdn) -ManualRepairPlan $state.manualDatabaseRepairPlan `
                    -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
                    -OriginalAdministratorObjectId ([string]$identity.userObjectId) `
                    -OriginalAdministratorLogin ([string]$identity.userPrincipalName) -ReturnNullUnlessFailed
            }
            catch { $failedRepair = $null }
            if ($null -ne $failedRepair) {
                $null = Set-BootstrapFailedManualDatabaseRepairPlan `
                    -State $state -StatePath $statePath -FailedRepair $failedRepair
                throw 'The sole manual database repair execution failed with the original SQL administrator restored. No replacement, restart, or deletion is authorized.'
            }
            throw $databaseFailure
        }
        $null = Complete-BootstrapManualDatabaseRepairPlan `
            -State $state -StatePath $statePath -PlanFingerprint $planFingerprint -DatabaseEvidence $database
        Write-GatewayExperienceEvent -Type Result -Message 'Manual database repair completed through one new one-shot Job. The original and both recovery Jobs remain preserved. Run gateway resume.' -Data ([ordered]@{
            step = 'Gateway database'; index = 11; total = $stepNames.Count
            manualDatabaseRepairPlanFingerprint = $planFingerprint; repaired = $true; runOnce = $true
            repairJob = [string]$database.databaseBootstrapJobName
            repairExecution = [string]$database.databaseBootstrapExecutionName
            originalAdministratorRestored = [bool]$database.originalSqlAdministratorRestored
        }) -OutputFormat $OutputFormat
        return
    }

    if ($Mode -eq 'RecoverDatabase') {
        if ($EventStreamOnly) { throw 'RecoverDatabase does not support EventStreamOnly.' }
        Assert-GatewayPlanPrerequisites -Install:$InstallPrerequisites | Out-Null
        $null = Connect-BootstrapAzure -Config $configuration -NonInteractive:$NonInteractive

        if ($state.Contains('databaseRecoveryPlan') -and
            $state.databaseRecoveryPlan -is [System.Collections.IDictionary] -and
            [string]$state.databaseRecoveryPlan.status -ceq 'Completed') {
            Assert-BootstrapAcceptedDatabaseRecoveryPlan `
                -State $state -PlanFingerprint ([string]$state.databaseRecoveryPlan.planFingerprint) -AllowCompleted | Out-Null
            Write-GatewayExperienceEvent -Type Result -Message 'Database recovery is already complete and reconciled. Run gateway resume to revalidate state and execute only the remaining deployment steps.' -Data ([ordered]@{
                step = 'Gateway database'; index = 11; total = $stepNames.Count
                recoveryPlanFingerprint = [string]$state.databaseRecoveryPlan.planFingerprint
                recovered = $true; runOnce = $true
            }) -OutputFormat $OutputFormat
            return
        }

        if ($state.Contains('databaseRecoveryPlan') -and
            $state.databaseRecoveryPlan -is [System.Collections.IDictionary] -and
            [string]$state.databaseRecoveryPlan.status -ceq 'Failed') {
            throw 'Both bounded database recovery attempts are exhausted. The second failure is manual-only; no Job will be updated, restarted, deleted, or replaced.'
        }
        $currentRecoveryAttempt = if ($state.Contains('databaseRecoveryPlan') -and $state.databaseRecoveryPlan -is [System.Collections.IDictionary]) {
            Get-BootstrapDatabaseRecoveryAttemptNumber -Plan $state.databaseRecoveryPlan
        } else { 0 }
        if ($currentRecoveryAttempt -eq 2 -and [string]$state.databaseRecoveryPlan.status -ceq 'Running') {
            $foundationForReconcile = $state.steps['Azure foundation'].evidence
            $identityForReconcile = $state.steps['Gateway API identity'].evidence
            $inertForReconcile = $state.steps['Inert identity deployment'].evidence
            $sqlPrivateEndpointForReconcile = $state.steps['SQL private endpoint'].evidence
            $apiForReconcile = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inertForReconcile.apiPrincipalId)
            $workerForReconcile = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inertForReconcile.workerPrincipalId)
            $secondContract = Get-GatewayDatabaseRecoveryAttemptContract -Config $configuration -AttemptNumber 2
            $secondReceiptPath = Join-Path (Get-RepositoryRoot) ".bootstrap/evidence/$($configuration.resourceGroupName)/database/$($secondContract.receiptFileName)"
            $secondReceipt = Read-GatewayPrivateDatabaseBootstrapRecord -Path $secondReceiptPath
            $hasExactFailureCandidate = Test-BootstrapDatabaseRecoveryFailureReceiptCandidate -Receipt $secondReceipt
            if ($hasExactFailureCandidate) {
                $secondFailure = Get-GatewayFailedDatabaseRecoveryBoundary `
                    -Config $configuration -Foundation $foundationForReconcile -SqlPrivateEndpoint $sqlPrivateEndpointForReconcile `
                    -SqlServerFqdn ([string]$inertForReconcile.sqlServerFqdn) -RecoveryPlan $state.databaseRecoveryPlan `
                    -ApiPrincipal $apiForReconcile -WorkerPrincipal $workerForReconcile `
                    -OriginalAdministratorObjectId ([string]$identityForReconcile.userObjectId) `
                    -OriginalAdministratorLogin ([string]$identityForReconcile.userPrincipalName) -ReturnNullUnlessFailed
                if ($null -ne $secondFailure) {
                    $null = Set-BootstrapFailedDatabaseRecoveryPlan -State $state -StatePath $statePath -FailedRecovery $secondFailure
                    throw 'The second and final database recovery execution failed with the original SQL administrator restored and no accepted evidence. Recovery is now manual-only; no third attempt is authorized.'
                }
            }
        }
        $attemptOneFailedRecovery = $null
        if ($currentRecoveryAttempt -eq 1 -and [string]$state.databaseRecoveryPlan.status -ceq 'Running') {
            $attemptOneContract = Get-GatewayDatabaseRecoveryAttemptContract -Config $configuration -AttemptNumber 1
            $attemptOneReceiptPath = Join-Path (Get-RepositoryRoot) ".bootstrap/evidence/$($configuration.resourceGroupName)/database/$($attemptOneContract.receiptFileName)"
            $attemptOneReceipt = Read-GatewayPrivateDatabaseBootstrapRecord -Path $attemptOneReceiptPath
            if (Test-BootstrapDatabaseRecoveryFailureReceiptCandidate -Receipt $attemptOneReceipt) {
                $foundationForFailure = $state.steps['Azure foundation'].evidence
                $identityForFailure = $state.steps['Gateway API identity'].evidence
                $inertForFailure = $state.steps['Inert identity deployment'].evidence
                $sqlPrivateEndpointForFailure = $state.steps['SQL private endpoint'].evidence
                $apiForFailure = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inertForFailure.apiPrincipalId)
                $workerForFailure = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inertForFailure.workerPrincipalId)
                $attemptOneFailedRecovery = Get-GatewayFailedDatabaseRecoveryBoundary `
                    -Config $configuration -Foundation $foundationForFailure -SqlPrivateEndpoint $sqlPrivateEndpointForFailure `
                    -SqlServerFqdn ([string]$inertForFailure.sqlServerFqdn) -RecoveryPlan $state.databaseRecoveryPlan `
                    -ApiPrincipal $apiForFailure -WorkerPrincipal $workerForFailure `
                    -OriginalAdministratorObjectId ([string]$identityForFailure.userObjectId) `
                    -OriginalAdministratorLogin ([string]$identityForFailure.userPrincipalName) -ReturnNullUnlessFailed
            }
        }
        $plan = if (-not $state.Contains('databaseRecoveryPlan')) {
            Get-GatewayDatabaseRecoveryPlan -Configuration $configuration -State $state
        }
        elseif ($currentRecoveryAttempt -eq 1 -and $null -ne $attemptOneFailedRecovery) {
            Get-GatewayDatabaseRecoveryPlan -Configuration $configuration -State $state
        }
        else {
            Assert-BootstrapAcceptedDatabaseRecoveryPlan `
                -State $state -PlanFingerprint ([string]$state.databaseRecoveryPlan.planFingerprint) | Out-Null
            $state.databaseRecoveryPlan
        }
        $planFingerprint = [string]$plan.planFingerprint
        Write-GatewayExperienceEvent -Type Info -Message "Database recovery dry plan is apply-ready. recoveryPlanFingerprint: $planFingerprint" -Data ([ordered]@{
            step = 'Gateway database'; index = 11; total = $stepNames.Count
            recoveryPlanFingerprint = $planFingerprint
            originalSourceFingerprint = [string]$plan.originalSourceFingerprint
            correctedSourceFingerprint = [string]$plan.correctedSourceFingerprint
            originalFailedJob = [string]$plan.failedJob.jobName
            originalFailedExecution = [string]$plan.failedJob.executionName
            recoveryJob = [string]$plan.recoveryJob.name
            recoveryAttempt = if ($plan.Contains('attemptNumber')) { [int]$plan.attemptNumber } else { 1 }
            recoveryMode = 'ResumeAfterSchemaCompleted'
            retryLimit = 0; maximumExecutions = 1; applyReady = $true
        }) -OutputFormat $OutputFormat

        if (-not $Yes) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and
                $ExpectedPlanFingerprint -cne $planFingerprint) {
                throw 'Expected database recovery plan fingerprint mismatch. No mutation was authorized.'
            }
            Write-GatewayExperienceEvent -Type Result -Message "No mutation was performed. Review the dry plan, then run gateway recover-database --config '$Config' --yes --expected-plan-fingerprint '$planFingerprint'." -Data ([ordered]@{
                step = 'Gateway database'; index = 11; total = $stepNames.Count
                recoveryPlanFingerprint = $planFingerprint; mutated = $false
            }) -OutputFormat $OutputFormat
            return
        }
        if ([string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint)) {
            throw 'RecoverDatabase --yes requires --expected-plan-fingerprint from the immediately reviewed dry What-If.'
        }
        if ($ExpectedPlanFingerprint -cne $planFingerprint) {
            throw 'Expected database recovery plan fingerprint mismatch. No mutation was authorized.'
        }
        $planAttemptNumber = if ($plan.Contains('attemptNumber')) { [int]$plan.attemptNumber } else { 1 }
        if (-not $state.Contains('databaseRecoveryPlan')) {
            $plan = Set-BootstrapAcceptedDatabaseRecoveryPlan -State $state -StatePath $statePath -Plan $plan
        }
        elseif ($planAttemptNumber -eq 2 -and $currentRecoveryAttempt -eq 1) {
            $foundationForTransition = $state.steps['Azure foundation'].evidence
            $identityForTransition = $state.steps['Gateway API identity'].evidence
            $inertForTransition = $state.steps['Inert identity deployment'].evidence
            $sqlPrivateEndpointForTransition = $state.steps['SQL private endpoint'].evidence
            $apiForTransition = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inertForTransition.apiPrincipalId)
            $workerForTransition = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inertForTransition.workerPrincipalId)
            $livePriorFailure = Get-GatewayFailedDatabaseRecoveryBoundary `
                -Config $configuration -Foundation $foundationForTransition -SqlPrivateEndpoint $sqlPrivateEndpointForTransition `
                -SqlServerFqdn ([string]$inertForTransition.sqlServerFqdn) -RecoveryPlan $state.databaseRecoveryPlan `
                -ApiPrincipal $apiForTransition -WorkerPrincipal $workerForTransition `
                -OriginalAdministratorObjectId ([string]$identityForTransition.userObjectId) `
                -OriginalAdministratorLogin ([string]$identityForTransition.userPrincipalName)
            if ([string]$livePriorFailure.boundaryFingerprint -cne [string]$plan.priorFailedRecovery.boundaryFingerprint) {
                throw 'The first recovery failure changed after dry-plan review. No continuation was accepted or started.'
            }
            $plan = Set-BootstrapAcceptedDatabaseRecoveryContinuationPlan `
                -State $state -StatePath $statePath -Plan $plan -FailedRecovery $livePriorFailure
        }
        Assert-BootstrapAcceptedDatabaseRecoveryPlan -State $state -PlanFingerprint $planFingerprint | Out-Null
        $recoverySourceRoot = Resolve-BootstrapDatabaseRecoverySourceRoot -State $state
        Set-BootstrapExecutionSourceRoot -Path $recoverySourceRoot
        foreach ($module in @('Experience', 'Prerequisites', 'Azure', 'Entra', 'Agent365', 'Database', 'Purview', 'Verification')) {
            Import-Module (Join-Path $recoverySourceRoot "bootstrap/modules/$module.psm1") -Force -DisableNameChecking
        }
        Set-BootstrapExecutionSourceRoot -Path $recoverySourceRoot

        $foundation = $state.steps['Azure foundation'].evidence
        $identity = $state.steps['Gateway API identity'].evidence
        $images = $state.steps['Immutable workload images'].evidence
        $inert = $state.steps['Inert identity deployment'].evidence
        $sqlPrivateEndpoint = $state.steps['SQL private endpoint'].evidence
        $apiPrincipal = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inert.apiPrincipalId)
        $workerPrincipal = Get-ManagedIdentityClientId -PrincipalObjectId ([string]$inert.workerPrincipalId)
        $liveFailedJob = Get-GatewayFailedDatabaseBootstrapBoundary `
            -Config $configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
            -SqlServerFqdn ([string]$inert.sqlServerFqdn) -OriginalJobImage ([string]$images.databaseMigrator) `
            -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
            -OriginalSourceFingerprint ([string]$plan.originalSourceFingerprint) `
            -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
            -OriginalAdministratorObjectId ([string]$identity.userObjectId) `
            -OriginalAdministratorLogin ([string]$identity.userPrincipalName)
        if ([string]$liveFailedJob.boundaryFingerprint -cne [string]$plan.failedJob.boundaryFingerprint) {
            throw 'The original failed database Job changed after plan review. No recovery mutation was started.'
        }
        if ($planAttemptNumber -eq 2) {
            $livePriorFailure = Get-GatewayFailedDatabaseRecoveryBoundary `
                -Config $configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
                -SqlServerFqdn ([string]$inert.sqlServerFqdn) -RecoveryPlan $plan.previousRecoveryPlan `
                -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
                -OriginalAdministratorObjectId ([string]$identity.userObjectId) `
                -OriginalAdministratorLogin ([string]$identity.userPrincipalName)
            if ([string]$livePriorFailure.boundaryFingerprint -cne [string]$plan.priorFailedRecovery.boundaryFingerprint) {
                throw 'The first recovery failure changed after continuation acceptance. No second Job mutation was started.'
            }
        }

        $null = Start-BootstrapDatabaseRecoveryPlan -State $state -StatePath $statePath -PlanFingerprint $planFingerprint
        $recoveryImage = Build-GatewayDatabaseRecoveryImage `
            -Config $configuration -AcrLoginServer ([string]$foundation.acrLoginServer) `
            -SourceFingerprint ([string]$plan.correctedSourceFingerprint) `
            -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
            -RecoveryPlanFingerprint $planFingerprint `
            -BuildIntent $state.databaseRecoveryPlan.correctedImage `
            -Checkpoint {
                param($imageEvidence)
                $state.databaseRecoveryPlan.correctedImage = ConvertTo-BootstrapCanonicalValue -Value $imageEvidence
                Save-BootstrapState -State $state -Path $statePath
            }
        $recoveryContract = Get-GatewayDatabaseRecoveryAttemptContract -Config $configuration -AttemptNumber $planAttemptNumber
        $recoveryReceiptPath = Join-Path (Get-RepositoryRoot) ".bootstrap/evidence/$($configuration.resourceGroupName)/database/$($recoveryContract.receiptFileName)"
        if (-not (Test-Path -LiteralPath $recoveryReceiptPath)) {
            $applyWhatIf = Invoke-GatewayDatabaseRecoveryWhatIf `
                -Config $configuration -Foundation $foundation -RepositoryRoot $recoverySourceRoot `
                -SqlServerFqdn ([string]$inert.sqlServerFqdn) `
                -ExpectedPrivateEndpointIpv4Address ([string]$sqlPrivateEndpoint.privateEndpointIpv4Address) `
                -DatabaseMigratorImageDigest ([string]$recoveryImage.digest) `
                -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
                -OriginalAcceptedSourceFingerprint ([string]$plan.originalSourceFingerprint) `
                -RecoverySourceFingerprint ([string]$plan.correctedSourceFingerprint) `
                -RecoveryPlanFingerprint $planFingerprint `
                -RecoveryExecutionIntentId ([string]$plan.recoveryJob.executionIntentId) `
                -RecoveryAttemptNumber $planAttemptNumber `
                -OriginalFailedDatabaseBoundaryFingerprint ([string]$plan.failedJob.boundaryFingerprint) `
                -PriorFailedRecoveryBoundaryFingerprint $(if ($planAttemptNumber -eq 2) { [string]$plan.priorFailedRecovery.boundaryFingerprint } else { '' }) `
                -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal
            if ([string]$applyWhatIf.changeFingerprint -cne [string]$plan.whatIf.changeFingerprint) {
                throw 'Database recovery What-If changed after the corrected immutable image was built. No Job deployment or start was attempted.'
            }
        }
        $database = $null
        $databaseFailure = $null
        try {
            $database = Initialize-GatewayDatabase `
                -Config $configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
                -SqlServerFqdn ([string]$inert.sqlServerFqdn) `
                -ApiPrincipalId ([string]$inert.apiPrincipalId) -WorkerPrincipalId ([string]$inert.workerPrincipalId) `
                -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
                -DatabaseMigratorImage ([string]$recoveryImage.image) `
                -OriginalEntraAdministratorObjectId ([string]$identity.userObjectId) `
                -OriginalEntraAdministratorLogin ([string]$identity.userPrincipalName) `
                -BootstrapClientIpv4 ([string]$state.acceptedPlan.bootstrapClientIpv4) `
                -RecoveryPlan $state.databaseRecoveryPlan
        }
        catch { $databaseFailure = $_ }
        if ($null -ne $databaseFailure) {
            if ($planAttemptNumber -eq 2) {
                $finalFailedRecovery = $null
                try {
                    $finalFailedRecovery = Get-GatewayFailedDatabaseRecoveryBoundary `
                        -Config $configuration -Foundation $foundation -SqlPrivateEndpoint $sqlPrivateEndpoint `
                        -SqlServerFqdn ([string]$inert.sqlServerFqdn) -RecoveryPlan $state.databaseRecoveryPlan `
                        -ApiPrincipal $apiPrincipal -WorkerPrincipal $workerPrincipal `
                        -OriginalAdministratorObjectId ([string]$identity.userObjectId) `
                        -OriginalAdministratorLogin ([string]$identity.userPrincipalName) -ReturnNullUnlessFailed
                }
                catch { $finalFailedRecovery = $null }
                if ($null -ne $finalFailedRecovery) {
                    $null = Set-BootstrapFailedDatabaseRecoveryPlan `
                        -State $state -StatePath $statePath -FailedRecovery $finalFailedRecovery
                    throw 'The second and final database recovery execution failed with the original SQL administrator restored and no accepted evidence. Recovery is manual-only; no third attempt is authorized.'
                }
            }
            throw $databaseFailure
        }
        $null = Complete-BootstrapDatabaseRecoveryPlan `
            -State $state -StatePath $statePath -PlanFingerprint $planFingerprint -DatabaseEvidence $database
        Write-GatewayExperienceEvent -Type Result -Message 'Database recovery completed with exactly one separate recovery Job execution; the original failed Job remains preserved. Run gateway resume to revalidate state and execute only the remaining deployment steps.' -Data ([ordered]@{
            step = 'Gateway database'; index = 11; total = $stepNames.Count
            recoveryPlanFingerprint = $planFingerprint; recovered = $true; runOnce = $true
            recoveryJob = [string]$database.databaseBootstrapJobName
            recoveryExecution = [string]$database.databaseBootstrapExecutionName
            originalAdministratorRestored = [bool]$database.originalSqlAdministratorRestored
        }) -OutputFormat $OutputFormat
        return
    }

    if ($Mode -eq 'Resume') {
        $resumePreflight = Invoke-GatewayResumePreflight `
            -Configuration $configuration `
            -State $state `
            -Format $OutputFormat `
            -InstallLocalPrerequisites:$InstallPrerequisites `
            -NonInteractive:$NonInteractive `
            -ExplicitlyAuthorized:$Yes `
            -ExpectedAcceptedPlanFingerprint $ExpectedPlanFingerprint `
            -ExpectedResumeAuthorizationFingerprint $ExpectedResumeAuthorizationFingerprint
        if ($resumePreflight.reviewOnly -eq $true) {
            return
        }
    }

    if ($Mode -in @('Plan', 'Up')) {
        $plan = Invoke-GatewayPlanWorkflow -Configuration $configuration -State $state -StatePath $statePath -Format $OutputFormat -InstallLocalPrerequisites:$InstallPrerequisites -StreamOnly:$EventStreamOnly
        $script:GatewayFailureStage = 'Plan review'
        $script:GatewayFailureCode = 'plan_acceptance'
        if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and
            $ExpectedPlanFingerprint -cne [string]$plan.planFingerprint) {
            Clear-BootstrapAcceptedPlan -State $state -StatePath $statePath | Out-Null
            Write-GatewayExperienceEvent -Type Warning -Message 'The computed plan fingerprint does not match the externally approved fingerprint. No mutation was authorized.' -Data ([ordered]@{
                step = 'Plan review'; index = 1; total = $stepNames.Count; applyReady = $false
            }) -OutputFormat $OutputFormat
            throw 'Expected plan fingerprint mismatch.'
        }
        if (-not $plan.whatIf.applyReady) {
            if ($Mode -eq 'Up') {
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
        $script:GatewayFailureStage = 'Deployment'
        $script:GatewayFailureCode = 'deployment'
        if ($Mode -eq 'Resume') {
            if ($resumePreflight -isnot [System.Collections.IDictionary] -or
                $resumePreflight.explicitlyAuthorized -ne $true) {
                throw 'Checkpoint-aware Resume preflight did not return an explicit authorization.'
            }
            $recordedPlanFingerprint = [string]$resumePreflight.acceptedPlanFingerprint
            $activeAcceptedPlanFingerprint = $recordedPlanFingerprint
            $activeAcceptedSourceFingerprint = [string]$resumePreflight.acceptedSourceFingerprint
            $activeDeploymentSourceFingerprint = [string]$resumePreflight.deploymentSourceFingerprint
            $executionSourceRoot = [string]$resumePreflight.executionSourceRoot
            if ((Get-BootstrapSourceFingerprint) -cne $activeAcceptedSourceFingerprint) {
                throw 'The running bootstrap engine changed after Resume preflight; no mutation was started.'
            }
            Assert-BootstrapAcceptedPlan `
                -State $state `
                -PlanFingerprint $recordedPlanFingerprint `
                -ConfigurationFingerprint (Get-BootstrapConfigurationFingerprint -Config $configuration) `
                -SourceFingerprint $activeAcceptedSourceFingerprint `
                -MaximumAge ([TimeSpan]::MaxValue) | Out-Null
        }
        else {
            $recordedPlanFingerprint = [string]$state.acceptedPlan.planFingerprint
            $activeAcceptedSourceFingerprint = [string]$state.acceptedPlan.sourceFingerprint
            $activeDeploymentSourceFingerprint = Get-BootstrapEffectiveDeploymentSourceFingerprint -State $state -ExecutionSourceFingerprint $activeAcceptedSourceFingerprint
            if ((Get-BootstrapSourceFingerprint) -cne $activeAcceptedSourceFingerprint) {
                throw 'The running bootstrap engine does not match the accepted source snapshot. Restore the reviewed checkout before Apply; no mutation was started.'
            }
            # Apply retains its original time-bounded accepted What-If contract.
            Assert-BootstrapAcceptedPlan `
                -State $state `
                -PlanFingerprint $recordedPlanFingerprint `
                -ConfigurationFingerprint (Get-BootstrapConfigurationFingerprint -Config $configuration) `
                -SourceFingerprint $activeAcceptedSourceFingerprint | Out-Null
            $executionSourceRoot = Resolve-BootstrapAcceptedSourceRoot -State $state
        }
        Set-BootstrapExecutionSourceRoot -Path $executionSourceRoot
        foreach ($module in @('Experience', 'Prerequisites', 'Azure', 'Entra', 'Agent365', 'Database', 'Purview', 'Verification')) {
            Import-Module (Join-Path $executionSourceRoot "bootstrap/modules/$module.psm1") -Force -DisableNameChecking
        }
        Set-BootstrapExecutionSourceRoot -Path $executionSourceRoot

        if ($Mode -eq 'Apply') {
            $descriptor = Get-GatewayPlanDescriptor `
                -Config $configuration `
                -State $state `
                -BootstrapClientIpv4 ([string]$state.acceptedPlan.bootstrapClientIpv4) `
                -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
                -SourceFingerprint $activeDeploymentSourceFingerprint
            $configurationFingerprint = Get-BootstrapConfigurationFingerprint -Config $configuration
            if ($plan -and $plan.whatIf) {
                $applyWhatIf = $plan.whatIf
            }
            else {
                Write-GatewayExperienceEvent -Type Info -Message 'Rechecking the accepted Azure What-If prediction before any mutation...' -Data ([ordered]@{
                    step = 'Plan review'; index = 1; total = $stepNames.Count
                }) -OutputFormat $OutputFormat
                $applyWhatIf = Invoke-GatewayFoundationWhatIf -Config $configuration -RepositoryRoot $executionSourceRoot -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint -ExecutionSourceFingerprint $activeAcceptedSourceFingerprint -State $state
            }
            if (-not $applyWhatIf.applyReady) { throw 'Accepted plan revalidation could not run authenticated Azure What-If. No mutation was started.' }
            $expectedPlanFingerprint = Get-GatewayPlanContractFingerprint -Descriptor $descriptor -WhatIf $applyWhatIf -ConfigurationFingerprint $configurationFingerprint -SourceFingerprint $activeAcceptedSourceFingerprint -DeploymentSourceFingerprint $activeDeploymentSourceFingerprint
            Assert-BootstrapAcceptedPlan -State $state -PlanFingerprint $expectedPlanFingerprint -SourceFingerprint $activeAcceptedSourceFingerprint | Out-Null
            $activeAcceptedPlanFingerprint = $expectedPlanFingerprint
        }
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
        $verifyDatabaseValidationPlans = Get-BootstrapCompletedDatabaseValidationPlans -State $state
        $verification = Invoke-GatewayStateStep -Name 'End-to-end deployment verification' -AlwaysRun -Action {
            Test-GatewayBootstrapDeployment -Config $configuration -Foundation $foundation -Identity $identity -Blueprint $blueprint -Runtime $runtime -Database $database -SqlPrivateEndpoint $sqlPrivateEndpoint -AdminUi $adminUi -Images $images -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -DatabaseRecoveryPlan $verifyDatabaseValidationPlans.databaseRecoveryPlan -ManualDatabaseRepairPlan $verifyDatabaseValidationPlans.manualDatabaseRepairPlan -State $state -NonInteractive:$NonInteractive
        }
        Save-Output -Name 'verification' -Value $verification
        Write-GatewayExperienceEvent -Type Result -Message "Verification passed. Admin UI: $($adminUi.adminUiUrl)" -Data ([ordered]@{
            step = 'End-to-end deployment verification'; index = $stepNames.Count; total = $stepNames.Count
            category = 'deploymentVerified'; verified = $true; verificationMode = 'Verify'
            adminUiUrl = [string]$adminUi.adminUiUrl
            apiUrl = "https://$($runtime.apiFqdn)"
            apiHealthUrl = "https://$($runtime.apiFqdn)/health/checks"
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
        Test-GatewaySubscriptionDeploymentEvidence -Config $configuration -Evidence $state.steps['Azure foundation'].evidence -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint
    } -Reconcile {
        Invoke-GatewayExactReconciliation -Readback {
            $recovered = Get-BootstrapFoundationEvidence -Config $configuration -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint
            $null = Test-GatewaySubscriptionDeploymentEvidence -Config $configuration -Evidence $recovered -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint
            return $recovered
        }
    } -NoAutomaticReplayAfterStart -Action {
        $created = Deploy-BootstrapFoundation -Config $configuration -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint
        $null = Test-GatewaySubscriptionDeploymentEvidence -Config $configuration -Evidence $created -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint
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
        Test-GatewayImmutableImageEvidence -Evidence $state.steps['Immutable workload images'].evidence -SourceFingerprint $activeDeploymentSourceFingerprint -DeploymentOwnershipId ([string]$state.deploymentOwnershipId)
    } -Action {
        $partialImageEvidence = if ($state.steps['Immutable workload images'].Contains('evidence')) {
            $state.steps['Immutable workload images'].evidence
        }
        else { $null }
        Build-GatewayImages `
            -Config $configuration `
            -AcrLoginServer ([string]$foundation.acrLoginServer) `
            -SourceFingerprint $activeDeploymentSourceFingerprint `
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
        Test-GatewayGroupDeploymentEvidence -Config $configuration -Foundation $foundation -Identity $identity -Evidence $state.steps['Inert identity deployment'].evidence -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -AllowRuntimeSupersession:$runtimeSupersededInert
    } -Action {
        $recoveredInertEvidence = if ($state.steps['Inert identity deployment'].Contains('evidence')) {
            $state.steps['Inert identity deployment'].evidence
        }
        else { $null }
        $created = Deploy-GatewayCore -Config $configuration -Foundation $foundation -Identity $identity -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -WorkerPrincipalId '' -ManagerApplicationIds @() -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint -ExecutionSourceFingerprint $activeAcceptedSourceFingerprint -Initial -RecoveredEvidence $recoveredInertEvidence -Checkpoint {
            param($partialEvidence)
            $state.steps['Inert identity deployment'].evidence = $partialEvidence
            Save-BootstrapState -State $state -Path $statePath
        }
        $null = Test-GatewayGroupDeploymentEvidence -Config $configuration -Foundation $foundation -Identity $identity -Evidence $created -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker)
        return $created
    }
    Complete-BootstrapPreInertSourceCorrectionPlan -State $state -StatePath $statePath | Out-Null

    $blueprint = Invoke-GatewayStateStep -Name 'Agent 365 seed blueprint' -Validate {
        Test-GatewayBlueprintEvidence `
            -Config $configuration `
            -Evidence $state.steps['Agent 365 seed blueprint'].evidence `
            -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
            -SourceFingerprint $activeDeploymentSourceFingerprint `
            -SponsorObjectId ([string]$azureIdentity.userObjectId) `
            -GatewayManagedIdentityPrincipalId ([string]$inert.workerPrincipalId)
    } -Reconcile {
        Invoke-GatewayExactReconciliation -Readback {
            Ensure-Agent365SeedBlueprint `
                -Config $configuration `
                -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
                -SourceFingerprint $activeDeploymentSourceFingerprint `
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
            -SourceFingerprint $activeDeploymentSourceFingerprint `
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
        Test-GatewaySqlPrivateEndpointEvidence -Config $configuration -Foundation $foundation -SqlServerFqdn ([string]$inert.sqlServerFqdn) -Evidence $evidence -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint
    } -Action {
        $created = Deploy-SqlPrivateEndpoint -Config $configuration -Foundation $foundation -SqlServerFqdn ([string]$inert.sqlServerFqdn) -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint
        $null = Test-GatewaySqlPrivateEndpointEvidence -Config $configuration -Foundation $foundation -SqlServerFqdn ([string]$inert.sqlServerFqdn) -Evidence $created -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint
        return $created
    }

    $databaseValidationPlans = Get-BootstrapCompletedDatabaseValidationPlans -State $state
    $databaseRecoveryPlan = $databaseValidationPlans.databaseRecoveryPlan
    $manualDatabaseRepairPlan = $databaseValidationPlans.manualDatabaseRepairPlan
    $database = Invoke-GatewayStateStep -Name 'Gateway database' -Validate {
        Test-GatewayDatabaseEvidence -Config $configuration -Foundation $foundation -Inert $inert -Evidence $state.steps['Gateway database'].evidence -StepRecord $state.steps['Gateway database'] -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint -DatabaseMigratorImage ([string]$images.databaseMigrator) -DatabaseRecoveryPlan $databaseRecoveryPlan -ManualDatabaseRepairPlan $manualDatabaseRepairPlan
    } -Action {
        Initialize-GatewayDatabase `
            -Config $configuration `
            -Foundation $foundation `
            -SqlPrivateEndpoint $sqlPrivateEndpoint `
            -SqlServerFqdn ([string]$inert.sqlServerFqdn) `
            -ApiPrincipalId ([string]$inert.apiPrincipalId) `
            -WorkerPrincipalId ([string]$inert.workerPrincipalId) `
            -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
            -DatabaseMigratorImage ([string]$images.databaseMigrator) `
            -OriginalEntraAdministratorObjectId ([string]$identity.userObjectId) `
            -OriginalEntraAdministratorLogin ([string]$identity.userPrincipalName) `
            -BootstrapClientIpv4 ([string]$state.acceptedPlan.bootstrapClientIpv4) `
            -ExecutionSourceFingerprint $activeAcceptedSourceFingerprint `
            -DeploymentSourceFingerprint $activeDeploymentSourceFingerprint
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
        Test-GatewayAdminCredentialEvidence `
            -Config $configuration `
            -AdminIdentity $adminIdentity `
            -Inert $inert `
            -Evidence $state.steps['Admin UI Key Vault credential'].evidence `
            -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
            -SourceFingerprint $activeDeploymentSourceFingerprint
    } -Reconcile {
        Invoke-GatewayExactReconciliation -Readback {
            Resolve-AdminUiCredentialAfterStartedOutcome `
                -Config $configuration `
                -AdminIdentity $adminIdentity `
                -KeyVaultUri ([string]$inert.keyVaultUri) `
                -UserObjectId ([string]$azureIdentity.userObjectId) `
                -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
                -SourceFingerprint $activeDeploymentSourceFingerprint
        }
    } -NoAutomaticReplayAfterStart -Action {
        New-AdminUiCredentialInKeyVault `
            -Config $configuration `
            -AdminIdentity $adminIdentity `
            -KeyVaultUri ([string]$inert.keyVaultUri) `
            -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) `
            -SourceFingerprint $activeDeploymentSourceFingerprint
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
    # Purview protection profiles are optional registration-level controls. Their
    # independent authority/readback boundary must not close ordinary registration.
    $enableProvisioning = $developmentPreviewRequested
    $runtime = Invoke-GatewayStateStep -Name 'Gateway runtime deployment' -Validate {
        Test-GatewayGroupDeploymentEvidence -Config $configuration -Foundation $foundation -Identity $identity -Evidence $state.steps['Gateway runtime deployment'].evidence -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -Database $database
    } -Action {
        $created = Deploy-GatewayCore -Config $configuration -Foundation $foundation -Identity $identity -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -WorkerPrincipalId ([string]$inert.workerPrincipalId) -ManagerApplicationIds @($blueprint.managerApplicationIds) -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint -ExecutionSourceFingerprint $activeAcceptedSourceFingerprint -Database $database -EnableWorkerProcessing -EnableProvisioning:$enableProvisioning -EnablePurview:($purview.enabled -eq $true)
        $null = Test-GatewayGroupDeploymentEvidence -Config $configuration -Foundation $foundation -Identity $identity -Evidence $created -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -Database $database
        return $created
    }

    $adminUi = Invoke-GatewayStateStep -Name 'Admin UI deployment' -Validate {
        Test-GatewayNamedGroupDeployment -Config $configuration -Foundation $foundation -Runtime $runtime -Identity $identity -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentName "a365gw-$($configuration.projectName)-bootstrap-admin-$($configuration.environment)" -Evidence $state.steps['Admin UI deployment'].evidence -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint -AdminUiImage ([string]$images.adminUi)
    } -Reconcile {
        Invoke-GatewayExactReconciliation -Readback {
            $recovered = Get-GatewayAdminUiDeploymentEvidence -Config $configuration -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint -AdminUiImage ([string]$images.adminUi)
            $null = Test-GatewayNamedGroupDeployment -Config $configuration -Foundation $foundation -Runtime $runtime -Identity $identity -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentName "a365gw-$($configuration.projectName)-bootstrap-admin-$($configuration.environment)" -Evidence $recovered -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint -AdminUiImage ([string]$images.adminUi)
            return $recovered
        }
    } -NoAutomaticReplayAfterStart -Action {
        $created = Deploy-GatewayAdminUi -Config $configuration -Foundation $foundation -Identity $identity -AdminIdentity $adminIdentity -AdminUiImage ([string]$images.adminUi) -AdminUiSecretUri ([string]$adminCredential.secretUri) -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint -ExecutionSourceFingerprint $activeAcceptedSourceFingerprint
        $null = Test-GatewayNamedGroupDeployment -Config $configuration -Foundation $foundation -Runtime $runtime -Identity $identity -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentName "a365gw-$($configuration.projectName)-bootstrap-admin-$($configuration.environment)" -Evidence $created -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -SourceFingerprint $activeDeploymentSourceFingerprint -AdminUiImage ([string]$images.adminUi)
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
        Test-GatewayBootstrapDeployment -Config $configuration -Foundation $foundation -Identity $identity -Blueprint $blueprint -Runtime $runtime -Database $database -SqlPrivateEndpoint $sqlPrivateEndpoint -AdminUi $adminUi -Images $images -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentOwnershipId ([string]$state.deploymentOwnershipId) -DatabaseRecoveryPlan $databaseRecoveryPlan -ManualDatabaseRepairPlan $manualDatabaseRepairPlan -State $state -NonInteractive:$NonInteractive
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
        apiUrl = "https://$($runtime.apiFqdn)"
        apiHealthUrl = "https://$($runtime.apiFqdn)/health/checks"
        statePath = $statePath
        readiness = if ($provisioningAdmissionReady) { @('InfrastructureReady', 'ControlPlaneReady', 'ProvisioningReady') } else { @('InfrastructureReady', 'ControlPlaneReady') }
        provisioningAdmission = if ($provisioningAdmissionReady) { 'OpenDevelopmentPreview' } else { [string]$verification.registrationMode }
    }) -OutputFormat $OutputFormat

    if (-not $provisioningAdmissionReady) {
        # Agent Registration is development-only while the Registry create API is preview.
        $closedReason = 'Agent creation remains closed because Registry create is unsupported for production outside the explicitly acknowledged development preview.'
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
    $failure = Get-GatewaySafeFailureEvent -FailureCode $script:GatewayFailureCode -FailureStage $script:GatewayFailureStage -CommandMode $Mode -Exception $_.Exception
    Write-GatewayExperienceEvent -Type Warning -Message $failure.message -Data $failure.data -OutputFormat $OutputFormat
    exit 1
}
finally {
    Set-BootstrapStructuredOutput -Enabled $false
}
