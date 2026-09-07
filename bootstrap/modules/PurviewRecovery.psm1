Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This recovery owns three prerequisites of an existing bootstrap-owned identity.
# It never creates/adopts an application, replaces a credential, or replays stage 14.
$script:PurviewRecoveryOperations = @('ExchangeGrant', 'ComplianceGrant', 'Certificate')
$script:PurviewRecoveryStep = 'Purview capability prerequisites'
$script:PurviewRecoveryRole = '17315797-102d-40b4-93e0-432062caca18'
$script:PurviewRecoveryTemplate = 'bootstrap/infra/purview-automation-certificate.bicep'

function Assert-BootstrapPurviewRecoveryEligibility {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Config)

    foreach ($name in @('databaseRecoveryPlan', 'databaseRecoveryHistory', 'manualDatabaseRepairPlan', 'preInertSourceCorrectionPlan')) {
        if ($State.Contains($name)) { throw 'Purview prerequisite recovery cannot be combined with another recovery generation.' }
    }
    if ($Config.purview.enabled -ne $true -or $State.acceptedPlan -isnot [Collections.IDictionary] -or
        [string]$State.configurationFingerprint -cne (Get-BootstrapConfigurationFingerprint -Config $Config) -or
        [string]$State.acceptedPlan.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        [string]$State.deploymentKey -cne "$($Config.subscriptionId)/$($Config.resourceGroupName)/$($Config.environment)") {
        throw 'Purview prerequisite recovery configuration or accepted authorization does not match.'
    }
    $names = @(Get-GatewayBootstrapStepNames)
    if ($names.Count -ne 19 -or $names[13] -cne $script:PurviewRecoveryStep -or $State.steps.Count -ne 14) {
        throw 'Purview prerequisite recovery requires exactly thirteen completed stages and failed stage fourteen.'
    }
    foreach ($name in $names[0..12]) {
        $step = $State.steps[$name]
        if ($step -isnot [Collections.IDictionary] -or [string]$step.status -cne 'Completed' -or
            $null -eq $step.evidence -or [string]$step.sourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint) {
            throw 'Purview prerequisite recovery completed prefix is not exact.'
        }
    }
    $failed = $State.steps[$script:PurviewRecoveryStep]
    if ($failed -isnot [Collections.IDictionary] -or [string]$failed.status -cne 'Failed' -or
        $failed.Contains('evidence') -or [string]$failed.sourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint) {
        throw 'Purview prerequisite recovery requires the preserved failed prerequisite record without completion evidence.'
    }
    Assert-BootstrapAcceptedPlan -State $State -PlanFingerprint ([string]$State.acceptedPlan.planFingerprint) `
        -ConfigurationFingerprint ([string]$State.configurationFingerprint) `
        -SourceFingerprint ([string]$State.acceptedPlan.sourceFingerprint) -MaximumAge ([TimeSpan]::MaxValue) | Out-Null
}

function Assert-BootstrapPurviewRecoverySourceBoundary {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$CandidateRoot)

    $originalRoot = Resolve-BootstrapAcceptedSourceRoot -State $State
    $original = @{}
    foreach ($entry in @(Get-BootstrapSourceManifest -Root $originalRoot)) { $original[[string]$entry.path] = [string]$entry.sha256 }
    $candidate = @{}
    foreach ($entry in @(Get-BootstrapSourceManifest -Root $CandidateRoot)) { $candidate[[string]$entry.path] = [string]$entry.sha256 }
    $allowed = @('bootstrap/modules/Entra.psm1', 'bootstrap/modules/Common.psm1', 'bootstrap/bootstrap.ps1',
        'bootstrap/modules/PurviewRecovery.psm1', 'bootstrap/recover-purview-prerequisites.ps1')
    foreach ($path in @(@($original.Keys) + @($candidate.Keys) | Sort-Object -Unique)) {
        if ($allowed -cnotcontains $path -and
            (-not $original.ContainsKey($path) -or -not $candidate.ContainsKey($path) -or $original[$path] -cne $candidate[$path])) {
            throw 'Purview prerequisite recovery changes source outside its tooling-only boundary.'
        }
        if ($original.ContainsKey($path) -and -not $candidate.ContainsKey($path)) {
            throw 'Purview prerequisite recovery cannot remove accepted source files.'
        }
    }
    foreach ($path in $allowed) {
        if (-not $candidate.ContainsKey($path)) { throw 'Purview prerequisite recovery tooling is incomplete.' }
    }
    return $true
}

