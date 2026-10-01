#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'bootstrap\modules\Common.psm1') -NoClobber -DisableNameChecking
Import-Module (Join-Path $repositoryRoot 'bootstrap\modules\Azure.psm1') -NoClobber -DisableNameChecking

function Read-AdminUiUpgradeReceipt {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $document = $null
    try {
        $json = [IO.File]::ReadAllText($Path)
        $options = [Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 100
        $document = [Text.Json.JsonDocument]::Parse($json, $options)
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'A receipt must be one JSON object.'
        }
        $pending = [Collections.Generic.Stack[Text.Json.JsonElement]]::new()
        $pending.Push($document.RootElement)
        while ($pending.Count -gt 0) {
            $element = $pending.Pop()
            if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) { throw 'Receipt property names must be unambiguous.' }
                    $pending.Push($property.Value)
                }
            }
            elseif ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($item in $element.EnumerateArray()) { $pending.Push($item) }
            }
        }
        $convertParameters = @{ AsHashtable = $true; Depth = 100; ErrorAction = 'Stop' }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $convertParameters['DateKind'] = 'String'
        }
        return ConvertFrom-Json -InputObject $json @convertParameters
    }
    catch {
        throw 'The Admin UI upgrade receipt is malformed. Preserve it for review; do not edit it to claim completion.'
    }
    finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}

function Get-RequiredCompletedEvidence {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$Name
    )
    $step = if ($State.steps -is [System.Collections.IDictionary]) { $State.steps[$Name] } else { $null }
    if ($step -isnot [System.Collections.IDictionary] -or
        [string]$step.status -cne 'Completed' -or
        $step.evidence -isnot [System.Collections.IDictionary]) {
        throw "Admin UI upgrade requires completed and evidenced bootstrap step '$Name'. Run gateway resume and gateway verify first."
    }
    return $step.evidence
}

function Assert-CompletedBootstrapBoundary {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )

    if ($State.acceptedPlan -isnot [System.Collections.IDictionary]) {
        throw 'Admin UI upgrade requires the preserved accepted bootstrap plan.'
    }
    foreach ($name in @(
        'Azure foundation',
        'Gateway API identity',
        'Immutable workload images',
        'Inert identity deployment',
        'Agent 365 seed blueprint',
        'Workflow v3 Entra configuration',
        'SQL private endpoint',
        'Gateway database',
        'Admin UI identity',
        'Admin UI Key Vault credential',
        'Gateway runtime deployment',
        'Admin UI deployment',
        'Admin UI redirect URIs',
        'Network hardening',
        'End-to-end deployment verification')) {
        $null = Get-RequiredCompletedEvidence -State $State -Name $name
    }

    $verificationStep = $State.steps['End-to-end deployment verification']
    $verification = if ($State.outputs -is [System.Collections.IDictionary]) { $State.outputs['verification'] } else { $null }
    if ($verification -isnot [System.Collections.IDictionary] -or
        [string]$verification.verifiedAtUtc -cne [string]$verificationStep.evidence.verifiedAtUtc) {
        throw 'Admin UI upgrade requires one current, completed bootstrap verification receipt.'
    }

    $canonicalOwnership = ([guid][string]$State.deploymentOwnershipId).ToString('D')
    if ([string]$State.deploymentOwnershipId -cne $canonicalOwnership -or
        [string]$State.configuration.subscriptionId -cne [string]$Configuration.subscriptionId -or
        [string]$State.configuration.tenantId -cne [string]$Configuration.tenantId -or
        [string]$State.configuration.resourceGroupName -cne [string]$Configuration.resourceGroupName -or
        [string]$State.configuration.projectName -cne [string]$Configuration.projectName -or
        [string]$State.configuration.environment -cne [string]$Configuration.environment) {
        throw 'Bootstrap state does not match the exact configured subscription, tenant, resource group, project, environment, and ownership boundary.'
    }

    if ($State.Contains('databaseRecoveryPlan')) {
        $recovery = $State.databaseRecoveryPlan
        $database = $State.steps['Gateway database'].evidence
        if ($recovery -isnot [System.Collections.IDictionary] -or
            [string]$recovery.status -cne 'Completed' -or
            [string]$recovery.deploymentOwnershipId -cne $canonicalOwnership -or
            [string]$database.databaseRecoveryPlanFingerprint -cne [string]$recovery.planFingerprint -or
            (Get-BootstrapObjectFingerprint -InputObject $database) -cne [string]$recovery.databaseEvidenceFingerprint) {
            throw 'The post-recovery database receipt is not exact, completed, or bound to the verified bootstrap state.'
        }
    }

    return [ordered]@{
        deploymentOwnershipId = $canonicalOwnership
        acceptedPlanFingerprint = [string]$State.acceptedPlan.planFingerprint
        acceptedPlanRecordFingerprint = Get-BootstrapObjectFingerprint -InputObject $State.acceptedPlan
        verifiedAtUtc = [string]$verification.verifiedAtUtc
    }
}

