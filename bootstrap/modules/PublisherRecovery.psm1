Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# A local tooling reconciliation, not an installer, provider retry, or upgrade.
# Its receipt never completes a deployment step or the publication operation.
function Assert-BootstrapPublisherRecoveryGeneration {
    param([Parameter(Mandatory)][Collections.IDictionary]$State)
    foreach ($name in @('databaseRecoveryPlan', 'databaseRecoveryHistory', 'manualDatabaseRepairPlan',
        'preInertSourceCorrectionPlan', 'purviewPrerequisiteRecoveryPlan', 'purviewPrerequisiteReconciliation')) {
        if ($State.Contains($name)) { throw 'Publisher metadata reconciliation cannot coexist with another recovery generation.' }
    }
}

function Get-BootstrapPublisherStableState {
    param([Parameter(Mandatory)][Collections.IDictionary]$State)
    $value = ConvertTo-BootstrapCanonicalValue -Value $State
    foreach ($name in @('updatedAtUtc', 'steps', 'outputs', 'freshPurviewExecutor', 'publisherMetadataReconciliation', 'hostSettingsAmendment')) {
        $value.Remove($name)
    }
    # Save-BootstrapState legitimately refreshes this provenance metadata, not the
    # accepted source. The source fingerprint is checked separately on every use.
    $value.source.Remove('lastWritten')
    return $value
}

function Get-BootstrapPublisherImmutableRecord {
    param([Parameter(Mandatory)][Collections.IDictionary]$Record)
    $value = ConvertTo-BootstrapCanonicalValue -Value $Record
    foreach ($name in @('status', 'operations', 'publication')) { $value.Remove($name) }
    return $value
}

function Assert-BootstrapPublisherOperator {
    param([Parameter(Mandatory)]$Actual, [Parameter(Mandatory)]$Expected)
    foreach ($name in @('tenantId', 'subscriptionId', 'userObjectId')) {
        Assert-GuidValue -Value ([string]$Expected[$name]) -Label 'Publisher reconciliation administrator binding'
        if ([string]$Actual[$name] -cne [string]$Expected[$name]) {
            throw 'Publisher reconciliation requires the exact original administrator and Azure target.'
        }
    }
}

function Get-BootstrapPublisherRecoveryIdentity {
    param([Parameter(Mandatory)]$Config)
    # Unlike interactive bootstrap authentication, review does not select an
    # account, log in, or write Azure CLI configuration.
    $account = Invoke-AzJson -Arguments @('account', 'show')
    if ([string]$account.id -cne [string]$Config.subscriptionId -or
        [string]$account.tenantId -cne [string]$Config.tenantId) { throw 'Publisher review Azure account is not the exact target.' }
    Set-BootstrapAzureSubscriptionContext -SubscriptionId $Config.subscriptionId -TenantId $Config.tenantId
    $user = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url',
        'https://graph.microsoft.com/v1.0/me?$select=id')
    Assert-GuidValue -Value ([string]$user.id) -Label 'Publisher review signed-in administrator'
    return @{ tenantId = [string]$account.tenantId; subscriptionId = [string]$account.id; userObjectId = [string]$user.id }
}

function Assert-BootstrapPublisherRecoveryEligibility {
    param([Parameter(Mandatory)][Collections.IDictionary]$State, [Parameter(Mandatory)]$Config)
    Assert-BootstrapPublisherRecoveryGeneration -State $State
    if ($State.Contains('publisherMetadataReconciliation')) { throw 'Use the existing exact completed publisher receipt.' }
    if ($Config.purview.enabled -ne $true -or
        (Get-BootstrapConfigurationFingerprint -Config $Config) -cne [string]$State.configurationFingerprint -or
        [string]$State.acceptedPlan.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        [string]$State.deploymentKey -cne "$($Config.subscriptionId)/$($Config.resourceGroupName)/$($Config.environment)") {
        throw 'Publisher reconciliation configuration or accepted plan changed.'
    }
    $names = @(Get-GatewayBootstrapStepNames)
    if ($names.Count -ne 19 -or $names[14] -cne 'Gateway runtime deployment' -or $State.steps.Count -ne 15) {
        throw 'Publisher reconciliation requires fourteen completed steps and failed runtime step fifteen.'
    }
    foreach ($name in $names[0..13]) {
        $step = $State.steps[$name]
        if ($step -isnot [Collections.IDictionary] -or [string]$step.status -cne 'Completed' -or
            $null -eq $step.evidence -or [string]$step.sourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint) {
            throw 'Publisher reconciliation completed prefix is not exact.'
        }
    }
    $failed = $State.steps[$names[14]]
    if ([string]$failed.status -cne 'Failed' -or $failed.Contains('evidence') -or
        [string]$failed.sourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint -or
        [string]$failed.message -cnotmatch "property 'publisher\.publish\.execution\.template' disagreed") {
        throw 'Publisher reconciliation requires the preserved execution-template failure.'
    }
    $record = $State.freshPurviewExecutor
    Assert-PurviewPublisherObjectFields -Object $record -Required @('schemaVersion', 'status', 'intentId',
        'context', 'operations', 'package', 'packageDirectory', 'identity', 'publisherImage', 'network', 'host', 'publisher')
    if ($record.schemaVersion -ne 1 -or [string]$record.status -cne 'Installing' -or $record.Contains('publication') -or
        [string]$record.context.sourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint -or
        [string]$record.context.deploymentOwnershipId -cne [string]$State.deploymentOwnershipId -or
        [string]$record.context.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        [string]$record.context.planFingerprint -cne [string]$State.acceptedPlan.planFingerprint) {
        throw 'Publisher reconciliation requires the original installing executor context.'
    }
    foreach ($name in @('package', 'packageDirectory', 'identity', 'publisherImage', 'network', 'host', 'publisher')) {
        if (-not $record.Contains($name)) { throw 'Publisher reconciliation executor prefix is incomplete.' }
    }
    $required = @('application', 'audience', 'principal', 'invokeRole', 'publisherImage',
        "a365gw-$($Config.projectName)-executor-host-$($Config.environment)",
        "a365gw-$($Config.projectName)-executor-publisher-$($Config.environment)", 'publish')
    if (@($record.operations.Keys | Where-Object { $_ -cnotin @($required + 'webProvider') }).Count -ne 0) {
        throw 'Publisher reconciliation contains an unknown or later operation.'
    }
    foreach ($name in $required) {
        if (-not $record.operations.Contains($name)) { throw 'Publisher reconciliation operation prefix is incomplete.' }
    }
    foreach ($name in $record.operations.Keys) {
        $op = $record.operations[$name]
        Assert-BootstrapFingerprintValue -Value ([string]$op.intentFingerprint) -Label 'Publisher original operation intent'
        if ($name -ceq 'publish') {
            Assert-PurviewPublisherObjectFields -Object $op -Required @('status', 'intentFingerprint')
            if ([string]$op.status -cne 'Started') { throw 'Publisher reconciliation requires the original Started intent.' }
        }
        else {
            Assert-PurviewPublisherObjectFields -Object $op -Required @('status', 'intentFingerprint', 'evidenceFingerprint')
            if ([string]$op.status -cne 'Completed') { throw 'Publisher reconciliation completed operation changed.' }
            Assert-BootstrapFingerprintValue -Value ([string]$op.evidenceFingerprint) -Label 'Publisher completed operation'
        }
    }
    $completedEvidence = @{
        application = @{ objectId = $record.identity.applicationObjectId; applicationId = $record.identity.applicationId }
        audience = @{ audience = "api://$($record.identity.applicationId)" }
        principal = @{ objectId = $record.identity.servicePrincipalId; applicationId = $record.identity.applicationId }
        invokeRole = @{ id = $record.identity.roleAssignmentId }
        publisherImage = $record.publisherImage
        "a365gw-$($Config.projectName)-executor-host-$($Config.environment)" = $record.host
        "a365gw-$($Config.projectName)-executor-publisher-$($Config.environment)" = $record.publisher
    }
    if ($record.operations.Contains('webProvider')) { $completedEvidence.webProvider = @{ namespace = 'Microsoft.Web' } }
    foreach ($name in $completedEvidence.Keys) {
        if ([string]$record.operations[$name].evidenceFingerprint -cne
            (Get-BootstrapObjectFingerprint -InputObject $completedEvidence[$name])) {
            throw 'Publisher original completed operation does not bind its retained identity or artifact.'
        }
    }
    $imageTag = Get-BootstrapImageBuildIntentTag -DeploymentOwnershipId $State.deploymentOwnershipId `
        -SourceFingerprint $State.acceptedPlan.sourceFingerprint -IntentId $record.intentId
    $imageIntent = @{ registry = [string]$State.steps['Azure foundation'].evidence.acrName
        repository = 'gateway-purview-package-publisher'; tag = $imageTag; receiptFingerprint = $record.package.receiptFingerprint }
    if ((Get-BootstrapObjectFingerprint -InputObject $imageIntent) -cne [string]$record.operations.publisherImage.intentFingerprint) {
        throw 'Publisher image intent is not bound to the original source and package.'
    }
    $priorRoot = Get-BootstrapExecutionSourceRoot
    try {
        Assert-BootstrapAcceptedPlan -State $State -PlanFingerprint $State.acceptedPlan.planFingerprint `
            -ConfigurationFingerprint $State.configurationFingerprint -SourceFingerprint $State.acceptedPlan.sourceFingerprint `
            -MaximumAge ([TimeSpan]::MaxValue) | Out-Null
    }
    finally { Set-BootstrapExecutionSourceRoot -Path $priorRoot }
}

function Get-BootstrapPublisherTokenFingerprint {
    param([Parameter(Mandatory)][string]$Text)
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'Publisher source cannot be parsed.' }
    $value = @($tokens | Where-Object Kind -NotIn @('Comment', 'NewLine', 'LineContinuation', 'EndOfInput') |
        ForEach-Object Text) -join "`n"
    return [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($value)))
}