function Get-BootstrapPurviewRecoveryProviderState {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$AzureIdentity, [Parameter()]$Binding)

    $recordedIdentity = $State.steps['Azure authentication'].evidence
    foreach ($name in @('tenantId', 'subscriptionId', 'userObjectId')) {
        if ([string]$AzureIdentity[$name] -cne [string]$recordedIdentity[$name]) {
            throw 'Purview prerequisite recovery requires the original administrator and Azure target.'
        }
    }
    $displayName = "A365 Gateway Purview Automation - $($Config.projectName)-$($Config.environment)"
    $discovered = Get-ExactApplicationByDisplayName -DisplayName $displayName
    if (-not $discovered) { throw 'The existing Purview automation application was not found.' }
    $app = Get-BootstrapPurviewAutomationApplication -ApplicationObjectId ([string]$discovered.id)
    $exchange = Get-BootstrapPurviewExchangeRole
    Assert-BootstrapPurviewAutomationApplication -Application $app -DisplayName $displayName `
        -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) -OwnerObjectId ([string]$AzureIdentity.userObjectId) `
        -ExchangeRole $exchange -AllowMissingCertificate | Out-Null
    $principal = Get-ServicePrincipalByAppId -AppId ([string]$app.appId)
    if (-not $principal) { throw 'The existing Purview automation principal was not found.' }
    $assignments = Assert-BootstrapPurviewAutomationServicePrincipal -Principal $principal `
        -ApplicationId ([string]$app.appId) -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) `
        -ExchangeRole $exchange -AllowMissingAssignments
    $definition = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url',
        "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/$script:PurviewRecoveryRole`?`$select=id,templateId,isBuiltIn,isEnabled")
    if ([string]$definition.id -cne $script:PurviewRecoveryRole -or [string]$definition.templateId -cne $script:PurviewRecoveryRole -or
        $definition.isBuiltIn -ne $true -or $definition.isEnabled -ne $true) {
        throw 'Purview prerequisite recovery Compliance Administrator definition is not exact.'
    }
    $vaultUri = [string]$State.steps['Inert identity deployment'].evidence.keyVaultUri
    $context = Get-GatewayPurviewAutomationCertificateContext -Config $Config -KeyVaultUri $vaultUri `
        -AutomationApplicationId ([string]$app.appId) -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) `
        -SourceFingerprint ([string]$State.acceptedPlan.sourceFingerprint)
    $observedBinding = [ordered]@{
        applicationObjectId = ([guid][string]$app.id).ToString('D')
        applicationId = ([guid][string]$app.appId).ToString('D')
        servicePrincipalId = ([guid][string]$principal.id).ToString('D')
        exchangeServicePrincipalId = [string]$exchange.servicePrincipalId
        exchangeRoleId = [string]$exchange.roleId
        complianceRoleDefinitionId = $script:PurviewRecoveryRole
        keyVaultUri = $vaultUri
        certificateSecretResourceId = [string]$context.secretResourceId
        certificateSecretUri = [string]$context.versionlessSecretUri
    }
    if ($null -ne $Binding -and (Get-BootstrapObjectFingerprint -InputObject $Binding) -cne
        (Get-BootstrapObjectFingerprint -InputObject $observedBinding)) {
        throw 'Purview prerequisite recovery identity, role or certificate scope changed.'
    }
    $certificate = Get-GatewayPurviewAutomationCertificateSecretArmMetadata -Config $Config -KeyVaultUri $vaultUri `
        -AutomationApplicationId ([string]$app.appId) -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) `
        -SourceFingerprint ([string]$State.acceptedPlan.sourceFingerprint)
    $keys = @($app.keyCredentials)
    if (($keys.Count -eq 0) -ne ([string]$certificate.status -ceq 'Absent')) {
        throw 'Purview prerequisite recovery found a partial certificate; no replacement is allowed.'
    }
    $automation = $null
    if ([string]$certificate.status -ceq 'Present') {
        $automation = Get-BootstrapPurviewAutomationIdentityEvidence -Config $Config -AzureIdentity $AzureIdentity `
            -KeyVaultUri $vaultUri -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) `
            -SourceFingerprint ([string]$State.acceptedPlan.sourceFingerprint)
    }
    elseif ([string]$certificate.status -cne 'Absent') { throw 'Purview prerequisite recovery certificate disposition is unknown.' }
    $operations = [ordered]@{}
    foreach ($pair in @(@('ExchangeGrant', 'exchangeAssignments'), @('ComplianceGrant', 'complianceAssignments'))) {
        $items = @($assignments[$pair[1]])
        $operations[$pair[0]] = [ordered]@{
            status = if ($items.Count -eq 1) { 'Present' } else { 'Absent' }
            assignmentId = if ($items.Count -eq 1) { [string]$items[0].id } else { '' }
        }
    }
    $operations.Certificate = [ordered]@{
        status = [string]$certificate.status
        keyCredentialId = if ($null -ne $automation) { [string]$automation.keyCredentialId } else { '' }
        evidenceFingerprint = if ($null -ne $automation) { Get-BootstrapObjectFingerprint -InputObject $automation } else { '' }
    }
    return [ordered]@{ binding = $observedBinding; operations = $operations; automationEvidence = $automation }
}

