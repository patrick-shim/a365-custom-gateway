#Requires -Version 7.0

<#
.SYNOPSIS
    Builds and promotes only the hosted Admin UI of one completed bootstrap deployment.

.DESCRIPTION
    This is a narrow, same-resource-group upgrade path. It never rewrites the
    accepted clean-bootstrap plan, never deploys the API or worker, and never reads
    Service Bus messages. It records a separate, safe upgrade receipt under the
    ignored .bootstrap/evidence tree before each external mutation. A successor
    requires one exact prior receipt and fresh read-only verification; the prior
    receipt is retained unchanged, including an Accepted post-check failure.
#>

[CmdletBinding()]
param(
    [string]$Config = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap/config.json'),
    [switch]$Yes,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $Yes) {
    throw 'Admin UI upgrade requires --yes to accept the exact source, scope, What-If, and build intent before any mutation.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'bootstrap/modules/Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $repositoryRoot 'bootstrap/modules/Azure.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'GatewayAdminUiReadback.psm1') -Force -DisableNameChecking

function Save-AdminUiUpgradeReceipt {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$Path
    )

    $Receipt['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ".receipt-$([guid]::NewGuid().ToString('N')).tmp"
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
            if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the Admin UI upgrade receipt to the current user.' }
        }
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-ContainerAppSnapshot {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExpectedOwnershipId,
        [Parameter(Mandatory)][string]$ExpectedBootstrapSourceFingerprint
    )

    $app = Invoke-AzJson -Arguments @(
        'containerapp', 'show', '--resource-group', [string]$Configuration.resourceGroupName,
        '--name', $Name)
    $containers = @($app.properties.template.containers)
    if ([string]$app.name -cne $Name -or
        [string]$app.properties.provisioningState -cne 'Succeeded' -or
        [string]$app.tags.bootstrapOwnershipId -cne $ExpectedOwnershipId -or
        [string]$app.tags.bootstrapSourceFingerprint -cne $ExpectedBootstrapSourceFingerprint -or
        $containers.Count -ne 1 -or
        [string]$containers[0].image -cnotmatch '@sha256:[0-9a-f]{64}$') {
        throw "Container App '$Name' is not the exact ownership/source-bound, digest-pinned baseline."
    }
    return [ordered]@{
        id = [string]$app.id
        name = $Name
        image = [string]$containers[0].image
        latestReadyRevisionName = [string]$app.properties.latestReadyRevisionName
        configurationFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
            identity = $app.identity
            configuration = $app.properties.configuration
            template = $app.properties.template
        })
    }
}

function Get-QueueCountSnapshot {
    param([Parameter(Mandatory)]$Configuration)
    $namespaceName = "sb-$($Configuration.projectName)-$($Configuration.environment)"
    $queues = @(Invoke-AzJson -Arguments @(
        'servicebus', 'queue', 'list',
        '--resource-group', [string]$Configuration.resourceGroupName,
        '--namespace-name', $namespaceName,
        '--query', '[].{name:name,active:countDetails.activeMessageCount,scheduled:countDetails.scheduledMessageCount,deadLetter:countDetails.deadLetterMessageCount,transfer:countDetails.transferMessageCount,transferDeadLetter:countDetails.transferDeadLetterMessageCount}'))
    if ($queues.Count -eq 0) { throw 'The verified Gateway Service Bus namespace returned no queues.' }
    $result = [Collections.Generic.List[object]]::new()
    foreach ($queue in @($queues | Sort-Object name)) {
        if ([string]$queue.name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,259}$') {
            throw 'Service Bus queue count readback returned a malformed queue name.'
        }
        $entry = [ordered]@{ name = [string]$queue.name }
        foreach ($name in @('active', 'scheduled', 'deadLetter', 'transfer', 'transferDeadLetter')) {
            $value = 0L
            if (-not [long]::TryParse([string]$queue.$name, [ref]$value) -or $value -lt 0) {
                throw 'Service Bus queue count readback returned a malformed nonnegative count.'
            }
            $entry[$name] = $value
        }
        $result.Add($entry)
    }
    return @($result)
}

