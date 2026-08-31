#Requires -Version 7.0

<#
.SYNOPSIS
    Continues only bootstrap steps 12-19 after an exact completed database recovery.

.DESCRIPTION
    This narrow continuation never replans or replays foundation, image, seed,
    workflow, private-endpoint, or database mutations. It loads corrected recovery
    modules, pins deployment inputs to the original accepted snapshot, validates
    completed steps 1-11, and then uses the canonical state-step engine for only
    steps 12-19. Output is JSON Lines and receipts contain safe identifiers and
    fingerprints only.
#>

[CmdletBinding()]
param(
    [string]$Config = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap/config.json'),
    [switch]$Yes,
    [string]$ExpectedContinuationFingerprint = '',
    [switch]$NonInteractive,
    [ValidateSet('Json')][string]$OutputFormat = 'Json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$PSDefaultParameterValues['Write-Host:InformationAction'] = 'Ignore'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'bootstrap/modules/Common.psm1') -Force -DisableNameChecking

$script:continuationToolPath = $PSCommandPath
$script:adminUiVerifierModulePath = Join-Path $repositoryRoot 'bootstrap/modules/Experience.psm1'
$script:keyVaultVerifierModulePath = Join-Path $repositoryRoot 'bootstrap/modules/Verification.psm1'
$script:preflightVerifierPath = Join-Path $repositoryRoot 'operations/test-provisioning-prerequisites.ps1'
$script:reviewedPreflightVerifierFingerprint = 'sha256:58d00078577cf08d7201a2221faa5c88eb76c7955503292a60e6f94c41c9cf84'
$script:continuationReceipt = $null
$script:continuationReceiptPath = ''
$script:continuationState = $null
$script:continuationStatePath = ''

function Write-ContinuationEvent {
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][System.Collections.IDictionary]$Data = [ordered]@{}
    )
    [Console]::Out.WriteLine(([ordered]@{
        schemaVersion = 1
        timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
        type = $Type
        message = $Message
        data = $Data
    } | ConvertTo-Json -Depth 30 -Compress))
}

function Save-ContinuationReceipt {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$Path
    )
    $Receipt['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ".continuation-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        ConvertTo-Json -InputObject (ConvertTo-BootstrapCanonicalValue -Value $Receipt) -Depth 100 |
            Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
        if ($IsWindows) {
            $acl = Get-Acl -LiteralPath $temporary
            $acl.SetAccessRuleProtection($true, $false)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'FullControl',
                'Allow')
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $temporary -AclObject $acl
        }
        elseif (Get-Command chmod -ErrorAction SilentlyContinue) {
            & chmod 600 $temporary
            if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the continuation receipt to the current user.' }
        }
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Read-ContinuationReceipt {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $parameters = @{ AsHashtable = $true; Depth = 100; ErrorAction = 'Stop' }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $parameters['DateKind'] = 'String'
        }
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json @parameters
    }
    catch {
        throw 'The continuation receipt is malformed. Preserve it for review; do not edit it to claim completion.'
    }
}