function Get-BootstrapPublisherReviewedFunctions {
    # V1 is one reviewed metadata repair, not permission to rewrite arbitrary
    # bodies in an allowlisted module. Token hashes bind the original functions
    # and their exact metadata/receipt/asset plumbing. Comments/line endings do
    # not confer authority. A subsequent tooling edit needs a new source review.
    return @{
        'Get-BootstrapEffectiveDeploymentSourceFingerprint' = @('b5047b796977b0366b897ff459388f70f8500642ebf6c9e6fccfa273b873c7a4', 'd525a94a44d55fbb7291aef2429ce98eef9001c5a4272c15342087e995618202')
        'Assert-BootstrapStateAllowsSourcePlan' = @('ce75a37ee3cf6ba85eca691308278bc0e2099ce27d475ca3485c46eb6712312f', '89172212647ce1ceaca3b567d83f559dd45695156c79cbf05ee5f65099ecd043')
        'Get-BootstrapAssetSourceRoot' = @('', '27498e5bf57ae3d97562075c242f73f179d64e160ae7cd0c45181fcb57b16ac1')
        'Deploy-GatewayCore' = @('1ed5c9c98cab8180879da0b23b0085a246f475e60b77bc45ec899f39c34d1c7e', '8d3c4f3f6feab242edccda4b1d498e1455a37b801a25764054e239527fde75a8')
        'Build-GatewayImages' = @('f6e6bb8aac2c69b4b64e76d702dac5c33e09240dbf2990aef86d00c93950ff95', '25dab9759e06689a734eb4f2dc34421732ad845ae3c909f0fbb3222166731f75')
        'Deploy-GatewayAdminUi' = @('8a79bc99f721145e56c21e482ca6b3dbbf717a4a3cfabb1ac600824eb67ef06c', '035bfedd4fbdf1536eb791786f05791064beb68c08cab1b06877296d4d6c1ad7')
        'Get-GatewayResumeExecutionSource' = @('3049be63fdbfbfcbc2784b707905627155373679c8e448f57c21f7b943f7be30', '357a0a4d77b120fd803a9ab525517c26ecffc24cc64e34c346062a6068703d94')
        'Invoke-GatewayStateStep' = @('de9398b0585c945ac0f5b1d1d9df7434a5fd76fb24056114da7e799a19aff82a', '00e47f2ac7e5ced19afdf03cf38c738cee29a60091cbfb2d6930b47abf9b9108')
        'ConvertTo-PurviewPublisherExecutionTemplate' = @('70ba71c5c49dcd291a8f3e3a3b64f616876e46c77f446f805b44ee70905aa534', '00877f55eb0ab41b99fd18bddf37ec5fdf58d4334aeff7aa86dbb6c5a1c7ca70')
        'Get-PurviewExecutorFreshContext' = @('c41f94d3b8109740b7a4573fd750c161d7357d9ede76cab1f59e4d459468ef2d', '205e50d51488ebe772f4e2c996cfc4ce6a9b680008ed3bf5d7ce8dfe28534190')
        'Get-PurviewExecutorWorkerGrant' = @('d07710389f2541ac41f74a51046e615e1ce55f278389e4c0be147296dfc5c97c', '82fd73e78403aba626a4da80293b54f55feaaf293d3e8ebdad25f2c89a47d0f8')
        'Install-BootstrapPurviewExecutor' = @('627b2a6819b3dbbc3a942c66df54e9fd886c47be3409840cd0cbcb47618d9451', '382c03a85aa5c3bfc14c17da0758c8511daa0a06b0a372a25510d7a4b072c33f')
        'Invoke-PurviewExecutorDeployment' = @('3dc54480198cdadc0c4d2a91a7912f7a915e05d9d1c49512137a0df78df2f854', 'b6db672324491a07cd6817f2267bd56c21ac171be04b8622db19f58715e20532')
        'Build-PurviewExecutorPublisher' = @('3f217b3912c2260c4e0f7faa5ab042ebb87676d5eb26777280db893ae46e83c4', '5cad39c303e0c8375138eb30d5a732f6874b7501cda5cec04f322f3e15831e3d')
        'Get-PurviewExecutorHostParameters' = @('', 'a1e3cae7c82f64fd7de4483f2df06c13df3467cc5db3e8780095be150caafdb3')
    }
}

function Get-BootstrapPublisherSourceSurface {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$AllowedFunctions,
        [switch]$Bootstrap, [switch]$Original)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'Publisher tooling source cannot be parsed.' }
    $functions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
    $reviewed = Get-BootstrapPublisherReviewedFunctions
    foreach ($name in $AllowedFunctions) {
        $found = @($functions | Where-Object Name -CEQ $name)
        if ($Original -and $found.Count -eq 0 -and [string]$reviewed[$name][0] -ceq '') { continue }
        if ($found.Count -ne 1) { throw 'Publisher tooling function is missing or duplicated.' }
        $hash = Get-BootstrapPublisherTokenFingerprint -Text $found[0].Extent.Text
        $expected = if ($Original) { @($reviewed[$name]) } else { @($reviewed[$name][1]) }
        if ($hash -cnotin $expected) { throw 'Publisher tooling function differs from the exact reviewed metadata repair.' }
    }
    $ranges = @($functions | Where-Object { $_.Name -cin $AllowedFunctions })
    # Exclude only explicitly named reconciliation functions, not whole modules.
    $retained = [Collections.Generic.List[string]]::new()
    foreach ($token in $tokens) {
        if ($token.Kind -in @('Comment', 'NewLine', 'LineContinuation', 'EndOfInput')) { continue }
        $inside = $false
        foreach ($range in $ranges) {
            if ($token.Extent.StartOffset -ge $range.Extent.StartOffset -and
                $token.Extent.EndOffset -le $range.Extent.EndOffset) { $inside = $true; break }
        }
        if (-not $inside) { $retained.Add($token.Text) }
    }
    $surface = $retained -join "`n"
    if ($Bootstrap) {
        # These are the only non-function glue additions allowed to the installer.
        $surface = $surface.Replace(",`n'PublisherRecovery'", '')
        $surface = $surface.Replace("-PublisherRecoveryState`n`$state", '')
        $surface = $surface.Replace("Initialize-BootstrapPublisherRecoveryTooling`n-State`n`$state`n-Config`n`$configuration`n-Mode`n`$Mode`n;", '')
        $surface = $surface.Replace("(`n`$activeExecutionSourceFingerprint`n-ceq`n`$activeDeploymentSourceFingerprint`n-or`n`$state`n.`nContains`n(`n'publisherMetadataReconciliation'`n)`n)",
            "`$activeExecutionSourceFingerprint`n-ceq`n`$activeDeploymentSourceFingerprint")
    }
    return (@($surface.Split("`n") | Where-Object { $_.Length -gt 0 }) -join "`n")
}