function New-ArmParameterFile {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Parameters)
    $parameterObject = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{}
    }
    foreach ($entry in $Parameters.GetEnumerator()) {
        $parameterObject.parameters[$entry.Key] = @{ value = $entry.Value }
    }
    $path = Join-Path ([IO.Path]::GetTempPath()) "a365gw-admin-upgrade-$([guid]::NewGuid().ToString('N')).json"
    $parameterObject | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    if (-not $IsWindows -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
        & chmod 600 $path
        if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the temporary Admin UI ARM parameter file.' }
    }
    return $path
}

function Invoke-AdminUiUpgradeWhatIf {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [Parameter(Mandatory)][string[]]$AllowedResourceIds,
        [Parameter(Mandatory)][string]$AdminAppId
    )
    $temporary = New-ArmParameterFile -Parameters $Parameters
    try {
        $result = Invoke-AzJson -Arguments @(
            'deployment', 'group', 'what-if',
            '--resource-group', [string]$Configuration.resourceGroupName,
            '--template-file', (Join-Path $repositoryRoot 'infrastructure/bicep/admin-ui.bicep'),
            '--parameters', "@$temporary", '--result-format', 'ResourceIdOnly',
            '--no-pretty-print', '--exclude-change-types', 'Ignore')
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    if (-not $result -or [string]$result.status -cne 'Succeeded') {
        throw 'Admin UI ARM What-If did not complete successfully.'
    }
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $AllowedResourceIds) { $null = $allowed.Add($id) }
    $changes = [Collections.Generic.List[object]]::new()
    foreach ($change in @($result.changes)) {
        $resourceId = [string]$change.resourceId
        $changeType = [string]$change.changeType
        if ($changeType -in @('Delete', 'Create') -or
            $changeType -notin @('Modify', 'Deploy', 'NoChange', 'Ignore') -or
            -not $allowed.Contains($resourceId)) {
            throw 'Admin UI What-If contains a deletion, creation, unsupported change, or resource outside the exact Admin UI allowlist.'
        }
        $changes.Add([ordered]@{ resourceId = $resourceId.ToLowerInvariant(); changeType = $changeType })
    }
    if ($changes.Count -eq 0 -or
        @($changes | Where-Object { [string]$_.resourceId -eq $AdminAppId.ToLowerInvariant() -or [string]$_.resourceId -like '*/providers/microsoft.resources/deployments/deploy-admin-ui-app' }).Count -eq 0) {
        throw 'Admin UI What-If did not contain the exact Admin UI app/module update.'
    }
    return @($changes | Sort-Object resourceId, changeType)
}