function Get-AdminUiUpgradeSourceMetadata {
    $buildSourceFingerprint = Get-BootstrapSourceFingerprint -Root $repositoryRoot
    $toolFiles = [ordered]@{}
    foreach ($relativePath in @('operations\upgrade-bootstrap-admin-ui.ps1', 'operations\GatewayAdminUiReadback.psm1')) {
        $toolPath = Join-Path $repositoryRoot $relativePath
        $toolFiles[$relativePath] = "sha256:$((Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash.ToLowerInvariant())"
    }
    $toolFingerprint = Get-BootstrapObjectFingerprint -InputObject $toolFiles
    Assert-BootstrapFingerprintValue -Value $buildSourceFingerprint -Label 'Admin UI build source fingerprint'
    Assert-BootstrapFingerprintValue -Value $toolFingerprint -Label 'Admin UI upgrade tool fingerprint'
    return [ordered]@{
        buildSourceFingerprint = $buildSourceFingerprint
        toolFingerprint = $toolFingerprint
        upgradeSourceFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
            buildSourceFingerprint = $buildSourceFingerprint
            toolFingerprint = $toolFingerprint
        })
    }
}

function Get-AdminUiUpgradeIntent {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Completion,
        [Parameter(Mandatory)][string]$ConfigurationFingerprint,
        [Parameter(Mandatory)][string]$UpgradeSourceFingerprint
    )
    Assert-BootstrapFingerprintValue -Value $UpgradeSourceFingerprint -Label 'Admin UI upgrade source fingerprint'
    $ownershipId = [string]$Completion.deploymentOwnershipId
    $intentId = Get-BootstrapDeterministicGuid -Material "$ownershipId|$UpgradeSourceFingerprint|$ConfigurationFingerprint|$($Completion.verifiedAtUtc)|admin-ui-upgrade"
    return [ordered]@{
        intentId = $intentId
        tag = Get-BootstrapImageBuildIntentTag -DeploymentOwnershipId $ownershipId -SourceFingerprint $UpgradeSourceFingerprint -IntentId $intentId
        deploymentName = "a365gw-$($Configuration.projectName)-admin-upgrade-$($UpgradeSourceFingerprint.Substring(7, 12))-$($Configuration.environment)"
        locatorFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
            operation = 'BootstrapAdminUiOnlyUpgrade'
            deploymentOwnershipId = $ownershipId
            configurationFingerprint = $ConfigurationFingerprint
            upgradeSourceFingerprint = $UpgradeSourceFingerprint
            intentId = $intentId
        })
    }
}

function Assert-AdminUiUpgradeReceipt {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SourceMetadata,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Completion,
        [Parameter(Mandatory)][string]$OwnershipId,
        [Parameter(Mandatory)][string]$ConfigurationFingerprint,
        [Parameter(Mandatory)][string]$IntentId,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$DeploymentName,
        [Parameter(Mandatory)][string]$LocatorFingerprint
    )

    if ([string]$Receipt.schemaVersion -cne '1' -or
        [string]$Receipt.operation -cne 'BootstrapAdminUiOnlyUpgrade' -or
        $Receipt.acceptedPlan -isnot [System.Collections.IDictionary] -or
        $Receipt.build -isnot [System.Collections.IDictionary] -or
        $Receipt.deployment -isnot [System.Collections.IDictionary]) {
        throw 'The Admin UI upgrade receipt has an unsupported or incomplete contract.'
    }
    Assert-BootstrapFingerprintValue -Value ([string]$Receipt.planFingerprint) -Label 'Admin UI accepted upgrade plan fingerprint'
    Assert-BootstrapFingerprintValue -Value ([string]$Receipt.locatorFingerprint) -Label 'Admin UI upgrade receipt locator fingerprint'
    if ((Get-BootstrapObjectFingerprint -InputObject $Receipt.acceptedPlan) -cne [string]$Receipt.planFingerprint -or
        [string]$Receipt.locatorFingerprint -cne $LocatorFingerprint) {
        throw 'The immutable accepted Admin UI upgrade plan or its deterministic receipt locator does not match its fingerprint.'
    }

    $plan = $Receipt.acceptedPlan
    if ([string]$plan.operation -cne 'BootstrapAdminUiOnlyUpgrade' -or
        [string]$plan.deploymentOwnershipId -cne $OwnershipId -or
        [string]$plan.configurationFingerprint -cne $ConfigurationFingerprint -or
        [string]$plan.acceptedBootstrapPlanFingerprint -cne [string]$Completion.acceptedPlanFingerprint -or
        [string]$plan.acceptedBootstrapPlanRecordFingerprint -cne [string]$Completion.acceptedPlanRecordFingerprint -or
        [string]$plan.buildSourceFingerprint -cne [string]$SourceMetadata.buildSourceFingerprint -or
        [string]$plan.upgradeToolFingerprint -cne [string]$SourceMetadata.toolFingerprint -or
        [string]$plan.upgradeSourceFingerprint -cne [string]$SourceMetadata.upgradeSourceFingerprint -or
        [string]$plan.build.intentId -cne $IntentId -or
        [string]$plan.build.tag -cne $Tag -or
        [string]$plan.build.component -cne 'adminUi' -or
        [string]$plan.build.repository -cne 'gateway-admin' -or
        [string]$plan.build.dockerfile -cne 'src/Gateway.AdminUi/Dockerfile' -or
        [string]$plan.deployment.name -cne $DeploymentName -or
        [string]$plan.deployment.mode -cne 'Incremental' -or
        [string]$plan.deployment.deployKeyVaultPrivateEndpoint -cne 'False') {
        throw 'The Admin UI upgrade receipt belongs to a different source, owner, configuration, build, deployment, or accepted bootstrap plan.'
    }

    if ([string]$Receipt.build.intentId -cne $IntentId -or
        [string]$Receipt.build.tag -cne $Tag -or
        [string]$Receipt.build.state -notin @('IntentRecorded', 'RunQueued', 'DigestCheckpointed') -or
        [string]$Receipt.deployment.name -cne $DeploymentName -or
        [string]$Receipt.deployment.mode -cne 'Incremental' -or
        [string]$Receipt.deployment.deployKeyVaultPrivateEndpoint -cne 'False' -or
        [string]$Receipt.deployment.state -notin @('Planned', 'IntentRecorded', 'Succeeded') -or
        [string]$Receipt.status -notin @('Accepted', 'Verified')) {
        throw 'The mutable Admin UI upgrade recovery checkpoints are malformed or outside the accepted plan.'
    }
    if ([string]$Receipt.build.state -ceq 'DigestCheckpointed') {
        if ([string]$Receipt.build.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$' -or
            [string]$Receipt.build.digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            [string]$Receipt.build.image -cne "$($plan.baseline.foundation.acrLoginServer)/gateway-admin@$($Receipt.build.digest)") {
            throw 'The Admin UI build checkpoint does not contain the one exact accepted immutable image.'
        }
    }
    elseif ([string]$Receipt.build.state -ceq 'RunQueued' -and
        [string]$Receipt.build.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$') {
        throw 'The queued Admin UI build checkpoint has no exact ACR run identifier.'
    }
    if ([string]$Receipt.deployment.state -in @('IntentRecorded', 'Succeeded') -and
        [string]$Receipt.build.state -cne 'DigestCheckpointed') {
        throw 'The Admin UI deployment checkpoint advanced without an immutable build digest.'
    }
    if ([string]$Receipt.status -ceq 'Verified' -and
        ([string]$Receipt.build.state -cne 'DigestCheckpointed' -or [string]$Receipt.deployment.state -cne 'Succeeded')) {
        throw 'The Admin UI upgrade receipt claims verification without completed build and deployment checkpoints.'
    }
    return $true
}