function Assert-BootstrapPublisherSourceDelta {
    param([Parameter(Mandatory)][Collections.IDictionary]$State, [Parameter(Mandatory)][string]$CandidateRoot)
    Assert-BootstrapSourcePathIsRegular -Root (Get-RepositoryRoot) -RelativePath $State.acceptedPlan.executionSource | Out-Null
    $originalRoot = Resolve-BootstrapAcceptedSourceRoot -State $State
    $original = @{}; $candidate = @{}
    foreach ($e in @(Get-BootstrapSourceManifest -Root $originalRoot)) { $original[$e.path] = $e.sha256 }
    foreach ($e in @(Get-BootstrapSourceManifest -Root $CandidateRoot)) { $candidate[$e.path] = $e.sha256 }
    $allowed = @{
        'bootstrap/modules/PurviewExecutor.psm1' = @('ConvertTo-PurviewPublisherExecutionTemplate',
            'Get-PurviewExecutorFreshContext', 'Get-PurviewExecutorWorkerGrant', 'Install-BootstrapPurviewExecutor',
            'Invoke-PurviewExecutorDeployment', 'Build-PurviewExecutorPublisher', 'Get-PurviewExecutorHostParameters')
        'bootstrap/modules/Common.psm1' = @('Get-BootstrapEffectiveDeploymentSourceFingerprint',
            'Assert-BootstrapStateAllowsSourcePlan', 'Get-BootstrapAssetSourceRoot')
        'bootstrap/modules/Azure.psm1' = @('Deploy-GatewayCore', 'Build-GatewayImages', 'Deploy-GatewayAdminUi')
        'bootstrap/bootstrap.ps1' = @('Get-GatewayResumeExecutionSource', 'Invoke-GatewayStateStep')
    }
    $newFiles = @('bootstrap/modules/PublisherRecovery.psm1', 'bootstrap/reconcile-publisher-metadata.ps1')
    $delta = [Collections.Generic.List[object]]::new()
    foreach ($path in @(@($original.Keys) + @($candidate.Keys) | Sort-Object -Unique)) {
        if (-not $candidate.ContainsKey($path)) { throw 'Publisher reconciliation cannot remove accepted source.' }
        if ($original.ContainsKey($path) -and $original[$path] -ceq $candidate[$path]) { continue }
        if ($path -cnotin $newFiles) {
            if (-not $allowed.ContainsKey($path) -or -not $original.ContainsKey($path)) {
                throw 'Publisher reconciliation changed immutable assets or unrelated source.'
            }
            $a = Get-BootstrapPublisherSourceSurface -Path (Join-Path $originalRoot $path) -AllowedFunctions $allowed[$path] -Bootstrap:($path -ceq 'bootstrap/bootstrap.ps1') -Original
            $b = Get-BootstrapPublisherSourceSurface -Path (Join-Path $CandidateRoot $path) -AllowedFunctions $allowed[$path] -Bootstrap:($path -ceq 'bootstrap/bootstrap.ps1')
            if ($a -cne $b) { throw 'Publisher reconciliation changed source outside the exact metadata/tooling functions.' }
        }
        $delta.Add([ordered]@{ path = $path; original = if ($original.ContainsKey($path)) { $original[$path] } else { '' }; corrected = $candidate[$path] })
    }
    if ($delta.Count -eq 0 -or 'bootstrap/modules/PurviewExecutor.psm1' -cnotin @($delta.path)) {
        throw 'Publisher reconciliation requires a distinct corrected metadata parser.'
    }
    foreach ($path in @($allowed.Keys) + $newFiles) {
        if (-not $candidate.ContainsKey($path)) { throw 'Publisher reconciliation tooling is incomplete.' }
    }
    return ,@($delta)
}

function Get-BootstrapPublisherRecoveryProviderState {
    param([Parameter(Mandatory)][Collections.IDictionary]$State, [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AzureIdentity, [Parameter(Mandatory)]$Operator)
    Assert-BootstrapPublisherOperator -Actual $AzureIdentity -Expected $Operator
    Assert-BootstrapPublisherOperator -Actual (Get-BootstrapPublisherRecoveryIdentity -Config $Config) -Expected $Operator
    Assert-BootstrapAzureContext -Config $Config | Out-Null
    $record = $State.freshPurviewExecutor
    $foundation = $State.steps['Azure foundation'].evidence
    $runtime = $State.steps['Inert identity deployment'].evidence
    foreach ($e in @($foundation, $runtime)) {
        if ([string]$e.sourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint -or
            [string]$e.deploymentOwnershipId -cne [string]$State.deploymentOwnershipId) {
            throw 'Publisher prerequisite provider scope is not original-source-bound.'
        }
    }
    foreach ($field in @('tenantId', 'subscriptionId', 'resourceGroupName')) {
        if ([string]$record.context[$field] -cne [string]$Config.$field) { throw 'Publisher context target changed.' }
    }
    if ([string]$record.publisherImage.digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        -not ([string]$record.publisher.publisherImage.value).EndsWith("@$($record.publisherImage.digest)", [StringComparison]::Ordinal)) {
        throw 'Publisher immutable image differs from the original built-image record.'
    }
    if ([string]$record.context.apiPrincipalId -cne [string]$runtime.apiPrincipalId -or
        [string]$record.context.workerPrincipalId -cne [string]$runtime.workerPrincipalId -or
        [string]$record.context.runtimePrincipalId -cne [string]$foundation.runtimeImagePullIdentityPrincipalId) {
        throw 'Publisher prerequisite principal binding changed.'
    }
    $image = Build-PurviewExecutorPublisher -Config $Config -Foundation $foundation -Record $record `
        -ReadOnly -Checkpoint { throw 'Publisher review cannot checkpoint or rebuild an image.' }
    Assert-PurviewExecutorEqual -Actual $image -Expected $record.publisherImage -Label 'publisher original image run'
    $network = Get-PurviewExecutorStorageNetwork -Config $Config -Foundation $foundation -Runtime $runtime -Context $record.context
    Assert-PurviewExecutorEqual -Actual $network -Expected $record.network -Label 'publisher recovery private network'
    $enableName = "a365gw-$($Config.projectName)-executor-enable-$($Config.environment)"
    Assert-PurviewExecutorHost -Config $Config -Foundation $foundation -Record $record -Enabled:($record.operations.Contains($enableName))
    $template = Assert-PurviewPublisherJob -Config $Config -Foundation $foundation -Record $record -Network $network
    # Crucially, this hashes the RAW job GET, before normalization. Two provider
    # objects agreeing with each other cannot replace the pre-dispatch intent.
    $rawIntent = Get-BootstrapObjectFingerprint -InputObject @{
        jobId = $record.publisher.jobId.value; template = $template; intentId = $record.intentId
    }
    if ($rawIntent -cne [string]$record.operations.publish.intentFingerprint) {
        throw 'Publisher raw job intent differs from its original pre-dispatch fingerprint.'
    }
    $publication = Start-PurviewPublisherOnce -Config $Config -Template $template -Record $record `
        -ReadOnly -Checkpoint { throw 'Publisher reconciliation cannot checkpoint publication.' }
    $parameters = Get-PurviewExecutorHostParameters -Config $Config -Foundation $foundation -Record $record
    $templatePath = Join-Path (Resolve-BootstrapAcceptedSourceRoot -State $State) 'bootstrap/infra/purview-windows-executor.bicep'
    $templateHash = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $disabledIntent = Get-BootstrapObjectFingerprint -InputObject @{ templateSha256 = $templateHash; parameters = $parameters }
    $hostName = "a365gw-$($Config.projectName)-executor-host-$($Config.environment)"
    if ($disabledIntent -cne [string]$record.operations[$hostName].intentFingerprint) {
        throw 'Publisher original disabled-host intent changed.'
    }
    # Independently re-read the completed host deployment record as well as its
    # resources. This is a projection of non-secret identifiers/parameters only.
    $deployment = Invoke-AzJson -Arguments @('deployment', 'group', 'show', '--subscription', $Config.subscriptionId,
        '--resource-group', $Config.resourceGroupName, '--name', $hostName,
        '--query', '{state:properties.provisioningState,parameters:properties.parameters,outputs:properties.outputs}')
    if ([string]$deployment.state -cne 'Succeeded') { throw 'Publisher original host deployment record is not Succeeded.' }
    Assert-GatewayExactReadableArmParameters -ActualParameters $deployment.parameters -ExpectedParameters $parameters | Out-Null
    Assert-PurviewExecutorEqual -Actual $deployment.outputs -Expected $record.host -Label 'publisher original host deployment record'
    $publisherParameters = [ordered]@{
        location = [string]$Config.location; environmentName = [string]$Config.environment; projectName = [string]$Config.projectName
        deploymentOwnershipId = $record.context.deploymentOwnershipId; bootstrapSourceFingerprint = $record.context.sourceFingerprint
        executionSourceFingerprint = $record.context.sourceFingerprint; executionIntentId = $record.intentId
        containerAppsEnvironmentId = [string]$foundation.containerAppsEnvironmentId
        imagePullIdentityResourceId = [string]$foundation.runtimeImagePullIdentityId; acrLoginServer = [string]$foundation.acrLoginServer
        publisherImageDigest = $record.publisherImage.digest; packageDigest = $record.package.receipt.packageDigest
        packageBytes = [int]$record.package.receipt.packageBytes; storageAccountName = $network.storageAccountName
        expectedStoragePrivateEndpointIp = $network.privateEndpointIp
    }
    $publisherName = "a365gw-$($Config.projectName)-executor-publisher-$($Config.environment)"
    $publisherTemplate = Join-Path (Resolve-BootstrapAcceptedSourceRoot -State $State) 'bootstrap/infra/purview-package-publisher-job.bicep'
    $publisherIntent = @{ templateSha256 = (Get-FileHash -LiteralPath $publisherTemplate -Algorithm SHA256).Hash.ToLowerInvariant()
        parameters = $publisherParameters }
    if ((Get-BootstrapObjectFingerprint -InputObject $publisherIntent) -cne [string]$record.operations[$publisherName].intentFingerprint) {
        throw 'Publisher original deployment intent changed.'
    }
    $deployment = Invoke-AzJson -Arguments @('deployment', 'group', 'show', '--subscription', $Config.subscriptionId,
        '--resource-group', $Config.resourceGroupName, '--name', $publisherName,
        '--query', '{state:properties.provisioningState,parameters:properties.parameters,outputs:properties.outputs}')
    if ([string]$deployment.state -cne 'Succeeded') { throw 'Publisher original job deployment record is not Succeeded.' }
    Assert-GatewayExactReadableArmParameters -ActualParameters $deployment.parameters -ExpectedParameters $publisherParameters | Out-Null
    Assert-PurviewExecutorEqual -Actual $deployment.outputs -Expected $record.publisher -Label 'publisher original job deployment record'
    $parameters.enableRuntime = $true
    return [ordered]@{
        rawIntentFingerprint = $rawIntent
        publication = $publication
        networkFingerprint = Get-BootstrapObjectFingerprint -InputObject $network
        enableName = $enableName
        enableIntentFingerprint = Get-BootstrapObjectFingerprint -InputObject @{ templateSha256 = $templateHash; parameters = $parameters }
    }
}

function Assert-BootstrapPublisherParentPlan {
    param([Parameter(Mandatory)][Collections.IDictionary]$State, [Parameter(Mandatory)]$Recovery)
    Assert-BootstrapPublisherRecoveryGeneration -State $State
    $plan = $Recovery.plan
    if ($plan.schemaVersion -ne 1 -or [string]$plan.kind -cne 'PublisherMetadataReconciliation' -or
        [string]$Recovery.planFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $plan) -or
        (Get-BootstrapObjectFingerprint -InputObject (Get-BootstrapPublisherStableState -State $State)) -cne [string]$plan.stableStateFingerprint -or
        [string]$plan.originalSourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint -or
        [string]$State.source.lastWritten.bootstrapSourceFingerprint -cne [string]$plan.originalSourceFingerprint) {
        throw 'Publisher reconciliation plan, configuration, target or current tooling changed.'
    }
    $expected = ".bootstrap/accepted-source/$($State.deploymentOwnershipId)/$(([string]$Recovery.planFingerprint).Substring(7))"
    if ([string]$Recovery.executionSource -cne $expected) { throw 'Publisher reconciliation snapshot ownership/path changed.' }
    $root = Join-Path (Get-RepositoryRoot) $expected
    Assert-BootstrapSourcePathIsRegular -Root (Get-RepositoryRoot) -RelativePath $expected | Out-Null
    if ((Get-BootstrapSourceFingerprint -Root $root) -cne [string]$plan.correctedSourceFingerprint) {
        throw 'Publisher reconciliation corrected immutable snapshot changed.'
    }
    $delta = Assert-BootstrapPublisherSourceDelta -State $State -CandidateRoot $root
    Assert-PurviewExecutorEqual -Actual $delta -Expected $plan.sourceDelta -Label 'publisher recovery source delta'
    return $root
}