function Resolve-AdminUiBuild {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][bool]$ReceiptCreatedThisInvocation,
        [Parameter(Mandatory)][string]$BuildSourceFingerprint
    )
    $foundation = $Receipt.acceptedPlan.baseline.foundation
    $registry = [string]$foundation.acrName
    $loginServer = [string]$foundation.acrLoginServer
    $repository = 'gateway-admin'
    $intent = $Receipt.build
    $tag = [string]$intent.tag
    if ([string]$intent.state -ceq 'DigestCheckpointed') {
        $found = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $tag
        if (-not $found -or [string]$found.digest -cne [string]$intent.digest -or
            [string]$intent.image -cne "$loginServer/$repository@$($intent.digest)") {
            throw 'The checkpointed Admin UI build no longer matches its exact immutable ACR digest.'
        }
        return [string]$intent.image
    }

    $createdIntent = $ReceiptCreatedThisInvocation
    $runs = @(Get-GatewayAcrExactImageRuns -Registry $registry -Repository $repository -Tag $tag)
    if ([string]$intent.state -ceq 'IntentRecorded' -and $runs.Count -eq 0) {
        if (-not $createdIntent) {
            throw 'The recovered Admin UI build intent has no exact run or digest. Submission outcome is ambiguous; automatic resubmission is forbidden.'
        }
        $context = $null
        try {
            $context = New-GatewayAcrBuildContext -RepositoryRoot $repositoryRoot -SourceFingerprint $BuildSourceFingerprint
            $run = Invoke-AzJson -CaptureStdoutOnly -Arguments @(
                'acr', 'build', '--registry', $registry,
                '--image', "${repository}:$tag",
                '--file', 'src/Gateway.AdminUi/Dockerfile',
                $context, '--no-logs',
                '--query', '{runId:runId,status:status,runType:runType,outputImages:not_null(outputImages, `[]`)[].{repository:repository,tag:tag,digest:digest}}')
            $run = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository $repository -Tag $tag
            $intent['runId'] = [string]$run.runId
        }
        finally {
            if ($context -and (Test-Path -LiteralPath $context)) { Remove-Item -LiteralPath $context -Recurse -Force }
        }
    }
    elseif ($runs.Count -eq 1) {
        $intent['runId'] = [string]$runs[0].runId
    }
    elseif ($runs.Count -ne 0) {
        throw 'Admin UI build recovery found an ambiguous exact-tag run set.'
    }
    if ([string]$intent.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$') {
        throw 'Admin UI build did not produce one bounded ACR run identifier.'
    }
    $intent['state'] = 'RunQueued'
    Save-AdminUiUpgradeReceipt -Receipt $Receipt -Path $ReceiptPath

    $terminal = $null
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        $run = Get-GatewayAcrExactRunById -Registry $registry -Repository $repository -Tag $tag -RunId ([string]$intent.runId)
        if ([string]$run.status -ceq 'Succeeded') { $terminal = $run; break }
        if ([string]$run.status -in @('Failed', 'Canceled', 'Error', 'Timeout')) {
            throw 'The exact Admin UI ACR build reached a terminal failure. No automatic resubmission is permitted.'
        }
        if ($attempt -lt 60) { Start-Sleep -Seconds 2 }
    }
    if (-not $terminal) { throw 'The exact Admin UI build remains pending. Rerun the same command later; no second build will be submitted.' }
    $digest = [string]@($terminal.outputImages)[0].digest
    $found = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $tag
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or -not $found -or [string]$found.digest -cne $digest) {
        throw 'The succeeded Admin UI build did not reconcile to its exact tag and immutable digest.'
    }
    $intent['state'] = 'DigestCheckpointed'
    $intent['digest'] = $digest
    $intent['image'] = "$loginServer/$repository@$digest"
    Save-AdminUiUpgradeReceipt -Receipt $Receipt -Path $ReceiptPath
    return [string]$intent.image
}