function Assert-AdminUiUpgradeCurrentImage {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$Image
    )
    $acceptedAdminImage = [string]$Receipt.acceptedPlan.baseline.adminUi.image
    $targetImage = if ([string]$Receipt.build.state -ceq 'DigestCheckpointed') { [string]$Receipt.build.image } else { '' }
    $allowedCurrentAdminImages = @($acceptedAdminImage)
    if ([string]$Receipt.deployment.state -ceq 'IntentRecorded' -and
        -not [string]::IsNullOrWhiteSpace($targetImage)) {
        $allowedCurrentAdminImages += $targetImage
    }
    elseif ([string]$Receipt.deployment.state -ceq 'Succeeded') {
        $allowedCurrentAdminImages = @($targetImage)
    }
    if ($allowedCurrentAdminImages -cnotcontains $Image) {
        throw 'The live Admin UI image is outside the accepted upgrade recovery boundary.'
    }
}

function Get-AdminUiUpgradePriorEvidence {
    [CmdletBinding(DefaultParameterSetName = 'Successor')]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Completion,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SourceMetadata,
        [Parameter(Mandatory)][string]$BootstrapSourceFingerprint,
        [Parameter(Mandatory)][System.Collections.IDictionary]$AdminUiBoundary,
        [Parameter(Mandatory, ParameterSetName = 'Successor')][string]$ReceiptPath,
        [Parameter(Mandatory, ParameterSetName = 'FullMaintenance')][switch]$ForFullMaintenance
    )

    $ownershipId = [string]$Completion.deploymentOwnershipId
    $configurationFingerprint = [string]$State.configurationFingerprint
    $intent = Get-AdminUiUpgradeIntent -Configuration $Configuration -Completion $Completion -ConfigurationFingerprint $configurationFingerprint -UpgradeSourceFingerprint ([string]$SourceMetadata.upgradeSourceFingerprint)
    $relativeDirectory = ".bootstrap\evidence\$($Configuration.resourceGroupName)\admin-ui-upgrade"
    $directory = Join-Path $repositoryRoot $relativeDirectory
    $null = Assert-BootstrapSourcePathIsRegular -Root $repositoryRoot -RelativePath $relativeDirectory
    if (-not $ForFullMaintenance) {
        $expectedPath = Join-Path $directory "$($intent.locatorFingerprint.Substring(7)).json"
        if (-not [IO.Path]::GetFullPath($ReceiptPath).Equals([IO.Path]::GetFullPath($expectedPath), [StringComparison]::Ordinal) -or
            (Test-Path -LiteralPath $ReceiptPath)) {
            throw 'Prior upgrade discovery cannot replace or bypass an existing current-source receipt.'
        }
    }

    $foundation = $State.steps['Azure foundation'].evidence
    $runtime = $State.steps['Gateway runtime deployment'].evidence
    $bootstrapAdmin = $State.steps['Admin UI deployment'].evidence
    $files = if (Test-Path -LiteralPath $directory) { @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -Force | Sort-Object Name) } else { @() }
    $fileHashes = @{}
    $candidates = [Collections.Generic.List[object]]::new()
    # Even a nonmatching interrupted source may still be mutating this same app.
    foreach ($file in $files) {
        $null = Assert-BootstrapSourcePathIsRegular -Root $repositoryRoot -RelativePath (Join-Path $relativeDirectory $file.Name)
        if ($file.PSIsContainer -or $file.Name -cnotmatch '^[0-9a-f]{64}\.json$') {
            throw 'The owned Admin UI receipt directory contains a noncanonical receipt locator.'
        }
        $fileHashes[$file.Name] = "sha256:$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
        $prior = Read-AdminUiUpgradeReceipt -Path $file.FullName
        if ($prior -isnot [System.Collections.IDictionary] -or $prior.acceptedPlan -isnot [System.Collections.IDictionary]) {
            throw 'Prior Admin UI upgrade discovery found an incomplete receipt.'
        }
        $plan = $prior.acceptedPlan
        $priorSource = [ordered]@{
            buildSourceFingerprint = [string]$plan.buildSourceFingerprint
            toolFingerprint = [string]$plan.upgradeToolFingerprint
            upgradeSourceFingerprint = [string]$plan.upgradeSourceFingerprint
        }
        foreach ($name in $priorSource.Keys) {
            Assert-BootstrapFingerprintValue -Value $priorSource[$name] -Label "Prior Admin UI $name"
        }
        if ((Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
                    buildSourceFingerprint = $priorSource.buildSourceFingerprint
                    toolFingerprint = $priorSource.toolFingerprint
                })) -cne $priorSource.upgradeSourceFingerprint) {
            throw 'The prior Admin UI upgrade source does not bind its build and tool fingerprints.'
        }
        $priorIntent = Get-AdminUiUpgradeIntent -Configuration $Configuration -Completion $Completion -ConfigurationFingerprint $configurationFingerprint -UpgradeSourceFingerprint $priorSource.upgradeSourceFingerprint
        $null = Assert-AdminUiUpgradeReceipt -Receipt $prior -SourceMetadata $priorSource -Completion $Completion -OwnershipId $ownershipId -ConfigurationFingerprint $configurationFingerprint -IntentId $priorIntent.intentId -Tag $priorIntent.tag -DeploymentName $priorIntent.deploymentName -LocatorFingerprint $priorIntent.locatorFingerprint
        if ($file.Name -cne "$($priorIntent.locatorFingerprint.Substring(7)).json" -or
            [string]$plan.schemaVersion -cne '1' -or
            [string]$plan.baselineVerifiedAtUtc -cne [string]$Completion.verifiedAtUtc -or
            [string]$plan.baselineBootstrapSourceFingerprint -cne $BootstrapSourceFingerprint -or
            [string]$plan.baseline.foundation.acrName -cne [string]$foundation.acrName -or
            [string]$plan.baseline.foundation.acrLoginServer -cne [string]$foundation.acrLoginServer -or
            [string]$plan.baseline.api.image -cne [string]$runtime.apiImage -or
            [string]$plan.baseline.worker.image -cne [string]$runtime.workerImage -or
            [string]$plan.baseline.adminUi.image -cnotmatch '@sha256:[0-9a-f]{64}$' -or
            [string]$plan.baseline.adminUi.principalId -cne [string]$bootstrapAdmin.adminUiPrincipalId -or
            [string]$plan.baseline.adminUi.principalId -cne [string]$AdminUiBoundary.principalId -or
            [string]$plan.baseline.adminUi.secretResourceId -cne [string]$AdminUiBoundary.secretResourceId) {
            throw 'A prior Admin UI receipt has a stale locator, bootstrap, source, registry, or identity boundary.'
        }
        foreach ($name in @('subscriptionId', 'tenantId', 'resourceGroupName', 'projectName', 'environment')) {
            if ([string]$plan[$name] -cne [string]$Configuration.$name) {
                throw 'A prior Admin UI receipt belongs to a different configured target.'
            }
        }
        if ([string]$prior.status -cnotin @('Accepted', 'Verified') -or
            (-not $ForFullMaintenance -and $priorSource.upgradeSourceFingerprint -ceq [string]$SourceMetadata.upgradeSourceFingerprint) -or
            [string]$prior.build.state -cne 'DigestCheckpointed' -or
            [string]$prior.deployment.state -cne 'Succeeded') {
            throw 'A prior Admin UI mutation is incomplete or is the current attempt; resume its exact receipt instead of starting another upgrade.'
        }
        if ([string]$prior.status -ceq 'Verified' -and (
            $prior.result -isnot [System.Collections.IDictionary] -or
            $prior.result.adminUi -isnot [System.Collections.IDictionary] -or
            [string]$prior.result.adminUi.image -cne [string]$prior.build.image -or
            [string]$prior.result.adminUi.digest -cne [string]$prior.build.digest -or
            [string]$prior.result.adminUi.principalId -cne [string]$AdminUiBoundary.principalId -or
            [string]$prior.result.adminUi.secretResourceId -cne [string]$AdminUiBoundary.secretResourceId -or
            [string]$prior.result.acceptedBootstrapPlanUnchanged -cne 'True')) {
            throw 'The prior Admin UI receipt claims verification with malformed or mismatched evidence.'
        }
        if ([string]$prior.build.image -ceq [string]$AdminUiBoundary.image) {
            $candidates.Add([ordered]@{ file = $file; receipt = $prior })
        }
    }

    $tags = ConvertTo-BootstrapCanonicalValue -Value $AdminUiBoundary.app.tags
    $liveUpgradeSource = if ($tags.Contains('adminUiUpgradeSourceFingerprint')) { [string]$tags['adminUiUpgradeSourceFingerprint'] } else { '' }
    if ([string]$AdminUiBoundary.image -ceq [string]$bootstrapAdmin.adminUiImage -and [string]::IsNullOrEmpty($liveUpgradeSource)) {
        return $null
    }
    if ($candidates.Count -ne 1) {
        throw 'Live Admin UI requires exactly one prior canonical upgrade receipt for its immutable image; absence or ambiguity forbids adoption.'
    }
    $match = $candidates[0]
    $prior = $match.receipt
    $plan = $prior.acceptedPlan
    if ($liveUpgradeSource -cne [string]$plan.upgradeSourceFingerprint) {
        throw 'The live Admin UI source tag does not match the exact prior upgrade plan.'
    }

    # Accepted + Succeeded is only permission to reverify, never a claim that the
    # old post-check passed. None of the build/deployment recovery writers run here.
    $run = Get-GatewayAcrExactRunById -Registry ([string]$foundation.acrName) -Repository 'gateway-admin' -Tag ([string]$prior.build.tag) -RunId ([string]$prior.build.runId)
    $null = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository 'gateway-admin' -Tag ([string]$prior.build.tag)
    $tagDigest = Get-GatewayAcrExactTagDigest -Registry ([string]$foundation.acrName) -Repository 'gateway-admin' -Tag ([string]$prior.build.tag)
    if ([string]$run.runId -cne [string]$prior.build.runId -or
        [string]$run.outputImages[0].digest -cne [string]$prior.build.digest -or
        -not $tagDigest -or [string]$tagDigest.tag -cne [string]$prior.build.tag -or
        [string]$tagDigest.digest -cne [string]$prior.build.digest) {
        throw 'The prior Admin UI build checkpoint does not match its exact successful ACR run and tag digest.'
    }
    $parameters = Get-AdminUiUpgradeParameters -Configuration $Configuration -State $State -OwnershipId $ownershipId -BootstrapSourceFingerprint $BootstrapSourceFingerprint -UpgradeSourceFingerprint ([string]$plan.upgradeSourceFingerprint) -Image ([string]$prior.build.image)
    $deployment = Invoke-AzJson -Arguments @(
        'deployment', 'group', 'show', '--subscription', [string]$Configuration.subscriptionId,
        '--resource-group', [string]$Configuration.resourceGroupName, '--name', [string]$prior.deployment.name)
    $deploymentId = "/subscriptions/$($Configuration.subscriptionId)/resourceGroups/$($Configuration.resourceGroupName)/providers/Microsoft.Resources/deployments/$($prior.deployment.name)"
    if (-not $deployment -or
        -not ([string]$deployment.id).Equals($deploymentId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$deployment.name -cne [string]$prior.deployment.name -or
        [string]$deployment.properties.mode -cne 'Incremental') {
        throw 'The prior Admin UI deployment readback is not its exact scoped incremental deployment.'
    }
    $null = Assert-AdminDeploymentResult -Deployment $deployment -Parameters $parameters -UpgradeSourceFingerprint ([string]$plan.upgradeSourceFingerprint) -Image ([string]$prior.build.image)
    $adminUi = Test-UpgradedAdminUi -Configuration $Configuration -State $State -OwnershipId $ownershipId -BootstrapSourceFingerprint $BootstrapSourceFingerprint -UpgradeSourceFingerprint ([string]$plan.upgradeSourceFingerprint) -Image ([string]$prior.build.image)
    if ([string]$adminUi.principalId -cne [string]$AdminUiBoundary.principalId -or
        [string]$adminUi.secretResourceId -cne [string]$AdminUiBoundary.secretResourceId -or
        [string]$adminUi.fqdn -cne [string]$AdminUiBoundary.fqdn) {
        throw 'The prior Admin UI identity or endpoint changed during read-only verification.'
    }
    $filesAfter = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -Force)
    if ($filesAfter.Count -ne $fileHashes.Count) { throw 'The prior Admin UI receipt set changed during verification.' }
    foreach ($file in $filesAfter) {
        $null = Assert-BootstrapSourcePathIsRegular -Root $repositoryRoot -RelativePath (Join-Path $relativeDirectory $file.Name)
        $hash = "sha256:$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
        if (-not $fileHashes.ContainsKey($file.Name) -or $hash -cne $fileHashes[$file.Name]) {
            throw 'Prior Admin UI receipt bytes changed during verification; no successor may be accepted.'
        }
    }
    return [ordered]@{
        context = [ordered]@{
            subscriptionId = [string]$Configuration.subscriptionId
            tenantId = [string]$Configuration.tenantId
            resourceGroupName = [string]$Configuration.resourceGroupName
            deploymentOwnershipId = $ownershipId
            bootstrapSourceFingerprint = $BootstrapSourceFingerprint
            bootstrapPlanFingerprint = [string]$Completion.acceptedPlanFingerprint
            configurationFingerprint = $configurationFingerprint
        }
        receiptSetFingerprint = Get-BootstrapObjectFingerprint -InputObject $fileHashes
        receiptFileName = [string]$match.file.Name
        receiptByteFingerprint = $fileHashes[$match.file.Name]
        locatorFingerprint = [string]$prior.locatorFingerprint
        planFingerprint = [string]$prior.planFingerprint
        recordedStatus = [string]$prior.status
        buildSourceFingerprint = [string]$plan.buildSourceFingerprint
        upgradeToolFingerprint = [string]$plan.upgradeToolFingerprint
        upgradeSourceFingerprint = [string]$plan.upgradeSourceFingerprint
        build = ConvertTo-BootstrapCanonicalValue -Value $prior.build
        deployment = [ordered]@{
            id = $deploymentId
            name = [string]$prior.deployment.name
            state = 'Succeeded'
            recordFingerprint = Get-BootstrapObjectFingerprint -InputObject $deployment
        }
        verification = [ordered]@{
            kind = 'ReadOnlyPredecessorReverification'
            verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            verifierToolFingerprint = [string]$SourceMetadata.toolFingerprint
            verifierUpgradeSourceFingerprint = [string]$SourceMetadata.upgradeSourceFingerprint
            acrRunFingerprint = Get-BootstrapObjectFingerprint -InputObject $run
            acrTagFingerprint = Get-BootstrapObjectFingerprint -InputObject $tagDigest
            adminUi = $adminUi
        }
    }
}