function New-BootstrapPurviewRecoveryPlan {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$AzureIdentity)

    if ($State.Contains('purviewPrerequisiteRecoveryPlan')) { throw 'A Purview prerequisite recovery already exists; use its exact persisted plan.' }
    Assert-BootstrapPurviewRecoveryEligibility -State $State -Config $Config
    $root = Get-RepositoryRoot
    Assert-BootstrapPurviewRecoverySourceBoundary -State $State -CandidateRoot $root | Out-Null
    $candidate = Get-BootstrapSourceFingerprint -Root $root
    Set-BootstrapExecutionSourceRoot -Path $root
    $template = Resolve-GatewayCredentialDeploymentTemplate -RelativeTemplate $script:PurviewRecoveryTemplate -ExecutionSourceFingerprint $candidate
    $provider = Get-BootstrapPurviewRecoveryProviderState -Config $Config -State $State -AzureIdentity $AzureIdentity
    # A certificate already created or partially created by the failed stage needs
    # read-only normal reconciliation, not a new certificate recovery authority.
    if ([string]$provider.operations.Certificate.status -cne 'Absent') { throw 'This recovery requires both certificate stores to be absent at planning.' }
    $prefix = [ordered]@{}
    foreach ($name in @(Get-GatewayBootstrapStepNames)[0..12]) { $prefix[$name] = $State.steps[$name] }
    $plan = ConvertTo-BootstrapCanonicalValue -Value ([ordered]@{
        schemaVersion = 1
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        deploymentOwnershipId = [string]$State.deploymentOwnershipId
        deploymentKey = [string]$State.deploymentKey
        configurationFingerprint = [string]$State.configurationFingerprint
        originalAcceptedPlan = $State.acceptedPlan
        originalSourceFingerprint = [string]$State.acceptedPlan.sourceFingerprint
        correctedSourceFingerprint = $candidate
        completedPrefix = $prefix
        failedStep = $State.steps[$script:PurviewRecoveryStep]
        binding = $provider.binding
        initialOperations = $provider.operations
        keyCredentialId = [guid]::NewGuid().ToString('D')
        certificateTemplateHash = (Get-FileHash -LiteralPath $template -Algorithm SHA256).Hash.ToLowerInvariant()
    })
    $fingerprint = Get-BootstrapObjectFingerprint -InputObject $plan
    $snapshot = New-BootstrapAcceptedSourceSnapshot -State $State -PlanFingerprint $fingerprint -SourceFingerprint $candidate
    return [ordered]@{ plan = $plan; planFingerprint = $fingerprint; executionSource = $snapshot }
}

function New-BootstrapPurviewCompletePrerequisiteReconciliationPlan {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$AzureIdentity)

    if ($State.Contains('purviewPrerequisiteRecoveryPlan') -or $State.Contains('purviewPrerequisiteReconciliation')) {
        throw 'A Purview prerequisite recovery or reconciliation already exists; use its exact persisted plan.'
    }
    Assert-BootstrapPurviewRecoveryEligibility -State $State -Config $Config
    $root = Get-RepositoryRoot
    Assert-BootstrapPurviewRecoverySourceBoundary -State $State -CandidateRoot $root | Out-Null
    $candidate = Get-BootstrapSourceFingerprint -Root $root
    Set-BootstrapExecutionSourceRoot -Path $root
    $template = Resolve-GatewayCredentialDeploymentTemplate -RelativeTemplate $script:PurviewRecoveryTemplate -ExecutionSourceFingerprint $candidate
    $provider = Get-BootstrapPurviewRecoveryProviderState -Config $Config -State $State -AzureIdentity $AzureIdentity
    foreach ($name in $script:PurviewRecoveryOperations) {
        if ([string]$provider.operations[$name].status -cne 'Present') {
            throw 'Complete-prerequisite reconciliation requires exact readback of every existing certificate and grant.'
        }
    }
    $prefix = [ordered]@{}
    foreach ($name in @(Get-GatewayBootstrapStepNames)[0..12]) { $prefix[$name] = $State.steps[$name] }
    $plan = ConvertTo-BootstrapCanonicalValue -Value ([ordered]@{
        schemaVersion = 1
        kind = 'CompletePrerequisiteReconciliation'
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        deploymentOwnershipId = [string]$State.deploymentOwnershipId
        deploymentKey = [string]$State.deploymentKey
        configurationFingerprint = [string]$State.configurationFingerprint
        originalAcceptedPlan = $State.acceptedPlan
        originalSourceFingerprint = [string]$State.acceptedPlan.sourceFingerprint
        correctedSourceFingerprint = $candidate
        completedPrefix = $prefix
        failedStep = $State.steps[$script:PurviewRecoveryStep]
        binding = $provider.binding
        initialOperations = $provider.operations
        initialAutomationEvidence = $provider.automationEvidence
        certificateTemplateHash = (Get-FileHash -LiteralPath $template -Algorithm SHA256).Hash.ToLowerInvariant()
    })
    $fingerprint = Get-BootstrapObjectFingerprint -InputObject $plan
    $snapshot = New-BootstrapAcceptedSourceSnapshot -State $State -PlanFingerprint $fingerprint -SourceFingerprint $candidate
    return [ordered]@{ plan = $plan; planFingerprint = $fingerprint; executionSource = $snapshot }
}