function Deploy-AdminUiUpgrade {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [Parameter(Mandatory)][string]$UpgradeSourceFingerprint,
        [Parameter(Mandatory)][string]$Image
    )
    $name = [string]$Receipt.deployment.name
    $startedThisInvocation = $false
    if ([string]$Receipt.deployment.state -ceq 'Planned') {
        $Receipt.deployment['state'] = 'IntentRecorded'
        Save-AdminUiUpgradeReceipt -Receipt $Receipt -Path $ReceiptPath
        $startedThisInvocation = $true
    }
    $existing = $null
    try {
        $existing = Invoke-AzJson -Arguments @(
            'deployment', 'group', 'show', '--resource-group', [string]$Configuration.resourceGroupName,
            '--name', $name)
    }
    catch { $existing = $null }
    if (-not $existing) {
        if (-not $startedThisInvocation) {
            throw 'The recovered Admin UI deployment intent has no ARM record. Its outcome is ambiguous; automatic replay is forbidden.'
        }
        $existing = Invoke-ArmDeploymentWithSecureParameters `
            -SubscriptionId ([string]$Configuration.subscriptionId) `
            -ResourceGroup ([string]$Configuration.resourceGroupName) `
            -Name $name `
            -TemplateFile (Join-Path $repositoryRoot 'infrastructure/bicep/admin-ui.bicep') `
            -Parameters $Parameters
    }
    $null = Assert-AdminDeploymentResult -Deployment $existing -Parameters $Parameters -UpgradeSourceFingerprint $UpgradeSourceFingerprint -Image $Image
    $Receipt.deployment['state'] = 'Succeeded'
    $Receipt.deployment['completedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    Save-AdminUiUpgradeReceipt -Receipt $Receipt -Path $ReceiptPath
    return $existing
}

$configuration = Read-BootstrapConfig -Path $Config
$statePath = Get-BootstrapStatePath -Config $configuration
$lock = Enter-BootstrapLock -StatePath $statePath
try {
    $state = Read-BootstrapState -Path $statePath -Config $configuration
    $completion = Assert-CompletedBootstrapBoundary -Configuration $configuration -State $state
    $null = Connect-BootstrapAzure -Config $configuration -NonInteractive:$NonInteractive
    $null = Assert-BootstrapAzureContext -Config $configuration

    $ownershipId = [string]$completion.deploymentOwnershipId
    $foundation = $state.steps['Azure foundation'].evidence
    $runtime = $state.steps['Gateway runtime deployment'].evidence
    $images = $state.steps['Immutable workload images'].evidence
    $bootstrapSourceFingerprint = [string]$state.steps['Admin UI deployment'].evidence.sourceFingerprint
    Assert-BootstrapFingerprintValue -Value $bootstrapSourceFingerprint -Label 'Baseline Admin UI bootstrap source fingerprint'

    $resourceGroup = Invoke-AzJson -Arguments @(
        'group', 'show', '--name', [string]$configuration.resourceGroupName,
        '--query', '{id:id,location:location,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}')
    if ([string]$resourceGroup.id -cne "/subscriptions/$($configuration.subscriptionId)/resourceGroups/$($configuration.resourceGroupName)" -or
        [string]$resourceGroup.ownershipId -cne $ownershipId -or
        [string]$resourceGroup.sourceFingerprint -cne [string]$foundation.sourceFingerprint) {
        throw 'The live resource group is outside the exact bootstrap subscription, resource-group, ownership, and source boundary.'
    }

    $apiBefore = Get-ContainerAppSnapshot -Configuration $configuration -Name "ca-gateway-api-$($configuration.environment)" -ExpectedOwnershipId $ownershipId -ExpectedBootstrapSourceFingerprint ([string]$runtime.sourceFingerprint)
    $workerBefore = Get-ContainerAppSnapshot -Configuration $configuration -Name "ca-gateway-worker-$($configuration.environment)-v3" -ExpectedOwnershipId $ownershipId -ExpectedBootstrapSourceFingerprint ([string]$runtime.sourceFingerprint)
    if ([string]$apiBefore.image -cne [string]$runtime.apiImage -or
        [string]$workerBefore.image -cne [string]$runtime.workerImage -or
        [string]$images.api -cne [string]$runtime.apiImage -or
        [string]$images.worker -cne [string]$runtime.workerImage) {
        throw 'API or worker live image does not match the completed bootstrap runtime evidence.'
    }
    $queuesBefore = @(Get-QueueCountSnapshot -Configuration $configuration)
    $adminBefore = Get-AdminUiLiveBoundary -Configuration $configuration -State $state -OwnershipId $ownershipId -BootstrapSourceFingerprint $bootstrapSourceFingerprint

    $sourceMetadata = Get-AdminUiUpgradeSourceMetadata
    $buildSourceFingerprint = [string]$sourceMetadata.buildSourceFingerprint
    $upgradeSourceFingerprint = [string]$sourceMetadata.upgradeSourceFingerprint
    Assert-BootstrapFingerprintValue -Value $upgradeSourceFingerprint -Label 'Admin UI upgrade source fingerprint'
    $intent = Get-AdminUiUpgradeIntent -Configuration $configuration -Completion $completion -ConfigurationFingerprint ([string]$state.configurationFingerprint) -UpgradeSourceFingerprint $upgradeSourceFingerprint
    $intentId = [string]$intent.intentId
    $tag = [string]$intent.tag
    $deploymentName = [string]$intent.deploymentName
    $locatorFingerprint = [string]$intent.locatorFingerprint
    $receiptPath = Join-Path $repositoryRoot ".bootstrap\evidence\$($configuration.resourceGroupName)\admin-ui-upgrade\$($locatorFingerprint.Substring(7)).json"
    $prospectiveImage = "$($foundation.acrLoginServer)/gateway-admin:$tag"
    $moduleDeploymentId = "/subscriptions/$($configuration.subscriptionId)/resourceGroups/$($configuration.resourceGroupName)/providers/Microsoft.Resources/deployments/deploy-admin-ui-app"
    $allowedIds = @([string]$adminBefore.appId, [string]$adminBefore.identityId, $moduleDeploymentId) + @($adminBefore.allowedRoleAssignmentIds)
    $prospectiveParameters = Get-AdminUiUpgradeParameters -Configuration $configuration -State $state -OwnershipId $ownershipId -BootstrapSourceFingerprint $bootstrapSourceFingerprint -UpgradeSourceFingerprint $upgradeSourceFingerprint -Image $prospectiveImage
    $prospectiveWhatIf = @(Invoke-AdminUiUpgradeWhatIf -Configuration $configuration -Parameters $prospectiveParameters -AllowedResourceIds $allowedIds -AdminAppId ([string]$adminBefore.appId))

    $receipt = Read-AdminUiUpgradeReceipt -Path $receiptPath
    $createdReceipt = $false
    if ($receipt) {
        $null = Assert-AdminUiUpgradeReceipt -Receipt $receipt -SourceMetadata $sourceMetadata -Completion $completion -OwnershipId $ownershipId -ConfigurationFingerprint ([string]$state.configurationFingerprint) -IntentId $intentId -Tag $tag -DeploymentName $deploymentName -LocatorFingerprint $locatorFingerprint
    }
    else {
        $preexistingTag = Get-GatewayAcrExactTagDigest -Registry ([string]$foundation.acrName) -Repository 'gateway-admin' -Tag $tag
        $preexistingRuns = @(Get-GatewayAcrExactImageRuns -Registry ([string]$foundation.acrName) -Repository 'gateway-admin' -Tag $tag)
        if ($preexistingTag -or $preexistingRuns.Count -ne 0) {
            throw 'Fresh Admin UI upgrade intent collides with existing ACR provider state.'
        }
        $priorUpgrade = Get-AdminUiUpgradePriorEvidence -Configuration $configuration -State $state -Completion $completion -SourceMetadata $sourceMetadata -BootstrapSourceFingerprint $bootstrapSourceFingerprint -AdminUiBoundary $adminBefore -ReceiptPath $receiptPath
        $acceptedPlan = [ordered]@{
            schemaVersion = 1
            operation = 'BootstrapAdminUiOnlyUpgrade'
            subscriptionId = [string]$configuration.subscriptionId
            tenantId = [string]$configuration.tenantId
            resourceGroupName = [string]$configuration.resourceGroupName
            projectName = [string]$configuration.projectName
            environment = [string]$configuration.environment
            deploymentOwnershipId = $ownershipId
            configurationFingerprint = [string]$state.configurationFingerprint
            acceptedBootstrapPlanFingerprint = [string]$completion.acceptedPlanFingerprint
            acceptedBootstrapPlanRecordFingerprint = [string]$completion.acceptedPlanRecordFingerprint
            baselineVerifiedAtUtc = [string]$completion.verifiedAtUtc
            baselineBootstrapSourceFingerprint = $bootstrapSourceFingerprint
            buildSourceFingerprint = $buildSourceFingerprint
            upgradeToolFingerprint = [string]$sourceMetadata.toolFingerprint
            upgradeSourceFingerprint = $upgradeSourceFingerprint
            baseline = [ordered]@{
                foundation = [ordered]@{ acrName = [string]$foundation.acrName; acrLoginServer = [string]$foundation.acrLoginServer }
                api = $apiBefore
                worker = $workerBefore
                queues = $queuesBefore
                adminUi = [ordered]@{ image = [string]$adminBefore.image; principalId = [string]$adminBefore.principalId; secretResourceId = [string]$adminBefore.secretResourceId }
            }
            build = [ordered]@{ component = 'adminUi'; repository = 'gateway-admin'; dockerfile = 'src/Gateway.AdminUi/Dockerfile'; intentId = $intentId; tag = $tag }
            prospectiveWhatIf = $prospectiveWhatIf
            deployment = [ordered]@{ name = $deploymentName; mode = 'Incremental'; deployKeyVaultPrivateEndpoint = $false }
        }
        if ($null -ne $priorUpgrade) { $acceptedPlan['priorUpgrade'] = $priorUpgrade }
        $planFingerprint = Get-BootstrapObjectFingerprint -InputObject $acceptedPlan
        $receipt = [ordered]@{
            schemaVersion = 1
            operation = 'BootstrapAdminUiOnlyUpgrade'
            locatorFingerprint = $locatorFingerprint
            planFingerprint = $planFingerprint
            acceptedPlan = ConvertTo-BootstrapCanonicalValue -Value $acceptedPlan
            status = 'Accepted'
            acceptedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            build = [ordered]@{ intentId = $intentId; tag = $tag; state = 'IntentRecorded' }
            deployment = [ordered]@{ name = $deploymentName; mode = 'Incremental'; deployKeyVaultPrivateEndpoint = $false; state = 'Planned' }
        }
        Save-AdminUiUpgradeReceipt -Receipt $receipt -Path $receiptPath
        $createdReceipt = $true
        $null = Assert-AdminUiUpgradeReceipt -Receipt $receipt -SourceMetadata $sourceMetadata -Completion $completion -OwnershipId $ownershipId -ConfigurationFingerprint ([string]$state.configurationFingerprint) -IntentId $intentId -Tag $tag -DeploymentName $deploymentName -LocatorFingerprint $locatorFingerprint
    }

    $planFingerprint = [string]$receipt.planFingerprint
    Assert-AdminUiUpgradeCurrentImage -Receipt $receipt -Image ([string]$adminBefore.image)
    $receipt['verificationBaseline'] = [ordered]@{
        capturedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        api = $apiBefore
        worker = $workerBefore
        queues = $queuesBefore
        adminUiImage = [string]$adminBefore.image
        prospectiveWhatIf = $prospectiveWhatIf
    }
    Save-AdminUiUpgradeReceipt -Receipt $receipt -Path $receiptPath

    Write-Host "Accepted Admin UI-only upgrade plan: $planFingerprint"
    Write-Host "Scope: $($configuration.subscriptionId)/$($configuration.resourceGroupName); API and worker are read-only invariants."
    Write-Host "What-If: $($prospectiveWhatIf.Count) exact Admin UI changes; zero Create/Delete; private endpoint redeployment disabled."

    $currentSourceMetadata = Get-AdminUiUpgradeSourceMetadata
    if ([string]$currentSourceMetadata.upgradeSourceFingerprint -cne $upgradeSourceFingerprint) {
        throw 'Admin UI upgrade source changed after plan acceptance.'
    }
    $image = Resolve-AdminUiBuild -Configuration $configuration -Receipt $receipt -ReceiptPath $receiptPath -ReceiptCreatedThisInvocation:$createdReceipt -BuildSourceFingerprint $buildSourceFingerprint
    $exactParameters = Get-AdminUiUpgradeParameters -Configuration $configuration -State $state -OwnershipId $ownershipId -BootstrapSourceFingerprint $bootstrapSourceFingerprint -UpgradeSourceFingerprint $upgradeSourceFingerprint -Image $image
    $exactWhatIf = @(Invoke-AdminUiUpgradeWhatIf -Configuration $configuration -Parameters $exactParameters -AllowedResourceIds $allowedIds -AdminAppId ([string]$adminBefore.appId))
    $receipt['exactDigestWhatIf'] = $exactWhatIf
    Save-AdminUiUpgradeReceipt -Receipt $receipt -Path $receiptPath
    $currentSourceMetadata = Get-AdminUiUpgradeSourceMetadata
    if ([string]$currentSourceMetadata.upgradeSourceFingerprint -cne $upgradeSourceFingerprint) {
        throw 'Admin UI upgrade source changed before the exact digest deployment.'
    }

    $null = Deploy-AdminUiUpgrade -Configuration $configuration -Receipt $receipt -ReceiptPath $receiptPath -Parameters $exactParameters -UpgradeSourceFingerprint $upgradeSourceFingerprint -Image $image
    $adminResult = Test-UpgradedAdminUi -Configuration $configuration -State $state -OwnershipId $ownershipId -BootstrapSourceFingerprint $bootstrapSourceFingerprint -UpgradeSourceFingerprint $upgradeSourceFingerprint -Image $image
    $apiAfter = Get-ContainerAppSnapshot -Configuration $configuration -Name "ca-gateway-api-$($configuration.environment)" -ExpectedOwnershipId $ownershipId -ExpectedBootstrapSourceFingerprint ([string]$runtime.sourceFingerprint)
    $workerAfter = Get-ContainerAppSnapshot -Configuration $configuration -Name "ca-gateway-worker-$($configuration.environment)-v3" -ExpectedOwnershipId $ownershipId -ExpectedBootstrapSourceFingerprint ([string]$runtime.sourceFingerprint)
    $queuesAfter = @(Get-QueueCountSnapshot -Configuration $configuration)
    if ((Get-BootstrapObjectFingerprint -InputObject $apiAfter) -cne (Get-BootstrapObjectFingerprint -InputObject $apiBefore) -or
        (Get-BootstrapObjectFingerprint -InputObject $workerAfter) -cne (Get-BootstrapObjectFingerprint -InputObject $workerBefore) -or
        (Get-BootstrapObjectFingerprint -InputObject $queuesAfter) -cne (Get-BootstrapObjectFingerprint -InputObject $queuesBefore)) {
        throw 'API, worker, or Service Bus queue counts changed during the Admin UI-only upgrade.'
    }
    $stateAfter = Read-BootstrapState -Path $statePath -Config $configuration
    if ((Get-BootstrapObjectFingerprint -InputObject $stateAfter.acceptedPlan) -cne [string]$completion.acceptedPlanRecordFingerprint) {
        throw 'The accepted bootstrap plan changed during the separate Admin UI upgrade.'
    }
    $receipt['status'] = 'Verified'
    $receipt['verifiedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    $receipt['result'] = [ordered]@{
        adminUi = $adminResult
        unchangedInvariants = [ordered]@{
            api = [ordered]@{ image = [string]$apiBefore.image; beforeFingerprint = Get-BootstrapObjectFingerprint -InputObject $apiBefore; afterFingerprint = Get-BootstrapObjectFingerprint -InputObject $apiAfter }
            worker = [ordered]@{ image = [string]$workerBefore.image; beforeFingerprint = Get-BootstrapObjectFingerprint -InputObject $workerBefore; afterFingerprint = Get-BootstrapObjectFingerprint -InputObject $workerAfter }
            queueCountsBefore = $queuesBefore
            queueCountsAfter = $queuesAfter
        }
        acceptedBootstrapPlanUnchanged = $true
        rollbackBoundary = [ordered]@{
            priorAdminUiImage = [string]$receipt.acceptedPlan.baseline.adminUi.image
            apiImage = [string]$receipt.acceptedPlan.baseline.api.image
            workerImage = [string]$receipt.acceptedPlan.baseline.worker.image
        }
    }
    Save-AdminUiUpgradeReceipt -Receipt $receipt -Path $receiptPath
    Write-Host "Admin UI upgrade verified: $($adminResult.url)"
    Write-Host "Image digest: $($adminResult.digest)"
    Write-Host 'API, worker, queues, ownership, original bootstrap plan, managed-identity pull, versionless Key Vault reference, and Entra sign-in redirect are unchanged or exact.'
    Write-Host "Safe receipt: $receiptPath"
}
finally {
    Clear-BootstrapAzureSubscriptionContext
    if ($lock) { $lock.Dispose() }
}
