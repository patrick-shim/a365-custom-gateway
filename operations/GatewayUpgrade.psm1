#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ToolingRoot = Split-Path -Parent $PSScriptRoot
$script:Stages = @('ContentSafety', 'PurviewPrerequisites', 'PurviewExecutor', 'DatabaseExpand', 'Worker', 'Api', 'Admin', 'Acceptance')
$script:Blockers = @(
    'FullMutationOrchestrationNotIntegrated', 'PurviewExactScopeAndAuthorityNotBound',
    'PrivateSqlUpgradeExecutorAndManifestCompatibilityNotVerified',
    'VersionedCapabilityTransitionNotIntegrated',
    'SourceBuildClosureNotVerified', 'ImmutableArtifactSourceProvenanceNotVerified', 'BackupRestoreAndRegistrationPreservationEvidenceRequired',
    'ExactProviderWhatIfNotPerformed', 'IndependentCandidateReviewAndExactPlanApprovalRequired'
)
$script:RequiredSteps = @(
    'Prerequisites', 'Azure authentication', 'Azure provider registration', 'Azure foundation',
    'Gateway API identity', 'Immutable workload images', 'Inert identity deployment',
    'Agent 365 seed blueprint', 'Workflow v3 Entra configuration', 'SQL private endpoint',
    'Gateway database', 'Admin UI identity', 'Admin UI Key Vault credential',
    'Purview capability prerequisites', 'Gateway runtime deployment', 'Admin UI deployment',
    'Admin UI redirect URIs', 'Network hardening', 'End-to-end deployment verification'
)

function Assert-GatewayUpgradeShape {
    param($Value, [string[]]$Keys, [string]$Label)
    if ($Value -isnot [Collections.IDictionary]) { throw "UpgradeContract: $Label must be an object." }
    $actual = @($Value.Keys)
    if ($actual.Count -ne $Keys.Count -or @($actual | Where-Object { $_ -cnotin $Keys }).Count) {
        throw "UpgradeContract: $Label has missing or unsupported fields."
    }
}

function Assert-GatewayUpgradeHash {
    param($Value)
    if ($Value -isnot [string] -or $Value -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'UpgradeContract: a canonical SHA-256 fingerprint is required.'
    }
}

function Assert-GatewayUpgradeGuid {
    param($Value)
    $parsed = [guid]::Empty
    if ($Value -isnot [string] -or -not [guid]::TryParseExact($Value, 'D', [ref]$parsed) -or
        $parsed -eq [guid]::Empty -or $Value -cne $parsed.ToString('D')) {
        throw 'UpgradeContract: a canonical nonempty GUID is required.'
    }
}

function ConvertTo-GatewayUpgradeCanonical {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    # PowerShell path results can be ETS-wrapped strings. Preserve their scalar
    # value before considering custom objects, or only their Length is hashed.
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal]) { return $Value }
    if ($Value -is [double] -and -not [double]::IsNaN($Value) -and -not [double]::IsInfinity($Value)) { return $Value }
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime().ToString('O') }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('O') }
    if ($Value -is [Collections.IDictionary]) {
        [string[]]$keys = @($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $result = [ordered]@{}
        foreach ($key in $keys) { $result[$key] = ConvertTo-GatewayUpgradeCanonical $Value[$key] }
        return $result
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        # ConvertFrom-Json -NoEnumerate can decorate arrays with ETS metadata.
        # Hash the ordered elements, not the collection object's properties.
        $items = @($Value | ForEach-Object { ConvertTo-GatewayUpgradeCanonical $_ })
        return ,$items
    }
    if ($Value -is [pscustomobject]) {
        $object = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $object[$property.Name] = $property.Value }
        return ConvertTo-GatewayUpgradeCanonical $object
    }
    throw 'UpgradeContract: unsupported canonical value type.'
}

function ConvertTo-GatewayUpgradeCanonicalJson {
    param([Parameter(Mandatory)]$Value)
    return ConvertTo-Json -InputObject (ConvertTo-GatewayUpgradeCanonical $Value) -Depth 100 -Compress
}

function Get-GatewayUpgradeFingerprint {
    param([Parameter(Mandatory)]$Value)
    $json = ConvertTo-GatewayUpgradeCanonicalJson $Value
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $hash = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)) }
    finally { $algorithm.Dispose() }
    return 'sha256:' + [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
}

function Get-GatewayUpgradeFileHash {
    param([Parameter(Mandatory)][string]$Path)
    return 'sha256:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertFrom-GatewayUpgradeJsonElement {
    param([System.Text.Json.JsonElement]$Element, [int]$Depth = 0)
    if ($Depth -gt 64) { throw 'UpgradeContract: JSON nesting limit exceeded.' }
    switch ([string]$Element.ValueKind) {
        Object {
            $result = [ordered]@{}
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $seen.Add($property.Name)) { throw 'UpgradeContract: duplicate JSON property.' }
                $result[$property.Name] = ConvertFrom-GatewayUpgradeJsonElement $property.Value ($Depth + 1)
            }
            return $result
        }
        Array {
            $items = @($Element.EnumerateArray() | ForEach-Object {
                ConvertFrom-GatewayUpgradeJsonElement $_ ($Depth + 1)
            })
            return ,$items
        }
        String { return $Element.GetString() }
        Number {
            $number = 0L
            if ($Element.TryGetInt64([ref]$number)) { return $number }
            $decimal = 0D
            if ($Element.TryGetDecimal([ref]$decimal)) { return $decimal }
            throw 'UpgradeContract: unsupported numeric range.'
        }
        True { return $true }
        False { return $false }
        Null { return $null }
        default { throw 'UpgradeContract: unsupported JSON value.' }
    }
}

function Read-GatewayUpgradeJson {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -gt 8388608 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'UpgradeContract: invalid or oversized input file.'
    }
    $document = $null
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($item.FullName))
        $document = [System.Text.Json.JsonDocument]::Parse($text.TrimStart([char]0xfeff))
        return ConvertFrom-GatewayUpgradeJsonElement $document.RootElement
    }
    catch { throw 'UpgradeContract: input JSON is invalid, duplicated, or unsupported; content suppressed.' }
    finally { if ($null -ne $document) { $document.Dispose() } }
}

function Resolve-GatewayUpgradeFile {
    param([string]$Root, [string]$RelativePath)
    if ($RelativePath -cnotmatch '^[A-Za-z0-9_.-]+(?:\\[A-Za-z0-9_.-]+)*$' -or
        @($RelativePath.Split('\') | Where-Object { $_ -in @('.', '..') }).Count) {
        throw 'UpgradeContract: invalid relative source path.'
    }
    $current = [IO.Path]::GetFullPath($Root)
    foreach ($segment in $RelativePath.Split('\')) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'UpgradeContract: source links are not allowed.'
        }
    }
    if ((Get-Item -LiteralPath $current).PSIsContainer) { throw 'UpgradeContract: a source file is required.' }
    return $current
}

function Get-GatewayUpgradeSourceManifest {
    param([Parameter(Mandatory)][string]$Root)
    $rootPath = [IO.Path]::GetFullPath($Root)
    if ((Get-Item -LiteralPath $rootPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'UpgradeContract: source root links are not allowed.'
    }
    $entries = [Collections.Generic.List[object]]::new()
    $roots = @('src', 'tools', 'bootstrap', 'infrastructure', 'operations', 'tests')
    $rootFiles = @('Directory.Build.props', 'global.json', 'nuget.config', '.dockerignore', 'VERSION', 'gateway', 'gateway.cmd')
    foreach ($directory in $roots) {
        $path = Join-Path $rootPath $directory
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'UpgradeContract: source directory links are not allowed.'
        }
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($path)
        while ($pending.Count) {
            foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
                $relative = [IO.Path]::GetRelativePath($rootPath, $item.FullName).Replace('/', '\')
                if ($relative -match '(?:^|\\)(?:bin|obj|node_modules|\.git|\.bootstrap|\.test-work|\.secrets?)(?:\\|$)' -or
                    $relative -match '^bootstrap\\config(?:\.[^\\]+)?\.json$' -or
                    $relative -match '(?:^|\\)\.env(?:\.|$)') { continue }
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'UpgradeContract: source links are not allowed.' }
                if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
                if ($item.Extension -notin @('.cs', '.csproj', '.sln', '.slnx', '.props', '.targets', '.razor', '.cshtml',
                        '.css', '.js', '.mjs', '.ts', '.tsx', '.json', '.sql', '.bicep', '.bicepparam',
                        '.ps1', '.psm1', '.psd1', '.sh', '.cmd', '.html', '.svg', '.md') -and $item.Name -cne 'Dockerfile') { continue }
                $file = Resolve-GatewayUpgradeFile $rootPath $relative
                $entries.Add([ordered]@{ path = $relative; sha256 = Get-GatewayUpgradeFileHash $file })
            }
        }
    }
    foreach ($relative in $rootFiles) {
        if (Test-Path -LiteralPath (Join-Path $rootPath $relative) -PathType Leaf) {
            $entries.Add([ordered]@{ path = $relative; sha256 = Get-GatewayUpgradeFileHash (Resolve-GatewayUpgradeFile $rootPath $relative) })
        }
    }
    if (-not $entries.Count) { throw 'UpgradeContract: candidate source is empty.' }
    $sorted = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $entries) { $sorted.Add($entry.path, $entry) }
    return @($sorted.Values)
}