function Assert-BootstrapPublisherParentReceipt {
    param([Parameter(Mandatory)][Collections.IDictionary]$State)
    $recovery = $State.publisherMetadataReconciliation
    Assert-PurviewPublisherObjectFields -Object $recovery -Required @('plan', 'planFingerprint', 'executionSource',
        'status', 'completedAtUtc', 'completionFingerprint')
    $root = Assert-BootstrapPublisherParentPlan -State $State -Recovery $recovery
    if ([string]$recovery.status -cne 'Completed' -or [string]$recovery.completionFingerprint -cne
        (Get-BootstrapObjectFingerprint -InputObject @{
            planFingerprint = $recovery.planFingerprint; completedAtUtc = $recovery.completedAtUtc; status = 'Completed'
        })) { throw 'Publisher reconciliation receipt is incomplete or changed.' }
    $time = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact([string]$recovery.completedAtUtc, 'O', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$time)) { throw 'Publisher receipt timestamp is invalid.' }
    $plan = $recovery.plan
    $names = @(Get-GatewayBootstrapStepNames)
    foreach ($name in $names[2..13]) {
        if (-not $State.steps.Contains($name) -or
            (Get-BootstrapObjectFingerprint -InputObject $State.steps[$name]) -cne [string]$plan.prefixFingerprints[$name]) {
            throw 'Publisher reconciliation immutable completed prefix changed.'
        }
    }
    # AlwaysRun checks 1/2 can be Running/Failed temporarily, with no evidence.
    # Any returned authentication evidence must still be the original operator.
    foreach ($name in $names[0..1]) {
        $step = $State.steps[$name]
        if ([string]$step.status -cnotin @('Running', 'Failed', 'Completed') -or
            [string]$step.sourceFingerprint -cne [string]$plan.originalSourceFingerprint) { throw 'Publisher session-check provenance changed.' }
    }
    $authentication = $State.steps[$names[1]]
    if ($authentication.Contains('evidence')) {
        Assert-BootstrapPublisherOperator -Actual $authentication.evidence -Expected $plan.operator
    }
    $record = $State.freshPurviewExecutor
    if ([string]$record.status -cnotin @('Installing', 'Installed') -or
        (Get-BootstrapObjectFingerprint -InputObject (Get-BootstrapPublisherImmutableRecord -Record $record)) -cne [string]$plan.recordFingerprint) {
        throw 'Publisher reconciliation original executor/package/identity binding changed.'
    }
    foreach ($name in $plan.originalOperations.Keys) {
        $actual = $record.operations[$name]
        if ($name -cne 'publish') {
            Assert-PurviewExecutorEqual -Actual $actual -Expected $plan.originalOperations[$name] -Label 'publisher completed operation'
            continue
        }
        $expected = ConvertTo-BootstrapCanonicalValue -Value $plan.originalOperations.publish
        if ([string]$actual.status -ceq 'Completed') {
            $expected.status = 'Completed'
            $expected.evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $plan.provider.publication
        }
        Assert-PurviewExecutorEqual -Actual $actual -Expected $expected -Label 'publisher publication transition'
    }
    foreach ($name in $record.operations.Keys) {
        if ($plan.originalOperations.Contains($name)) { continue }
        $op = $record.operations[$name]
        if ($name -cne [string]$plan.provider.enableName -or
            [string]$record.operations.publish.status -cne 'Completed' -or
            [string]$op.intentFingerprint -cne [string]$plan.provider.enableIntentFingerprint -or
            [string]$op.status -cnotin @('Started', 'Completed')) { throw 'Publisher reconciliation found an unapproved later operation.' }
        $expected = @{ status = $op.status; intentFingerprint = $plan.provider.enableIntentFingerprint }
        if ([string]$op.status -ceq 'Completed') { $expected.evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $record.host }
        Assert-PurviewExecutorEqual -Actual $op -Expected $expected -Label 'publisher host-enable transition'
    }
    if ($record.Contains('publication')) {
        if ([string]$record.operations.publish.status -cne 'Completed') { throw 'Publisher publication is not checkpointed.' }
        Assert-PurviewExecutorEqual -Actual $record.publication -Expected $plan.provider.publication -Label 'publisher publication evidence'
    }
    if ([string]$record.status -ceq 'Installed' -and
        (-not $record.Contains('publication') -or -not $record.operations.Contains([string]$plan.provider.enableName) -or
         [string]$record.operations[$plan.provider.enableName].status -cne 'Completed')) { throw 'Publisher installation is incomplete.' }
    if ($State.steps.Count -lt 15 -or $State.steps.Count -gt 19 -or
        @($State.steps.Keys | Where-Object { $_ -cnotin $names }).Count -ne 0) { throw 'Publisher continuation has unknown steps.' }
    for ($i = 14; $i -lt $State.steps.Count; $i++) {
        $step = $State.steps[$names[$i]]
        if ($step -isnot [Collections.IDictionary] -or [string]$step.status -cnotin @('Running', 'Failed', 'Completed') -or
            [string]$step.sourceFingerprint -cne [string]$plan.originalSourceFingerprint -or
            ($i -lt $State.steps.Count - 1 -and [string]$step.status -cne 'Completed') -or
            ([string]$step.status -ceq 'Completed' -and -not $step.Contains('evidence'))) {
            throw 'Publisher continuation is not an exact forward prefix.'
        }
        if ([string]$step.status -ceq 'Completed' -and [string]$record.status -cne 'Installed') {
            throw 'Publisher continuation preceded executor completion.'
        }
    }
    foreach ($name in $plan.originalOutputs.Keys) {
        Assert-PurviewExecutorEqual -Actual $State.outputs[$name] -Expected $plan.originalOutputs[$name] -Label 'publisher original output'
    }
    if (@($State.outputs.Keys | Where-Object { -not $plan.originalOutputs.Contains($_) -and
        $_ -cnotin @('adminUiUrl', 'apiUrl', 'seedBlueprint', 'verification') }).Count -ne 0) {
        throw 'Publisher continuation contains unknown outputs.'
    }
    return $root
}

