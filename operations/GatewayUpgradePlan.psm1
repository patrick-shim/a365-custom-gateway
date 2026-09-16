#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgrade.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradePackaging.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeOperator.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeSqlAdmission.psm1')
Import-Module (Join-Path $PSScriptRoot 'GatewayUpgradeCutover.psm1')

function New-GatewayUpgradePlanV2 {
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)]$Validation,
        [string]$ReviewPath, [string]$ArtifactBundlePath, [string]$RollbackContractPath)
    $source = Test-GatewayUpgradeCandidate $Validation.candidateReceiptPath $Validation.candidateFingerprint
    $null = Test-GatewayUpgradeLocalValidation $Validation
    if ($source -cne $Validation.sourceRoot -or (Get-GatewayUpgradeFileHash $Validation.toolPath) -cne $Validation.toolSha256) {
        throw 'UpgradePlan: candidate/local validation binding changed.'
    }
    if (-not $Request.database.Contains('targetModelFingerprint') -or
        $Request.database.targetModelFingerprint -cne $Validation.modelFingerprint) {
        throw 'UpgradePlan: the exact compiled target model must be selected explicitly.'
    }
    $envelope = New-GatewayUpgradePlan -Request $Request -StatePath $StatePath -ConfigPath $ConfigPath -SourceRoot $source
    $plan = $envelope.plan
    $review = $null
    if ($ReviewPath) {
        $review = Read-GatewayUpgradeJson $ReviewPath
        if ($review.schemaVersion -ne 1 -or $review.candidateFingerprint -cne $Validation.candidateFingerprint -or
            $review.sourceFingerprint -cne $plan.content.sourceFingerprint -or
            $review.decision -cne 'ApprovedForMaintenance' -or $review.reviewerModel -cne 'gpt-6-astra') {
            throw 'UpgradePlan: independent source review is missing or bound to another candidate.'
        }
        $review = @{ reference = [IO.Path]::GetFullPath($ReviewPath); sha256 = Get-GatewayUpgradeFileHash $ReviewPath; record = $review }
    }
    $artifacts = $null
    if ($ArtifactBundlePath) {
        $artifacts = Read-GatewayUpgradeJson $ArtifactBundlePath
        if ($artifacts.record.schemaVersion -ne 1 -or
            (Get-GatewayUpgradeFingerprint $artifacts.record) -cne $artifacts.fingerprint -or
            $artifacts.record.candidateFingerprint -cne $Validation.candidateFingerprint -or
            $artifacts.record.sourceFingerprint -cne $plan.content.sourceFingerprint -or
            $artifacts.record.artifactSourceFingerprint -cne $Validation.artifactSourceFingerprint) {
            throw 'UpgradePlan: artifact provenance is not bound to this exact source.'
        }
        foreach ($component in @('api', 'worker', 'adminUi', 'databaseMigrator')) {
            if ($Request.images[$component] -cne $artifacts.record.images[$component].image) {
                throw 'UpgradePlan: every immutable deployment digest requires exact approval.'
            }
        }
        $artifacts = @{ reference = [IO.Path]::GetFullPath($ArtifactBundlePath); sha256 = Get-GatewayUpgradeFileHash $ArtifactBundlePath; bundle = $artifacts }
    }
    $plan.schemaVersion = 2
    Add-GatewayUpgradeCutoverScope $Request $plan.scope
    $plan['cutover'] = New-GatewayUpgradeCutoverContract $Request $plan.scope
    $plan['candidate'] = @{
        fingerprint = $Validation.candidateFingerprint
        receiptPath = [IO.Path]::GetFullPath($Validation.candidateReceiptPath)
        receiptSha256 = Get-GatewayUpgradeFileHash $Validation.candidateReceiptPath
        artifactSourceFingerprint = $Validation.artifactSourceFingerprint
    }
    $plan['localValidation'] = $Validation
    $plan['independentReview'] = $review
    $plan['artifacts'] = $artifacts
    $plan['authorizedOperator'] = Get-GatewayUpgradeAuthenticatedOperator $Request.target.tenantId $Request.target.subscriptionId
    $plan['buildSupported'] = $null -ne $review
    if ($null -ne $review -and $null -ne $artifacts) {
        Assert-GatewayUpgradeSqlAdmission -SourceRoot $source -Database $Request.database -Mode $(if ($Request.schemaVersion -eq 2) { 'SourceOnlyFull' } else { 'CoreToFull' })
    }
    $plan.executionSupported = $null -ne $review -and $null -ne $artifacts
    $plan.review['artifactApproval'] = 'ACR builds require their own approved Build Plan; resource deployment requires a new Plan approving the returned immutable digests.'
    $plan.review['workerMinimumReplicas'] = 'The upgraded worker remains at minimum one replica for independently observable startup; this adds ongoing Container Apps compute cost.'
    $plan.review['maintenanceAdmission'] = 'CutoverClose stages the exact candidate API in pinned PreSchemaClosed mode before old-writer exclusion. SQL independently verifies the closed API and zero excluded replicas. PostSchemaClosed attestation plus the held worker, schema and capabilities must pass joint readback before explicit Open admission; closed-host health is never operational readiness.'
    $plan.review['privilegedOperator'] = 'The exact tenant Member and automation application owner in authorizedOperator are approval-bound and freshly revalidated before mutations; account switching requires a new Plan.'
    $stageNames = if ($Request.schemaVersion -eq 2) {
        @('Artifacts', 'CutoverClose', 'CapabilityPreservation', 'DatabasePreservation', 'ExecutorSourceCutover', 'Worker', 'Api', 'Admin', 'CutoverOpen', 'Acceptance')
    } else { @('Artifacts', 'CutoverClose', 'ContentSafety', 'PurviewPrerequisites', 'PurviewExecutor', 'DatabaseExpand', 'Worker', 'Api', 'Admin', 'CutoverOpen', 'Acceptance') }
    $plan.stages = $stageNames |
        ForEach-Object { @{ name = $_; implementation = 'MaintenanceAdapterV2'; mutationAllowed = [bool]$plan.executionSupported } }
    $plan.blockers = @(
        if ($null -eq $review) { 'IndependentCandidateReviewRequired' }
        if ($null -eq $artifacts) { 'BuildArtifactsAndExactDigestApprovalRequired' }
        'LiveAuthenticationLicensingAndProviderReadinessNotClaimedByPlan'
    )
    $plan.scope.unresolvedScopes = @()
    if ($RollbackContractPath) {
        $rollback = Read-GatewayUpgradeJson $RollbackContractPath
        $plan['rollbackContract'] = $rollback
        $plan['rollbackContractReference'] = @{ path = [IO.Path]::GetFullPath($RollbackContractPath); sha256 = Get-GatewayUpgradeFileHash $RollbackContractPath }
    }
    $envelope.planFingerprint = Get-GatewayUpgradeFingerprint $plan
    return $envelope
}