function Assert-BoundedAdminUiVerifierCompatibility {
    param([Parameter(Mandatory)][string]$RecoveryExperiencePath)

    $currentPath = [IO.Path]::GetFullPath($script:adminUiVerifierModulePath)
    $recoveryPath = [IO.Path]::GetFullPath($RecoveryExperiencePath)
    $currentText = [IO.File]::ReadAllText($currentPath)
    $recoveryText = [IO.File]::ReadAllText($recoveryPath)
    $legacyClause = '        [string]$entries[0].identity -cne $ExpectedIdentity -or'
    $correctedClause = '        -not ([string]$entries[0].identity).Equals($ExpectedIdentity, [StringComparison]::OrdinalIgnoreCase) -or'
    $first = $currentText.IndexOf($correctedClause, [StringComparison]::Ordinal)
    if ($first -lt 0 -or
        $currentText.IndexOf($correctedClause, $first + $correctedClause.Length, [StringComparison]::Ordinal) -ge 0) {
        throw 'The current Admin UI verifier does not contain exactly one reviewed Azure-resource-ID casing correction.'
    }
    $legacyEquivalent = $currentText.Remove($first, $correctedClause.Length).Insert($first, $legacyClause)
    if (-not [string]::Equals($legacyEquivalent, $recoveryText, [StringComparison]::Ordinal)) {
        throw 'The current Admin UI verifier differs from the recovery snapshot beyond the reviewed Azure-resource-ID casing correction.'
    }
    $recoveryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $recoveryPath))
    $relativeVerifierPath = 'bootstrap/modules/Experience.psm1'
    if (-not ([IO.Path]::GetFullPath((Join-Path $recoveryRoot $relativeVerifierPath))).Equals(
            $recoveryPath,
            [StringComparison]::Ordinal)) {
        throw 'The recovery Admin UI verifier is outside its exact accepted-source location.'
    }
    $currentManifest = @(Get-BootstrapSourceManifest -Root (Get-RepositoryRoot))
    $recoveryManifest = @(Get-BootstrapSourceManifest -Root $recoveryRoot)
    $currentByPath = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $recoveryByPath = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $currentManifest) {
        if (-not $currentByPath.TryAdd([string]$entry.path, [string]$entry.sha256)) {
            throw 'The current bootstrap source manifest contains a duplicate path.'
        }
    }
    foreach ($entry in $recoveryManifest) {
        if (-not $recoveryByPath.TryAdd([string]$entry.path, [string]$entry.sha256)) {
            throw 'The recovery bootstrap source manifest contains a duplicate path.'
        }
    }
    if ($currentByPath.Count -ne $recoveryByPath.Count) {
        throw 'The current bootstrap source differs from the recovery snapshot beyond the reviewed verifier correction.'
    }
    $reviewedVerifierPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $null = $reviewedVerifierPaths.Add('bootstrap/modules/Experience.psm1')
    $null = $reviewedVerifierPaths.Add('bootstrap/modules/Verification.psm1')
    $null = $reviewedVerifierPaths.Add('operations/test-provisioning-prerequisites.ps1')
    foreach ($path in $currentByPath.Keys) {
        if (-not $recoveryByPath.ContainsKey($path)) {
            throw 'The current bootstrap source differs from the recovery snapshot beyond the reviewed verifier correction.'
        }
        if (-not $reviewedVerifierPaths.Contains($path) -and $currentByPath[$path] -cne $recoveryByPath[$path]) {
            throw 'The current bootstrap source differs from the recovery snapshot beyond the reviewed verifier correction.'
        }
    }
    $currentVerifierSha256 = (Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $recoveryVerifierSha256 = (Get-FileHash -LiteralPath $recoveryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($currentByPath[$relativeVerifierPath] -cne $currentVerifierSha256 -or
        $recoveryByPath[$relativeVerifierPath] -cne $recoveryVerifierSha256) {
        throw 'The reviewed Admin UI verifier hashes do not match their exact source manifests.'
    }
    return "sha256:$currentVerifierSha256"
}

function Assert-BoundedKeyVaultVerifierCompatibility {
    param([Parameter(Mandatory)][string]$RecoveryVerificationPath)

    $currentPath = [IO.Path]::GetFullPath($script:keyVaultVerifierModulePath)
    $recoveryPath = [IO.Path]::GetFullPath($RecoveryVerificationPath)
    $currentText = [IO.File]::ReadAllText($currentPath)
    $recoveryText = [IO.File]::ReadAllText($recoveryPath)
    $reviewedBlock = @(
        '        $vaultDefaultAction = [string]$vault.defaultAction',
        '        $vaultBypass = [string]$vault.bypass',
        '        $vaultNetworkAclsAreExact =',
        "            (`$vaultDefaultAction -ceq 'Allow' -and `$vaultBypass -ceq 'AzureServices') -or",
        '            ([string]::IsNullOrEmpty($vaultDefaultAction) -and [string]::IsNullOrEmpty($vaultBypass))',
        ''
    ) -join "`n"
    $legacyClause = "            [string]`$vault.defaultAction -cne 'Allow' -or [string]`$vault.bypass -cne 'AzureServices' -or"
    $correctedClause = '            -not $vaultNetworkAclsAreExact -or'
    $legacyRootClause = '    $root = Get-BootstrapExecutionSourceRoot'
    $correctedRootClause = "    `$root = [IO.Path]::GetFullPath((Join-Path `$PSScriptRoot '../..'))"
    $blockIndex = $currentText.IndexOf($reviewedBlock, [StringComparison]::Ordinal)
    $clauseIndex = $currentText.IndexOf($correctedClause, [StringComparison]::Ordinal)
    $rootClauseIndex = $currentText.IndexOf($correctedRootClause, [StringComparison]::Ordinal)
    if ($blockIndex -lt 0 -or
        $currentText.IndexOf($reviewedBlock, $blockIndex + $reviewedBlock.Length, [StringComparison]::Ordinal) -ge 0 -or
        $clauseIndex -lt 0 -or
        $currentText.IndexOf($correctedClause, $clauseIndex + $correctedClause.Length, [StringComparison]::Ordinal) -ge 0 -or
        $rootClauseIndex -lt 0 -or
        $currentText.IndexOf($correctedRootClause, $rootClauseIndex + $correctedRootClause.Length, [StringComparison]::Ordinal) -ge 0) {
        throw 'The current Verification module does not contain exactly the reviewed provider-normalized corrections.'
    }
    $legacyEquivalent = $currentText.Remove($blockIndex, $reviewedBlock.Length)
    $clauseIndex = $legacyEquivalent.IndexOf($correctedClause, [StringComparison]::Ordinal)
    $legacyEquivalent = $legacyEquivalent.Remove($clauseIndex, $correctedClause.Length).Insert($clauseIndex, $legacyClause)
    $rootClauseIndex = $legacyEquivalent.IndexOf($correctedRootClause, [StringComparison]::Ordinal)
    $legacyEquivalent = $legacyEquivalent.Remove($rootClauseIndex, $correctedRootClause.Length).Insert($rootClauseIndex, $legacyRootClause)
    if (-not [string]::Equals($legacyEquivalent, $recoveryText, [StringComparison]::Ordinal)) {
        throw 'The current Verification module differs from the recovery snapshot beyond the reviewed provider-normalized corrections.'
    }
    return "sha256:$((Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash.ToLowerInvariant())"
}

function Assert-BoundedPreflightVerifierCompatibility {
    param([Parameter(Mandatory)][string]$RecoveryPreflightPath)

    $currentPath = [IO.Path]::GetFullPath($script:preflightVerifierPath)
    $recoveryPath = [IO.Path]::GetFullPath($RecoveryPreflightPath)
    $recoveryRoot = Split-Path -Parent (Split-Path -Parent $recoveryPath)
    if (-not ([IO.Path]::GetFullPath((Join-Path $recoveryRoot 'operations/test-provisioning-prerequisites.ps1'))).Equals(
            $recoveryPath,
            [StringComparison]::Ordinal)) {
        throw 'The recovery provisioning preflight is outside its exact accepted-source location.'
    }
    Assert-BootstrapFingerprintValue `
        -Value $script:reviewedPreflightVerifierFingerprint `
        -Label 'Reviewed provisioning preflight verifier fingerprint'
    $currentFingerprint = "sha256:$((Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash.ToLowerInvariant())"
    if ($currentFingerprint -cne $script:reviewedPreflightVerifierFingerprint) {
        throw 'The current provisioning preflight differs from the exact reviewed optional-empty provider-normalization correction.'
    }
    return $currentFingerprint
}

function Enable-BoundedAdminUiRegistryIdentityCasingCorrection {
    param([Parameter(Mandatory)][System.Management.Automation.PSModuleInfo]$ExperienceModule)

    $result = & $ExperienceModule {
        function script:Assert-GatewayExactContainerRegistry {
            param(
                [Parameter(Mandatory)]$Registries,
                [Parameter(Mandatory)][string]$ExpectedServer,
                [Parameter(Mandatory)][string]$ExpectedIdentity
            )
            $entries = @($Registries)
            if ($entries.Count -ne 1 -or [string]$entries[0].server -cne $ExpectedServer -or
                -not ([string]$entries[0].identity).Equals($ExpectedIdentity, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::IsNullOrWhiteSpace([string](Get-GatewayOptionalObjectProperty -Object $entries[0] -Name 'username')) -or
                -not [string]::IsNullOrWhiteSpace([string](Get-GatewayOptionalObjectProperty -Object $entries[0] -Name 'passwordSecretRef'))) {
                throw 'Container registry configuration is not the one exact managed-identity-backed registry contract.'
            }
            return $true
        }

        $expectedIdentity = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-reviewed'
        $caseVariant = $expectedIdentity.Replace('/resourceGroups/', '/resourcegroups/')
        $accepted = Assert-GatewayExactContainerRegistry `
            -Registries @([pscustomobject]@{ server = 'reviewed.azurecr.io'; identity = $caseVariant }) `
            -ExpectedServer 'reviewed.azurecr.io' `
            -ExpectedIdentity $expectedIdentity
        $differentIdentityRejected = $false
        try {
            Assert-GatewayExactContainerRegistry `
                -Registries @([pscustomobject]@{ server = 'reviewed.azurecr.io'; identity = "$expectedIdentity-other" }) `
                -ExpectedServer 'reviewed.azurecr.io' `
                -ExpectedIdentity $expectedIdentity | Out-Null
        }
        catch { $differentIdentityRejected = $true }
        $passwordFallbackRejected = $false
        try {
            Assert-GatewayExactContainerRegistry `
                -Registries @([pscustomobject]@{
                    server = 'reviewed.azurecr.io'
                    identity = $expectedIdentity
                    passwordSecretRef = 'forbidden'
                }) `
                -ExpectedServer 'reviewed.azurecr.io' `
                -ExpectedIdentity $expectedIdentity | Out-Null
        }
        catch { $passwordFallbackRejected = $true }
        return $accepted -eq $true -and $differentIdentityRejected -and $passwordFallbackRejected
    }
    if ($result -isnot [bool] -or $result -ne $true) {
        throw 'The bounded Admin UI registry-identity casing correction failed its exact local contract self-test.'
    }
    return $true
}

function Assert-ContinuationCompletedManualDatabaseRepairBoundary {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )

    Assert-BootstrapManualDatabaseRepairPrerequisite -State $State | Out-Null
    Assert-BootstrapFingerprintValue -Value ([string]$Plan.planFingerprint) -Label 'Manual database repair plan fingerprint'
    $contract = Get-GatewayManualDatabaseRepairContract -Config ([pscustomobject]@{
        projectName = [string]$State.configuration.projectName
        environment = [string]$State.configuration.environment
    })
    if ([string]$Plan.status -cne 'Completed' -or
        [string]$Plan.planFingerprint -cne [string]$State.manualDatabaseRepairPlan.planFingerprint -or
        [string]$Plan.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        [string]$Plan.deploymentOwnershipId -cne ([guid][string]$State.deploymentOwnershipId).ToString('D') -or
        $Plan.originalAcceptedPlan -isnot [System.Collections.IDictionary] -or
        $State.acceptedPlan -isnot [System.Collections.IDictionary] -or
        (Get-BootstrapObjectFingerprint -InputObject $Plan.originalAcceptedPlan) -cne
            (Get-BootstrapObjectFingerprint -InputObject $State.acceptedPlan) -or
        [string]$Plan.exhaustedRecoveryPlanFingerprint -cne [string]$State.databaseRecoveryPlan.planFingerprint -or
        [string]$Plan.repairJob.name -cne [string]$contract.jobName -or
        [string]$Plan.repairJob.repairMode -cne 'ResumeAfterSchemaCompleted' -or
        [int]$Plan.repairJob.replicaRetryLimit -ne 0 -or
        [int]$Plan.repairJob.maximumExecutions -ne 1) {
        throw 'The completed manual database repair plan no longer matches its exact state, ownership, failure chain, or one-shot Job contract.'
    }
    return Resolve-BootstrapManualDatabaseRepairPlanSourceRoot -State $State -Plan $Plan
}

function Get-ContinuationBoundary {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )
    if ([string]$Configuration.purview.enabled -cne 'False' -or
        [string]$Configuration.purview.activateGatewayAdapterAfterPolicyReadback -cne 'False' -or
        [string]$Configuration.purview.policyProvisioningEnabled -cne 'False') {
        throw 'This narrow continuation requires Purview and its policy-provisioning path to be disabled.'
    }
    $automaticCompleted = $State.Contains('databaseRecoveryPlan') -and
        $State.databaseRecoveryPlan -is [System.Collections.IDictionary] -and
        [string]$State.databaseRecoveryPlan.status -ceq 'Completed'
    $manualCompleted = $State.Contains('manualDatabaseRepairPlan') -and
        $State.manualDatabaseRepairPlan -is [System.Collections.IDictionary] -and
        [string]$State.manualDatabaseRepairPlan.status -ceq 'Completed'
    if ($automaticCompleted -eq $manualCompleted) {
        throw 'Continuation requires exactly one completed automatic recovery or completed manual database repair boundary.'
    }
    $completionMode = if ($manualCompleted) { 'ManualDatabaseRepair' } else { 'AutomaticDatabaseRecovery' }
    $recoveryPlan = if ($manualCompleted) { $State.manualDatabaseRepairPlan } else { $State.databaseRecoveryPlan }
    $attemptNumber = if ($manualCompleted) { 0 } else { Get-BootstrapDatabaseRecoveryAttemptNumber -Plan $recoveryPlan }
    if ($manualCompleted) {
        $recoverySourceRoot = Assert-ContinuationCompletedManualDatabaseRepairBoundary -State $State -Plan $recoveryPlan
    }
    else {
        Assert-BootstrapAcceptedDatabaseRecoveryPlan `
            -State $State -PlanFingerprint ([string]$recoveryPlan.planFingerprint) -AllowCompleted | Out-Null
        Assert-BootstrapDatabaseRecoveryHistory -State $State -CurrentPlan $recoveryPlan | Out-Null
        $recoverySourceRoot = Resolve-BootstrapDatabaseRecoveryPlanSourceRoot -State $State -Plan $recoveryPlan
    }
    $recoveryExperiencePath = Join-Path $recoverySourceRoot 'bootstrap/modules/Experience.psm1'
    $adminUiVerifierFingerprint = Assert-BoundedAdminUiVerifierCompatibility -RecoveryExperiencePath $recoveryExperiencePath
    Assert-BootstrapFingerprintValue -Value $adminUiVerifierFingerprint -Label 'Admin UI verifier fingerprint'
    $adminUiRecoveryExperienceFingerprint = "sha256:$((Get-FileHash -LiteralPath $recoveryExperiencePath -Algorithm SHA256).Hash.ToLowerInvariant())"
    Assert-BootstrapFingerprintValue -Value $adminUiRecoveryExperienceFingerprint -Label 'Admin UI recovery verifier fingerprint'
    $recoveryVerificationPath = Join-Path $recoverySourceRoot 'bootstrap/modules/Verification.psm1'
    $keyVaultVerifierFingerprint = Assert-BoundedKeyVaultVerifierCompatibility `
        -RecoveryVerificationPath $recoveryVerificationPath
    Assert-BootstrapFingerprintValue -Value $keyVaultVerifierFingerprint -Label 'Key Vault verifier fingerprint'
    $keyVaultRecoveryVerifierFingerprint = "sha256:$((Get-FileHash -LiteralPath $recoveryVerificationPath -Algorithm SHA256).Hash.ToLowerInvariant())"
    Assert-BootstrapFingerprintValue -Value $keyVaultRecoveryVerifierFingerprint -Label 'Key Vault recovery verifier fingerprint'
    $recoveryPreflightPath = Join-Path $recoverySourceRoot 'operations/test-provisioning-prerequisites.ps1'
    $preflightVerifierFingerprint = Assert-BoundedPreflightVerifierCompatibility `
        -RecoveryPreflightPath $recoveryPreflightPath
    Assert-BootstrapFingerprintValue -Value $preflightVerifierFingerprint -Label 'Provisioning preflight verifier fingerprint'
    $recoveryPreflightVerifierFingerprint = "sha256:$((Get-FileHash -LiteralPath $recoveryPreflightPath -Algorithm SHA256).Hash.ToLowerInvariant())"
    Assert-BootstrapFingerprintValue -Value $recoveryPreflightVerifierFingerprint -Label 'Recovery provisioning preflight verifier fingerprint'
    $originalSourceRoot = Resolve-BootstrapAcceptedSourceRoot -State $State
    if ([string]$State.acceptedPlan.sourceFingerprint -cne [string]$recoveryPlan.originalSourceFingerprint -or
        (Get-BootstrapObjectFingerprint -InputObject $State.acceptedPlan) -cne
            (Get-BootstrapObjectFingerprint -InputObject $recoveryPlan.originalAcceptedPlan)) {
        throw 'The completed recovery no longer preserves the exact original accepted deployment snapshot.'
    }
    $databaseStep = $State.steps['Gateway database']
    $databaseEvidenceExact = if ($manualCompleted) {
        [string]$databaseStep.completionMode -ceq 'ManualDatabaseRepair' -and
        $recoveryPlan.correctedImage -is [System.Collections.IDictionary] -and
        [string]$recoveryPlan.correctedImage.state -ceq 'DigestCheckpointed' -and
        [string]$recoveryPlan.correctedImage.sourceFingerprint -ceq [string]$recoveryPlan.repairSourceFingerprint -and
        [string]$recoveryPlan.correctedImage.deploymentOwnershipId -ceq ([guid][string]$State.deploymentOwnershipId).ToString('D') -and
        [string]$recoveryPlan.correctedImage.recoveryPlanFingerprint -ceq [string]$recoveryPlan.planFingerprint -and
        [string]$recoveryPlan.correctedImage.intentId -ceq [string]$recoveryPlan.repairJob.imageIntentId -and
        [string]$databaseStep.evidence.databaseBootstrapJobImage -ceq [string]$recoveryPlan.correctedImage.image -and
        [string]$databaseStep.evidence.manualDatabaseRepairPlanFingerprint -ceq [string]$recoveryPlan.planFingerprint -and
        [string]$databaseStep.evidence.manualDatabaseRepairSourceFingerprint -ceq [string]$recoveryPlan.repairSourceFingerprint -and
        [string]$databaseStep.evidence.exhaustedDatabaseRecoveryPlanFingerprint -ceq [string]$recoveryPlan.exhaustedRecoveryPlanFingerprint
    }
    else {
        [string]$databaseStep.evidence.databaseRecoveryPlanFingerprint -ceq [string]$recoveryPlan.planFingerprint -and
        [int]$databaseStep.evidence.databaseRecoveryAttemptNumber -eq $attemptNumber
    }
    $completionSourceFingerprint = if ($manualCompleted) { [string]$recoveryPlan.repairSourceFingerprint } else { [string]$recoveryPlan.correctedSourceFingerprint }
    if ($databaseStep -isnot [System.Collections.IDictionary] -or
        [string]$databaseStep.status -cne 'Completed' -or
        $databaseStep.evidence -isnot [System.Collections.IDictionary] -or
        [string]$databaseStep.sourceFingerprint -cne $completionSourceFingerprint -or
        -not $databaseEvidenceExact -or
        (Get-BootstrapObjectFingerprint -InputObject $databaseStep.evidence) -cne [string]$recoveryPlan.databaseEvidenceFingerprint) {
        throw 'The completed Gateway database evidence is not exactly bound to the final successful recovery attempt.'
    }

    $validatedStepNames = @(
        'Prerequisites',
        'Azure authentication',
        'Azure provider registration',
        'Azure foundation',
        'Gateway API identity',
        'Immutable workload images',
        'Inert identity deployment',
        'Agent 365 seed blueprint',
        'Workflow v3 Entra configuration',
        'SQL private endpoint',
        'Gateway database'
    )
    $completedBoundary = [Collections.Generic.List[object]]::new()
    foreach ($name in $validatedStepNames) {
        $step = $State.steps[$name]
        $expectedStepSource = if ($name -ceq 'Gateway database') {
            $completionSourceFingerprint
        }
        else { [string]$recoveryPlan.originalSourceFingerprint }
        if ($step -isnot [System.Collections.IDictionary] -or
            [string]$step.status -cne 'Completed' -or
            $step.evidence -isnot [System.Collections.IDictionary] -or
            [string]$step.sourceFingerprint -cne $expectedStepSource) {
            throw "Continuation requires completed and evidenced bootstrap step '$name'."
        }
        $completedBoundary.Add([ordered]@{
            name = $name
            sourceFingerprint = [string]$step.sourceFingerprint
            evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $step.evidence
        })
    }

    $continuationStepNames = @(
        'Admin UI identity',
        'Admin UI Key Vault credential',
        'Purview policies',
        'Gateway runtime deployment',
        'Admin UI deployment',
        'Admin UI redirect URIs',
        'Network hardening',
        'End-to-end deployment verification'
    )
    $toolFingerprint = "sha256:$((Get-FileHash -LiteralPath $script:continuationToolPath -Algorithm SHA256).Hash.ToLowerInvariant())"
    Assert-BootstrapFingerprintValue -Value $toolFingerprint -Label 'Continuation tool fingerprint'
    $contract = [ordered]@{
        schemaVersion = 1
        operation = 'ContinueBootstrapAfterDatabaseRecovery'
        subscriptionId = [string]$Configuration.subscriptionId
        tenantId = [string]$Configuration.tenantId
        resourceGroupName = [string]$Configuration.resourceGroupName
        projectName = [string]$Configuration.projectName
        environment = [string]$Configuration.environment
        deploymentOwnershipId = ([guid][string]$State.deploymentOwnershipId).ToString('D')
        configurationFingerprint = [string]$State.configurationFingerprint
        originalAcceptedPlanFingerprint = [string]$State.acceptedPlan.planFingerprint
        originalAcceptedPlanRecordFingerprint = Get-BootstrapObjectFingerprint -InputObject $State.acceptedPlan
        originalSourceFingerprint = [string]$recoveryPlan.originalSourceFingerprint
        originalExecutionSource = [string]$State.acceptedPlan.executionSource
        databaseCompletionMode = $completionMode
        recoveryAttemptNumber = $attemptNumber
        recoveryPlanFingerprint = [string]$recoveryPlan.planFingerprint
        recoverySourceFingerprint = $completionSourceFingerprint
        recoveryExecutionSource = [string]$recoveryPlan.executionSource
        recoveryDatabaseEvidenceFingerprint = [string]$recoveryPlan.databaseEvidenceFingerprint
        recoveryHistoryFingerprint = if ($manualCompleted) { [string]$recoveryPlan.exhaustedRecoveryPlanFingerprint } elseif ($attemptNumber -eq 2) { [string](@($State.databaseRecoveryHistory)[0].archiveFingerprint) } else { '' }
        manualDatabaseRepairPlanFingerprint = if ($manualCompleted) { [string]$recoveryPlan.planFingerprint } else { '' }
        manualDatabaseRepairSourceFingerprint = if ($manualCompleted) { [string]$recoveryPlan.repairSourceFingerprint } else { '' }
        exhaustedRecoveryPlanFingerprint = if ($manualCompleted) { [string]$recoveryPlan.exhaustedRecoveryPlanFingerprint } else { '' }
        toolFingerprint = $toolFingerprint
        adminUiVerifierFingerprint = $adminUiVerifierFingerprint
        adminUiRecoveryExperienceFingerprint = $adminUiRecoveryExperienceFingerprint
        adminUiVerifierCorrection = 'AzureResourceIdOrdinalIgnoreCaseV1'
        keyVaultVerifierFingerprint = $keyVaultVerifierFingerprint
        keyVaultRecoveryVerifierFingerprint = $keyVaultRecoveryVerifierFingerprint
        keyVaultVerifierCorrection = 'DisabledPublicAccessNullNetworkAclsV1'
        preflightVerifierFingerprint = $preflightVerifierFingerprint
        recoveryPreflightVerifierFingerprint = $recoveryPreflightVerifierFingerprint
        preflightVerifierCorrection = 'OptionalEmptyContainerEnvironmentOmissionV1'
        validatedSteps = @($completedBoundary)
        continuationSteps = $continuationStepNames
        purviewDisabled = $true
    }
    return [ordered]@{
        contract = $contract
        continuationFingerprint = Get-BootstrapObjectFingerprint -InputObject $contract
        recoverySourceRoot = $recoverySourceRoot
        originalSourceRoot = $originalSourceRoot
        recoveryPlan = $recoveryPlan
        manualDatabaseRepairPlan = if ($manualCompleted) { $recoveryPlan } else { $null }
        attemptNumber = $attemptNumber
        continuationStepNames = $continuationStepNames
    }
}

function Assert-ContinuationReceipt {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Boundary
    )
    if ([string]$Receipt.schemaVersion -cne '1' -or
        [string]$Receipt.operation -cne 'ContinueBootstrapAfterDatabaseRecovery' -or
        [string]$Receipt.continuationFingerprint -cne [string]$Boundary.continuationFingerprint -or
        $Receipt.acceptedContract -isnot [System.Collections.IDictionary] -or
        $Receipt.validatedSteps -isnot [System.Collections.IDictionary] -or
        $Receipt.checkpoints -isnot [System.Collections.IDictionary] -or
        (Get-BootstrapObjectFingerprint -InputObject $Receipt.acceptedContract) -cne [string]$Receipt.continuationFingerprint -or
        [string]$Receipt.status -notin @('Accepted', 'Running', 'NeedsAttention', 'Verified')) {
        throw 'The continuation receipt is not exact, supported, or bound to the current recovered bootstrap.'
    }
    return $true
}

function Assert-VerifiedContinuationState {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string[]]$StepNames
    )
    if ($Receipt.result -isnot [System.Collections.IDictionary]) {
        throw 'The verified continuation receipt has no safe final result.'
    }
    foreach ($name in $StepNames) {
        $step = $State.steps[$name]
        $checkpoint = $Receipt.checkpoints[$name]
        if ($step -isnot [System.Collections.IDictionary] -or
            [string]$step.status -cne 'Completed' -or
            $step.evidence -isnot [System.Collections.IDictionary] -or
            $checkpoint -isnot [System.Collections.IDictionary] -or
            [string]$checkpoint.evidenceFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $step.evidence)) {
            throw 'The verified continuation receipt no longer matches every completed continuation step.'
        }
    }
    if ($State.outputs.verification -isnot [System.Collections.IDictionary] -or
        [string]$Receipt.result.verificationFingerprint -cne
            (Get-BootstrapObjectFingerprint -InputObject $State.outputs.verification) -or
        (Get-BootstrapObjectFingerprint -InputObject $State.outputs.verification) -cne
            (Get-BootstrapObjectFingerprint -InputObject $State.steps['End-to-end deployment verification'].evidence)) {
        throw 'The verified continuation output no longer matches final verification evidence.'
    }
    return $true
}