function Assert-BootstrapPublisherRecoveryPlan {
    param([Parameter(Mandatory)][Collections.IDictionary]$State, [Parameter(Mandatory)]$Recovery)
    $root = Assert-BootstrapPublisherParentPlan -State $State -Recovery $Recovery
    if ($State.Contains('hostSettingsAmendment')) {
        return Assert-BootstrapHostSettingsAmendment -State $State
    }
    if ([string]$Recovery.plan.correctedSourceFingerprint -cne (Get-BootstrapSourceFingerprint)) {
        throw 'Publisher reconciliation current tooling changed; an explicitly approved amendment is required.'
    }
    return $root
}

function Assert-BootstrapPublisherRecoveryReceipt {
    param([Parameter(Mandatory)][Collections.IDictionary]$State)
    $null = Assert-BootstrapPublisherParentReceipt -State $State
    return Assert-BootstrapPublisherRecoveryPlan -State $State -Recovery $State.publisherMetadataReconciliation
}

function New-BootstrapPublisherRecoveryPlan {
    param([Parameter(Mandatory)][Collections.IDictionary]$State, [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AzureIdentity)
    Assert-BootstrapPublisherRecoveryEligibility -State $State -Config $Config
    $delta = Assert-BootstrapPublisherSourceDelta -State $State -CandidateRoot (Get-RepositoryRoot)
    $operator = [ordered]@{}
    foreach ($name in @('tenantId', 'subscriptionId', 'userObjectId')) { $operator[$name] = $State.steps['Azure authentication'].evidence[$name] }
    $provider = Get-BootstrapPublisherRecoveryProviderState -State $State -Config $Config -AzureIdentity $AzureIdentity -Operator $operator
    $package = Read-PurviewExecutorPackage -PackageDirectory $State.freshPurviewExecutor.packageDirectory `
        -ExpectedSourceFingerprint $State.acceptedPlan.sourceFingerprint
    Assert-PurviewExecutorEqual -Actual $package.receipt -Expected $State.freshPurviewExecutor.package.receipt -Label 'publisher original package'
    if ($package.receiptFingerprint -cne [string]$State.freshPurviewExecutor.package.receiptFingerprint) { throw 'Publisher package receipt changed.' }
    $prefix = [ordered]@{}
    foreach ($name in @(Get-GatewayBootstrapStepNames)[2..13]) { $prefix[$name] = Get-BootstrapObjectFingerprint -InputObject $State.steps[$name] }
    $plan = ConvertTo-BootstrapCanonicalValue -Value ([ordered]@{
        schemaVersion = 1; kind = 'PublisherMetadataReconciliation'; createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        originalSourceFingerprint = [string]$State.acceptedPlan.sourceFingerprint
        correctedSourceFingerprint = Get-BootstrapSourceFingerprint
        sourceDelta = $delta; operator = $operator; provider = $provider
        initialStateFingerprint = Get-BootstrapObjectFingerprint -InputObject $State
        stableStateFingerprint = Get-BootstrapObjectFingerprint -InputObject (Get-BootstrapPublisherStableState -State $State)
        prefixFingerprints = $prefix
        recordFingerprint = Get-BootstrapObjectFingerprint -InputObject (Get-BootstrapPublisherImmutableRecord -Record $State.freshPurviewExecutor)
        originalOperations = $State.freshPurviewExecutor.operations
        originalOutputs = $State.outputs
    })
    $fingerprint = Get-BootstrapObjectFingerprint -InputObject $plan
    $snapshot = New-BootstrapAcceptedSourceSnapshot -State $State -PlanFingerprint $fingerprint -SourceFingerprint $plan.correctedSourceFingerprint
    return [ordered]@{ plan = $plan; planFingerprint = $fingerprint; executionSource = $snapshot }
}

function Initialize-BootstrapPublisherRecoveryTooling {
    param([Parameter(Mandatory)][Collections.IDictionary]$State, [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Mode)
    if ($State.Contains('hostSettingsAmendment') -and -not $State.Contains('publisherMetadataReconciliation')) { throw 'Host settings amendment requires its original completed publisher receipt.' }
    if (-not $State.Contains('publisherMetadataReconciliation')) { return }
    if ($Mode -cnotin @('Resume', 'Verify', 'Apply', 'Up')) { throw 'Publisher receipt is only usable by normal Resume or Verify.' }
    if ((Get-BootstrapConfigurationFingerprint -Config $Config) -cne [string]$State.configurationFingerprint) { throw 'Publisher configuration changed.' }
    $root = Assert-BootstrapPublisherRecoveryReceipt -State $State
    foreach ($module in @('Experience', 'Prerequisites', 'Azure', 'Entra', 'Agent365', 'Database', 'Purview', 'Verification', 'PurviewPackage', 'PurviewExecutor')) {
        Import-Module (Join-Path $root "bootstrap/modules/$module.psm1") -Force -Global -DisableNameChecking
    }
    Set-BootstrapExecutionSourceRoot -Path $root
}

function Get-BootstrapHostSettingsReviewedFunctions {
    # Exact token digests for this one adapter/amendment generation. The parent
    # v1 review table above remains immutable. This table is review data, bound
    # with the complete current source by the operator's amendment fingerprint.
    return @{
        'bootstrap/modules/Common.psm1' = @{
            'Get-BootstrapAzureCliArguments' = @('a94ad3795a2342eb05265b2fefb3bfb32cb599dc9e88e2147349e04d944bff60', '384d90e28bdc487cf7ec642e32e9a2fbde24822317e891de6b0f9c8e064f63c3')
            'Get-BootstrapEffectiveDeploymentSourceFingerprint' = @('d525a94a44d55fbb7291aef2429ce98eef9001c5a4272c15342087e995618202', 'bcaa981f2b08d0ca9cd7cb70cf452b752a109f47af6dfdbca4e60559267cf87b')
            'Get-BootstrapAssetSourceRoot' = @('27498e5bf57ae3d97562075c242f73f179d64e160ae7cd0c45181fcb57b16ac1', '237cba526744a625d83c0215ed24b5ce3f568d1cf2114fdfe6f603cf96d6d621')
            'Assert-BootstrapStateAllowsSourcePlan' = @('89172212647ce1ceaca3b567d83f559dd45695156c79cbf05ee5f65099ecd043', 'b881d51c01f96e3008ac3629e2ffc1ecaeb80e1efce537829a7d23466811b60c')
        }
        'bootstrap/modules/PurviewExecutor.psm1' = @{
            'Get-PurviewExecutorArmSettings' = @('cfaceb933f08f337520acaf5942d2eac8e90677a7b296b590780e4c07002b83f', '167d036f9a6658c84db762691aa63212bfa59f9170bbd24d79a31f1effc7cbaf')
            'Invoke-PurviewExecutorDeployment' = @('b6db672324491a07cd6817f2267bd56c21ac171be04b8622db19f58715e20532', 'fa175a5a8c2badbb5860d8590819f489ad556dc18bbcdcd8933825013e0b641f')
            'Build-PurviewExecutorPublisher' = @('5cad39c303e0c8375138eb30d5a732f6874b7501cda5cec04f322f3e15831e3d', 'b1a06f6600b264ea38cf9f48fbabf17aa78f9ee993ba166cf27eeb74cc72282d')
            'Get-PurviewExecutorFreshContext' = @('205e50d51488ebe772f4e2c996cfc4ce6a9b680008ed3bf5d7ce8dfe28534190', 'dead75c81842bd48f401c36cedf5095b372cf62d869b80e1f63a4936587eebdc')
            'Install-BootstrapPurviewExecutor' = @('382c03a85aa5c3bfc14c17da0758c8511daa0a06b0a372a25510d7a4b072c33f', 'a308d756e395096c160a6d32b04e05eec1c384b7eb49743d9b359128baf5c10f')
            'Get-PurviewExecutorWorkerGrant' = @('82fd73e78403aba626a4da80293b54f55feaaf293d3e8ebdad25f2c89a47d0f8', '76002dc4ab030c8f1c3fc7e1ef175a5b1edcf87c8f81279b5f30ed356c0ba5a6')
        }
        'bootstrap/modules/PublisherRecovery.psm1' = @{
            'Get-BootstrapPublisherStableState' = @('d6ca319919119cf46e5ad4460e2d79763328400b0ec4b612478df7b699b34449', '220e15816a5df8394959056abe82493c72aa9e9d097a6c50e7425aebae044058')
            'Initialize-BootstrapPublisherRecoveryTooling' = @('8fa340f19fff49d145d7707a4b317202985eacefa390f404543bb81831442127', 'd175db5d26721b5f24059b657086934b0bde472d4976ba1a2da7a85c2aa93d8f')
            'Assert-BootstrapPublisherRecoveryPlan' = @('88beefeb65aea2a7ddd168a9b3fd2be1714151a1b6d158e5e0cece7d75b248ce', '15570640f4d9624f9946feaee99f9af8accdc9005c4acb1aa6d0c2ca47bd2ea4')
            'Assert-BootstrapPublisherRecoveryReceipt' = @('912d3aa65d7d02a288dd3138203ebdcb7d15ab42b73e5a9d8c8fd0c91fa7a4d8', '82cca0b24284f9f3d67b6c6e54c504c092b8d36ba6256497e03f6134de89178c')
            'Assert-BootstrapPublisherParentPlan' = @('', 'aab30e552a51f2ad4605f0f9a8c91c73e38fdc5c6fdc8cb1fd84c044ad98c531')
            'Assert-BootstrapPublisherParentReceipt' = @('', '75e890bef01e01fffdbd0955ab5aae6dcc82ce3998d44ea4511370f8dfad4823')
            'Get-BootstrapHostSettingsSourceSurface' = @('', '60450908023b0cd1213bff9865503339145827a491c5038648a9a6c742dd58c3')
            'Assert-BootstrapHostSettingsSourceDelta' = @('', '415101b8453570875f1a267f834a1b3b497538cc730fec69cc3fe86977efe4b7')
            'Assert-BootstrapHostSettingsEligibility' = @('', 'b3a4f6a8b111697e6b4c1f8fbe1e07b3b4dee883bc89eec682feb41686917cf2')
            'Assert-BootstrapHostSettingsPlan' = @('', '7f11b2fad857ddeada90b851d9407d937fba4c3f3d5eb25ee17fef497cad8b86')
            'Assert-BootstrapHostSettingsAmendment' = @('', '4d8b1d589ba1233bdad038dd82a2019c2d67de3dd3ed7a17bc1089be7c7694c8')
            'Get-BootstrapHostSettingsProof' = @('', 'ac18661a0381618227f2fb71cd3c5efebbee9ccb9de1ed8617df48af95e17b78')
            'Invoke-BootstrapHostSettingsAmendment' = @('', '7bb5bb8f6590864a2c9b4cdcdc657bf8a6304e148ec3d125580b47eef7b1db78')
        }
        'bootstrap/reconcile-publisher-metadata.ps1' = @{ '#script' = @('7fdff6d423d36fe0f6e6a765cb91e494f12dffa26bd090c08bb647bc3aee8cd0', '9f4441cd0130b863271c241459fdbc7d9633bc89fdf0a6972bec45db0a127be0') }
    }
}

function Get-BootstrapHostSettingsSourceSurface {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Functions, [switch]$Original)
    $text = [IO.File]::ReadAllText($Path)
    if ($Functions.Contains('#script')) {
        $expected = $Functions['#script'][[int](-not $Original)]
        if ((Get-BootstrapPublisherTokenFingerprint -Text $text) -cne $expected) {
            throw 'The amendment CLI differs from the exact reviewed command.'
        }
        return ''
    }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Host settings tooling cannot be parsed.' }
    $definitions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
    foreach ($name in $Functions.Keys) {
        $found = @($definitions | Where-Object Name -CEQ $name)
        $expected = $Functions[$name][[int](-not $Original)]
        if ($Original -and $expected -ceq '' -and $found.Count -eq 0) { continue }
        if ($found.Count -ne 1 -or (Get-BootstrapPublisherTokenFingerprint -Text $found[0].Extent.Text) -cne $expected) {
            throw 'Host settings tooling differs from the exact reviewed function.'
        }
    }
    $names = @($Functions.Keys)
    if ($Functions.Contains('Assert-BootstrapHostSettingsPlan')) { $names += 'Get-BootstrapHostSettingsReviewedFunctions' }
    $ranges = @($definitions | Where-Object { $_.Name -cin $names })
    $surface = [Collections.Generic.List[string]]::new()
    foreach ($token in $tokens) {
        if ($token.Kind -in @('Comment', 'NewLine', 'LineContinuation', 'EndOfInput')) { continue }
        $inside = $false
        foreach ($range in $ranges) {
            if ($token.Extent.StartOffset -ge $range.Extent.StartOffset -and
                $token.Extent.EndOffset -le $range.Extent.EndOffset) { $inside = $true; break }
        }
        if (-not $inside) { $surface.Add($token.Text) }
    }
    return $surface -join "`n"
}

function Assert-BootstrapHostSettingsSourceDelta {
    param([Parameter(Mandatory)][string]$ParentRoot, [Parameter(Mandatory)][string]$CandidateRoot)
    $parent = @{}; $candidate = @{}
    foreach ($entry in @(Get-BootstrapSourceManifest -Root $ParentRoot)) { $parent[$entry.path] = $entry.sha256 }
    foreach ($entry in @(Get-BootstrapSourceManifest -Root $CandidateRoot)) { $candidate[$entry.path] = $entry.sha256 }
    $allowed = Get-BootstrapHostSettingsReviewedFunctions
    $delta = [Collections.Generic.List[object]]::new()
    foreach ($path in @(@($parent.Keys) + @($candidate.Keys) | Sort-Object -Unique)) {
        if (-not $parent.ContainsKey($path) -or -not $candidate.ContainsKey($path)) {
            throw 'Host settings amendment cannot add or remove deployment source files.'
        }
        if ($parent[$path] -ceq $candidate[$path]) { continue }
        if (-not $allowed.Contains($path)) { throw 'Host settings amendment changed immutable assets or unrelated source.' }
        $a = Get-BootstrapHostSettingsSourceSurface -Path (Join-Path $ParentRoot $path) -Functions $allowed[$path] -Original
        $b = Get-BootstrapHostSettingsSourceSurface -Path (Join-Path $CandidateRoot $path) -Functions $allowed[$path]
        if ($a -cne $b) { throw 'Host settings amendment changed source outside its exact adapter and receipt glue.' }
        $delta.Add([ordered]@{ path = $path; original = $parent[$path]; corrected = $candidate[$path] })
    }
    if ($delta.Count -ne $allowed.Count) { throw 'The complete, distinct host settings amendment source is required.' }
    return ,@($delta)
}

function Assert-BootstrapHostSettingsEligibility {
    param([Parameter(Mandatory)][Collections.IDictionary]$State, [Parameter(Mandatory)]$Config)
    if ($State.Contains('hostSettingsAmendment')) { throw 'Use the existing exact completed host settings amendment.' }
    $null = Assert-BootstrapPublisherParentReceipt -State $State
    if ((Get-BootstrapConfigurationFingerprint -Config $Config) -cne [string]$State.configurationFingerprint -or
        $Config.purview.enabled -ne $true -or $State.steps.Count -ne 15 -or
        [string]$State.steps['Gateway runtime deployment'].status -cne 'Failed' -or
        $State.steps['Gateway runtime deployment'].Contains('evidence') -or
        [string]$State.freshPurviewExecutor.status -cne 'Installing') {
        throw 'Host settings amendment requires the exact post-publication failed runtime checkpoint.'
    }
    foreach ($name in @(Get-GatewayBootstrapStepNames)[0..13]) {
        if ([string]$State.steps[$name].status -cne 'Completed') { throw 'Host settings amendment prefix is incomplete.' }
    }
    $record = $State.freshPurviewExecutor
    $enableName = [string]$State.publisherMetadataReconciliation.plan.provider.enableName
    if ([string]$record.operations.publish.status -cne 'Completed' -or
        -not $record.Contains('publication') -or -not $record.operations.Contains($enableName) -or
        [string]$record.operations[$enableName].status -cne 'Completed') {
        throw 'Host settings amendment requires completed publication and host-enable operations; no replay is allowed.'
    }
}

function Assert-BootstrapHostSettingsPlan {
    param([Parameter(Mandatory)][Collections.IDictionary]$State, [Parameter(Mandatory)]$Amendment)
    $parentRoot = Assert-BootstrapPublisherParentReceipt -State $State
    Assert-PurviewPublisherObjectFields -Object $Amendment -Required @('plan', 'planFingerprint', 'executionSource') `
        -Optional @('status', 'completedAtUtc', 'completionFingerprint')
    $plan = $Amendment.plan
    $enableName = [string]$State.publisherMetadataReconciliation.plan.provider.enableName
    if ([string]$State.freshPurviewExecutor.operations.publish.status -cne 'Completed' -or
        -not $State.freshPurviewExecutor.operations.Contains($enableName) -or
        [string]$State.freshPurviewExecutor.operations[$enableName].status -cne 'Completed' -or
        -not $State.freshPurviewExecutor.Contains('publication')) {
        throw 'Host settings amendment cannot regress completed publication or host enablement.'
    }
    Assert-PurviewPublisherObjectFields -Object $plan -Required @('schemaVersion', 'kind', 'createdAtUtc',
        'parentReceiptFingerprint', 'parentSourceFingerprint', 'correctedSourceFingerprint', 'initialStateFingerprint',
        'operationsFingerprint', 'sourceDelta', 'provider')
    if ($plan.schemaVersion -ne 1 -or [string]$plan.kind -cne 'PublisherHostSettingsAmendment' -or
        [string]$Amendment.planFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $plan) -or
        [string]$plan.parentReceiptFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $State.publisherMetadataReconciliation) -or
        [string]$plan.parentSourceFingerprint -cne [string]$State.publisherMetadataReconciliation.plan.correctedSourceFingerprint -or
        [string]$plan.operationsFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $State.freshPurviewExecutor.operations) -or
        [string]$plan.correctedSourceFingerprint -cne (Get-BootstrapSourceFingerprint)) {
        throw 'Host settings amendment parent, operations, plan or current source changed.'
    }
    $expected = ".bootstrap/accepted-source/$($State.deploymentOwnershipId)/$(([string]$Amendment.planFingerprint).Substring(7))"
    if ([string]$Amendment.executionSource -cne $expected) { throw 'Host settings amendment snapshot owner or path changed.' }
    Assert-BootstrapSourcePathIsRegular -Root (Get-RepositoryRoot) -RelativePath $expected | Out-Null
    $root = Join-Path (Get-RepositoryRoot) $expected
    if ((Get-BootstrapSourceFingerprint -Root $root) -cne [string]$plan.correctedSourceFingerprint) {
        throw 'Host settings amendment snapshot changed.'
    }
    $delta = Assert-BootstrapHostSettingsSourceDelta -ParentRoot $parentRoot -CandidateRoot $root
    Assert-PurviewExecutorEqual -Actual $delta -Expected $plan.sourceDelta -Label 'host settings amendment source delta'
    Assert-PurviewExecutorEqual -Actual $plan.provider -Expected $State.publisherMetadataReconciliation.plan.provider `
        -Label 'host settings original provider binding'
    return $root
}

function Assert-BootstrapHostSettingsAmendment {
    param([Parameter(Mandatory)][Collections.IDictionary]$State)
    $amendment = $State.hostSettingsAmendment
    Assert-PurviewPublisherObjectFields -Object $amendment -Required @('plan', 'planFingerprint', 'executionSource',
        'status', 'completedAtUtc', 'completionFingerprint')
    if ([string]$amendment.status -cne 'Completed' -or [string]$amendment.completionFingerprint -cne
        (Get-BootstrapObjectFingerprint -InputObject @{
            planFingerprint = $amendment.planFingerprint; completedAtUtc = $amendment.completedAtUtc; status = 'Completed'
        })) { throw 'Host settings amendment is incomplete or changed.' }
    $time = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact([string]$amendment.completedAtUtc, 'O', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$time)) { throw 'Host settings amendment timestamp is invalid.' }
    return Assert-BootstrapHostSettingsPlan -State $State -Amendment $amendment
}