function Test-GatewayUpgradePlanV2 {
    param([Parameter(Mandatory)]$Envelope, [Parameter(Mandatory)][string]$ExpectedPlanFingerprint,
        [Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][string]$ConfigPath)
    $plan = $Envelope.plan
    $keys = @('schemaVersion', 'operation', 'releaseId', 'createdAtUtc', 'executionSupported', 'request', 'original',
        'baseline', 'content', 'scope', 'databaseUpgradeProtocol', 'stages', 'blockers', 'review',
        'candidate', 'localValidation', 'independentReview', 'artifacts', 'buildSupported', 'authorizedOperator', 'cutover')
    if ($plan.Contains('rollbackContract') -or $plan.Contains('rollbackContractReference')) {
        $keys += @('rollbackContract', 'rollbackContractReference')
    }
    if ($Envelope.Keys.Count -ne 2 -or @($Envelope.Keys | Where-Object { $_ -cnotin @('planFingerprint', 'plan') }).Count -ne 0 -or
        $plan.Keys.Count -ne $keys.Count -or @($plan.Keys | Where-Object { $_ -cnotin $keys }).Count -ne 0) {
        throw 'UpgradePlan: unsupported Plan field or missing contract.'
    }
    if ($plan.schemaVersion -ne 2 -or $plan.operation -cne 'GatewayInPlaceUpgradePlan' -or
        $Envelope.planFingerprint -cne $ExpectedPlanFingerprint -or
        (Get-GatewayUpgradeFingerprint $plan) -cne $ExpectedPlanFingerprint) {
        throw 'UpgradePlan: exact approved v2 Plan integrity failed.'
    }
    Assert-GatewayUpgradeOperatorBinding $plan.authorizedOperator $plan.request.target.tenantId
    if ((Get-GatewayUpgradeFingerprint $plan.cutover) -cne
        (Get-GatewayUpgradeFingerprint (New-GatewayUpgradeCutoverContract $plan.request $plan.scope))) {
        throw 'UpgradePlan: fixed quiescence, drain and reconciliation contract changed.'
    }
    $source = Test-GatewayUpgradeCandidate $plan.candidate.receiptPath $plan.candidate.fingerprint
    if ($plan.executionSupported -eq $true) {
        Assert-GatewayUpgradeSqlAdmission -SourceRoot $source -Database $plan.request.database `
            -Mode $(if ($plan.request.schemaVersion -eq 2) { 'SourceOnlyFull' } else { 'CoreToFull' })
    }
    $null = Test-GatewayUpgradeLocalValidation $plan.localValidation
    if ((Get-GatewayUpgradeFileHash $plan.candidate.receiptPath) -cne $plan.candidate.receiptSha256 -or
        (Get-GatewayUpgradeFileHash $plan.localValidation.toolPath) -cne $plan.localValidation.toolSha256) {
        throw 'UpgradePlan: approved candidate or local validation artifact changed.'
    }
    $binding = & (Get-Module GatewayUpgrade) {
        param($state, $config, $request, $sourceRoot)
        $inputs = Read-GatewayUpgradeBaselineInputs $state $config $request
        $scope = Get-GatewayUpgradeScope $request $inputs.state
        return @{
            original = Get-GatewayUpgradeOriginalBinding $inputs
            scope = $scope
            content = Get-GatewayUpgradeContentBinding $sourceRoot $request $scope
        }
    } $StatePath $ConfigPath $plan.request $source
    Add-GatewayUpgradeCutoverScope $plan.request $binding.scope
    $binding.scope.unresolvedScopes = @()
    foreach ($field in @('original', 'scope', 'content')) {
        if ((Get-GatewayUpgradeFingerprint $plan[$field]) -cne (Get-GatewayUpgradeFingerprint $binding[$field])) {
            throw "UpgradePlan: $field binding changed."
        }
    }
    foreach ($entry in @($plan.independentReview, $plan.artifacts)) {
        if ($null -ne $entry -and (Get-GatewayUpgradeFileHash $entry.reference) -cne $entry.sha256) {
            throw 'UpgradePlan: source review or approved artifact evidence changed.'
        }
        if ($null -ne $plan.independentReview -and (
            $plan.independentReview.record.schemaVersion -ne 1 -or
            $plan.independentReview.record.candidateFingerprint -cne $plan.candidate.fingerprint -or
            $plan.independentReview.record.sourceFingerprint -cne $plan.content.sourceFingerprint -or
            $plan.independentReview.record.decision -cne 'ApprovedForMaintenance' -or
            $plan.independentReview.record.reviewerModel -cne 'gpt-6-astra')) {
            throw 'UpgradePlan: source review does not authorize this exact candidate.'
        }
        if ($null -ne $plan.artifacts) {
            $bundle = $plan.artifacts.bundle
            if ((Get-GatewayUpgradeFingerprint $bundle.record) -cne $bundle.fingerprint -or
                $bundle.record.sourceFingerprint -cne $plan.content.sourceFingerprint -or
                $bundle.record.candidateFingerprint -cne $plan.candidate.fingerprint -or
                $bundle.record.artifactSourceFingerprint -cne $plan.candidate.artifactSourceFingerprint -or
                (Get-GatewayUpgradeFingerprint $bundle.record.buildPlan) -cne $bundle.record.buildPlanFingerprint) {
                throw 'UpgradePlan: approved artifacts differ from their exact build Plan/source.'
            }
            foreach ($component in @('api', 'worker', 'adminUi', 'databaseMigrator')) {
                if ($plan.request.images[$component] -cne $bundle.record.images[$component].image) {
                    throw 'UpgradePlan: immutable component digest changed.'
                }
            }
        }
        $stageNames = if ($plan.request.schemaVersion -eq 2) {
            @('Artifacts', 'CutoverClose', 'CapabilityPreservation', 'DatabasePreservation', 'ExecutorSourceCutover', 'Worker', 'Api', 'Admin', 'CutoverOpen', 'Acceptance')
        } else { @('Artifacts', 'CutoverClose', 'ContentSafety', 'PurviewPrerequisites', 'PurviewExecutor', 'DatabaseExpand', 'Worker', 'Api', 'Admin', 'CutoverOpen', 'Acceptance') }
        $expectedStages = $stageNames |
            ForEach-Object { @{ name = $_; implementation = 'MaintenanceAdapterV2'; mutationAllowed = [bool]$plan.executionSupported } }
        if ((Get-GatewayUpgradeFingerprint $plan.stages) -cne (Get-GatewayUpgradeFingerprint $expectedStages)) {
            throw 'UpgradePlan: unsupported stage or mutation dispatch declaration.'
        }
        $expectedReview = & (Get-Module GatewayUpgrade) { param($request) Get-GatewayUpgradeReview -Request $request } $plan.request
        $expectedReview['artifactApproval'] = 'ACR builds require their own approved Build Plan; resource deployment requires a new Plan approving the returned immutable digests.'
        $expectedReview['workerMinimumReplicas'] = 'The upgraded worker remains at minimum one replica for independently observable startup; this adds ongoing Container Apps compute cost.'
        $expectedReview['maintenanceAdmission'] = 'CutoverClose stages the exact candidate API in pinned PreSchemaClosed mode before old-writer exclusion. SQL independently verifies the closed API and zero excluded replicas. PostSchemaClosed attestation plus the held worker, schema and capabilities must pass joint readback before explicit Open admission; closed-host health is never operational readiness.'
        $expectedReview['privilegedOperator'] = 'The exact tenant Member and automation application owner in authorizedOperator are approval-bound and freshly revalidated before mutations; account switching requires a new Plan.'
        if ((Get-GatewayUpgradeFingerprint $plan.review) -cne (Get-GatewayUpgradeFingerprint $expectedReview)) {
            throw 'UpgradePlan: mandatory cost, preservation or approval review was altered.'
        }
    }
    if ($plan.buildSupported -ne ($null -ne $plan.independentReview) -or
        $plan.executionSupported -ne ($null -ne $plan.independentReview -and $null -ne $plan.artifacts)) {
        throw 'UpgradePlan: build/deployment admission differs from its verified inputs.'
    }
    if ($plan.Contains('rollbackContractReference') -and
        (Get-GatewayUpgradeFileHash $plan.rollbackContractReference.path) -cne $plan.rollbackContractReference.sha256) {
        throw 'UpgradePlan: compatibility review changed.'
    }
    return $true
}

Export-ModuleMember -Function New-GatewayUpgradePlanV2, Test-GatewayUpgradePlanV2