function Get-ExactAdminRoleAssignment {
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$RoleDefinitionGuid
    )
    $assignments = @(Invoke-AzJson -Arguments @(
        'role', 'assignment', 'list', '--assignee-object-id', $PrincipalId,
        '--scope', $Scope, '--include-inherited',
        '--query', '[].{id:id,principalId:principalId,scope:scope,roleDefinitionId:roleDefinitionId}'))
    if ($assignments.Count -ne 1 -or
        -not ([string]$assignments[0].principalId).Equals($PrincipalId, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$assignments[0].scope).Equals($Scope, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$assignments[0].roleDefinitionId).EndsWith("/$RoleDefinitionGuid", [StringComparison]::OrdinalIgnoreCase) -or
        [string]$assignments[0].id -cnotmatch '^/subscriptions/[0-9a-f-]{36}/.+/providers/Microsoft.Authorization/roleAssignments/[0-9a-f-]{36}$') {
        throw 'Admin UI managed identity does not have the one exact least-privilege role assignment.'
    }
    return [string]$assignments[0].id
}

function Get-AdminUiLiveBoundary {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$OwnershipId,
        [Parameter(Mandatory)][string]$BootstrapSourceFingerprint
    )
    $foundation = $State.steps['Azure foundation'].evidence
    $adminEvidence = $State.steps['Admin UI deployment'].evidence
    $credential = $State.steps['Admin UI Key Vault credential'].evidence
    $identityName = "id-gateway-admin-$($Configuration.environment)"
    $appName = "ca-gateway-admin-$($Configuration.environment)"
    $identity = Invoke-AzJson -Arguments @(
        'identity', 'show', '--resource-group', [string]$Configuration.resourceGroupName,
        '--name', $identityName)
    $app = Invoke-AzJson -Arguments @(
        'containerapp', 'show', '--resource-group', [string]$Configuration.resourceGroupName,
        '--name', $appName)
    $containers = @($app.properties.template.containers)
    $attachedIdentityIds = @($app.identity.userAssignedIdentities.PSObject.Properties.Name)
    $secrets = @($app.properties.configuration.secrets)
    $secretUri = [string]$credential.secretUri
    if ([string]$identity.name -cne $identityName -or
        [string]$identity.principalId -cne [string]$adminEvidence.adminUiPrincipalId -or
        [string]$identity.tags.bootstrapOwnershipId -cne $OwnershipId -or
        [string]$identity.tags.bootstrapSourceFingerprint -cne $BootstrapSourceFingerprint -or
        [string]$app.name -cne $appName -or
        [string]$app.properties.provisioningState -cne 'Succeeded' -or
        [string]$app.properties.configuration.activeRevisionsMode -cne 'Single' -or
        [string]$app.tags.bootstrapOwnershipId -cne $OwnershipId -or
        [string]$app.tags.bootstrapSourceFingerprint -cne $BootstrapSourceFingerprint -or
        [string]$app.identity.type -cne 'UserAssigned' -or
        $containers.Count -ne 1 -or
        [string]$containers[0].image -cnotmatch '@sha256:[0-9a-f]{64}$' -or
        $attachedIdentityIds.Count -ne 1 -or
        -not ([string]$attachedIdentityIds[0]).Equals([string]$identity.id, [StringComparison]::OrdinalIgnoreCase) -or
        @($app.properties.configuration.registries).Count -ne 1 -or
        [string]$app.properties.configuration.registries[0].server -cne [string]$foundation.acrLoginServer -or
        -not ([string]$app.properties.configuration.registries[0].identity).Equals([string]$identity.id, [StringComparison]::OrdinalIgnoreCase) -or
        $secrets.Count -ne 1 -or [string]$secrets[0].name -cne 'admin-ui-entra-client-secret' -or
        [string]$secrets[0].keyVaultUrl -cne $secretUri -or
        -not ([string]$secrets[0].identity).Equals([string]$identity.id, [StringComparison]::OrdinalIgnoreCase) -or
        $secretUri -cnotmatch '^https://[a-z0-9-]+\.vault\.azure\.net/secrets/admin-ui-entra-client-secret$') {
        throw 'The live Admin UI identity, registry pull, versionless Key Vault secret, source, or ownership boundary is not exact.'
    }
    $acrScope = "/subscriptions/$($Configuration.subscriptionId)/resourceGroups/$($Configuration.resourceGroupName)/providers/Microsoft.ContainerRegistry/registries/$($foundation.acrName)"
    $secretScope = "/subscriptions/$($Configuration.subscriptionId)/resourceGroups/$($Configuration.resourceGroupName)/providers/Microsoft.KeyVault/vaults/kv-$($Configuration.projectName)-$($Configuration.environment)/secrets/admin-ui-entra-client-secret"
    $registry = Invoke-AzJson -Arguments @(
        'resource', 'show', '--ids', $acrScope, '--api-version', '2023-11-01-preview')
    $vault = Invoke-AzJson -Arguments @(
        'keyvault', 'show', '--resource-group', [string]$Configuration.resourceGroupName,
        '--name', "kv-$($Configuration.projectName)-$($Configuration.environment)")
    if ([string]$registry.properties.adminUserEnabled -cne 'False' -or
        [string]$registry.properties.policies.azureADAuthenticationAsArmPolicy.status -cne 'enabled' -or
        [string]$vault.properties.enableRbacAuthorization -cne 'True' -or
        [string]$vault.properties.publicNetworkAccess -cne 'Disabled') {
        throw 'Admin UI dependencies are not on the required Entra/RBAC-only ACR and private Key Vault boundary.'
    }
    $acrRole = Get-ExactAdminRoleAssignment -PrincipalId ([string]$identity.principalId) -Scope $acrScope -RoleDefinitionGuid '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    $secretRole = Get-ExactAdminRoleAssignment -PrincipalId ([string]$identity.principalId) -Scope $secretScope -RoleDefinitionGuid '4633458b-17de-408a-b874-0445c86b69e6'
    return [ordered]@{
        app = $app
        appId = [string]$app.id
        appName = $appName
        image = [string]$containers[0].image
        fqdn = [string]$app.properties.configuration.ingress.fqdn
        identityId = [string]$identity.id
        principalId = [string]$identity.principalId
        secretUri = $secretUri
        secretResourceId = $secretScope
        allowedRoleAssignmentIds = @(@($acrRole, $secretRole) | Sort-Object)
        localRegistryAuthenticationDisabled = $true
        keyVaultRbacOnly = $true
        keyVaultPublicNetworkDisabled = $true
    }
}