function Get-BootstrapHostSettingsProof {
    param([Parameter(Mandatory)][Collections.IDictionary]$State, [Parameter(Mandatory)]$Config)
    $identity = Get-BootstrapPublisherRecoveryIdentity -Config $Config
    $proof = Get-BootstrapPublisherRecoveryProviderState -State $State -Config $Config -AzureIdentity $identity `
        -Operator $State.publisherMetadataReconciliation.plan.operator
    Assert-PurviewExecutorEqual -Actual $proof -Expected $State.publisherMetadataReconciliation.plan.provider `
        -Label 'host settings original publication and enabled host'
    # The added completed operation is now part of this immutable prefix.
    # Re-read its exact record too; matching resources alone cannot hide a later
    # failed or replaced deployment under the original enable name.
    $parameters = Get-PurviewExecutorHostParameters -Config $Config `
        -Foundation $State.steps['Azure foundation'].evidence -Record $State.freshPurviewExecutor
    $parameters.enableRuntime = $true
    $deployment = Invoke-AzJson -Arguments @('deployment', 'group', 'show', '--subscription', $Config.subscriptionId,
        '--resource-group', $Config.resourceGroupName, '--name', $proof.enableName,
        '--query', '{state:properties.provisioningState,parameters:properties.parameters,outputs:properties.outputs}')
    if ([string]$deployment.state -cne 'Succeeded') { throw 'Original host-enable deployment is not Succeeded.' }
    Assert-GatewayExactReadableArmParameters -ActualParameters $deployment.parameters -ExpectedParameters $parameters | Out-Null
    Assert-PurviewExecutorEqual -Actual $deployment.outputs -Expected $State.freshPurviewExecutor.host -Label 'original host-enable deployment outputs'
    $package = Read-PurviewExecutorPackage -PackageDirectory $State.freshPurviewExecutor.packageDirectory `
        -ExpectedSourceFingerprint $State.acceptedPlan.sourceFingerprint
    Assert-PurviewExecutorEqual -Actual $package.receipt -Expected $State.freshPurviewExecutor.package.receipt -Label 'host settings original package'
    if ($package.receiptFingerprint -cne [string]$State.freshPurviewExecutor.package.receiptFingerprint) { throw 'Original package changed.' }
    return $proof
}