function Assert-BootstrapPurviewCompletePrerequisiteReconciliationPlan {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Reconciliation,
        [Parameter()][string]$ExpectedPlanFingerprint = '', [switch]$Completed)

    $plan = $Reconciliation.plan
    if ($plan -isnot [Collections.IDictionary] -or [string]$plan.kind -cne 'CompletePrerequisiteReconciliation' -or
        [string]$Reconciliation.planFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $plan) -or
        (-not [string]::IsNullOrEmpty($ExpectedPlanFingerprint) -and [string]$Reconciliation.planFingerprint -cne $ExpectedPlanFingerprint) -or
        [string]$plan.deploymentOwnershipId -cne [string]$State.deploymentOwnershipId -or
        [string]$plan.deploymentKey -cne [string]$State.deploymentKey -or
        [string]$plan.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        (Get-BootstrapObjectFingerprint -InputObject $plan.originalAcceptedPlan) -cne (Get-BootstrapObjectFingerprint -InputObject $State.acceptedPlan) -or
        [string]$plan.originalSourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint -or
        [string]$plan.correctedSourceFingerprint -cne (Get-BootstrapSourceFingerprint)) {
        throw 'Purview prerequisite reconciliation plan, target or source binding changed.'
    }
    foreach ($name in @('databaseRecoveryPlan', 'databaseRecoveryHistory', 'manualDatabaseRepairPlan', 'preInertSourceCorrectionPlan', 'purviewPrerequisiteRecoveryPlan')) {
        if ($State.Contains($name)) { throw 'Purview prerequisite reconciliation cannot be combined with another recovery generation.' }
    }
    $expected = ".bootstrap/accepted-source/$($State.deploymentOwnershipId)/$(([string]$Reconciliation.planFingerprint).Substring(7))"
    if ([string]$Reconciliation.executionSource -cne $expected) { throw 'Purview prerequisite reconciliation snapshot path is not exact.' }
    $snapshot = Join-Path (Get-RepositoryRoot) $expected
    if ((Get-BootstrapSourceFingerprint -Root $snapshot) -cne [string]$plan.correctedSourceFingerprint) {
        throw 'Purview prerequisite reconciliation immutable snapshot changed.'
    }
    Assert-BootstrapPurviewRecoverySourceBoundary -State $State -CandidateRoot $snapshot | Out-Null
    $template = Join-Path $snapshot $script:PurviewRecoveryTemplate
    if ((Get-FileHash -LiteralPath $template -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$plan.certificateTemplateHash) {
        throw 'Purview prerequisite reconciliation certificate template changed.'
    }
    if ($Reconciliation.Contains('status') -and [string]$Reconciliation.status -ceq 'Completed' -and $Completed -ne $true) {
        throw 'Completed Purview prerequisite reconciliation requires completed validation.'
    }
    if ($Completed) {
        if ([string]$Reconciliation.status -cne 'Completed' -or
            [string]::IsNullOrWhiteSpace([string]$Reconciliation.providerEvidenceFingerprint) -or
            [string]::IsNullOrWhiteSpace([string]$Reconciliation.completionFingerprint)) {
            throw 'Purview prerequisite reconciliation has no exact completed receipt.'
        }
        $receipt = [ordered]@{
            planFingerprint = [string]$Reconciliation.planFingerprint
            providerEvidenceFingerprint = [string]$Reconciliation.providerEvidenceFingerprint
            completedAtUtc = [string]$Reconciliation.completedAtUtc
        }
        if ([string]$Reconciliation.completionFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $receipt)) {
            throw 'Purview prerequisite reconciliation completion receipt changed.'
        }
    }
    return $snapshot
}