function Get-AdminUiUpgradeParameters {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$OwnershipId,
        [Parameter(Mandatory)][string]$BootstrapSourceFingerprint,
        [Parameter(Mandatory)][string]$UpgradeSourceFingerprint,
        [Parameter(Mandatory)][string]$Image
    )
    $foundation = $State.steps['Azure foundation'].evidence
    $apiIdentity = $State.steps['Gateway API identity'].evidence
    $adminIdentity = $State.steps['Admin UI identity'].evidence
    $credential = $State.steps['Admin UI Key Vault credential'].evidence
    return [ordered]@{
        environment = [string]$Configuration.environment
        projectName = [string]$Configuration.projectName
        deploymentOwnershipId = $OwnershipId
        bootstrapSourceFingerprint = $BootstrapSourceFingerprint
        adminUiUpgradeSourceFingerprint = $UpgradeSourceFingerprint
        containerAppsEnvironmentName = [string]$foundation.containerAppsEnvironmentName
        adminUiContainerImage = $Image
        entraIdTenantId = [string]$Configuration.tenantId
        adminUiEntraClientId = [string]$adminIdentity.adminUiClientId
        adminUiEntraClientSecretKeyVaultSecretUri = [string]$credential.secretUri
        adminUiGatewayApiScope = "$($apiIdentity.gatewayApiScopeBaseUri)/access_as_user"
        deployKeyVaultPrivateEndpoint = $false
    }
}