function Invoke-BootstrapHostSettingsAmendment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Plan', 'Execute')][string]$Mode,
        [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$StatePath,
        [string]$ExpectedPlanFingerprint = '', [switch]$Yes)
    if ($Mode -ceq 'Execute' -and (-not $Yes -or $ExpectedPlanFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$')) {
        throw 'Host settings amendment Execute requires Yes and the exact reviewed amendment fingerprint.'
    }
    if ([IO.Path]::GetFullPath($StatePath) -cne [IO.Path]::GetFullPath((Get-BootstrapStatePath -Config $Config)) -or
        -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { throw 'Original exact deployment state is required.' }
    $repository = Get-RepositoryRoot
    Assert-BootstrapSourcePathIsRegular -Root $repository -RelativePath ([IO.Path]::GetRelativePath($repository, $StatePath)) | Out-Null
    $lock = Enter-BootstrapLock -StatePath $StatePath
    try {
        $state = Read-BootstrapState -Path $StatePath -Config $Config
        if ((Get-BootstrapConfigurationFingerprint -Config $Config) -cne [string]$state.configurationFingerprint) {
            throw 'Host settings amendment configuration changed.'
        }
        $rawHash = (Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash
        $completed = $state.Contains('hostSettingsAmendment')
        if ($completed) { $null = Assert-BootstrapHostSettingsAmendment -State $state }
        else { Assert-BootstrapHostSettingsEligibility -State $state -Config $Config }
        $planPath = Join-Path $repository ".bootstrap/publisher-host-settings-amendment/$($state.deploymentOwnershipId)/plan.json"
        Assert-BootstrapSourcePathIsRegular -Root $repository -RelativePath ([IO.Path]::GetRelativePath($repository, $planPath)) | Out-Null
        $amendment = $null
        if ($completed) { $amendment = $state.hostSettingsAmendment }
        elseif (Test-Path -LiteralPath $planPath -PathType Leaf) {
            $amendment = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json -AsHashtable -Depth 100
            Convert-BootstrapParsedJsonDatesToStrings -Value $amendment
        }
        elseif ($Mode -ceq 'Execute') { throw 'A separately reviewed host settings amendment Plan is required.' }
        if ($null -eq $amendment) {
            $parentRoot = Assert-BootstrapPublisherParentReceipt -State $state
            $delta = Assert-BootstrapHostSettingsSourceDelta -ParentRoot $parentRoot -CandidateRoot $repository
            $proof = Get-BootstrapHostSettingsProof -State $state -Config $Config
            $plan = ConvertTo-BootstrapCanonicalValue -Value @{
                schemaVersion = 1; kind = 'PublisherHostSettingsAmendment'; createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                parentReceiptFingerprint = Get-BootstrapObjectFingerprint -InputObject $state.publisherMetadataReconciliation
                parentSourceFingerprint = $state.publisherMetadataReconciliation.plan.correctedSourceFingerprint
                correctedSourceFingerprint = Get-BootstrapSourceFingerprint
                initialStateFingerprint = Get-BootstrapObjectFingerprint -InputObject $state
                operationsFingerprint = Get-BootstrapObjectFingerprint -InputObject $state.freshPurviewExecutor.operations
                sourceDelta = $delta; provider = $proof
            }
            $fingerprint = Get-BootstrapObjectFingerprint -InputObject $plan
            $snapshot = New-BootstrapAcceptedSourceSnapshot -State $state -PlanFingerprint $fingerprint -SourceFingerprint $plan.correctedSourceFingerprint
            $amendment = [ordered]@{ plan = $plan; planFingerprint = $fingerprint; executionSource = $snapshot }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $planPath)) | Out-Null
            Write-BootstrapPublisherRecoveryJson -Path $planPath -Value $amendment
        }
        if ($Mode -ceq 'Execute' -and $ExpectedPlanFingerprint -cne [string]$amendment.planFingerprint) {
            throw 'Host settings amendment approval fingerprint does not match.'
        }
        $null = Assert-BootstrapHostSettingsPlan -State $state -Amendment $amendment
        if (-not $completed -and (Get-BootstrapObjectFingerprint -InputObject $state) -cne [string]$amendment.plan.initialStateFingerprint) {
            throw 'Original forward state changed after host settings Plan.'
        }
        $null = Get-BootstrapHostSettingsProof -State $state -Config $Config
        if ($Mode -ceq 'Execute' -and -not $completed) {
            $amendment.status = 'Completed'
            $amendment.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            $amendment.completionFingerprint = Get-BootstrapObjectFingerprint -InputObject @{
                planFingerprint = $amendment.planFingerprint; completedAtUtc = $amendment.completedAtUtc; status = 'Completed'
            }
            $state.hostSettingsAmendment = $amendment
            $null = Assert-BootstrapHostSettingsAmendment -State $state
            if ((Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash -cne $rawHash) { throw 'Original state changed while locked.' }
            Write-BootstrapPublisherRecoveryJson -Path $StatePath -Value $state -Replace
            $completed = $true
        }
        return [ordered]@{ status = if ($completed) { 'Completed' } else { 'ReviewedReadOnly' }
            planFingerprint = $amendment.planFingerprint; planPath = $planPath
            correctedSourceFingerprint = $amendment.plan.correctedSourceFingerprint
            providerMutations = 0; stageReconciliation = 'NormalResumeOnly' }
    }
    finally { $lock.Dispose() }
}

function Write-BootstrapPublisherRecoveryJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [switch]$Replace)
    $repository = Get-RepositoryRoot
    Assert-BootstrapSourcePathIsRegular -Root $repository -RelativePath ([IO.Path]::GetRelativePath($repository, $Path)) | Out-Null
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $stream = [IO.File]::Open($temporary, 'CreateNew', 'Write', 'None')
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Value -Depth 100))
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        if ($Replace) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Invoke-BootstrapPublisherMetadataReconciliation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Plan', 'Execute')][string]$Mode,
        [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$StatePath,
        [string]$ExpectedPlanFingerprint = '', [switch]$Yes)
    if ($Mode -ceq 'Execute' -and (-not $Yes -or $ExpectedPlanFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$')) {
        throw 'Publisher reconciliation Execute requires Yes and the exact reviewed plan fingerprint.'
    }
    $expectedStatePath = Get-BootstrapStatePath -Config $Config
    if ([IO.Path]::GetFullPath($StatePath) -cne [IO.Path]::GetFullPath($expectedStatePath) -or
        -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { throw 'The original exact deployment state is required.' }
    Assert-BootstrapSourcePathIsRegular -Root (Get-RepositoryRoot) `
        -RelativePath ([IO.Path]::GetRelativePath((Get-RepositoryRoot), $StatePath)) | Out-Null
    $lock = Enter-BootstrapLock -StatePath $StatePath
    try {
        $state = Read-BootstrapState -Path $StatePath -Config $Config
        $rawHash = (Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash
        $completed = $state.Contains('publisherMetadataReconciliation')
        $planPath = Join-Path (Get-RepositoryRoot) ".bootstrap/publisher-metadata-reconciliation/$($state.deploymentOwnershipId)/plan.json"
        Assert-BootstrapSourcePathIsRegular -Root (Get-RepositoryRoot) `
            -RelativePath ([IO.Path]::GetRelativePath((Get-RepositoryRoot), $planPath)) | Out-Null
        if ($completed) { $recovery = $state.publisherMetadataReconciliation }
        elseif (Test-Path -LiteralPath $planPath -PathType Leaf) {
            $recovery = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json -AsHashtable -Depth 100
            Convert-BootstrapParsedJsonDatesToStrings -Value $recovery
        }
        elseif ($Mode -ceq 'Execute') { throw 'Publisher reconciliation requires a separately reviewed Plan.' }
        else { $recovery = $null }
        if ($null -ne $recovery -and $Mode -ceq 'Execute' -and $ExpectedPlanFingerprint -cne [string]$recovery.planFingerprint) {
            throw 'Publisher reconciliation approval fingerprint does not match.'
        }
        if ($completed) { $null = Assert-BootstrapPublisherRecoveryReceipt -State $state }
        else { Assert-BootstrapPublisherRecoveryEligibility -State $state -Config $Config }
        $identity = Get-BootstrapPublisherRecoveryIdentity -Config $Config
        if ($null -eq $recovery) {
            $recovery = New-BootstrapPublisherRecoveryPlan -State $state -Config $Config -AzureIdentity $identity
            [IO.Directory]::CreateDirectory((Split-Path -Parent $planPath)) | Out-Null
            Write-BootstrapPublisherRecoveryJson -Path $planPath -Value $recovery
        }
        $snapshot = Assert-BootstrapPublisherRecoveryPlan -State $state -Recovery $recovery
        if (-not $completed -and (Get-BootstrapObjectFingerprint -InputObject $state) -cne [string]$recovery.plan.initialStateFingerprint) {
            throw 'Publisher reconciliation original state changed since Plan.'
        }
        $provider = Get-BootstrapPublisherRecoveryProviderState -State $state -Config $Config -AzureIdentity $identity -Operator $recovery.plan.operator
        Assert-PurviewExecutorEqual -Actual $provider -Expected $recovery.plan.provider -Label 'publisher reviewed provider evidence'
        $package = Read-PurviewExecutorPackage -PackageDirectory $state.freshPurviewExecutor.packageDirectory `
            -ExpectedSourceFingerprint $state.acceptedPlan.sourceFingerprint
        Assert-PurviewExecutorEqual -Actual $package.receipt -Expected $state.freshPurviewExecutor.package.receipt -Label 'publisher original package'
        if ($package.receiptFingerprint -cne [string]$state.freshPurviewExecutor.package.receiptFingerprint) { throw 'Publisher package receipt changed.' }
        if ($Mode -ceq 'Execute' -and -not $completed) {
            $recovery.status = 'Completed'
            $recovery.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            $recovery.completionFingerprint = Get-BootstrapObjectFingerprint -InputObject @{
                planFingerprint = $recovery.planFingerprint; completedAtUtc = $recovery.completedAtUtc; status = 'Completed'
            }
            $state.publisherMetadataReconciliation = $recovery
            $null = Assert-BootstrapPublisherRecoveryReceipt -State $state
            if ((Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash -cne $rawHash) { throw 'Publisher state changed while locked.' }
            # Deliberately not Save-BootstrapState: only the separate receipt is
            # added. Do not alter updatedAt/source/failed step/publish Started.
            Write-BootstrapPublisherRecoveryJson -Path $StatePath -Value $state -Replace
            $completed = $true
        }
        return [ordered]@{ status = if ($completed) { 'Completed' } else { 'ReviewedReadOnly' }
            planFingerprint = $recovery.planFingerprint; planPath = $planPath
            correctedSourceFingerprint = $recovery.plan.correctedSourceFingerprint
            providerMutations = 0; stageReconciliation = 'NormalResumeOnly' }
    }
    finally { $lock.Dispose() }
}