function Invoke-BootstrapPurviewCompletePrerequisiteReconciliation {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$AzureIdentity,
        [Parameter(Mandatory)]$Reconciliation, [Parameter(Mandatory)][string]$ExpectedPlanFingerprint, [switch]$Yes)

    if (-not $Yes) { throw 'Purview prerequisite reconciliation Execute requires Yes and the reviewed plan fingerprint.' }
    if ([string]$State.configurationFingerprint -cne (Get-BootstrapConfigurationFingerprint -Config $Config)) {
        throw 'Purview prerequisite reconciliation configuration changed.'
    }
    $snapshot = Assert-BootstrapPurviewCompletePrerequisiteReconciliationPlan -State $State `
        -Reconciliation $Reconciliation -ExpectedPlanFingerprint $ExpectedPlanFingerprint
    Set-BootstrapExecutionSourceRoot -Path $snapshot
    $plan = $Reconciliation.plan
    $provider = Get-BootstrapPurviewRecoveryProviderState -Config $Config -State $State -AzureIdentity $AzureIdentity
    foreach ($name in $script:PurviewRecoveryOperations) {
        if ((Get-BootstrapObjectFingerprint -InputObject $provider.operations[$name]) -cne
            (Get-BootstrapObjectFingerprint -InputObject $plan.initialOperations[$name])) {
            throw 'Complete-prerequisite reconciliation provider readback changed.'
        }
    }
    $Reconciliation.status = 'Completed'
    $Reconciliation.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    $Reconciliation.providerEvidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $provider
    $receipt = [ordered]@{ planFingerprint = [string]$Reconciliation.planFingerprint
        providerEvidenceFingerprint = [string]$Reconciliation.providerEvidenceFingerprint
        completedAtUtc = [string]$Reconciliation.completedAtUtc }
    $Reconciliation.completionFingerprint = Get-BootstrapObjectFingerprint -InputObject $receipt
    $null = Assert-BootstrapPurviewCompletePrerequisiteReconciliationPlan -State $State `
        -Reconciliation $Reconciliation -ExpectedPlanFingerprint $ExpectedPlanFingerprint -Completed
    Save-BootstrapState -State $State -Path $StatePath
    return [ordered]@{ status = 'Completed'; planFingerprint = [string]$Reconciliation.planFingerprint; stageReconciliation = 'PendingResume' }
}