function Save-ValidationCheckpoint {
    param([Parameter(Mandatory)][string]$Name)
    $step = $script:continuationState.steps[$Name]
    $script:continuationReceipt.validatedSteps[$Name] = [ordered]@{
        validatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $step.evidence
    }
    Save-ContinuationReceipt -Receipt $script:continuationReceipt -Path $script:continuationReceiptPath
    Write-ContinuationEvent -Type 'StepValidated' -Message "Validated: $Name" -Data ([ordered]@{ step = $Name })
}

function Assert-CanonicalValidationResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Result
    )
    if ($Result -isnot [bool] -or $Result -ne $true) {
        throw "Canonical read-only validation did not accept completed step '$Name'."
    }
    return $true
}

function Invoke-ContinuationStateStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter()][scriptblock]$Validate,
        [Parameter()][scriptblock]$Reconcile,
        [switch]$NoAutomaticReplayAfterStart,
        [switch]$AlwaysRun
    )
    $parameters = @{
        Name = $Name
        State = $script:continuationState
        StatePath = $script:continuationStatePath
        Action = $Action
    }
    if ($Validate) { $parameters.Validate = $Validate }
    if ($Reconcile) { $parameters.Reconcile = $Reconcile }
    if ($NoAutomaticReplayAfterStart) { $parameters.NoAutomaticReplayAfterStart = $true }
    if ($AlwaysRun) { $parameters.AlwaysRun = $true }
    $result = Invoke-BootstrapStateStep @parameters
    $step = $script:continuationState.steps[$Name]
    $script:continuationReceipt.checkpoints[$Name] = [ordered]@{
        status = [string]$step.status
        completedAtUtc = [string]$step.completedAtUtc
        evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $step.evidence
    }
    Save-ContinuationReceipt -Receipt $script:continuationReceipt -Path $script:continuationReceiptPath
    Write-ContinuationEvent -Type 'StepCompleted' -Message "Completed: $Name" -Data ([ordered]@{ step = $Name })
    return $result
}