function Assert-GatewayUpgradeRequest {
    param([Parameter(Mandatory)]$Request)
    $keys = @('schemaVersion', 'releaseId', 'target', 'capabilities', 'images', 'database', 'acknowledgeHistoricalVerificationFailure')
    if ($Request.schemaVersion -eq 2) { $keys += 'mode' }
    Assert-GatewayUpgradeShape $Request $keys 'request'
    if ($Request.schemaVersion -isnot [long] -and $Request.schemaVersion -isnot [int]) { throw 'UpgradeContract: schemaVersion must be an integer.' }
    if ($Request.schemaVersion -notin @(1, 2) -or
        ($Request.schemaVersion -eq 2 -and $Request.mode -cne 'SourceOnlyFull') -or $Request.releaseId -isnot [string] -or
        $Request.releaseId -cnotmatch '^[a-z][a-z0-9-]{2,19}$' -or
        $Request.acknowledgeHistoricalVerificationFailure -isnot [bool]) { throw 'UpgradeContract: unsupported request version or release.' }
    $target = $Request.target
    Assert-GatewayUpgradeShape $target @('subscriptionId', 'tenantId', 'resourceGroupName', 'location', 'projectName', 'environment', 'deploymentOwnershipId') 'target'
    foreach ($value in $target.Values) {
        if ($value -isnot [string]) { throw 'UpgradeContract: target fields must be strings.' }
    }
    foreach ($name in @('subscriptionId', 'tenantId', 'deploymentOwnershipId')) { Assert-GatewayUpgradeGuid $target[$name] }
    if ($target.projectName -cnotmatch '^[a-z][a-z0-9]{1,7}$' -or $target.environment -cnotin @('dev', 'staging', 'prod') -or
        $target.location -cnotmatch '^[a-z][a-z0-9]{1,31}$' -or
        $target.resourceGroupName -cne "rg-$($target.projectName)-$($target.environment)") {
        throw 'UpgradeContract: target must be the exact conventional existing deployment.'
    }
    Assert-GatewayUpgradeShape $Request.capabilities @('promptShields', 'purview') 'capabilities'
    Assert-GatewayUpgradeShape $Request.capabilities.promptShields @('enabled', 'sku', 'acceptPaidUsage') 'promptShields'
    Assert-GatewayUpgradeShape $Request.capabilities.purview @('enabled', 'executorSku', 'acceptPaidHosting') 'purview'
    $shields = $Request.capabilities.promptShields
    $purview = $Request.capabilities.purview
    $sourceOnly = $Request.schemaVersion -eq 2
    if ($shields.enabled -isnot [bool] -or $shields.enabled -ne $true -or
        ($sourceOnly -and $shields.sku -cnotin @('F0', 'S0')) -or (-not $sourceOnly -and $shields.sku -cne 'S0') -or
        $shields.acceptPaidUsage -isnot [bool] -or $shields.acceptPaidUsage -ne ($shields.sku -ceq 'S0') -or
        $purview.enabled -isnot [bool] -or $purview.enabled -ne $true -or $purview.executorSku -cnotin @('B1','B2') -or
        $purview.acceptPaidHosting -isnot [bool] -or $purview.acceptPaidHosting -ne $true) {
        throw 'UpgradeContract: this review requires explicitly acknowledged S0 Prompt Shields and the selected Windows B1/B2 Purview plan.'
    }
    Assert-GatewayUpgradeShape $Request.images @('api', 'worker', 'adminUi', 'databaseMigrator') 'images'
    foreach ($image in $Request.images.Values) {
        if ($image -isnot [string] -or ($image -cne '' -and $image -cnotmatch '^[a-z0-9]+\.azurecr\.io/gateway-(?:api|worker|admin|db-migrator)@sha256:[0-9a-f]{64}$')) {
            throw 'UpgradeContract: images must be empty (blocked) or immutable ACR digests.'
        }
    }
    $database = $Request.database
    $databaseKeys = @('name', 'currentSchemaFingerprint', 'targetSchemaFingerprint', 'scripts', 'rollbackStrategy')
    if ($database -is [Collections.IDictionary] -and $database.Contains('targetModelFingerprint')) {
        $databaseKeys += 'targetModelFingerprint'
        Assert-GatewayUpgradeHash $database.targetModelFingerprint
    }
    Assert-GatewayUpgradeShape $database $databaseKeys 'database'
    if ($database.name -cne 'GatewayDb' -or $database.rollbackStrategy -cne 'RetainExpandedSchema') {
        throw 'UpgradeContract: database replacement and destructive rollback are forbidden.'
    }
    Assert-GatewayUpgradeHash $database.currentSchemaFingerprint
    if ($database.targetSchemaFingerprint -cne '') { Assert-GatewayUpgradeHash $database.targetSchemaFingerprint }
    elseif (-not $database.Contains('targetModelFingerprint')) {
        throw 'UpgradeContract: an unknown physical target fingerprint requires an exact approved EF-model fingerprint.'
    }
    if ($database.scripts -isnot [array] -or $database.scripts.Count -gt 32) { throw 'UpgradeContract: invalid SQL manifest.' }
    if (($database.scripts.Count -eq 0) -ne ($database.currentSchemaFingerprint -ceq $database.targetSchemaFingerprint)) {
        throw 'UpgradeContract: changed schema requires a nonempty additive SQL manifest.'
    }
    if ($sourceOnly -and ($Request.acknowledgeHistoricalVerificationFailure -ne $false -or
        $database.scripts.Count -ne 0 -or -not $database.Contains('targetModelFingerprint'))) {
        throw 'UpgradeContract: SourceOnlyFull requires a verified Full baseline, exact target model and unchanged physical schema with no SQL scripts.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $previous = ''
    foreach ($entry in $database.scripts) {
        Assert-GatewayUpgradeShape $entry @('path', 'sha256', 'classification') 'SQL script'
        if ($entry.path -cnotmatch '^infrastructure\\sql\\[0-9]{8}_[a-z0-9_]+\.sql$' -or
            $entry.classification -cne 'Additive' -or -not $seen.Add($entry.path) -or
            [StringComparer]::Ordinal.Compare($previous, $entry.path) -ge 0) {
            throw 'UpgradeContract: SQL paths must be unique, ordered, checked-in additive scripts.'
        }
        Assert-GatewayUpgradeHash $entry.sha256
        $previous = $entry.path
    }
}

function Read-GatewayUpgradeBaselineInputs {
    param([string]$StatePath, [string]$ConfigPath, $Request)
    Assert-GatewayUpgradeRequest $Request
    $stateHash = Get-GatewayUpgradeFileHash $StatePath
    $configHash = Get-GatewayUpgradeFileHash $ConfigPath
    $state = Read-GatewayUpgradeJson $StatePath
    $config = Read-GatewayUpgradeJson $ConfigPath
    if ((Get-GatewayUpgradeFileHash $StatePath) -cne $stateHash -or
        (Get-GatewayUpgradeFileHash $ConfigPath) -cne $configHash) {
        throw 'UpgradeBaseline: original input files changed while being read.'
    }
    foreach ($name in @('subscriptionId', 'tenantId', 'resourceGroupName', 'projectName', 'environment', 'location')) {
        if ([string]$state.configuration[$name] -cne [string]$Request.target[$name] -or
            [string]$config[$name] -cne [string]$Request.target[$name]) {
            throw 'UpgradeBaseline: state/configuration/request target mismatch.'
        }
    }
    if ([string]$state.deploymentOwnershipId -cne $Request.target.deploymentOwnershipId -or
        $state.acceptedPlan -isnot [Collections.IDictionary]) { throw 'UpgradeBaseline: accepted ownership proof is missing.' }
    foreach ($key in @('sourceFingerprint', 'planFingerprint', 'configurationFingerprint')) {
        Assert-GatewayUpgradeHash $state.acceptedPlan[$key]
    }
    if ($state.configurationFingerprint -cne $state.acceptedPlan.configurationFingerprint) {
        throw 'UpgradeBaseline: accepted configuration binding changed.'
    }
    if ($state.steps.Count -ne $script:RequiredSteps.Count) { throw 'UpgradeBaseline: unsupported bootstrap stage set.' }
    foreach ($step in $script:RequiredSteps) {
        if (-not $state.steps.Contains($step) -or $state.steps[$step].evidence -isnot [Collections.IDictionary]) {
            throw 'UpgradeBaseline: required original evidence is missing.'
        }
        $status = [string]$state.steps[$step].status
        if ($step -ceq 'End-to-end deployment verification') {
            if ($status -cnotin @('Completed', 'Failed') -or
                ($status -ceq 'Failed' -and -not $Request.acknowledgeHistoricalVerificationFailure)) {
                throw 'UpgradeBaseline: historical verification failure must be explicitly acknowledged.'
            }
        }
        elseif ($status -cne 'Completed') { throw 'UpgradeBaseline: an unfinished installation cannot be upgraded.' }
    }
    if ($Request.schemaVersion -eq 2) {
        Assert-GatewayUpgradeFullBaseline $Request $state $config
    }
    elseif ($config.promptShield.enabled -isnot [bool] -or $config.purview.enabled -isnot [bool] -or
        $config.promptShield.enabled -ne $false -or $config.purview.enabled -ne $false) {
        throw 'UpgradeBaseline: request v1 supports only an existing Core capability baseline.'
    }
    if ($state.steps['Gateway database'].evidence.schemaFingerprint -cne $Request.database.currentSchemaFingerprint) {
        throw 'UpgradeBaseline: current schema does not match original database evidence.'
    }
    $unsupported = @('databaseRecoveryPlan', 'manualDatabaseRepairPlan')
    if ($Request.schemaVersion -eq 1) { $unsupported += 'freshPurviewExecutor' }
    foreach ($name in $unsupported) {
        if ($state.Contains($name)) { throw 'UpgradeBaseline: this baseline variant is not implemented; retained evidence was not reinterpreted.' }
    }
    return @{
        state = $state; config = $config
        statePath = [IO.Path]::GetFullPath($StatePath); configPath = [IO.Path]::GetFullPath($ConfigPath)
        stateSha256 = $stateHash; configSha256 = $configHash
    }
}

function Assert-GatewayUpgradeFullBaseline {
        param($Request, $State, $Config)
        $allowedState = @('acceptedPlan', 'bootstrapVersion', 'configuration', 'configurationFingerprint', 'createdAtUtc',
            'deploymentKey', 'deploymentOwnershipId', 'freshPurviewExecutor', 'outputs', 'schemaVersion', 'source', 'steps', 'updatedAtUtc')
        if (@($State.Keys | Where-Object { $_ -cnotin $allowedState }).Count) {
            throw 'UpgradeBaseline: SourceOnlyFull does not reinterpret recovery, repair or other unsupported state variants.'
        }
        Import-Module (Join-Path $script:ToolingRoot 'bootstrap\modules\Common.psm1') -DisableNameChecking
        if ((Get-BootstrapConfigurationFingerprint $Config) -cne $State.acceptedPlan.configurationFingerprint) {
            throw 'UpgradeBaseline: current configuration does not match the original accepted configuration fingerprint.'
        }
        $runtime = $State.steps['Gateway runtime deployment'].evidence
        $capabilities = $State.steps['Purview capability prerequisites'].evidence
        $fresh = $State.freshPurviewExecutor
        $verification = $State.steps['End-to-end deployment verification']
        if ($Config.promptShield.enabled -isnot [bool] -or $Config.promptShield.enabled -ne $true -or
            $Config.purview.enabled -isnot [bool] -or $Config.purview.enabled -ne $true -or
            $Config.promptShield.skuName -cne $Request.capabilities.promptShields.sku -or
            $verification.status -cne 'Completed' -or $verification.evidence.deploymentVerification -cne 'Passed' -or
            $verification.evidence.promptShield -cne 'Passed' -or $verification.evidence.purviewCapability -cne 'Installed' -or
            $capabilities.enabled -ne $true -or $capabilities.promptShields.status -cne 'Installed' -or
            $capabilities.purview.status -cne 'Installed' -or $fresh.schemaVersion -ne 1 -or $fresh.status -cne 'Installed') {
            throw 'UpgradeBaseline: SourceOnlyFull requires an exact independently verified Full fresh-executor baseline and unchanged SKUs.'
        }
        foreach ($key in @('deploymentOwnershipId', 'sourceFingerprint', 'configurationFingerprint', 'planFingerprint')) {
            $expected = if ($key -ceq 'deploymentOwnershipId') { $State.deploymentOwnershipId } else { $State.acceptedPlan[$key] }
            if ($fresh.context[$key] -cne $expected) { throw 'UpgradeBaseline: fresh executor ownership/source/accepted-plan binding differs.' }
        }
        foreach ($key in @('tenantId', 'subscriptionId', 'resourceGroupName')) {
            if ($fresh.context[$key] -cne $Request.target[$key]) { throw 'UpgradeBaseline: fresh executor target differs.' }
        }
        foreach ($step in @('Azure foundation', 'Gateway runtime deployment', 'Purview capability prerequisites')) {
            $evidence = $State.steps[$step].evidence
            if ($evidence.deploymentOwnershipId -cne $State.deploymentOwnershipId -or
                $evidence.sourceFingerprint -cne $State.acceptedPlan.sourceFingerprint) {
                throw 'UpgradeBaseline: required Full evidence is not owned by the original accepted source.'
            }
        }
        $binding = $fresh.host.executorBinding.value
        if ($fresh.host.executorPlanSku.value -cne $Request.capabilities.purview.executorSku -or
            $binding.DeploymentOwnershipId -cne $State.deploymentOwnershipId -or $binding.TenantId -cne $Request.target.tenantId -or
            $fresh.package.receipt.sourceFingerprint -cne $State.acceptedPlan.sourceFingerprint -or
            $binding.BootstrapSourceFingerprint -cne $State.acceptedPlan.sourceFingerprint -or
            $binding.ExecutionSourceFingerprint -cne $State.acceptedPlan.sourceFingerprint -or
            $binding.PackageDigest -cne $fresh.package.receipt.packageDigest -or
            $binding.ExecutorPrincipalId -cne $fresh.host.executorPrincipalId.value -or
            $binding.ExecutorApplicationId -cne $fresh.identity.applicationId -or
            $binding.GatewayApiPrincipalId -cne $runtime.apiPrincipalId -or
            $binding.GatewayWorkerPrincipalId -cne $runtime.workerPrincipalId -or
            $fresh.context.apiPrincipalId -cne $runtime.apiPrincipalId -or $fresh.context.workerPrincipalId -cne $runtime.workerPrincipalId -or
            $binding.CallerApplicationId -cne $State.steps['Gateway database'].evidence.workerPrincipalClientId -or
            $binding.RuntimePrincipalId -cne $runtime.purviewRuntimeIdentityPrincipalId -or
            $binding.RuntimeClientId -cne $runtime.purviewRuntimeIdentityClientId -or
            $binding.RuntimePrincipalId -cne $fresh.context.runtimePrincipalId -or $binding.RuntimeClientId -cne $fresh.context.runtimeClientId -or
            $binding.AutomationApplicationId -cne $capabilities.purview.automationApplicationId -or
            $binding.AutomationServicePrincipalObjectId -cne $capabilities.purview.automationServicePrincipalObjectId -or
            $binding.CertificateSecretUri -cne $capabilities.purview.certificateSecretUri -or
            $runtime.promptShieldAccountId -cne $capabilities.promptShields.contentSafetyAccountResourceId -or
            $runtime.promptShieldEndpoint -cne $capabilities.promptShields.contentSafetyEndpoint) {
            throw 'UpgradeBaseline: installed capability identity, package, endpoint, certificate or SKU differs.'
        }
        foreach ($operation in $fresh.operations.Values) {
            if ($operation.status -cne 'Completed') { throw 'UpgradeBaseline: fresh executor has unfinished operations.' }
            Assert-GatewayUpgradeHash $operation.intentFingerprint
            Assert-GatewayUpgradeHash $operation.evidenceFingerprint
        }
        foreach ($operation in @('application', 'audience', 'principal', 'invokeRole', 'publisherImage', 'publish',
            "a365gw-$($Config.projectName)-executor-host-$($Config.environment)",
            "a365gw-$($Config.projectName)-executor-publisher-$($Config.environment)",
            "a365gw-$($Config.projectName)-executor-enable-$($Config.environment)")) {
            if (-not $fresh.operations.Contains($operation)) { throw 'UpgradeBaseline: completed fresh executor evidence is partial.' }
        }
        foreach ($key in @('ExecutorPrincipalId', 'ExecutorApplicationId', 'RuntimePrincipalId', 'RuntimeClientId')) {
            Assert-GatewayUpgradeGuid $binding[$key]
        }
    }
function Initialize-GatewayUpgradeVerifier {
    foreach ($name in @('Common', 'Experience', 'Prerequisites', 'Azure', 'Entra', 'Agent365', 'Database', 'Purview',
            'PurviewRecovery', 'Verification', 'PublisherRecovery', 'PurviewPackage', 'PurviewExecutor')) {
        Import-Module (Join-Path $script:ToolingRoot "bootstrap\modules\$name.psm1") -Force -DisableNameChecking -Global -Verbose:$false
    }
}

function Invoke-GatewayUpgradeCanonicalVerifierCore {
    [CmdletBinding()]
    param($Inputs)
    Initialize-GatewayUpgradeVerifier
    $config = $Inputs.config
    $state = $Inputs.state
    $previousAssetRoot = Get-BootstrapExecutionSourceRoot
    Set-BootstrapAzureSubscriptionContext -SubscriptionId $config.subscriptionId -TenantId $config.tenantId
    try {
        if ($state.Contains('freshPurviewExecutor')) {
            # Current verifier code checks the original executor's content-addressed
            # assets. Candidate source must never impersonate that accepted source.
            Set-BootstrapExecutionSourceRoot -Path (Resolve-BootstrapAcceptedSourceRoot -State $state)
        }
        Assert-BootstrapAzureContext -Config $config | Out-Null
        $arguments = @{
            Config = $config; State = $state; DeploymentOwnershipId = $state.deploymentOwnershipId; NonInteractive = $true
        }
        $mapping = @{
            Foundation = 'Azure foundation'; Identity = 'Gateway API identity'; Blueprint = 'Agent 365 seed blueprint'
            Runtime = 'Gateway runtime deployment'; Database = 'Gateway database'; SqlPrivateEndpoint = 'SQL private endpoint'
            AdminUi = 'Admin UI deployment'; Images = 'Immutable workload images'
            AdminIdentity = 'Admin UI identity'; AdminCredential = 'Admin UI Key Vault credential'
        }
        foreach ($key in $mapping.Keys) { $arguments[$key] = $state.steps[$mapping[$key]].evidence }
        # Invoke the current read-only verifier, not bootstrap's state-writing dispatcher.
        $result = Test-GatewayBootstrapDeployment @arguments
        if ($result.deploymentVerification -cne 'Passed' -or $result.azureRbac -cne 'Passed' -or
            $result.sqlPrivateEndpoint -cne 'Passed' -or $result.adminUiIdentity -cne 'Passed' -or
            $result.adminUiCredential -cne 'Passed' -or $result.provisioningAdmissionReady -ne $true) {
            throw 'UpgradeBaseline: independent verification did not prove the working deployment.'
        }
        return $result
    }
    catch {
        Write-Verbose ("Verifier failure type: {0}; source stack: {1}" -f $_.Exception.GetType().Name, $_.ScriptStackTrace)
        throw 'UpgradeBaseline: current canonical read-only verification failed; provider details suppressed. No historical status was changed.'
    }
    finally {
        Set-BootstrapExecutionSourceRoot -Path $previousAssetRoot
        Clear-BootstrapAzureSubscriptionContext
    }
}

function Invoke-GatewayUpgradeBaselineProcess {
    param($Inputs, [ValidateRange(1, 1800)][int]$TimeoutSeconds = 1800)
    $scriptPath = Resolve-GatewayUpgradeFile $script:ToolingRoot 'operations\gateway-upgrade-baseline.ps1'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath,
            '-StatePath', $Inputs.statePath, '-ConfigPath', $Inputs.configPath,
            '-ExpectedStateSha256', $Inputs.stateSha256, '-ExpectedConfigSha256', $Inputs.configSha256)) {
        $start.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    try {
        if (-not $process.Start()) { throw 'UpgradeBaseline: verifier process did not start.' }
        $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'UpgradeBaseline: read-only verification deadline exceeded; child process tree stopped, no result accepted.'
        }
        $text = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'UpgradeBaseline: current read-only verifier failed; child output suppressed. Original history was not rewritten.' }
        $marker = 'A365GW_UPGRADE_BASELINE:'
        $lines = @($text.Split("`n") | Where-Object { $_.StartsWith($marker) })
        if ($lines.Count -ne 1 -or $lines[0].Length -gt 4096) { throw 'UpgradeBaseline: expected exactly one bounded verifier result.' }
        $document = $null
        try {
            $document = [System.Text.Json.JsonDocument]::Parse($lines[0].Substring($marker.Length).Trim())
            $result = ConvertFrom-GatewayUpgradeJsonElement $document.RootElement
        }
        catch { throw 'UpgradeBaseline: invalid verifier result; child output suppressed.' }
        finally { if ($null -ne $document) { $document.Dispose() } }
        Assert-GatewayUpgradeShape $result @('status', 'verifiedAtUtc', 'verifierResultFingerprint') 'verifier result'
        Assert-GatewayUpgradeHash $result.verifierResultFingerprint
        if ($result.status -cne 'Passed') { throw 'UpgradeBaseline: current verifier did not pass.' }
        return $result
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