function Assert-BootstrapPurviewRecoveryPlan {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Recovery,
        [Parameter()][string]$ExpectedPlanFingerprint = '', [switch]$Completed)

    $plan = $Recovery.plan
    if ($plan -isnot [Collections.IDictionary] -or $plan.schemaVersion -ne 1 -or
        [string]$Recovery.planFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $plan) -or
        (-not [string]::IsNullOrEmpty($ExpectedPlanFingerprint) -and [string]$Recovery.planFingerprint -cne $ExpectedPlanFingerprint) -or
        [string]$plan.deploymentOwnershipId -cne [string]$State.deploymentOwnershipId -or
        [string]$plan.deploymentKey -cne [string]$State.deploymentKey -or
        [string]$plan.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        (Get-BootstrapObjectFingerprint -InputObject $plan.originalAcceptedPlan) -cne (Get-BootstrapObjectFingerprint -InputObject $State.acceptedPlan) -or
        [string]$plan.originalSourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint -or
        [string]$plan.correctedSourceFingerprint -cne (Get-BootstrapSourceFingerprint)) {
        throw 'Purview prerequisite recovery plan, target or source binding changed.'
    }
    foreach ($name in @('databaseRecoveryPlan', 'databaseRecoveryHistory', 'manualDatabaseRepairPlan', 'preInertSourceCorrectionPlan')) {
        if ($State.Contains($name)) { throw 'Purview prerequisite recovery cannot be combined with another recovery generation.' }
    }
    Assert-GuidValue -Value ([string]$plan.keyCredentialId) -Label 'Planned Purview certificate key ID'
    $expected = ".bootstrap/accepted-source/$($State.deploymentOwnershipId)/$(([string]$Recovery.planFingerprint).Substring(7))"
    if ([string]$Recovery.executionSource -cne $expected) { throw 'Purview prerequisite recovery snapshot path is not exact.' }
    $snapshot = Join-Path (Get-RepositoryRoot) $expected
    if ((Get-BootstrapSourceFingerprint -Root $snapshot) -cne [string]$plan.correctedSourceFingerprint) {
        throw 'Purview prerequisite recovery immutable snapshot changed.'
    }
    Assert-BootstrapPurviewRecoverySourceBoundary -State $State -CandidateRoot $snapshot | Out-Null
    $template = Join-Path $snapshot $script:PurviewRecoveryTemplate
    if ((Get-FileHash -LiteralPath $template -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$plan.certificateTemplateHash) {
        throw 'Purview prerequisite recovery certificate template changed.'
    }
    $names = @(Get-GatewayBootstrapStepNames)
    if ($plan.completedPrefix.Count -ne 13 -or [string]$plan.failedStep.status -cne 'Failed') {
        throw 'Purview prerequisite recovery original stage boundary is incomplete.'
    }
    foreach ($name in $names[0..12]) {
        if ($Completed -and $names[0..1] -ccontains $name) {
            if ([string]$State.steps[$name].status -cnotin @('Completed', 'Running', 'Failed') -or
                [string]$State.steps[$name].sourceFingerprint -cne [string]$plan.originalSourceFingerprint) {
                throw 'Purview prerequisite recovery preflight transition is outside the original source boundary.'
            }
            if ($name -ceq 'Azure authentication') {
                foreach ($field in @('tenantId', 'subscriptionId', 'userObjectId')) {
                    if ([string]$State.steps[$name].evidence[$field] -cne [string]$plan.completedPrefix[$name].evidence[$field]) {
                        throw 'Purview prerequisite recovery original administrator or Azure target changed.'
                    }
                }
            }
        }
        elseif ((Get-BootstrapObjectFingerprint -InputObject $State.steps[$name]) -cne
            (Get-BootstrapObjectFingerprint -InputObject $plan.completedPrefix[$name])) {
            throw 'Purview prerequisite recovery completed prefix changed.'
        }
    }
    $step = $State.steps[$script:PurviewRecoveryStep]
    if ($Completed -and [string]$step.status -cin @('Completed', 'Failed') -and $step.Contains('evidence')) {
        $evidence = ConvertTo-BootstrapCanonicalValue -Value $step.evidence
        $evidence.Remove('readbackAtUtc')
        if ([string]$step.sourceFingerprint -cne [string]$plan.originalSourceFingerprint -or
            (Get-BootstrapObjectFingerprint -InputObject $evidence) -cne [string]$Recovery.capabilityEvidenceFingerprint) {
            throw 'Reconciled Purview capability evidence differs from the exact recovery receipt.'
        }
    }
    elseif ((Get-BootstrapObjectFingerprint -InputObject $step) -cne (Get-BootstrapObjectFingerprint -InputObject $plan.failedStep) -or
        (-not $Completed -and $State.steps.Count -ne 14)) { throw 'Purview prerequisite recovery failed-stage boundary changed.' }
    if ($Completed) {
        if ([string]$Recovery.status -cne 'Completed' -or $Recovery.operations.Count -ne 3 -or
            [string]$Recovery.automationEvidenceFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $Recovery.automationEvidence)) {
            throw 'Purview prerequisite recovery has no exact completed receipt.'
        }
        foreach ($name in $script:PurviewRecoveryOperations) {
            if ([string]$Recovery.operations[$name].status -cne 'Completed' -or
                [string]$Recovery.operations[$name].evidence.status -cne 'Present') {
                throw 'Purview prerequisite recovery operation is incomplete.'
            }
        }
        $receipt = [ordered]@{ planFingerprint = [string]$Recovery.planFingerprint; operations = $Recovery.operations
            automationEvidenceFingerprint = [string]$Recovery.automationEvidenceFingerprint
            capabilityEvidenceFingerprint = [string]$Recovery.capabilityEvidenceFingerprint; completedAtUtc = [string]$Recovery.completedAtUtc }
        if ([string]$Recovery.completionFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $receipt)) {
            throw 'Purview prerequisite recovery completion receipt changed.'
        }
    }
    return $snapshot
}