function Invoke-ExactReconciliation {
    param([Parameter(Mandatory)][scriptblock]$Readback)
    try {
        [object[]]$result = @(& $Readback)
        if ($result.Count -ne 1 -or $result[0] -isnot [System.Collections.IDictionary]) {
            return [ordered]@{ recovered = $false }
        }
        return [ordered]@{ recovered = $true; evidence = $result[0] }
    }
    catch { return [ordered]@{ recovered = $false } }
}

function Test-ContinuationNetworkHardening {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Evidence
    )

    $expectedSharedVault = "kv-$($Config.projectName)-$($Config.environment)"
    $expectedProvisioningVault = "kv-$($Config.projectName)-$($Config.environment)-prov"
    if ([string]$Evidence.sharedKeyVault -cne $expectedSharedVault -or
        [string]$Evidence.provisioningKeyVault -cne $expectedProvisioningVault -or
        [string]$Evidence.publicNetworkAccess -cne 'Disabled' -or
        $Evidence.exactPostMutationReadback -ne $true) {
        return $false
    }
    foreach ($vault in @($expectedSharedVault, $expectedProvisioningVault)) {
        $actual = Invoke-AzTsv -Arguments @(
            'keyvault', 'show', '--resource-group', [string]$Config.resourceGroupName,
            '--name', $vault, '--query', 'properties.publicNetworkAccess'
        )
        if ($actual -cne 'Disabled') { return $false }
    }
    return $true
}