function Invoke-GatewayUpgradeCanonicalVerifier {
    param($Inputs)
    return Invoke-GatewayUpgradeBaselineProcess $Inputs
}

function Get-GatewayUpgradeScope {
    param($Request, $State)
    if ($Request.schemaVersion -eq 2) { return Get-GatewayUpgradeFullScope $Request $State }
    $target = $Request.target
    $prefix = "/subscriptions/$($target.subscriptionId)/resourceGroups/$($target.resourceGroupName)"
    $runtime = $State.steps['Gateway runtime deployment'].evidence
    $foundation = $State.steps['Azure foundation'].evidence
    $environment = $target.environment
    $accountName = "cs-$($target.projectName)-$environment-upgrade"
    $accountId = "$prefix/providers/Microsoft.CognitiveServices/accounts/$accountName"
    Assert-GatewayUpgradeGuid $runtime.apiPrincipalId
    Assert-GatewayUpgradeGuid $runtime.workerPrincipalId
    $roleHash = Get-GatewayUpgradeFingerprint @{ accountId = $accountId; principalId = $runtime.apiPrincipalId; role = 'Cognitive Services User' }
    $roleName = [guid]::new($roleHash.Substring(7, 32)).ToString('D')
    $jobHash = Get-GatewayUpgradeFingerprint @{ ownership = $target.deploymentOwnershipId; release = $Request.releaseId; operation = 'database-upgrade' }
    $jobId = "$prefix/providers/Microsoft.App/jobs/job-$($target.projectName)-upg-$($jobHash.Substring(7, 10))"
    $storageId = [string]$runtime.storageAccountId
    if (-not $storageId.StartsWith("$prefix/providers/Microsoft.Storage/storageAccounts/", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'UpgradeContract: original private storage account is outside the target resource group.'
    }
    $evidenceContainerId = "$storageId/blobServices/default/containers/gateway-upgrade-evidence"
    $databaseRoleHash = Get-GatewayUpgradeFingerprint @{ scope = $evidenceContainerId; principalResourceId = $jobId; role = 'Storage Blob Data Contributor' }
    $databaseRoleId = "$evidenceContainerId/providers/Microsoft.Authorization/roleAssignments/$([guid]::new($databaseRoleHash.Substring(7, 32)).ToString('D'))"
    $databaseEvidence = $State.steps['Gateway database'].evidence
    Assert-GatewayUpgradeGuid $databaseEvidence.originalSqlAdministratorObjectId
    if ([string]::IsNullOrWhiteSpace([string]$databaseEvidence.originalSqlAdministratorLogin) -or
        [string]$databaseEvidence.originalSqlAdministratorLogin -match '[\r\n]' -or
        ([string]$databaseEvidence.originalSqlAdministratorLogin).Length -gt 256) {
        throw 'UpgradeContract: original SQL administrator restoration binding is invalid.'
    }
    $purview = Get-GatewayUpgradePurviewScope $Request $State
    $resources = @(
        @{ stage = 'ContentSafety'; resourceId = $accountId; permittedChange = 'Create' }
        @{ stage = 'ContentSafety'; resourceId = "$accountId/providers/Microsoft.Authorization/roleAssignments/$roleName"; permittedChange = 'Create' }
        @{ stage = 'DatabaseExpand'; resourceId = $jobId; permittedChange = 'Create' }
        @{ stage = 'DatabaseExpand'; resourceId = $evidenceContainerId; permittedChange = 'Create' }
        @{ stage = 'DatabaseExpand'; resourceId = $databaseRoleId; permittedChange = 'Create' }
        @{ stage = 'Coordination'; resourceId = "$storageId/blobServices/default/containers/gateway-upgrade-lock"; permittedChange = 'CreateOrReadExactOwned' }
        @{ stage = 'Worker'; resourceId = "$prefix/providers/Microsoft.App/containerApps/ca-gateway-worker-$environment-v3"; permittedChange = 'Modify' }
        @{ stage = 'Api'; resourceId = "$prefix/providers/Microsoft.App/containerApps/ca-gateway-api-$environment"; permittedChange = 'Modify' }
        @{ stage = 'Admin'; resourceId = "$prefix/providers/Microsoft.App/containerApps/ca-gateway-admin-$environment"; permittedChange = 'Modify' }
    ) + @($purview.resources)
    return [ordered]@{
        resourceGroupId = $prefix
        resources = $resources
        roles = @(@{
            scope = $accountId
            principalId = [string]$runtime.apiPrincipalId
            roleDefinitionId = "/subscriptions/$($target.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908"
            assignmentResourceId = "$accountId/providers/Microsoft.Authorization/roleAssignments/$roleName"
        }, @{
            scope = $evidenceContainerId
            principalResourceId = $jobId
            roleDefinitionId = "/subscriptions/$($target.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe"
            assignmentResourceId = $databaseRoleId
        }) + @($purview.roles)
        existing = @{
            apiImage = [string]$runtime.apiImage; workerImage = [string]$runtime.workerImage
            adminImage = [string]$State.steps['Immutable workload images'].evidence.adminUi
            apiPrincipalId = [string]$runtime.apiPrincipalId; workerPrincipalId = [string]$runtime.workerPrincipalId
            apiFqdn = [string]$runtime.apiFqdn; adminUrl = [string]$State.steps['Admin UI deployment'].evidence.adminUiUrl
            sqlServerFqdn = [string]$runtime.sqlServerFqdn; databaseName = 'GatewayDb'
            provisioningQueueName = 'gateway-provisioning-v3'
            acrLoginServer = [string]$foundation.acrLoginServer
        }
        unresolvedScopes = @('PurviewPrerequisites', 'PurviewExecutor', 'DatabaseExecutorAuthority')
        purview = $purview
        privilegedMutations = @(@{
            operation = 'TemporarySqlAdministratorDelegation'
            resourceId = "$prefix/providers/Microsoft.Sql/servers/$(([string]$runtime.sqlServerFqdn).Split('.')[0])/administrators/ActiveDirectory"
            executionPrincipalResourceId = $jobId
            restoreObjectId = $databaseEvidence.originalSqlAdministratorObjectId
            restoreLogin = $databaseEvidence.originalSqlAdministratorLogin
            restorationRequiredBeforeAcceptance = $true
        })
    }
}

function Get-GatewayUpgradeFullScope {
    param($Request, $State)
    # Derive disposable job/coordination scope through the v1 naming contract, then
    # replace all capability installation authority with retained resource evidence.
    $legacy = ConvertFrom-Json (ConvertTo-Json $Request -Depth 100) -AsHashtable -Depth 100
    $legacy.schemaVersion = 1
    $scope = Get-GatewayUpgradeScope $legacy $State
    $fresh = $State.freshPurviewExecutor
    $runtime = $State.steps['Gateway runtime deployment'].evidence
    $purview = $scope.purview
    $purview.siteId = [string]$fresh.host.executorId.value
    $purview.siteName = $purview.siteId.Split('/')[-1]
    $purview.planName = "asp-$($Request.target.projectName)-$($Request.target.environment)-purview"
    $purview.endpointName = ([string]$fresh.host.privateEndpointId.value).Split('/')[-1]
    $purview.packagesId = [string]$fresh.host.packageContainerId.value
    $purview.claimsId = [string]$fresh.host.claimsContainerId.value
    $purview.certificateId = "$($runtime.sharedKeyVaultId)/secrets/$($fresh.context.certificateName)"
    $purview.queueId = [string]$runtime.protectionAdminQueueId
    $purview['retained'] = @{
        executor = $fresh; contentSafetyAccountId = $runtime.promptShieldAccountId
        contentSafetyEndpoint = $runtime.promptShieldEndpoint
        planId = "$($scope.resourceGroupId)/providers/Microsoft.Web/serverfarms/$($purview.planName)"
        capabilities = $State.steps['Purview capability prerequisites'].evidence
    }
    $publisher = @($purview.roles | Where-Object key -CEQ 'publisherWriter')
    $purview.roles = $publisher
    $purview.graphRoleAllowlist = @()
    $purview.directoryRoleAllowlist = @()
    $purview.resources = @(
        @{ stage = 'PurviewExecutor'; resourceId = "$($purview.siteId)/config/appsettings"; permittedChange = 'ModifyExactPackageBindingOnly' }
        @{ stage = 'PurviewPublisher'; resourceId = $purview.publisherId; permittedChange = 'Create' }
        @{ stage = 'PurviewPublisher'; resourceId = $publisher[0].assignmentResourceId; permittedChange = 'Create' }
    )
    $scope.resources = @($scope.resources | Where-Object { $_.stage -cnotin @('ContentSafety', 'PurviewPrerequisites', 'PurviewExecutor', 'PurviewQueue', 'PurviewPublisher') }) + @($purview.resources)
    $scope.roles = @($scope.roles[1]) + $publisher
    $scope['preservedResourceIds'] = @(
        $runtime.promptShieldAccountId, $purview.siteId, $purview.retained.planId,
        $purview.queueId, $runtime.serviceBusQueueId, $purview.packagesId, $purview.claimsId, $purview.certificateId,
        $fresh.host.privateEndpointId.value, $fresh.host.privateDnsZoneId.value, $fresh.host.integrationSubnetId.value,
        $fresh.host.packageReaderRoleId.value, $fresh.host.claimWriterRoleId.value, $fresh.host.certificateReaderRoleId.value
    )
    foreach ($id in $scope.preservedResourceIds) {
        if ($id -isnot [string] -or -not $id.StartsWith("$($scope.resourceGroupId)/providers/", [StringComparison]::Ordinal) -or
            $id.Contains('?') -or $id.Contains('..') -or $id.Contains('#')) {
            throw 'UpgradeBaseline: retained resource is outside the exact approved target.'
        }
    }
    return $scope
}

function Get-GatewayUpgradePurviewScope {
    param($Request, $State)
    $target = $Request.target
    $prefix = "/subscriptions/$($target.subscriptionId)/resourceGroups/$($target.resourceGroupName)"
    $runtime = $State.steps['Gateway runtime deployment'].evidence
    $foundation = $State.steps['Azure foundation'].evidence
    $suffix = (Get-GatewayUpgradeFingerprint @{ owner = $target.deploymentOwnershipId; purpose = 'purview-executor' }).Substring(7, 8)
    $siteName = "app-$($target.projectName)-pv-$suffix-$($target.environment)"
    $planName = "asp-$($target.projectName)-pv-$($target.environment)"
    $publisherName = "job-$($target.projectName)-pvp-$suffix"
    $endpointName = "pe-$($target.projectName)-pv-$($target.environment)"
    $linkName = "link-$($target.projectName)-pv-$($target.environment)"
    $siteId = "$prefix/providers/Microsoft.Web/sites/$siteName"
    $publisherId = "$prefix/providers/Microsoft.App/jobs/$publisherName"
    $packages = "$($runtime.storageAccountId)/blobServices/default/containers/purview-executor-packages"
    $claims = "$($runtime.storageAccountId)/blobServices/default/containers/purview-executor-claims"
    $vaultId = "$prefix/providers/Microsoft.KeyVault/vaults/kv-$($target.projectName)-$($target.environment)"
    $certificate = "$vaultId/secrets/purview-automation-certificate"
    $queue = "$prefix/providers/Microsoft.ServiceBus/namespaces/sb-$($target.projectName)-$($target.environment)/queues/gateway-protection-admin-v1"
    $network = "$prefix/providers/Microsoft.Network/virtualNetworks/vnet-$($target.projectName)-$($target.environment)"
    if ($foundation.Contains('virtualNetworkName')) {
        $network = "$prefix/providers/Microsoft.Network/virtualNetworks/$($foundation.virtualNetworkName)"
    }
    $dns = "$prefix/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net"
    $endpoint = "$prefix/providers/Microsoft.Network/privateEndpoints/$endpointName"
    $roles = @(
        @{ key = 'packageReader'; scope = $packages; principalResourceId = $siteId; role = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'; stage = 'PurviewExecutor' }
        @{ key = 'claimWriter'; scope = $claims; principalResourceId = $siteId; role = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'; stage = 'PurviewExecutor' }
        @{ key = 'certificateReader'; scope = $certificate; principalResourceId = $siteId; role = '4633458b-17de-408a-b874-0445c86b69e6'; stage = 'PurviewExecutor' }
        @{ key = 'publisherWriter'; scope = $packages; principalResourceId = $publisherId; role = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'; stage = 'PurviewPublisher' }
        @{ key = 'apiQueueSender'; scope = $queue; principalId = $runtime.apiPrincipalId; role = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'; stage = 'PurviewQueue' }
        @{ key = 'workerQueueReceiver'; scope = $queue; principalId = $runtime.workerPrincipalId; role = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'; stage = 'PurviewQueue' }
        @{ key = 'workerCertificateReader'; scope = $certificate; principalId = $runtime.workerPrincipalId; role = '4633458b-17de-408a-b874-0445c86b69e6'; stage = 'PurviewQueue' }
    )
    foreach ($role in $roles) {
        $hash = Get-GatewayUpgradeFingerprint $role
        $role.assignmentName = [guid]::new($hash.Substring(7, 32)).ToString('D')
        $role.assignmentResourceId = "$($role.scope)/providers/Microsoft.Authorization/roleAssignments/$($role.assignmentName)"
        $role.roleDefinitionId = "/subscriptions/$($target.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$($role.role)"
    }
    $resources = @(
        @{ stage = 'PurviewPrerequisites'; resourceId = $certificate; permittedChange = 'Create' }
        @{ stage = 'PurviewQueue'; resourceId = $queue; permittedChange = 'Create' }
        @{ stage = 'PurviewPublisher'; resourceId = $publisherId; permittedChange = 'Create' }
        @{ stage = 'PurviewExecutor'; resourceId = "$prefix/providers/Microsoft.Web/serverfarms/$planName"; permittedChange = 'Create' }
        @{ stage = 'PurviewExecutor'; resourceId = $siteId; permittedChange = 'CreateThenEnableExactOwned' }
        @{ stage = 'PurviewExecutor'; resourceId = "$siteId/config/authsettingsV2"; permittedChange = 'Create' }
        @{ stage = 'PurviewExecutor'; resourceId = "$siteId/config/appsettings"; permittedChange = 'Create' }
        @{ stage = 'PurviewExecutor'; resourceId = "$siteId/basicPublishingCredentialsPolicies/ftp"; permittedChange = 'Create' }
        @{ stage = 'PurviewExecutor'; resourceId = "$siteId/basicPublishingCredentialsPolicies/scm"; permittedChange = 'Create' }
        @{ stage = 'PurviewExecutor'; resourceId = "$network/subnets/snet-purview-executor"; permittedChange = 'Create' }
        @{ stage = 'PurviewExecutor'; resourceId = $packages; permittedChange = 'Create' }
        @{ stage = 'PurviewExecutor'; resourceId = $claims; permittedChange = 'Create' }
        @{ stage = 'PurviewExecutor'; resourceId = $dns; permittedChange = 'Create' }
        @{ stage = 'PurviewExecutor'; resourceId = "$dns/virtualNetworkLinks/$linkName"; permittedChange = 'Create' }
        @{ stage = 'PurviewExecutor'; resourceId = $endpoint; permittedChange = 'Create' }
        @{ stage = 'PurviewExecutor'; resourceId = "$endpoint/privateDnsZoneGroups/purviewExecutorDnsGroup"; permittedChange = 'Create' }
    ) + @($roles | ForEach-Object { @{ stage = $_.stage; resourceId = $_.assignmentResourceId; permittedChange = 'Create' } })
    return @{
        siteName = $siteName; siteId = $siteId; planName = $planName; publisherName = $publisherName; publisherId = $publisherId
        endpointName = $endpointName; dnsLinkName = $linkName; packagesId = $packages; claimsId = $claims; certificateId = $certificate
        queueId = $queue; networkId = $network; roles = $roles; resources = $resources
        graphRoleAllowlist = @('ProtectionScopes.Compute.User', 'Content.Process.User', 'ContentActivity.Write', 'Exchange.ManageAsApp')
        directoryRoleAllowlist = @(@{ roleDefinitionId = '17315797-102d-40b4-93e0-432062caca18'; scope = '/'; principal = 'ExactNewAutomationPrincipal' })
    }
}

function Get-GatewayUpgradeContentBinding {
    param([string]$SourceRoot, $Request, $Scope)
    $manifest = @(Get-GatewayUpgradeSourceManifest $SourceRoot)
    $migratorManifest = Get-GatewayUpgradeMigratorManifest $SourceRoot
    foreach ($scriptEntry in $Request.database.scripts) {
        $file = Resolve-GatewayUpgradeFile $SourceRoot $scriptEntry.path
        if ((Get-GatewayUpgradeFileHash $file) -cne $scriptEntry.sha256) { throw 'UpgradeContract: SQL checksum mismatch.' }
        $name = [IO.Path]::GetFileName($scriptEntry.path)
        if ($migratorManifest.status -cne 'Bound' -or $name -cnotin $migratorManifest.prepareScripts) {
            throw 'UpgradeContract: requested SQL is not wired into the candidate migrator prepare manifest.'
        }
    }
    $repositories = @{ api = 'gateway-api'; worker = 'gateway-worker'; adminUi = 'gateway-admin'; databaseMigrator = 'gateway-db-migrator' }
    foreach ($component in $repositories.Keys) {
        $image = [string]$Request.images[$component]
        $expectedPrefix = "$($Scope.existing.acrLoginServer)/$($repositories[$component])@"
        if ($image -cne '' -and -not $image.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) {
            throw 'UpgradeContract: image repository or registry is outside the exact deployment.'
        }
    }
    $toolManifest = @(Get-GatewayUpgradeSourceManifest $script:ToolingRoot | Where-Object {
        $_.path -match '^(bootstrap\\modules\\.*\.psm1|operations\\.*\.ps(?:1|m1)|tools\\_common\.ps1)$'
    })
    return @{
        sourceManifest = $manifest; sourceFingerprint = Get-GatewayUpgradeFingerprint $manifest
        verifierManifest = $toolManifest; verifierFingerprint = Get-GatewayUpgradeFingerprint $toolManifest
        sqlManifest = $Request.database.scripts; migratorManifest = $migratorManifest
    }
}

function Get-GatewayUpgradeMigratorManifest {
    param([string]$SourceRoot)
    $relativePath = 'tools\Gateway.DatabaseMigrator\Program.cs'
    if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot $relativePath) -PathType Leaf)) {
        return @{ status = 'Unavailable'; path = $relativePath; sha256 = ''; prepareScripts = @() }
    }
    $path = Resolve-GatewayUpgradeFile $SourceRoot $relativePath
    $source = [IO.File]::ReadAllText($path)
    $matches = [regex]::Matches($source, 'static string\[\] GetPrepareScriptNames\(\) =>\s*\[(?<scripts>[\s\S]*?)\];')
    if ($matches.Count -ne 1) { throw 'UpgradeContract: candidate migrator manifest declaration is unsupported.' }
    $body = $matches[0].Groups['scripts'].Value
    $names = @([regex]::Matches($body, '"(?<name>[0-9]{8}_[a-z0-9_]+\.sql)"') |
        ForEach-Object { $_.Groups['name'].Value })
    $remainder = [regex]::Replace($body, '"[0-9]{8}_[a-z0-9_]+\.sql"', '')
    if ($names.Count -eq 0 -or $remainder -notmatch '^[\s,]*$' -or @($names | Select-Object -Unique).Count -ne $names.Count) {
        throw 'UpgradeContract: candidate migrator manifest must be a unique literal SQL allowlist.'
    }
    return @{ status = 'Bound'; path = $relativePath; sha256 = Get-GatewayUpgradeFileHash $path; prepareScripts = $names }
}

function Get-GatewayUpgradeDatabaseProtocol {
    param($Request, $Inputs, $Content)
    return @{
        schemaVersion = $(if ($Request.schemaVersion -eq 2) { 2 } else { 1 }); operation = 'GatewayDatabaseUpgradeProtocol'
        integrationStatus = $(if ($Request.schemaVersion -eq 2) { 'PrivateSchemaPreservationPendingLiveVerification' } else { 'BlockedPendingSchemaAndRuntimeReview' })
        migratorPhase = 'upgrade'; privateExecutionRequired = $true; bootstrapInitializationForbidden = $true
        genericPrepareExecutionForbidden = $true; executableSqlScope = $(if ($Request.schemaVersion -eq 2) { 'NoDdl;ReadOnlySchemaPrincipalAndRegistrationPreservation' } else { 'OnlyReviewedUpgradeSqlSubset' })
        original = @{
            markerName = 'A365GatewayBootstrapInitializationIntent'
            markerMustRemainByteForByteUnchanged = $true
            acceptedSourceFingerprint = [string]$Inputs.state.acceptedPlan.sourceFingerprint
            deploymentOwnershipId = [string]$Inputs.state.deploymentOwnershipId
            databaseEvidenceFingerprint = Get-GatewayUpgradeFingerprint $Inputs.state.steps['Gateway database'].evidence
        }
        candidate = @{
            upgradeSourceFingerprint = $Content.sourceFingerprint
            currentSchemaFingerprint = $Request.database.currentSchemaFingerprint
            targetSchemaFingerprint = $Request.database.targetSchemaFingerprint
            targetModelFingerprint = if ($Request.database.Contains('targetModelFingerprint')) { $Request.database.targetModelFingerprint } else { $null }
            sqlManifest = $Content.sqlManifest; migratorManifest = $Content.migratorManifest
        }
        receiptRules = @{
            storage = 'SeparateVersionedMaintenanceEvidence'
            planBinding = 'ExactApprovedEnvelopePlanFingerprint'
            intentBeforeDispatch = $true; allowAutomaticReplay = $false
            unknownOutcome = 'BoundedReadOnlyExactExecutionAndDatabaseReconciliation'
            requiredFields = @(
                'upgradePlanFingerprint', 'upgradeSourceFingerprint', 'previousUpgradeReceiptFingerprint',
                'executionIntentId', 'privateJobResourceId', 'privateJobExecutionName', 'migratorImageDigest',
                'originalMarkerFingerprintBefore', 'originalMarkerFingerprintAfter',
                'schemaFingerprintBefore', 'schemaFingerprintAfter', 'executedSqlChecksums',
                'databaseIdentityAndPrincipalBindingFingerprint', 'registrationPreservationEvidenceFingerprint',
                'verifiedAtUtc', 'outcome'
            )
        }
        runtimeAttestation = @{
            integration = $(if ($Request.schemaVersion -eq 2) { 'VersionedUpgradeReceipt;PreserveOriginalFullCapabilityProjection' } else { 'DatabaseProbeImplemented;CapabilityTransitionRequiresCoordination' })
            requiredBindings = @(
                'originalDeploymentOwnershipId', 'originalAcceptedSourceFingerprint', 'originalInitializationMarkerFingerprint',
                'upgradePlanFingerprint', 'upgradeSourceFingerprint', 'verifiedUpgradeReceiptFingerprint',
                'currentSchemaFingerprint', 'databaseIdentityAndPrincipalBindingFingerprint'
            )
            originalBootstrapReceiptMutable = $false
            connectivityReadinessIsUpgradeProof = $false
        }
        rollback = @{
            strategy = 'RetainExpandedSchema'
            requireOldCodeCompatibilityWithCurrentSchema = $true
            preserveUserWrites = $true; destructiveDownMigrationAllowed = $false
        }
    }
}

function Get-GatewayUpgradeOriginalBinding {
    param($Inputs)
    return @{
        stateSha256 = $Inputs.stateSha256; configSha256 = $Inputs.configSha256
        acceptedPlanSha256 = Get-GatewayUpgradeFingerprint $Inputs.state.acceptedPlan
        acceptedSourceFingerprint = [string]$Inputs.state.acceptedPlan.sourceFingerprint
        historicalVerificationStatus = [string]$Inputs.state.steps['End-to-end deployment verification'].status
        historicalDisposition = 'RetainedUnchanged;FailureCauseNotReclassified'
    }
}

function Get-GatewayUpgradeReview {
    param([Parameter(Mandatory)]$Request)
    if ($Request.schemaVersion -eq 2) {
        return @{
            costBoundary = "SourceOnlyFull retains installed $($Request.capabilities.promptShields.sku)/$($Request.capabilities.purview.executorSku); no capability installation or paid SKU transition."
            contentSafety = 'Preserve exact existing account, SKU, endpoint, identity and permissions.'
            purviewHosting = 'Preserve exact existing Windows plan/site/private network/identity/certificate/permissions; change package binding only.'
            dataPreservation = 'Keep endpoint identities, registrations, keys, user writes, bootstrap marker, accepted snapshots and original state/configuration.'
            rollback = 'Compatible immutable code only; retain verified unchanged schema and upgrade receipt. No down migration, restore-over-live, queue purge or repeated Registry create.'
            policyScope = 'Purview DLP is blueprint-shared; per-registration editing must validate cross-registration effects.'
            outage = 'Single-revision HTTP readiness is not proof of schema compatibility, queue continuity or zero downtime.'
        }
    }
    $sku = [string]$Request.capabilities.purview.executorSku
    if ($sku -cnotin @('B1','B2')) { throw 'UpgradeContract: the reviewed hosting SKU is invalid.' }
    $hosting = if ($sku -ceq 'B2') {
        'USD retail reference: Windows B2 0.17/hour (~124.10 per 730 hours), plus network, storage, builds, logs and Purview licensing/usage. Reprice before approval.'
    } else {
        'USD retail reference: Windows B1 0.085/hour (~62.05 per 730 hours), plus network, storage, builds, logs and Purview licensing/usage. Reprice before approval.'
    }
    return @{
        costBoundary = "Paid S0 usage and Windows $sku hosting explicitly selected; not a spending cap."
        contentSafety = 'USD retail reference: 0.375 per 1000 text records; each record up to 1000 Unicode code points, rounded up. Reprice before approval.'
        purviewHosting = $hosting
        dataPreservation = 'Keep endpoint identities, registrations, keys, user writes, bootstrap marker, accepted snapshots and original state/configuration.'
        rollback = 'Compatible immutable code only; retain expanded schema. No down migration, restore-over-live, queue purge or repeated Registry create.'
        policyScope = 'Purview DLP is blueprint-shared; per-registration editing must validate cross-registration effects.'
        outage = 'Single-revision HTTP readiness is not proof of schema compatibility, queue continuity or zero downtime.'
    }
}

function New-GatewayUpgradePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$SourceRoot)
    $inputs = Read-GatewayUpgradeBaselineInputs $StatePath $ConfigPath $Request
    $scope = Get-GatewayUpgradeScope $Request $inputs.state
    $content = Get-GatewayUpgradeContentBinding $SourceRoot $Request $scope
    $originalObjectHash = Get-GatewayUpgradeFingerprint $inputs.state
    $result = Invoke-GatewayUpgradeCanonicalVerifier $inputs
    if ((Get-GatewayUpgradeFingerprint $inputs.state) -cne $originalObjectHash -or
        (Get-GatewayUpgradeFileHash $StatePath) -cne $inputs.stateSha256 -or
        (Get-GatewayUpgradeFileHash $ConfigPath) -cne $inputs.configSha256) {
        throw 'UpgradeBaseline: original evidence changed during read-only verification.'
    }
    $after = Get-GatewayUpgradeContentBinding $SourceRoot $Request $scope
    if ($after.sourceFingerprint -cne $content.sourceFingerprint -or $after.verifierFingerprint -cne $content.verifierFingerprint) {
        throw 'UpgradeContract: candidate or verifier source changed during planning.'
    }
    $body = [ordered]@{
        schemaVersion = 1; operation = 'GatewayInPlaceUpgradePlan'; releaseId = $Request.releaseId
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        executionSupported = $false
        request = $Request
        original = Get-GatewayUpgradeOriginalBinding $inputs
        baseline = @{
            status = 'IndependentlyVerified'; verifiedAtUtc = [string]$result.verifiedAtUtc
            verifierResultFingerprint = [string]$result.verifierResultFingerprint
            source = 'CurrentCanonicalReadOnlyVerifier'; historicalStatusChanged = $false
        }
        content = $content; scope = $scope
        databaseUpgradeProtocol = Get-GatewayUpgradeDatabaseProtocol $Request $inputs $content
        stages = @($script:Stages | ForEach-Object { @{ name = $_; implementation = 'NotImplemented'; mutationAllowed = $false } })
        blockers = $script:Blockers
        review = Get-GatewayUpgradeReview -Request $Request
    }
    return @{ planFingerprint = Get-GatewayUpgradeFingerprint $body; plan = $body }
}

function Test-GatewayUpgradePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Envelope, [Parameter(Mandatory)][string]$ExpectedPlanFingerprint,
        [Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$SourceRoot)
    Assert-GatewayUpgradeHash $ExpectedPlanFingerprint
    Assert-GatewayUpgradeShape $Envelope @('planFingerprint', 'plan') 'plan envelope'
    $plan = $Envelope.plan
    Assert-GatewayUpgradeShape $plan @('schemaVersion', 'operation', 'releaseId', 'createdAtUtc', 'executionSupported',
        'request', 'original', 'baseline', 'content', 'scope', 'databaseUpgradeProtocol', 'stages', 'blockers', 'review') 'plan'
    if ($plan.schemaVersion -ne 1 -or $plan.operation -cne 'GatewayInPlaceUpgradePlan' -or
        $plan.executionSupported -isnot [bool] -or $plan.executionSupported -ne $false -or
        $Envelope.planFingerprint -cne $ExpectedPlanFingerprint -or
        (Get-GatewayUpgradeFingerprint $plan) -cne $ExpectedPlanFingerprint) {
        throw 'UpgradeContract: plan integrity or exact approval binding failed.'
    }
    $inputs = Read-GatewayUpgradeBaselineInputs $StatePath $ConfigPath $plan.request
    if ($plan.releaseId -cne $plan.request.releaseId -or
        (Get-GatewayUpgradeFingerprint $plan.original) -cne (Get-GatewayUpgradeFingerprint (Get-GatewayUpgradeOriginalBinding $inputs))) {
        throw 'UpgradeContract: original evidence binding changed.'
    }
    Assert-GatewayUpgradeShape $plan.baseline @('status', 'verifiedAtUtc', 'verifierResultFingerprint', 'source', 'historicalStatusChanged') 'baseline'
    Assert-GatewayUpgradeHash $plan.baseline.verifierResultFingerprint
    $created = [DateTimeOffset]::MinValue
    $verified = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact($plan.createdAtUtc, 'O', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$created) -or
        -not [DateTimeOffset]::TryParseExact($plan.baseline.verifiedAtUtc, 'O', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$verified) -or
        $created -gt [DateTimeOffset]::UtcNow.AddMinutes(2) -or $verified -gt $created -or
        $plan.baseline.status -cne 'IndependentlyVerified' -or $plan.baseline.source -cne 'CurrentCanonicalReadOnlyVerifier' -or
        $plan.baseline.historicalStatusChanged -isnot [bool] -or $plan.baseline.historicalStatusChanged -ne $false) {
        throw 'UpgradeContract: invalid independent baseline declaration.'
    }
    if ((Get-GatewayUpgradeFingerprint $plan.blockers) -cne (Get-GatewayUpgradeFingerprint $script:Blockers) -or
        (Get-GatewayUpgradeFingerprint $plan.review) -cne (Get-GatewayUpgradeFingerprint (Get-GatewayUpgradeReview -Request $plan.request))) {
        throw 'UpgradeContract: required blockers or preservation/cost review was altered.'
    }
    $scope = Get-GatewayUpgradeScope $plan.request $inputs.state
    if ((Get-GatewayUpgradeFingerprint $scope) -cne (Get-GatewayUpgradeFingerprint $plan.scope)) {
        throw 'UpgradeContract: exact resource/role scope differs from the derived allowlist.'
    }
    $content = Get-GatewayUpgradeContentBinding $SourceRoot $plan.request $scope
    if ((Get-GatewayUpgradeFingerprint $content) -cne (Get-GatewayUpgradeFingerprint $plan.content)) {
        throw 'UpgradeContract: source, verifier or SQL manifest changed.'
    }
    $protocol = Get-GatewayUpgradeDatabaseProtocol $plan.request $inputs $content
    if ((Get-GatewayUpgradeFingerprint $protocol) -cne (Get-GatewayUpgradeFingerprint $plan.databaseUpgradeProtocol)) {
        throw 'UpgradeContract: database upgrade marker, evidence, attestation or preservation protocol was altered.'
    }
    $stages = @($script:Stages | ForEach-Object { @{ name = $_; implementation = 'NotImplemented'; mutationAllowed = $false } })
    if ((Get-GatewayUpgradeFingerprint $stages) -cne (Get-GatewayUpgradeFingerprint $plan.stages)) {
        throw 'UpgradeContract: unsupported stage or executable callback.'
    }
    return $true
}