function Assert-AdminDeploymentResult {
    param(
        [Parameter(Mandatory)]$Deployment,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [Parameter(Mandatory)][string]$UpgradeSourceFingerprint,
        [Parameter(Mandatory)][string]$Image
    )
    if (-not $Deployment -or [string]$Deployment.properties.provisioningState -cne 'Succeeded') {
        throw 'The exact Admin UI upgrade deployment did not reach Succeeded.'
    }
    $actual = $Deployment.properties.parameters
    $outputs = $Deployment.properties.outputs
    foreach ($name in @('environment', 'projectName', 'deploymentOwnershipId', 'bootstrapSourceFingerprint', 'adminUiUpgradeSourceFingerprint', 'containerAppsEnvironmentName', 'adminUiContainerImage', 'entraIdTenantId', 'adminUiEntraClientId', 'adminUiGatewayApiScope', 'deployKeyVaultPrivateEndpoint')) {
        if ([string]$actual.$name.value -cne [string]$Parameters[$name]) {
            throw 'The Admin UI upgrade deployment parameter receipt does not match the accepted plan.'
        }
    }
    if ([string]$outputs.adminUiUpgradeSourceFingerprint.value -cne $UpgradeSourceFingerprint -or
        [string]$outputs.adminUiContainerImage.value -cne $Image -or
        [string]$outputs.deploymentOwnershipId.value -cne [string]$Parameters.deploymentOwnershipId -or
        [string]$outputs.bootstrapSourceFingerprint.value -cne [string]$Parameters.bootstrapSourceFingerprint) {
        throw 'The Admin UI upgrade deployment did not echo the exact original ownership/source plus separate upgrade source and digest.'
    }
    return $true
}