function Invoke-BootstrapPurviewRecoveryOperation {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][ValidateSet('ExchangeGrant', 'ComplianceGrant', 'Certificate')][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Read, [Parameter(Mandatory)][scriptblock]$Mutate)

    $recovery = $State.purviewPrerequisiteRecoveryPlan
    $previous = $recovery.operations[$Name]
    $observed = & $Read
    if ($observed -isnot [Collections.IDictionary] -or [string]$observed.status -cnotin @('Absent', 'Present')) {
        throw 'Purview prerequisite recovery readback did not return an exact disposition.'
    }
    $initial = $recovery.plan.initialOperations[$Name]
    if ([string]$initial.status -ceq 'Present' -and
        (Get-BootstrapObjectFingerprint -InputObject $initial) -cne (Get-BootstrapObjectFingerprint -InputObject $observed)) {
        throw 'An initially present Purview prerequisite is readback-only; its original assignment cannot be replaced.'
    }
    if ($null -ne $previous -and [string]$previous.status -ceq 'Completed') {
        if ((Get-BootstrapObjectFingerprint -InputObject $observed) -cne (Get-BootstrapObjectFingerprint -InputObject $previous.evidence)) {
            throw 'A completed Purview prerequisite no longer matches exact readback.'
        }
        return
    }
    if ([string]$observed.status -ceq 'Absent') {
        if ($null -ne $previous) { throw 'Purview prerequisite outcome remains unknown; this mutation cannot be repeated.' }
        $recovery.operations[$Name] = [ordered]@{ status = 'Started'; startedAtUtc = [DateTimeOffset]::UtcNow.ToString('O') }
        Save-BootstrapState -State $State -Path $StatePath
        try { & $Mutate | Out-Null } catch { } # Readback alone resolves an unknown provider outcome.
        $observed = & $Read
        if ($observed -isnot [Collections.IDictionary] -or [string]$observed.status -cne 'Present') {
            throw 'Purview prerequisite mutation was attempted once; exact readback has not proved completion.'
        }
    }
    $recovery.operations[$Name] = [ordered]@{ status = 'Completed'; evidence = $observed; completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O') }
    Save-BootstrapState -State $State -Path $StatePath
}