function Save-GatewayUpgradePlan {
    param([Parameter(Mandatory)]$Envelope, [Parameter(Mandatory)][string]$WorkspaceRoot)
    Assert-GatewayUpgradeHash $Envelope.planFingerprint
    Assert-GatewayUpgradeRequest $Envelope.plan.request
    if ($Envelope.plan.releaseId -cne $Envelope.plan.request.releaseId -or
        (Get-GatewayUpgradeFingerprint $Envelope.plan) -cne $Envelope.planFingerprint) {
        throw 'UpgradeContract: plan must be intact before evidence creation.'
    }
    $relative = ".maintenance\upgrades\$($Envelope.plan.releaseId)\$($Envelope.planFingerprint.Substring(7))"
    $root = [IO.Path]::GetFullPath($WorkspaceRoot)
    if ($root -match '(?:^|[\\/])\.bootstrap(?:[\\/]|$)') {
        throw 'UpgradeContract: maintenance evidence must not be written inside preserved bootstrap directories.'
    }
    $directory = $root
    foreach ($part in $relative.Split('\')) {
        $directory = Join-Path $directory $part
        if (Test-Path -LiteralPath $directory) {
            if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'UpgradeContract: evidence links are forbidden.'
            }
        }
        else { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    }
    $ignorePath = Join-Path $root '.maintenance\.gitignore'
    if (Test-Path -LiteralPath $ignorePath) {
        if ((Get-Item -LiteralPath $ignorePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or
            [IO.File]::ReadAllText($ignorePath) -cnotin @("*`n", "*`r`n")) {
            throw 'UpgradeContract: existing maintenance evidence exclusion is not exact; it was not overwritten.'
        }
    }
    else {
        $ignoreStream = [IO.File]::Open($ignorePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $ignoreBytes = [Text.Encoding]::UTF8.GetBytes("*`n")
            $ignoreStream.Write($ignoreBytes, 0, $ignoreBytes.Length)
            $ignoreStream.Flush($true)
        }
        finally { $ignoreStream.Dispose() }
    }
    $path = Join-Path $directory 'plan.json'
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject (ConvertTo-GatewayUpgradeCanonical $Envelope) -Depth 100))
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    return $path
}

function Invoke-GatewayUpgradeStage {
    param([Parameter(Mandatory)][ValidateSet('Execute', 'Verify', 'Rollback')][string]$Mode,
        [Parameter(Mandatory)]$Envelope, [Parameter(Mandatory)][string]$ExpectedPlanFingerprint,
        [Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$SourceRoot)
    $null = Test-GatewayUpgradePlan -Envelope $Envelope -ExpectedPlanFingerprint $ExpectedPlanFingerprint `
        -StatePath $StatePath -ConfigPath $ConfigPath -SourceRoot $SourceRoot
    throw "UpgradeNotImplemented: $Mode is not integrated. This review-only plan authorizes no mutation and is not deployment acceptance."
}

Export-ModuleMember -Function ConvertTo-GatewayUpgradeCanonicalJson, Get-GatewayUpgradeFingerprint, Get-GatewayUpgradeFileHash, Read-GatewayUpgradeJson,
    Assert-GatewayUpgradeRequest, New-GatewayUpgradePlan, Test-GatewayUpgradePlan, Save-GatewayUpgradePlan, Invoke-GatewayUpgradeStage