function Test-AdminUiHttpBoundary {
    param(
        [Parameter(Mandatory)][string]$Fqdn,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId
    )
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        $health = $client.GetAsync("https://$Fqdn/health").GetAwaiter().GetResult()
        if ([int]$health.StatusCode -ne 200) { throw 'Admin UI health endpoint did not return HTTP 200.' }
        $signIn = $client.GetAsync("https://$Fqdn/MicrosoftIdentity/Account/SignIn?returnUrl=%2F").GetAwaiter().GetResult()
        $location = $signIn.Headers.Location
        if ([int]$signIn.StatusCode -notin @(302, 303) -or -not $location -or
            $location.Scheme -cne 'https' -or
            -not $location.IsDefaultPort -or
            -not $location.Host.Equals('login.microsoftonline.com', [StringComparison]::OrdinalIgnoreCase) -or
            -not $location.AbsolutePath.Contains("/$TenantId/", [StringComparison]::OrdinalIgnoreCase) -or
            $location.Query -cnotmatch "(?i)(?:[?&])client_id=$([regex]::Escape($ClientId))(?:&|$)") {
            throw 'Admin UI sign-in endpoint did not return the exact Entra authorization redirect shape.'
        }
        return [ordered]@{ healthStatus = 200; signInStatus = [int]$signIn.StatusCode; authorityHost = 'login.microsoftonline.com' }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Test-UpgradedAdminUi {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$OwnershipId,
        [Parameter(Mandatory)][string]$BootstrapSourceFingerprint,
        [Parameter(Mandatory)][string]$UpgradeSourceFingerprint,
        [Parameter(Mandatory)][string]$Image
    )
    $boundary = Get-AdminUiLiveBoundary -Configuration $Configuration -State $State -OwnershipId $OwnershipId -BootstrapSourceFingerprint $BootstrapSourceFingerprint
    $app = $boundary.app
    if ([string]$boundary.image -cne $Image -or
        [string]$app.tags.adminUiUpgradeSourceFingerprint -cne $UpgradeSourceFingerprint) {
        throw 'Admin UI did not read back the exact upgraded digest and separate source tag.'
    }
    $revisions = @(Invoke-AzJson -Arguments @(
        'containerapp', 'revision', 'list', '--resource-group', [string]$Configuration.resourceGroupName,
        '--name', [string]$boundary.appName,
        '--query', '[?properties.active==`true`].{name:name,healthState:properties.healthState,runningState:properties.runningState,replicas:properties.replicas}'))
    if ($revisions.Count -ne 1 -or
        [string]$revisions[0].name -cne [string]$app.properties.latestReadyRevisionName -or
        [string]$revisions[0].healthState -cne 'Healthy' -or
        -not (Test-GatewayContainerAppRevisionRunning $revisions[0].runningState) -or
        [int]$revisions[0].replicas -lt 1) {
        throw 'Admin UI does not have exactly one active, healthy, running, ready revision.'
    }
    $clientId = [string]$State.steps['Admin UI identity'].evidence.adminUiClientId
    $http = Test-AdminUiHttpBoundary -Fqdn ([string]$boundary.fqdn) -TenantId ([string]$Configuration.tenantId) -ClientId $clientId
    return [ordered]@{
        image = $Image
        digest = $Image.Split('@')[-1]
        fqdn = [string]$boundary.fqdn
        url = "https://$($boundary.fqdn)"
        revisionName = [string]$revisions[0].name
        runningState = [string]$revisions[0].runningState
        principalId = [string]$boundary.principalId
        secretResourceId = [string]$boundary.secretResourceId
        versionlessSecretUri = $true
        managedIdentityRegistryPull = $true
        localRegistryAuthenticationDisabled = [bool]$boundary.localRegistryAuthenticationDisabled
        keyVaultRbacOnly = [bool]$boundary.keyVaultRbacOnly
        keyVaultPublicNetworkDisabled = [bool]$boundary.keyVaultPublicNetworkDisabled
        http = $http
    }
}

Export-ModuleMember -Function Read-AdminUiUpgradeReceipt, Get-RequiredCompletedEvidence, Assert-CompletedBootstrapBoundary, Get-AdminUiUpgradeSourceMetadata, Get-AdminUiUpgradeIntent, Assert-AdminUiUpgradeReceipt, Assert-AdminUiUpgradeCurrentImage, Get-AdminUiUpgradePriorEvidence, Get-ExactAdminRoleAssignment, Get-AdminUiLiveBoundary, Get-AdminUiUpgradeParameters, Assert-AdminDeploymentResult, Test-AdminUiHttpBoundary, Test-UpgradedAdminUi