if ($MyInvocation.InvocationName -ceq '.') { return }

$lock = $null
$boundary = $null
try {
    $configuration = Read-BootstrapConfig -Path $Config
    $statePath = Get-BootstrapStatePath -Config $configuration
    $state = Read-BootstrapState -Path $statePath -Config $configuration
    $boundary = Get-ContinuationBoundary -Configuration $configuration -State $state
    $fingerprint = [string]$boundary.continuationFingerprint

    if (-not $Yes) {
        Write-ContinuationEvent -Type 'ContinuationReview' -Message 'No mutation performed. Review and authorize this exact recovered-bootstrap continuation fingerprint.' -Data ([ordered]@{
            continuationFingerprint = $fingerprint
            recoveryAttemptNumber = [int]$boundary.attemptNumber
            recoveryPlanFingerprint = [string]$boundary.recoveryPlan.planFingerprint
            steps = @($boundary.continuationStepNames)
            mutationAuthorized = $false
        })
        return
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedContinuationFingerprint) -or
        $ExpectedContinuationFingerprint -cne $fingerprint) {
        throw 'Continuation --yes requires the exact expected continuation fingerprint from the immediately reviewed JSON result.'
    }

    $lock = Enter-BootstrapLock -StatePath $statePath
    $state = Read-BootstrapState -Path $statePath -Config $configuration
    $boundary = Get-ContinuationBoundary -Configuration $configuration -State $state
    if ([string]$boundary.continuationFingerprint -cne $ExpectedContinuationFingerprint) {
        throw 'Recovered bootstrap state changed after continuation review. No mutation was started.'
    }
    $fingerprint = [string]$boundary.continuationFingerprint
    $receiptPath = Join-Path $repositoryRoot ".bootstrap/evidence/$($configuration.resourceGroupName)/continuation/$($fingerprint.Substring(7)).json"
    $receipt = Read-ContinuationReceipt -Path $receiptPath
    if ($receipt) {
        $null = Assert-ContinuationReceipt -Receipt $receipt -Boundary $boundary
    }
    else {
        $receipt = [ordered]@{
            schemaVersion = 1
            operation = 'ContinueBootstrapAfterDatabaseRecovery'
            continuationFingerprint = $fingerprint
            acceptedContract = ConvertTo-BootstrapCanonicalValue -Value $boundary.contract
            status = 'Accepted'
            acceptedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            validatedSteps = [ordered]@{}
            checkpoints = [ordered]@{}
        }
        Save-ContinuationReceipt -Receipt $receipt -Path $receiptPath
    }
    if ([string]$receipt.status -ceq 'Verified') {
        $null = Assert-VerifiedContinuationState -Receipt $receipt -State $state -StepNames @($boundary.continuationStepNames)
        Write-ContinuationEvent -Type 'Result' -Message 'This exact recovered-bootstrap continuation is already verified.' -Data ([ordered]@{
            continuationFingerprint = $fingerprint
            receiptPath = $receiptPath
            verified = $true
        })
        return
    }
    $receipt['status'] = 'Running'
    $receipt['startedAtUtc'] = if ($receipt.Contains('startedAtUtc')) { [string]$receipt.startedAtUtc } else { [DateTimeOffset]::UtcNow.ToString('O') }
    Save-ContinuationReceipt -Receipt $receipt -Path $receiptPath

    $script:continuationReceipt = $receipt
    $script:continuationReceiptPath = $receiptPath
    $script:continuationState = $state
    $script:continuationStatePath = $statePath

    $recoverySourceRoot = [string]$boundary.recoverySourceRoot
    foreach ($module in @('Experience', 'Prerequisites', 'Azure', 'Entra', 'Agent365', 'Database', 'Purview')) {
        Import-Module (Join-Path $recoverySourceRoot "bootstrap/modules/$module.psm1") -Force -DisableNameChecking
    }
    $runtimeAdminUiVerifierFingerprint = Assert-BoundedAdminUiVerifierCompatibility `
        -RecoveryExperiencePath (Join-Path $recoverySourceRoot 'bootstrap/modules/Experience.psm1')
    if ($runtimeAdminUiVerifierFingerprint -cne [string]$boundary.contract.adminUiVerifierFingerprint) {
        throw 'The bounded Admin UI verifier changed after continuation authorization.'
    }
    $recoveryExperiencePath = [IO.Path]::GetFullPath((Join-Path $recoverySourceRoot 'bootstrap/modules/Experience.psm1'))
    $runtimeRecoveryExperienceFingerprint = "sha256:$((Get-FileHash -LiteralPath $recoveryExperiencePath -Algorithm SHA256).Hash.ToLowerInvariant())"
    $experienceModules = @(Get-Module Experience -All | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.Path) -and
        ([IO.Path]::GetFullPath([string]$_.Path)).Equals($recoveryExperiencePath, [StringComparison]::Ordinal)
    })
    if ($runtimeRecoveryExperienceFingerprint -cne [string]$boundary.contract.adminUiRecoveryExperienceFingerprint -or
        [string]$boundary.contract.adminUiVerifierCorrection -cne 'AzureResourceIdOrdinalIgnoreCaseV1' -or
        $experienceModules.Count -ne 1) {
        throw 'The exact recovery Experience module is absent, ambiguous, modified, or outside the reviewed correction contract.'
    }
    Enable-BoundedAdminUiRegistryIdentityCasingCorrection -ExperienceModule $experienceModules[0] | Out-Null
    $recoveryVerificationPath = [IO.Path]::GetFullPath((Join-Path $recoverySourceRoot 'bootstrap/modules/Verification.psm1'))
    $runtimeKeyVaultVerifierFingerprint = Assert-BoundedKeyVaultVerifierCompatibility `
        -RecoveryVerificationPath $recoveryVerificationPath
    $runtimeRecoveryVerificationFingerprint = "sha256:$((Get-FileHash -LiteralPath $recoveryVerificationPath -Algorithm SHA256).Hash.ToLowerInvariant())"
    if ($runtimeKeyVaultVerifierFingerprint -cne [string]$boundary.contract.keyVaultVerifierFingerprint -or
        $runtimeRecoveryVerificationFingerprint -cne [string]$boundary.contract.keyVaultRecoveryVerifierFingerprint -or
        [string]$boundary.contract.keyVaultVerifierCorrection -cne 'DisabledPublicAccessNullNetworkAclsV1') {
        throw 'The bounded Key Vault verifier changed after continuation authorization.'
    }
    $recoveryPreflightPath = [IO.Path]::GetFullPath((Join-Path $recoverySourceRoot 'operations/test-provisioning-prerequisites.ps1'))
    $runtimePreflightVerifierFingerprint = Assert-BoundedPreflightVerifierCompatibility `
        -RecoveryPreflightPath $recoveryPreflightPath
    $runtimeRecoveryPreflightFingerprint = "sha256:$((Get-FileHash -LiteralPath $recoveryPreflightPath -Algorithm SHA256).Hash.ToLowerInvariant())"
    if ($runtimePreflightVerifierFingerprint -cne [string]$boundary.contract.preflightVerifierFingerprint -or
        $runtimeRecoveryPreflightFingerprint -cne [string]$boundary.contract.recoveryPreflightVerifierFingerprint -or
        [string]$boundary.contract.preflightVerifierCorrection -cne 'OptionalEmptyContainerEnvironmentOmissionV1') {
        throw 'The bounded provisioning preflight verifier changed after continuation authorization.'
    }
    $currentVerificationPath = [IO.Path]::GetFullPath($script:keyVaultVerifierModulePath)
    Import-Module $currentVerificationPath -Force -DisableNameChecking
    $verificationModules = @(Get-Module Verification -All)
    if ($verificationModules.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$verificationModules[0].Path) -or
        -not ([IO.Path]::GetFullPath([string]$verificationModules[0].Path)).Equals(
            $currentVerificationPath,
            [StringComparison]::Ordinal)) {
        throw 'The exact reviewed Key Vault verifier module is absent, ambiguous, or outside the corrected-source contract.'
    }
    $originalSourceRoot = [string]$boundary.originalSourceRoot
    Set-BootstrapExecutionSourceRoot -Path $originalSourceRoot
    if ((Get-BootstrapSourceFingerprint -Root (Get-BootstrapExecutionSourceRoot)) -cne [string]$boundary.contract.originalSourceFingerprint) {
        throw 'The original accepted deployment snapshot changed before continuation validation.'
    }

    $ownershipId = [string]$state.deploymentOwnershipId
    $deploymentSourceFingerprint = [string]$boundary.contract.originalSourceFingerprint
    $databaseRecoveryPlan = if ([string]$boundary.contract.databaseCompletionMode -ceq 'AutomaticDatabaseRecovery') { $state.databaseRecoveryPlan } else { $null }
    $manualDatabaseRepairPlan = if ([string]$boundary.contract.databaseCompletionMode -ceq 'ManualDatabaseRepair') { $state.manualDatabaseRepairPlan } else { $null }

    $null = Assert-BootstrapPrerequisites -Install:$false -RequirePurview:$false
    Save-ValidationCheckpoint -Name 'Prerequisites'

    $azureIdentity = Connect-BootstrapAzure -Config $configuration -NonInteractive:$NonInteractive
    $null = Assert-BootstrapAzureContext -Config $configuration
    $recordedAzureIdentity = $state.steps['Azure authentication'].evidence
    if ([string]$azureIdentity.subscriptionId -cne [string]$recordedAzureIdentity.subscriptionId -or
        [string]$azureIdentity.tenantId -cne [string]$recordedAzureIdentity.tenantId -or
        [string]$azureIdentity.userObjectId -cne [string]$recordedAzureIdentity.userObjectId -or
        [string]$azureIdentity.userPrincipalName -cne [string]$recordedAzureIdentity.userPrincipalName) {
        throw 'The current Azure administrator does not match the completed bootstrap authentication boundary.'
    }
    Save-ValidationCheckpoint -Name 'Azure authentication'

    $resourceGroupExists = [string](Invoke-AzTsv -Arguments @('group', 'exists', '--name', [string]$configuration.resourceGroupName))
    if ($resourceGroupExists -cne 'true') { throw 'The exact recovered bootstrap resource group is absent.' }
    Assert-GatewayResourceGroupRecoveryBoundary -ResourceGroupExists $resourceGroupExists -FoundationStep $state.steps['Azure foundation'] | Out-Null

    $null = Assert-CanonicalValidationResult -Name 'Azure provider registration' -Result (Test-GatewayResourceProviderEvidence)
    Save-ValidationCheckpoint -Name 'Azure provider registration'

    $foundation = $state.steps['Azure foundation'].evidence
    $null = Assert-CanonicalValidationResult -Name 'Azure foundation' -Result (Test-GatewaySubscriptionDeploymentEvidence -Config $configuration -Evidence $foundation -DeploymentOwnershipId $ownershipId -SourceFingerprint $deploymentSourceFingerprint)
    Save-ValidationCheckpoint -Name 'Azure foundation'

    $identity = $state.steps['Gateway API identity'].evidence
    $null = Assert-CanonicalValidationResult -Name 'Gateway API identity' -Result (Test-GatewayApplicationEvidence -Config $configuration -Evidence $identity -ObjectIdProperty 'gatewayApiApplicationObjectId' -ClientIdProperty 'gatewayApiClientId' -ApplicationKind GatewayApi)
    Save-ValidationCheckpoint -Name 'Gateway API identity'

    $images = $state.steps['Immutable workload images'].evidence
    $null = Assert-CanonicalValidationResult -Name 'Immutable workload images' -Result (Test-GatewayImmutableImageEvidence -Evidence $images -SourceFingerprint $deploymentSourceFingerprint -DeploymentOwnershipId $ownershipId)
    Save-ValidationCheckpoint -Name 'Immutable workload images'

    $inert = $state.steps['Inert identity deployment'].evidence
    $runtimeSupersededInert = $state.steps['Gateway runtime deployment'] -and [string]$state.steps['Gateway runtime deployment'].status -eq 'Completed'
    $null = Assert-CanonicalValidationResult -Name 'Inert identity deployment' -Result (Test-GatewayGroupDeploymentEvidence -Config $configuration -Foundation $foundation -Identity $identity -Evidence $inert -DeploymentOwnershipId $ownershipId -SourceFingerprint $deploymentSourceFingerprint -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -AllowRuntimeSupersession:$runtimeSupersededInert)
    Save-ValidationCheckpoint -Name 'Inert identity deployment'

    $blueprint = $state.steps['Agent 365 seed blueprint'].evidence
    $null = Assert-CanonicalValidationResult -Name 'Agent 365 seed blueprint' -Result (Test-GatewayBlueprintEvidence -Config $configuration -Evidence $blueprint -DeploymentOwnershipId $ownershipId -SourceFingerprint $deploymentSourceFingerprint -SponsorObjectId ([string]$azureIdentity.userObjectId) -GatewayManagedIdentityPrincipalId ([string]$inert.workerPrincipalId))
    Save-ValidationCheckpoint -Name 'Agent 365 seed blueprint'

    $null = Assert-CanonicalValidationResult -Name 'Workflow v3 Entra configuration' -Result (Test-GatewayWorkflowIdentityEvidence -Config $configuration -Identity $identity -Inert $inert -Evidence $state.steps['Workflow v3 Entra configuration'].evidence)
    Save-ValidationCheckpoint -Name 'Workflow v3 Entra configuration'

    $sqlPrivateEndpoint = $state.steps['SQL private endpoint'].evidence
    $null = Assert-CanonicalValidationResult -Name 'SQL private endpoint' -Result (Test-GatewaySqlPrivateEndpointEvidence -Config $configuration -Foundation $foundation -SqlServerFqdn ([string]$inert.sqlServerFqdn) -Evidence $sqlPrivateEndpoint -DeploymentOwnershipId $ownershipId -SourceFingerprint $deploymentSourceFingerprint)
    Save-ValidationCheckpoint -Name 'SQL private endpoint'

    $database = $state.steps['Gateway database'].evidence
    $null = Assert-CanonicalValidationResult -Name 'Gateway database' -Result (Test-GatewayDatabaseEvidence -Config $configuration -Foundation $foundation -Inert $inert -Evidence $database -StepRecord $state.steps['Gateway database'] -DeploymentOwnershipId $ownershipId -SourceFingerprint $deploymentSourceFingerprint -DatabaseMigratorImage ([string]$images.databaseMigrator) -DatabaseRecoveryPlan $databaseRecoveryPlan -ManualDatabaseRepairPlan $manualDatabaseRepairPlan)
    Save-ValidationCheckpoint -Name 'Gateway database'

    $adminIdentity = Invoke-ContinuationStateStep -Name 'Admin UI identity' -Validate {
        $expectedAdminUiUrl = if ($state.steps['Admin UI deployment'] -and [string]$state.steps['Admin UI deployment'].status -eq 'Completed') { [string]$state.steps['Admin UI deployment'].evidence.adminUiUrl } else { '' }
        Test-GatewayApplicationEvidence -Config $configuration -Evidence $state.steps['Admin UI identity'].evidence -ObjectIdProperty 'adminUiApplicationObjectId' -ClientIdProperty 'adminUiClientId' -ApplicationKind AdminUi -ExpectedAdminUiUrl $expectedAdminUiUrl
    } -Reconcile {
        Invoke-ExactReconciliation -Readback { Ensure-AdminUiApplication -Config $configuration -Identity $identity -DeploymentOwnershipId $ownershipId -ReconcileOnly }
    } -NoAutomaticReplayAfterStart -Action {
        Ensure-AdminUiApplication -Config $configuration -Identity $identity -DeploymentOwnershipId $ownershipId
    }

    $adminCredential = Invoke-ContinuationStateStep -Name 'Admin UI Key Vault credential' -Validate {
        Test-GatewayAdminCredentialEvidence -Config $configuration -AdminIdentity $adminIdentity -Inert $inert -Evidence $state.steps['Admin UI Key Vault credential'].evidence
    } -Reconcile {
        Invoke-ExactReconciliation -Readback { Resolve-AdminUiCredentialAfterStartedOutcome -Config $configuration -AdminIdentity $adminIdentity -KeyVaultUri ([string]$inert.keyVaultUri) -UserObjectId ([string]$azureIdentity.userObjectId) }
    } -NoAutomaticReplayAfterStart -Action {
        New-AdminUiCredentialInKeyVault -Config $configuration -AdminIdentity $adminIdentity -KeyVaultUri ([string]$inert.keyVaultUri) -UserObjectId ([string]$azureIdentity.userObjectId)
    }

    $purview = Invoke-ContinuationStateStep -Name 'Purview policies' -Validate {
        Test-GatewayPurviewEvidence -Config $configuration -Blueprint $blueprint -Evidence $state.steps['Purview policies'].evidence -UserPrincipalName ([string]$azureIdentity.userPrincipalName) -NonInteractive:$NonInteractive
    } -Reconcile {
        Invoke-ExactReconciliation -Readback {
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
        $created = @(Ensure-BootstrapPurviewPolicies -Config $configuration -Blueprint $blueprint -UserPrincipalName ([string]$azureIdentity.userPrincipalName) -NonInteractive:$NonInteractive)
        if ($created.Count -eq 0 -or $created[-1] -isnot [System.Collections.IDictionary]) { throw 'Purview-disabled evidence did not return its canonical safe shape.' }
        return $created[-1]
    }

    $developmentPreviewRequested = [string]$configuration.environment -eq 'dev' -and $configuration.agent365.allowDevelopmentRegistryPreview -eq $true
    $enableProvisioning = $developmentPreviewRequested -and $configuration.purview.policyProvisioningEnabled -ne $true
    $runtime = Invoke-ContinuationStateStep -Name 'Gateway runtime deployment' -Validate {
        Test-GatewayGroupDeploymentEvidence -Config $configuration -Foundation $foundation -Identity $identity -Evidence $state.steps['Gateway runtime deployment'].evidence -DeploymentOwnershipId $ownershipId -SourceFingerprint $deploymentSourceFingerprint -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -Database $database
    } -Action {
        $created = Deploy-GatewayCore -Config $configuration -Foundation $foundation -Identity $identity -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -WorkerPrincipalId ([string]$inert.workerPrincipalId) -ManagerApplicationIds @($blueprint.managerApplicationIds) -DeploymentOwnershipId $ownershipId -SourceFingerprint $deploymentSourceFingerprint -Database $database -EnableWorkerProcessing -EnableProvisioning:$enableProvisioning -EnablePurview:($purview.enabled -eq $true)
        $null = Test-GatewayGroupDeploymentEvidence -Config $configuration -Foundation $foundation -Identity $identity -Evidence $created -DeploymentOwnershipId $ownershipId -SourceFingerprint $deploymentSourceFingerprint -ApiImage ([string]$images.api) -WorkerImage ([string]$images.worker) -Database $database
        return $created
    }

    $adminUi = Invoke-ContinuationStateStep -Name 'Admin UI deployment' -Validate {
        Test-GatewayNamedGroupDeployment -Config $configuration -Foundation $foundation -Runtime $runtime -Identity $identity -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentName "a365gw-$($configuration.projectName)-bootstrap-admin-$($configuration.environment)" -Evidence $state.steps['Admin UI deployment'].evidence -DeploymentOwnershipId $ownershipId -SourceFingerprint $deploymentSourceFingerprint -AdminUiImage ([string]$images.adminUi)
    } -Reconcile {
        Invoke-ExactReconciliation -Readback {
            $recovered = Get-GatewayAdminUiDeploymentEvidence -Config $configuration -DeploymentOwnershipId $ownershipId -SourceFingerprint $deploymentSourceFingerprint -AdminUiImage ([string]$images.adminUi)
            $null = Test-GatewayNamedGroupDeployment -Config $configuration -Foundation $foundation -Runtime $runtime -Identity $identity -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentName "a365gw-$($configuration.projectName)-bootstrap-admin-$($configuration.environment)" -Evidence $recovered -DeploymentOwnershipId $ownershipId -SourceFingerprint $deploymentSourceFingerprint -AdminUiImage ([string]$images.adminUi)
            return $recovered
        }
    } -NoAutomaticReplayAfterStart -Action {
        $created = Deploy-GatewayAdminUi -Config $configuration -Foundation $foundation -Identity $identity -AdminIdentity $adminIdentity -AdminUiImage ([string]$images.adminUi) -AdminUiSecretUri ([string]$adminCredential.secretUri) -DeploymentOwnershipId $ownershipId -SourceFingerprint $deploymentSourceFingerprint
        $null = Test-GatewayNamedGroupDeployment -Config $configuration -Foundation $foundation -Runtime $runtime -Identity $identity -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentName "a365gw-$($configuration.projectName)-bootstrap-admin-$($configuration.environment)" -Evidence $created -DeploymentOwnershipId $ownershipId -SourceFingerprint $deploymentSourceFingerprint -AdminUiImage ([string]$images.adminUi)
        return $created
    }

    $null = Invoke-ContinuationStateStep -Name 'Admin UI redirect URIs' -Validate {
        Test-GatewayAdminRedirectEvidence -AdminIdentity $adminIdentity -AdminUi $adminUi
    } -Action {
        $created = Set-AdminUiRedirectUris -AdminIdentity $adminIdentity -AdminUiFqdn ([string]$adminUi.adminUiFqdn)
        $null = Test-GatewayAdminRedirectEvidence -AdminIdentity $adminIdentity -AdminUi $adminUi
        return $created
    }

    $null = Invoke-ContinuationStateStep -Name 'Network hardening' -Validate {
        Test-ContinuationNetworkHardening `
            -Config $configuration `
            -Evidence $state.steps['Network hardening'].evidence
    } -Action {
        Set-GatewayNetworkHardening -Config $configuration
    }

    $verification = Invoke-ContinuationStateStep -Name 'End-to-end deployment verification' -AlwaysRun -Action {
        Test-GatewayBootstrapDeployment -Config $configuration -Foundation $foundation -Identity $identity -Blueprint $blueprint -Runtime $runtime -Database $database -SqlPrivateEndpoint $sqlPrivateEndpoint -AdminUi $adminUi -Images $images -AdminIdentity $adminIdentity -AdminCredential $adminCredential -DeploymentOwnershipId $ownershipId -DatabaseRecoveryPlan $databaseRecoveryPlan -ManualDatabaseRepairPlan $manualDatabaseRepairPlan -State $state -NonInteractive:$NonInteractive
    }

    $state.outputs['adminUiUrl'] = [string]$adminUi.adminUiUrl
    $state.outputs['apiUrl'] = "https://$($runtime.apiFqdn)"
    $state.outputs['seedBlueprint'] = $blueprint
    $state.outputs['verification'] = $verification
    Save-BootstrapState -State $state -Path $statePath

    $receipt['status'] = 'Verified'
    $receipt['verifiedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    $receipt['result'] = [ordered]@{
        adminUiUrl = [string]$adminUi.adminUiUrl
        apiUrl = "https://$($runtime.apiFqdn)"
        verificationFingerprint = Get-BootstrapObjectFingerprint -InputObject $verification
        recoveryAttemptNumber = [int]$boundary.attemptNumber
        recoveryPlanFingerprint = [string]$boundary.recoveryPlan.planFingerprint
        originalDeploymentSourceFingerprint = $deploymentSourceFingerprint
        correctedModuleSourceFingerprint = [string]$boundary.contract.recoverySourceFingerprint
    }
    Save-ContinuationReceipt -Receipt $receipt -Path $receiptPath
    Write-ContinuationEvent -Type 'Result' -Message 'Recovered bootstrap continuation completed and final verification passed.' -Data ([ordered]@{
        continuationFingerprint = $fingerprint
        adminUiUrl = [string]$adminUi.adminUiUrl
        apiUrl = "https://$($runtime.apiFqdn)"
        receiptPath = $receiptPath
        verified = $true
    })
}
catch {
    if ($script:continuationReceipt -is [System.Collections.IDictionary] -and
        -not [string]::IsNullOrWhiteSpace($script:continuationReceiptPath)) {
        $script:continuationReceipt['status'] = 'NeedsAttention'
        $script:continuationReceipt['failedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
        Save-ContinuationReceipt -Receipt $script:continuationReceipt -Path $script:continuationReceiptPath
    }
    Write-ContinuationEvent -Type 'Error' -Message 'Recovered bootstrap continuation stopped safely; dependency details were withheld and existing state was preserved.' -Data ([ordered]@{
        resumable = $true
        continuationFingerprint = if ($null -ne $boundary) { [string]$boundary.continuationFingerprint } else { '' }
    })
    exit 1
}
finally {
    Clear-BootstrapAzureSubscriptionContext
    if ($lock) { $lock.Dispose() }
}