function Invoke-BootstrapPurviewRecovery {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$AzureIdentity,
        [Parameter(Mandatory)]$Recovery, [Parameter(Mandatory)][string]$ExpectedPlanFingerprint, [switch]$Yes)

    if (-not $Yes) { throw 'Purview prerequisite recovery Execute requires Yes and the reviewed plan fingerprint.' }
    if ([string]$State.configurationFingerprint -cne (Get-BootstrapConfigurationFingerprint -Config $Config)) {
        throw 'Purview prerequisite recovery configuration changed.'
    }
    $snapshot = Assert-BootstrapPurviewRecoveryPlan -State $State -Recovery $Recovery -ExpectedPlanFingerprint $ExpectedPlanFingerprint
    Set-BootstrapExecutionSourceRoot -Path $snapshot
    $plan = $Recovery.plan
    $null = Resolve-GatewayCredentialDeploymentTemplate -RelativeTemplate $script:PurviewRecoveryTemplate `
        -ExecutionSourceFingerprint ([string]$plan.correctedSourceFingerprint)
    $provider = Get-BootstrapPurviewRecoveryProviderState -Config $Config -State $State -AzureIdentity $AzureIdentity -Binding $plan.binding
    if (-not $State.Contains('purviewPrerequisiteRecoveryPlan')) {
        Assert-BootstrapPurviewRecoveryEligibility -State $State -Config $Config
        if ((Get-BootstrapObjectFingerprint -InputObject $provider.operations) -cne (Get-BootstrapObjectFingerprint -InputObject $plan.initialOperations)) {
            throw 'Purview prerequisite recovery initial observations changed; no mutation is authorized.'
        }
        $Recovery = ConvertTo-BootstrapCanonicalValue -Value $Recovery
        $Recovery['status'] = 'Started'
        $Recovery['operations'] = [ordered]@{}
        $State['purviewPrerequisiteRecoveryPlan'] = $Recovery
        Save-BootstrapState -State $State -Path $StatePath
    }
    elseif ([string]$State.purviewPrerequisiteRecoveryPlan.planFingerprint -cne $ExpectedPlanFingerprint) {
        throw 'A different Purview prerequisite recovery is already persisted.'
    }
    $Recovery = $State.purviewPrerequisiteRecoveryPlan
    Set-BootstrapExecutionSourceRoot -Path $snapshot
    foreach ($name in $script:PurviewRecoveryOperations) {
        $null = Assert-BootstrapPurviewRecoveryPlan -State $State -Recovery $Recovery -ExpectedPlanFingerprint $ExpectedPlanFingerprint
        $read = {
            $value = Get-BootstrapPurviewRecoveryProviderState -Config $Config -State $State -AzureIdentity $AzureIdentity -Binding $plan.binding
            foreach ($priorName in @('ExchangeGrant', 'ComplianceGrant', 'Certificate')) {
                $prior = $Recovery.operations[$priorName]
                if ($null -ne $prior -and [string]$prior.status -ceq 'Completed' -and
                    (Get-BootstrapObjectFingerprint -InputObject $prior.evidence) -cne
                        (Get-BootstrapObjectFingerprint -InputObject $value.operations[$priorName])) {
                    throw 'An earlier completed Purview prerequisite changed before a later operation.'
                }
            }
            if ($name -ceq 'Certificate' -and [string]$value.operations.Certificate.status -ceq 'Present' -and
                [string]$value.operations.Certificate.keyCredentialId -cne [string]$plan.keyCredentialId) {
                throw 'Purview prerequisite certificate does not match the precommitted key ID.'
            }
            return $value.operations[$name]
        }
        $mutate = {
            # The source/template check happens before each one-time write.
            $null = Resolve-GatewayCredentialDeploymentTemplate -RelativeTemplate 'bootstrap/infra/purview-automation-certificate.bicep' `
                -ExecutionSourceFingerprint ([string]$plan.correctedSourceFingerprint)
            switch ($name) {
                'ExchangeGrant' {
                    Invoke-GraphJsonBody -Method POST -Url "https://graph.microsoft.com/v1.0/servicePrincipals/$($plan.binding.servicePrincipalId)/appRoleAssignments" `
                        -Body @{ principalId = [string]$plan.binding.servicePrincipalId; resourceId = [string]$plan.binding.exchangeServicePrincipalId; appRoleId = [string]$plan.binding.exchangeRoleId } | Out-Null
                }
                'ComplianceGrant' {
                    Invoke-GraphJsonBody -Method POST -Url 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' `
                        -Body @{ principalId = [string]$plan.binding.servicePrincipalId; roleDefinitionId = [string]$plan.binding.complianceRoleDefinitionId; directoryScopeId = '/' } | Out-Null
                }
                'Certificate' {
                    New-BootstrapPurviewAutomationCertificate -Config $Config -AzureIdentity $AzureIdentity `
                        -ApplicationObjectId ([string]$plan.binding.applicationObjectId) -ApplicationId ([string]$plan.binding.applicationId) `
                        -KeyCredentialId ([string]$plan.keyCredentialId) -KeyVaultUri ([string]$plan.binding.keyVaultUri) `
                        -DeploymentOwnershipId ([string]$plan.deploymentOwnershipId) -SourceFingerprint ([string]$plan.originalSourceFingerprint) `
                        -ExecutionSourceFingerprint ([string]$plan.correctedSourceFingerprint)
                }
            }
        }
        Invoke-BootstrapPurviewRecoveryOperation -State $State -StatePath $StatePath -Name $name -Read $read -Mutate $mutate
    }
    $provider = Get-BootstrapPurviewRecoveryProviderState -Config $Config -State $State -AzureIdentity $AzureIdentity -Binding $plan.binding
    if ($null -eq $provider.automationEvidence -or [string]$provider.automationEvidence.keyCredentialId -cne [string]$plan.keyCredentialId) {
        throw 'Purview prerequisite recovery final evidence does not match the planned certificate.'
    }
    $component = Get-GatewayPurviewCapabilityEvidence -Config $Config -WorkloadIdentity $State.steps['Workflow v3 Entra configuration'].evidence -Automation $provider.automationEvidence
    $capability = Get-GatewayBootstrapCapabilityEvidence -Config $Config -Identity $State.steps['Gateway API identity'].evidence `
        -RuntimeReadback $State.steps['Inert identity deployment'].evidence -PurviewCapability $component
    $capability.Remove('readbackAtUtc')
    $Recovery['automationEvidence'] = $provider.automationEvidence
    $Recovery['automationEvidenceFingerprint'] = Get-BootstrapObjectFingerprint -InputObject $provider.automationEvidence
    $Recovery['capabilityEvidenceFingerprint'] = Get-BootstrapObjectFingerprint -InputObject $capability
    $Recovery['completedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    $Recovery['completionFingerprint'] = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
        planFingerprint = [string]$Recovery.planFingerprint; operations = $Recovery.operations
        automationEvidenceFingerprint = [string]$Recovery.automationEvidenceFingerprint
        capabilityEvidenceFingerprint = [string]$Recovery.capabilityEvidenceFingerprint; completedAtUtc = [string]$Recovery.completedAtUtc
    })
    $Recovery.status = 'Completed'
    $null = Assert-BootstrapPurviewRecoveryPlan -State $State -Recovery $Recovery -Completed
    Save-BootstrapState -State $State -Path $StatePath
    return [ordered]@{ status = 'Completed'; planFingerprint = [string]$Recovery.planFingerprint; stageReconciliation = 'PendingResume' }
}

Export-ModuleMember -Function *
