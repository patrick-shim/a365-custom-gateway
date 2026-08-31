#Requires -Version 7.0

<#
.SYNOPSIS
    Corrects only the Gateway API database-attestation contract of one eligible bootstrap deployment.

.DESCRIPTION
    This is a bounded, resumable correction operation. It synthesizes build source
    from the original accepted bootstrap snapshot, overlays exactly two reviewed
    API-transitive files, builds only gateway-api, and updates only the existing API
    Container App to an immutable digest. It performs no Plan, What-If, Bicep, ARM
    deployment, resource replay, worker deployment, or Service Bus message access.

    A safe additive receipt is written before each external mutation. Once the
    corrected revision is independently verified, the canonical read-only bootstrap
    verifier reruns only the existing final verification state step.
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

$ApiAttestationCorrectionRepositoryRoot = Split-Path -Parent $PSScriptRoot
$ApiAttestationCorrectionToolPath = $PSCommandPath

$ApiAttestationCorrectionOperation = 'BootstrapApiAttestationCorrection'
$ApiAttestationCorrectionModuleImportOrder = @(
    'Common', 'Experience', 'Prerequisites', 'Azure', 'Entra',
    'Agent365', 'Database', 'Purview', 'Verification'
)
$ApiAttestationCorrectionExecutionDependencyPaths = @(
    'bootstrap/modules/Agent365.psm1'
    'bootstrap/modules/Azure.psm1'
    'bootstrap/modules/Common.psm1'
    'bootstrap/modules/Database.psm1'
    'bootstrap/modules/Entra.psm1'
    'bootstrap/modules/Experience.psm1'
    'bootstrap/modules/Prerequisites.psm1'
    'bootstrap/modules/Purview.psm1'
    'bootstrap/modules/Verification.psm1'
    'operations/test-provisioning-prerequisites.ps1'
)
$ApiAttestationCorrectionPredecessorResume = [ordered]@{
    locatorFingerprint = 'sha256:cdd5f598eaef9412e78e30c4a45008742b47de82af9179daa8c8518e7f6cf582'
    receiptFingerprint = 'sha256:829f814305c31f5af2659c3127243cfe99e2fa287a3e18adac3ec9e962cccbe8'
    contractFingerprint = 'sha256:a41dfefa5253e5dd14e7c0af54651118acaf3abfec57b82194bcc825ab4e015c'
    sourceContractFingerprint = 'sha256:3d16a0d6461b843dfcd10761554382b683d3397c610c9cffc2a8e7c707bab20a'
    originalSourceFingerprint = 'sha256:fb259d102fffe19da629a13eb4b3a84e385c978e2e2166d4171ddcb9566ec23c'
    synthesizedBuildSourceFingerprint = 'sha256:bdeb375ec0ce1b22cc5d7f5039cecc808b12b16cf171d356d7110843859e32df'
    toolFingerprint = 'sha256:c3c3275329b7dbdebc94a98c4543fd0ca7461c80afd15b21561c7231787808cc'
    nestedOverlaysFingerprint = 'sha256:a2ad0594eae88fcc112a4deef6c3eeed42c0dc33bb6da7a4d93ace0e9e0b527e'
    normalizedOverlaysFingerprint = 'sha256:16a76ed7e09f4ecdb3f15134cbc419652c60365750d133e2920e9e8fbfd3ded5'
    nestedDependenciesFingerprint = 'sha256:eb8bea500ea72de7e5b6e6f262ca9b4576390aab29f92f0be8c666f62f050b77'
    normalizedDependenciesFingerprint = 'sha256:97160cdcb38437c7cc3739993da99e576b4cb56b3c8e55c15de83c84120ceef0'
    runId = 'de9'
    tag = 'bootstrap-ac7c916d8bc848e89b26d4c8fdac73bf-bdeb375ec0ce1b22cc5d7f5039cecc80-0bab79ccab7d570799d87c337dac6db9'
    digest = 'sha256:adffb7076989d50a82a1067d3558e1bc4ac029305278c4bbb432a3bec9a5c6e0'
    targetRevisionName = 'ca-gateway-api-dev--attest-cdd5f598eaef'
    executionDependencies = @(
        [ordered]@{ path = 'bootstrap/modules/Agent365.psm1'; sha256 = 'f857bbdd8f12116e1610cdf4250a6eca473726cc2bd64ce6910edfb3ce80edc2' }
        [ordered]@{ path = 'bootstrap/modules/Azure.psm1'; sha256 = 'f996fa44ea3a7ba6dc1d69b3c70cc17fce54662ca260680b2f402919c317acd1' }
        [ordered]@{ path = 'bootstrap/modules/Common.psm1'; sha256 = '24ed938b8790defdda979f786ea907f25fb218bb01bf76d5db5f219d2671315b' }
        [ordered]@{ path = 'bootstrap/modules/Database.psm1'; sha256 = '098d33b73ee12c2d802b85bc7e7c58c08df160d3e343a81de4a7cb7e84394415' }
        [ordered]@{ path = 'bootstrap/modules/Entra.psm1'; sha256 = '21d3d9d128cc314378a82e210addd7910957c944813c151b9fe27bc4b774ebac' }
        [ordered]@{ path = 'bootstrap/modules/Experience.psm1'; sha256 = '87c299de3f3720965911576c9b0ca2835e0c0ebe9134baf7372282fcf25f9ef3' }
        [ordered]@{ path = 'bootstrap/modules/Prerequisites.psm1'; sha256 = '5b693fa4bef406e66fbed6e5b7b76761a223bc1ba5f653ea5c2e6407af7e82cb' }
        [ordered]@{ path = 'bootstrap/modules/Purview.psm1'; sha256 = 'f93289faddce31062f1f032090434d82ba3e8952619866082c5351ada05cd649' }
        [ordered]@{ path = 'bootstrap/modules/Verification.psm1'; sha256 = '4268f49387e251f2a623bfbe2f111754d939ba614c1e460c57af0494467bf526' }
        [ordered]@{ path = 'operations/test-provisioning-prerequisites.ps1'; sha256 = '58d00078577cf08d7201a2221faa5c88eb76c7955503292a60e6f94c41c9cf84' }
    )
}
$ApiAttestationCorrectionAcrProjectionResume = [ordered]@{
    schema2ReceiptFingerprint = 'sha256:b080dbff2513d36951e141569f771f18a23f6e244688883e92c2a42ad8ca1365'
    schema2ReconciliationFingerprint = 'sha256:dbf4190280614b69c98f11afd083634f71c44ed80d578fa5a91b306eaba96723'
    schema2ReconciliationContractFingerprint = 'sha256:730803804f17fbe111755f480f2b2ef2ecd9bc51c4fe85d02ea06d8288467483'
    schema2CurrentSourceContractFingerprint = 'sha256:4686b4a76bacb4ce9f5d69cba9c430cfd2ee53269be31c78b1a14b0b32b9a5f5'
    schema2CurrentToolFingerprint = 'sha256:0954527472b8d420aa8e62e09066bb4b9f862314b030bf20ec053242c7318b63'
    schema2CurrentExecutionDependenciesFingerprint = 'sha256:472866712266d3d65f135e39f3128ebde7046ac26960c446347f368113f841a3'
}
$ApiAttestationCorrectionOverlayContract = @(
    [ordered]@{
        path = 'src/Gateway.Infrastructure/Persistence/DatabaseBootstrapAttestationService.cs'
        acceptedSha256 = 'd3cd443c7fff178dee8c7c153f32ec3fb6556f6f4eb408d1bb34dfc2be21559b'
        correctedSha256 = 'ea455f13ddb8db52c2208f49a8b598e81fcdaf01d9f977a89f4afa40fa675541'
    },
    [ordered]@{
        path = 'src/Gateway.Infrastructure/Persistence/DatabaseBootstrapContract.cs'
        acceptedSha256 = 'f0b10e9b3d5786c44cdaa4676641bf9387236cd60f8df863e940dbbb8ad41496'
        correctedSha256 = '3e188ee8ab2080d5cee0436bb3ebaf85de47f76720ceafd943b46a57748523e1'
    }
)

function Import-ApiAttestationCorrectionModules {
    foreach ($module in $ApiAttestationCorrectionModuleImportOrder) {
        Import-Module (Join-Path $ApiAttestationCorrectionRepositoryRoot "bootstrap/modules/$module.psm1") -Force -DisableNameChecking
    }
}

function Get-ApiAttestationCorrectionExecutionDependencyMetadata {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot = $ApiAttestationCorrectionRepositoryRoot,
        [string[]]$RelativePaths = $ApiAttestationCorrectionExecutionDependencyPaths
    )

    if ([string]::IsNullOrWhiteSpace($RepositoryRoot) -or $null -eq $RelativePaths -or $RelativePaths.Count -eq 0) {
        throw 'The API-attestation correction execution-dependency boundary is empty.'
    }
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $rootPrefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $canonicalPaths = [string[]]@($RelativePaths)
    [Array]::Sort($canonicalPaths, [StringComparer]::Ordinal)
    $metadata = [Collections.Generic.List[object]]::new()
    $previous = $null
    foreach ($relativePath in $canonicalPaths) {
        if ([string]::IsNullOrWhiteSpace($relativePath) -or
            $relativePath -cne $relativePath.Replace('\', '/') -or
            [IO.Path]::IsPathRooted($relativePath) -or
            @($relativePath.Split('/')) -contains '..' -or
            $relativePath.StartsWith('./', [StringComparison]::Ordinal) -or
            ($null -ne $previous -and $relativePath -ceq $previous)) {
            throw 'The API-attestation correction execution-dependency path set is not exact, relative, and unique.'
        }
        $path = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
        if (-not $path.StartsWith($rootPrefix, [StringComparison]::Ordinal) -or
            -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The API-attestation correction execution dependency '$relativePath' is absent or outside the repository."
        }
        $sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "The API-attestation correction execution dependency '$relativePath' has no exact SHA256."
        }
        $metadata.Add([ordered]@{ path = $relativePath; sha256 = $sha256 })
        $previous = $relativePath
    }
    return @($metadata)
}

function Assert-ApiAttestationCorrectionExecutionDependencyContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Expected,
        [string]$RepositoryRoot = $ApiAttestationCorrectionRepositoryRoot,
        [string[]]$RelativePaths = $ApiAttestationCorrectionExecutionDependencyPaths
    )

    $current = @(Get-ApiAttestationCorrectionExecutionDependencyMetadata `
        -RepositoryRoot $RepositoryRoot -RelativePaths $RelativePaths)
    if ((Get-BootstrapObjectFingerprint -InputObject @($Expected)) -cne
        (Get-BootstrapObjectFingerprint -InputObject $current)) {
        throw 'The API-attestation correction executable dependency contract changed.'
    }
    return $current
}

function Get-ApiAttestationCorrectionDictionaryKeys {
    param([Parameter()][AllowNull()]$Value)
    if ($Value -is [System.Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ }) }
    if ($null -ne $Value) { return @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name }) }
    return @()
}

function Assert-ApiAttestationCorrectionExactKeys {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Label
    )
    $actual = @(Get-ApiAttestationCorrectionDictionaryKeys -Value $Value | Sort-Object)
    $expectedSorted = @($Expected | Sort-Object)
    if (($actual -join '|') -cne ($expectedSorted -join '|')) {
        throw "$Label has an unsupported field surface."
    }
}

function Get-ApiAttestationCorrectionAcceptedDependencyBinding {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$SourceContract)

    if (-not $SourceContract.Contains('executionDependencies')) {
        throw 'The accepted API correction source contract has no executable dependency binding.'
    }
    $outer = @($SourceContract.executionDependencies)
    $mode = ''
    $entries = @()
    if ($outer.Count -eq $ApiAttestationCorrectionExecutionDependencyPaths.Count -and
        @($outer | Where-Object { $_ -isnot [System.Collections.IDictionary] }).Count -eq 0) {
        $mode = 'CurrentFlat'
        $entries = $outer
    }
    elseif ($outer.Count -eq 1 -and $outer[0] -is [System.Array]) {
        $inner = @($outer[0])
        if ($inner.Count -ne $ApiAttestationCorrectionExecutionDependencyPaths.Count -or
            @($inner | Where-Object { $_ -isnot [System.Collections.IDictionary] }).Count -ne 0) {
            throw 'The legacy API correction execution dependencies have unsupported nesting.'
        }
        $mode = 'ExactPredecessorNested'
        $entries = $inner
    }
    else {
        throw 'The accepted API correction execution dependencies have unsupported cardinality or nesting.'
    }

    for ($index = 0; $index -lt $entries.Count; $index++) {
        Assert-ApiAttestationCorrectionExactKeys `
            -Value $entries[$index] `
            -Label 'Accepted API correction execution dependency' `
            -Expected @('path', 'sha256')
        if ([string]$entries[$index].path -cne [string]$ApiAttestationCorrectionExecutionDependencyPaths[$index] -or
            [string]$entries[$index].sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'The accepted API correction execution-dependency order or SHA256 is not exact.'
        }
    }
    return [ordered]@{
        mode = $mode
        entries = $entries
        rawFingerprint = Get-BootstrapObjectFingerprint -InputObject $SourceContract.executionDependencies
        normalizedFingerprint = Get-BootstrapObjectFingerprint -InputObject $entries
    }
}

function Get-ApiAttestationCorrectionAcceptedOverlayBinding {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$SourceContract)

    if (-not $SourceContract.Contains('overlays')) {
        throw 'The accepted API correction source contract has no reviewed overlay binding.'
    }
    $outer = @($SourceContract.overlays)
    $mode = ''
    $entries = @()
    if ($outer.Count -eq $ApiAttestationCorrectionOverlayContract.Count -and
        @($outer | Where-Object { $_ -isnot [System.Collections.IDictionary] }).Count -eq 0) {
        $mode = 'CurrentFlat'
        $entries = $outer
    }
    elseif ($outer.Count -eq 1 -and $outer[0] -is [System.Array]) {
        $inner = @($outer[0])
        if ($inner.Count -ne $ApiAttestationCorrectionOverlayContract.Count -or
            @($inner | Where-Object { $_ -isnot [System.Collections.IDictionary] }).Count -ne 0) {
            throw 'The legacy API correction reviewed overlays have unsupported nesting.'
        }
        $mode = 'ExactPredecessorNested'
        $entries = $inner
    }
    else {
        throw 'The accepted API correction reviewed overlays have unsupported cardinality or nesting.'
    }
    foreach ($entry in $entries) {
        Assert-ApiAttestationCorrectionExactKeys -Value $entry -Label 'Accepted API correction overlay' -Expected @(
            'path', 'acceptedSha256', 'correctedSha256')
    }
    $normalizedFingerprint = Get-BootstrapObjectFingerprint -InputObject $entries
    if ($normalizedFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject @($ApiAttestationCorrectionOverlayContract))) {
        throw 'The accepted API correction reviewed overlay contract is not exact.'
    }
    return [ordered]@{
        mode = $mode
        entries = $entries
        rawFingerprint = Get-BootstrapObjectFingerprint -InputObject $SourceContract.overlays
        normalizedFingerprint = $normalizedFingerprint
    }
}

function New-ApiAttestationCorrectionResumeReconciliation {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$CurrentSource)

    $currentDependencies = @(Get-ApiAttestationCorrectionExecutionDependencyMetadata)
    $contract = [ordered]@{
        schemaVersion = 1
        mode = 'ExactPredecessorReceiptResume'
        predecessorReceiptFingerprint = [string]$ApiAttestationCorrectionPredecessorResume.receiptFingerprint
        predecessorContractFingerprint = [string]$ApiAttestationCorrectionPredecessorResume.contractFingerprint
        predecessorSourceContractFingerprint = [string]$ApiAttestationCorrectionPredecessorResume.sourceContractFingerprint
        predecessorToolFingerprint = [string]$ApiAttestationCorrectionPredecessorResume.toolFingerprint
        predecessorNestedOverlaysFingerprint = [string]$ApiAttestationCorrectionPredecessorResume.nestedOverlaysFingerprint
        predecessorNormalizedOverlaysFingerprint = [string]$ApiAttestationCorrectionPredecessorResume.normalizedOverlaysFingerprint
        predecessorNestedDependenciesFingerprint = [string]$ApiAttestationCorrectionPredecessorResume.nestedDependenciesFingerprint
        predecessorNormalizedDependenciesFingerprint = [string]$ApiAttestationCorrectionPredecessorResume.normalizedDependenciesFingerprint
        currentSourceContractFingerprint = [string]$CurrentSource.sourceContractFingerprint
        currentToolFingerprint = [string]$CurrentSource.toolFingerprint
        currentExecutionDependencies = ConvertTo-BootstrapCanonicalValue -Value $currentDependencies
        currentExecutionDependenciesFingerprint = Get-BootstrapObjectFingerprint -InputObject $currentDependencies
    }
    return [ordered]@{
        schemaVersion = 1
        acceptedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        contract = $contract
        contractFingerprint = Get-BootstrapObjectFingerprint -InputObject $contract
    }
}

function Assert-ApiAttestationCorrectionResumeReconciliation {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Reconciliation,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CurrentSource
    )

    Assert-ApiAttestationCorrectionExactKeys -Value $Reconciliation -Label 'API correction resume reconciliation' -Expected @(
        'schemaVersion', 'acceptedAtUtc', 'contract', 'contractFingerprint')
    if ($Reconciliation.contract -isnot [System.Collections.IDictionary]) {
        throw 'The API correction resume reconciliation contract is malformed.'
    }
    $contract = $Reconciliation.contract
    Assert-ApiAttestationCorrectionExactKeys -Value $contract -Label 'API correction resume reconciliation contract' -Expected @(
        'schemaVersion', 'mode', 'predecessorReceiptFingerprint', 'predecessorContractFingerprint',
        'predecessorSourceContractFingerprint', 'predecessorToolFingerprint',
        'predecessorNestedOverlaysFingerprint', 'predecessorNormalizedOverlaysFingerprint',
        'predecessorNestedDependenciesFingerprint', 'predecessorNormalizedDependenciesFingerprint',
        'currentSourceContractFingerprint', 'currentToolFingerprint', 'currentExecutionDependencies',
        'currentExecutionDependenciesFingerprint')
    foreach ($name in @(
        'contractFingerprint',
        'predecessorReceiptFingerprint', 'predecessorContractFingerprint', 'predecessorSourceContractFingerprint',
        'predecessorToolFingerprint', 'predecessorNestedOverlaysFingerprint',
        'predecessorNormalizedOverlaysFingerprint', 'predecessorNestedDependenciesFingerprint',
        'predecessorNormalizedDependenciesFingerprint', 'currentSourceContractFingerprint',
        'currentToolFingerprint', 'currentExecutionDependenciesFingerprint')) {
        $value = if ($name -ceq 'contractFingerprint') { [string]$Reconciliation[$name] } else { [string]$contract[$name] }
        Assert-BootstrapFingerprintValue -Value $value -Label "API correction resume reconciliation $name"
    }
    $acceptedAt = [DateTimeOffset]::MinValue
    $dependencySource = [ordered]@{ executionDependencies = $contract.currentExecutionDependencies }
    $dependencyBinding = Get-ApiAttestationCorrectionAcceptedDependencyBinding -SourceContract $dependencySource
    if ([int]$Reconciliation.schemaVersion -ne 1 -or
        [int]$contract.schemaVersion -ne 1 -or
        [string]$contract.mode -cne 'ExactPredecessorReceiptResume' -or
        (Get-BootstrapObjectFingerprint -InputObject $contract) -cne [string]$Reconciliation.contractFingerprint -or
        [string]$contract.predecessorReceiptFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.receiptFingerprint -or
        [string]$contract.predecessorContractFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.contractFingerprint -or
        [string]$contract.predecessorSourceContractFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.sourceContractFingerprint -or
        [string]$contract.predecessorToolFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.toolFingerprint -or
        [string]$contract.predecessorNestedOverlaysFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.nestedOverlaysFingerprint -or
        [string]$contract.predecessorNormalizedOverlaysFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.normalizedOverlaysFingerprint -or
        [string]$contract.predecessorNestedDependenciesFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.nestedDependenciesFingerprint -or
        [string]$contract.predecessorNormalizedDependenciesFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.normalizedDependenciesFingerprint -or
        [string]$contract.currentSourceContractFingerprint -cne [string]$CurrentSource.sourceContractFingerprint -or
        [string]$contract.currentToolFingerprint -cne [string]$CurrentSource.toolFingerprint -or
        [string]$dependencyBinding.mode -cne 'CurrentFlat' -or
        [string]$dependencyBinding.normalizedFingerprint -cne [string]$contract.currentExecutionDependenciesFingerprint -or
        [string]$contract.currentExecutionDependenciesFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject @($CurrentSource.executionDependencies)) -or
        -not [DateTimeOffset]::TryParse([string]$Reconciliation.acceptedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$acceptedAt) -or
        $acceptedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        throw 'The API correction resume reconciliation is outside its exact predecessor and current execution contract.'
    }
    $null = Assert-ApiAttestationCorrectionExecutionDependencyContract -Expected @($dependencyBinding.entries)
    return $true
}

function Assert-ApiAttestationCorrectionHistoricalSchema2Reconciliation {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Reconciliation)

    Assert-ApiAttestationCorrectionExactKeys -Value $Reconciliation -Label 'Historical schema-2 API correction resume reconciliation' -Expected @(
        'schemaVersion', 'acceptedAtUtc', 'contract', 'contractFingerprint')
    if ($Reconciliation.contract -isnot [System.Collections.IDictionary]) {
        throw 'The historical schema-2 API correction resume reconciliation is malformed.'
    }
    $contract = $Reconciliation.contract
    Assert-ApiAttestationCorrectionExactKeys -Value $contract -Label 'Historical schema-2 API correction resume reconciliation contract' -Expected @(
        'schemaVersion', 'mode', 'predecessorReceiptFingerprint', 'predecessorContractFingerprint',
        'predecessorSourceContractFingerprint', 'predecessorToolFingerprint',
        'predecessorNestedOverlaysFingerprint', 'predecessorNormalizedOverlaysFingerprint',
        'predecessorNestedDependenciesFingerprint', 'predecessorNormalizedDependenciesFingerprint',
        'currentSourceContractFingerprint', 'currentToolFingerprint', 'currentExecutionDependencies',
        'currentExecutionDependenciesFingerprint')
    $dependencySource = [ordered]@{ executionDependencies = $contract.currentExecutionDependencies }
    $dependencyBinding = Get-ApiAttestationCorrectionAcceptedDependencyBinding -SourceContract $dependencySource
    $acceptedAt = [DateTimeOffset]::MinValue
    if ([int]$Reconciliation.schemaVersion -ne 1 -or
        [int]$contract.schemaVersion -ne 1 -or
        [string]$contract.mode -cne 'ExactPredecessorReceiptResume' -or
        (Get-BootstrapObjectFingerprint -InputObject $Reconciliation) -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2ReconciliationFingerprint -or
        (Get-BootstrapObjectFingerprint -InputObject $contract) -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2ReconciliationContractFingerprint -or
        [string]$Reconciliation.contractFingerprint -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2ReconciliationContractFingerprint -or
        [string]$contract.predecessorReceiptFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.receiptFingerprint -or
        [string]$contract.predecessorContractFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.contractFingerprint -or
        [string]$contract.predecessorSourceContractFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.sourceContractFingerprint -or
        [string]$contract.predecessorToolFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.toolFingerprint -or
        [string]$contract.predecessorNestedOverlaysFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.nestedOverlaysFingerprint -or
        [string]$contract.predecessorNormalizedOverlaysFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.normalizedOverlaysFingerprint -or
        [string]$contract.predecessorNestedDependenciesFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.nestedDependenciesFingerprint -or
        [string]$contract.predecessorNormalizedDependenciesFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.normalizedDependenciesFingerprint -or
        [string]$contract.currentSourceContractFingerprint -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2CurrentSourceContractFingerprint -or
        [string]$contract.currentToolFingerprint -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2CurrentToolFingerprint -or
        [string]$contract.currentExecutionDependenciesFingerprint -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2CurrentExecutionDependenciesFingerprint -or
        [string]$dependencyBinding.mode -cne 'CurrentFlat' -or
        [string]$dependencyBinding.normalizedFingerprint -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2CurrentExecutionDependenciesFingerprint -or
        -not [DateTimeOffset]::TryParse([string]$Reconciliation.acceptedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$acceptedAt) -or
        $acceptedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        throw 'The historical schema-2 API correction resume reconciliation is not the exact reviewed predecessor.'
    }
    return $true
}

function New-ApiAttestationCorrectionAcrProjectionReconciliation {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$CurrentSource)

    $currentDependencies = @(Get-ApiAttestationCorrectionExecutionDependencyMetadata)
    $contract = [ordered]@{
        schemaVersion = 1
        mode = 'ExactSchema2AcrOutputProjectionResume'
        schema2ReceiptFingerprint = [string]$ApiAttestationCorrectionAcrProjectionResume.schema2ReceiptFingerprint
        schema2ReconciliationFingerprint = [string]$ApiAttestationCorrectionAcrProjectionResume.schema2ReconciliationFingerprint
        schema2ReconciliationContractFingerprint = [string]$ApiAttestationCorrectionAcrProjectionResume.schema2ReconciliationContractFingerprint
        schema2CurrentSourceContractFingerprint = [string]$ApiAttestationCorrectionAcrProjectionResume.schema2CurrentSourceContractFingerprint
        schema2CurrentToolFingerprint = [string]$ApiAttestationCorrectionAcrProjectionResume.schema2CurrentToolFingerprint
        schema2CurrentExecutionDependenciesFingerprint = [string]$ApiAttestationCorrectionAcrProjectionResume.schema2CurrentExecutionDependenciesFingerprint
        currentSourceContractFingerprint = [string]$CurrentSource.sourceContractFingerprint
        currentToolFingerprint = [string]$CurrentSource.toolFingerprint
        currentExecutionDependencies = ConvertTo-BootstrapCanonicalValue -Value $currentDependencies
        currentExecutionDependenciesFingerprint = Get-BootstrapObjectFingerprint -InputObject $currentDependencies
    }
    return [ordered]@{
        schemaVersion = 1
        acceptedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        contract = $contract
        contractFingerprint = Get-BootstrapObjectFingerprint -InputObject $contract
    }
}

function Assert-ApiAttestationCorrectionAcrProjectionReconciliation {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Reconciliation,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CurrentSource
    )

    Assert-ApiAttestationCorrectionExactKeys -Value $Reconciliation -Label 'API correction ACR projection reconciliation' -Expected @(
        'schemaVersion', 'acceptedAtUtc', 'contract', 'contractFingerprint')
    if ($Reconciliation.contract -isnot [System.Collections.IDictionary]) {
        throw 'The API correction ACR projection reconciliation is malformed.'
    }
    $contract = $Reconciliation.contract
    Assert-ApiAttestationCorrectionExactKeys -Value $contract -Label 'API correction ACR projection reconciliation contract' -Expected @(
        'schemaVersion', 'mode', 'schema2ReceiptFingerprint', 'schema2ReconciliationFingerprint',
        'schema2ReconciliationContractFingerprint', 'schema2CurrentSourceContractFingerprint',
        'schema2CurrentToolFingerprint', 'schema2CurrentExecutionDependenciesFingerprint',
        'currentSourceContractFingerprint', 'currentToolFingerprint', 'currentExecutionDependencies',
        'currentExecutionDependenciesFingerprint')
    foreach ($name in @(
        'contractFingerprint', 'schema2ReceiptFingerprint', 'schema2ReconciliationFingerprint',
        'schema2ReconciliationContractFingerprint', 'schema2CurrentSourceContractFingerprint',
        'schema2CurrentToolFingerprint', 'schema2CurrentExecutionDependenciesFingerprint',
        'currentSourceContractFingerprint', 'currentToolFingerprint', 'currentExecutionDependenciesFingerprint')) {
        $value = if ($name -ceq 'contractFingerprint') { [string]$Reconciliation[$name] } else { [string]$contract[$name] }
        Assert-BootstrapFingerprintValue -Value $value -Label "API correction ACR projection reconciliation $name"
    }
    $dependencySource = [ordered]@{ executionDependencies = $contract.currentExecutionDependencies }
    $dependencyBinding = Get-ApiAttestationCorrectionAcceptedDependencyBinding -SourceContract $dependencySource
    $acceptedAt = [DateTimeOffset]::MinValue
    if ([int]$Reconciliation.schemaVersion -ne 1 -or
        [int]$contract.schemaVersion -ne 1 -or
        [string]$contract.mode -cne 'ExactSchema2AcrOutputProjectionResume' -or
        (Get-BootstrapObjectFingerprint -InputObject $contract) -cne [string]$Reconciliation.contractFingerprint -or
        [string]$contract.schema2ReceiptFingerprint -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2ReceiptFingerprint -or
        [string]$contract.schema2ReconciliationFingerprint -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2ReconciliationFingerprint -or
        [string]$contract.schema2ReconciliationContractFingerprint -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2ReconciliationContractFingerprint -or
        [string]$contract.schema2CurrentSourceContractFingerprint -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2CurrentSourceContractFingerprint -or
        [string]$contract.schema2CurrentToolFingerprint -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2CurrentToolFingerprint -or
        [string]$contract.schema2CurrentExecutionDependenciesFingerprint -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2CurrentExecutionDependenciesFingerprint -or
        [string]$contract.currentSourceContractFingerprint -cne [string]$CurrentSource.sourceContractFingerprint -or
        [string]$contract.currentToolFingerprint -cne [string]$CurrentSource.toolFingerprint -or
        [string]$dependencyBinding.mode -cne 'CurrentFlat' -or
        [string]$dependencyBinding.normalizedFingerprint -cne [string]$contract.currentExecutionDependenciesFingerprint -or
        [string]$contract.currentExecutionDependenciesFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject @($CurrentSource.executionDependencies)) -or
        -not [DateTimeOffset]::TryParse([string]$Reconciliation.acceptedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$acceptedAt) -or
        $acceptedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        throw 'The API correction ACR projection reconciliation is outside its exact schema-2 predecessor and current execution contract.'
    }
    $null = Assert-ApiAttestationCorrectionExecutionDependencyContract -Expected @($dependencyBinding.entries)
    return $true
}

function ConvertTo-ApiAttestationCorrectionSchema3Receipt {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CurrentSource
    )

    Assert-ApiAttestationCorrectionExactKeys -Value $Receipt -Label 'Exact schema-2 API correction receipt' -Expected @(
        'schemaVersion', 'operation', 'locatorFingerprint', 'contractFingerprint', 'receiptFingerprint',
        'acceptedContract', 'status', 'acceptedAtUtc', 'updatedAtUtc', 'verifiedAtUtc', 'build', 'deployment',
        'verification', 'resumeReconciliation')
    if ([int]$Receipt.schemaVersion -ne 2 -or
        [string]$Receipt.receiptFingerprint -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2ReceiptFingerprint -or
        (Get-BootstrapApiAttestationCorrectionReceiptFingerprint -Receipt $Receipt) -cne [string]$ApiAttestationCorrectionAcrProjectionResume.schema2ReceiptFingerprint) {
        throw 'Only the exact reviewed schema-2 API correction receipt may enter ACR projection reconciliation.'
    }
    $null = Assert-ApiAttestationCorrectionHistoricalSchema2Reconciliation -Reconciliation $Receipt.resumeReconciliation
    $acceptedContractFingerprint = Get-BootstrapObjectFingerprint -InputObject $Receipt.acceptedContract
    $resumeReconciliationFingerprint = Get-BootstrapObjectFingerprint -InputObject $Receipt.resumeReconciliation
    $copy = ConvertTo-BootstrapCanonicalValue -Value $Receipt
    if ($copy -isnot [System.Collections.IDictionary]) {
        throw 'The exact schema-2 API correction receipt could not be copied canonically.'
    }
    $copy['schemaVersion'] = 3
    $copy['acrProjectionReconciliation'] = New-ApiAttestationCorrectionAcrProjectionReconciliation -CurrentSource $CurrentSource
    if ((Get-BootstrapObjectFingerprint -InputObject $copy.acceptedContract) -cne $acceptedContractFingerprint -or
        (Get-BootstrapObjectFingerprint -InputObject $copy.resumeReconciliation) -cne $resumeReconciliationFingerprint) {
        throw 'Schema-3 API correction reconciliation changed preserved receipt authority.'
    }
    return $copy
}

function Assert-ApiAttestationCorrectionExactPredecessorReceipt {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][System.Collections.IDictionary]$DependencyBinding,
        [Parameter(Mandatory)][System.Collections.IDictionary]$OverlayBinding,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CurrentSource,
        [switch]$AllowUnreconciled,
        [switch]$AllowSchema2ProjectionUpgrade
    )

    $contract = $Receipt.acceptedContract
    if ([string]$DependencyBinding.mode -cne 'ExactPredecessorNested' -or
        [string]$OverlayBinding.mode -cne 'ExactPredecessorNested' -or
        [string]$Receipt.locatorFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.locatorFingerprint -or
        [string]$Receipt.contractFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.contractFingerprint -or
        [string]$contract.source.toolFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.toolFingerprint -or
        [string]$contract.source.originalSourceFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.originalSourceFingerprint -or
        [string]$contract.source.synthesizedBuildSourceFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.synthesizedBuildSourceFingerprint -or
        (Get-BootstrapObjectFingerprint -InputObject $contract.source) -cne [string]$ApiAttestationCorrectionPredecessorResume.sourceContractFingerprint -or
        [string]$OverlayBinding.rawFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.nestedOverlaysFingerprint -or
        [string]$OverlayBinding.normalizedFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.normalizedOverlaysFingerprint -or
        [string]$DependencyBinding.rawFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.nestedDependenciesFingerprint -or
        [string]$DependencyBinding.normalizedFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.normalizedDependenciesFingerprint -or
        [string]$DependencyBinding.normalizedFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject @($ApiAttestationCorrectionPredecessorResume.executionDependencies)) -or
        [string]$contract.build.tag -cne [string]$ApiAttestationCorrectionPredecessorResume.tag -or
        [string]$Receipt.build.tag -cne [string]$ApiAttestationCorrectionPredecessorResume.tag -or
        [string]$Receipt.build.runId -cne [string]$ApiAttestationCorrectionPredecessorResume.runId -or
        [string]$Receipt.build.digest -cne [string]$ApiAttestationCorrectionPredecessorResume.digest -or
        [string]$Receipt.build.state -cne 'DigestCheckpointed' -or
        [string]$Receipt.build.image -cne [string]$Receipt.deployment.targetImage -or
        [string]$Receipt.build.image -cnotmatch "@$([regex]::Escape([string]$ApiAttestationCorrectionPredecessorResume.digest))$" -or
        [string]$contract.deployment.targetRevisionName -cne [string]$ApiAttestationCorrectionPredecessorResume.targetRevisionName -or
        [string]$Receipt.deployment.targetRevisionName -cne [string]$ApiAttestationCorrectionPredecessorResume.targetRevisionName -or
        [string]$Receipt.deployment.state -notin @('IntentRecorded', 'Succeeded')) {
        throw 'The receipt is not the exact reviewed predecessor API-correction execution.'
    }
    if ([int]$Receipt.schemaVersion -eq 3) {
        if (-not $Receipt.Contains('resumeReconciliation') -or
            -not $Receipt.Contains('acrProjectionReconciliation')) {
            throw 'The schema-3 predecessor API-correction receipt is missing an additive reconciliation contract.'
        }
        $null = Assert-ApiAttestationCorrectionHistoricalSchema2Reconciliation `
            -Reconciliation $Receipt.resumeReconciliation
        $null = Assert-ApiAttestationCorrectionAcrProjectionReconciliation `
            -Reconciliation $Receipt.acrProjectionReconciliation -CurrentSource $CurrentSource
    }
    elseif ([int]$Receipt.schemaVersion -eq 2 -and $Receipt.Contains('resumeReconciliation')) {
        if ($Receipt.Contains('acrProjectionReconciliation')) {
            throw 'The schema-2 predecessor API-correction receipt carries an unsupported projection reconciliation.'
        }
        if ($AllowSchema2ProjectionUpgrade -and
            [string]$Receipt.receiptFingerprint -ceq [string]$ApiAttestationCorrectionAcrProjectionResume.schema2ReceiptFingerprint) {
            $null = Assert-ApiAttestationCorrectionHistoricalSchema2Reconciliation `
                -Reconciliation $Receipt.resumeReconciliation
        }
        else {
            $null = Assert-ApiAttestationCorrectionResumeReconciliation `
                -Reconciliation $Receipt.resumeReconciliation -CurrentSource $CurrentSource
        }
    }
    elseif ([int]$Receipt.schemaVersion -ne 1 -or
        $Receipt.Contains('resumeReconciliation') -or
        $Receipt.Contains('acrProjectionReconciliation') -or
        -not $AllowUnreconciled -or
        [string]$Receipt.receiptFingerprint -cne [string]$ApiAttestationCorrectionPredecessorResume.receiptFingerprint -or
        [string]$Receipt.status -cne 'NeedsAttention' -or
        [string]$Receipt.deployment.state -cne 'IntentRecorded' -or
        [string]$Receipt.verification.state -cne 'Pending') {
        throw 'The exact predecessor API-correction receipt has not been additively bound to the current reconciliation code.'
    }
    return $true
}

function Get-BootstrapApiAttestationCorrectionReceiptFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Receipt)

    $copy = ConvertTo-BootstrapCanonicalValue -Value $Receipt
    if ($copy -isnot [System.Collections.IDictionary]) {
        throw 'The API-attestation correction receipt is not a canonical object.'
    }
    $null = $copy.Remove('receiptFingerprint')
    return Get-BootstrapObjectFingerprint -InputObject $copy
}

function Write-ApiAttestationCorrectionReceiptAtomic {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$Path
    )

    if ((Get-BootstrapApiAttestationCorrectionReceiptFingerprint -Receipt $Receipt) -cne [string]$Receipt.receiptFingerprint) {
        throw 'The prepared API-attestation correction receipt fingerprint is invalid.'
    }
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ".api-attestation-$([guid]::NewGuid().ToString('N')).tmp"
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
            if ($LASTEXITCODE -ne 0) {
                throw 'Could not restrict the API-attestation correction receipt to the current user.'
            }
        }
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Save-ApiAttestationCorrectionReceipt {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$Path
    )

    $Receipt['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    $Receipt['receiptFingerprint'] = Get-BootstrapApiAttestationCorrectionReceiptFingerprint -Receipt $Receipt
    Write-ApiAttestationCorrectionReceiptAtomic -Receipt $Receipt -Path $Path
}

function Get-BootstrapApiAttestationCorrectionReceiptPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter()][string]$LocatorFingerprint = ''
    )

    $directory = Join-Path $ApiAttestationCorrectionRepositoryRoot ".bootstrap/evidence/$($Config.resourceGroupName)/api-attestation-correction"
    if (-not [string]::IsNullOrWhiteSpace($LocatorFingerprint)) {
        Assert-BootstrapFingerprintValue -Value $LocatorFingerprint -Label 'API-attestation correction receipt locator fingerprint'
        return Join-Path $directory "$($LocatorFingerprint.Substring(7)).json"
    }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return $null }
    $receipts = @(Get-ChildItem -LiteralPath $directory -File -Filter '*.json')
    if ($receipts.Count -gt 1) {
        throw 'More than one API-attestation correction receipt exists for this resource group.'
    }
    if ($receipts.Count -eq 0) { return $null }
    if ([string]$receipts[0].BaseName -cnotmatch '^[0-9a-f]{64}$') {
        throw 'The API-attestation correction receipt filename is malformed.'
    }
    return [string]$receipts[0].FullName
}

function Read-BootstrapApiAttestationCorrectionReceipt {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'State')]$Config,
        [Parameter(Mandatory, ParameterSetName = 'State')][System.Collections.IDictionary]$State
    )

    if ($PSCmdlet.ParameterSetName -ceq 'State') {
        $Path = Get-BootstrapApiAttestationCorrectionReceiptPath -Config $Config -State $State
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $parameters = @{ AsHashtable = $true; Depth = 100; ErrorAction = 'Stop' }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $parameters['DateKind'] = 'String'
        }
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json @parameters
    }
    catch {
        throw 'The API-attestation correction receipt is malformed. Preserve it for exact recovery.'
    }
}

function Get-ApiAttestationCorrectionStateBoundary {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )

    $canonicalOwnershipId = ([guid][string]$State.deploymentOwnershipId).ToString('D')
    if ([string]$State.deploymentOwnershipId -cne $canonicalOwnershipId -or
        $State.configuration -isnot [System.Collections.IDictionary] -or
        [string]$State.configuration.subscriptionId -cne [string]$Config.subscriptionId -or
        [string]$State.configuration.tenantId -cne [string]$Config.tenantId -or
        [string]$State.configuration.resourceGroupName -cne [string]$Config.resourceGroupName -or
        [string]$State.configuration.projectName -cne [string]$Config.projectName -or
        [string]$State.configuration.environment -cne [string]$Config.environment -or
        [string]$State.configurationFingerprint -cne (Get-BootstrapConfigurationFingerprint -Config $Config) -or
        $State.acceptedPlan -isnot [System.Collections.IDictionary]) {
        throw 'The bootstrap state is outside the exact configured tenant, subscription, resource group, project, environment, ownership, or configuration boundary.'
    }
    foreach ($name in @('planFingerprint', 'configurationFingerprint', 'sourceFingerprint')) {
        Assert-BootstrapFingerprintValue -Value ([string]$State.acceptedPlan[$name]) -Label "Accepted bootstrap $name"
    }
    if ([string]$State.acceptedPlan.configurationFingerprint -cne [string]$State.configurationFingerprint) {
        throw 'The preserved accepted bootstrap plan does not match the current configuration fingerprint.'
    }

    $prerequisiteNames = @(
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
        'Gateway database',
        'Admin UI identity',
        'Admin UI Key Vault credential',
        'Purview policies',
        'Gateway runtime deployment',
        'Admin UI deployment',
        'Admin UI redirect URIs',
        'Network hardening'
    )
    if ($State.steps -isnot [System.Collections.IDictionary]) {
        throw 'The bootstrap state has no exact persisted step map.'
    }
    $stepBoundary = [Collections.Generic.List[object]]::new()
    foreach ($name in $prerequisiteNames) {
        $step = $State.steps[$name]
        if ($step -isnot [System.Collections.IDictionary] -or
            [string]$step.status -cne 'Completed' -or
            $step.evidence -isnot [System.Collections.IDictionary]) {
            throw "API-attestation correction requires completed, evidenced bootstrap step '$name'."
        }
        Assert-BootstrapFingerprintValue -Value ([string]$step.sourceFingerprint) -Label "Bootstrap step '$name' source fingerprint"
        $stepBoundary.Add([ordered]@{
            name = $name
            sourceFingerprint = [string]$step.sourceFingerprint
            evidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $step.evidence
        })
    }

    $manualPlan = $State.manualDatabaseRepairPlan
    $databaseRecovery = $State.databaseRecoveryPlan
    $database = $State.steps['Gateway database'].evidence
    if ($manualPlan -isnot [System.Collections.IDictionary] -or
        [string]$manualPlan.status -cne 'Completed' -or
        [string]$manualPlan.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        [string]$manualPlan.deploymentOwnershipId -cne $canonicalOwnershipId -or
        [string]$manualPlan.originalSourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint -or
        [string]$manualPlan.databaseEvidenceFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject $database) -or
        $databaseRecovery -isnot [System.Collections.IDictionary] -or
        [string]$databaseRecovery.status -cne 'Failed' -or
        [string]$manualPlan.exhaustedRecoveryPlanFingerprint -cne [string]$databaseRecovery.planFingerprint -or
        [string]$database.manualDatabaseRepairPlanFingerprint -cne [string]$manualPlan.planFingerprint -or
        [string]$database.manualDatabaseRepairSourceFingerprint -cne [string]$manualPlan.repairSourceFingerprint -or
        [string]$database.databaseBootstrapJobImage -cne [string]$manualPlan.correctedImage.image) {
        throw 'The completed manual database repair and its preserved exhausted recovery chain are absent or mismatched.'
    }
    foreach ($value in @(
        [string]$manualPlan.planFingerprint,
        [string]$manualPlan.repairSourceFingerprint,
        [string]$manualPlan.exhaustedRecoveryPlanFingerprint,
        [string]$manualPlan.databaseEvidenceFingerprint)) {
        Assert-BootstrapFingerprintValue -Value $value -Label 'Manual database repair fingerprint'
    }

    $foundation = $State.steps['Azure foundation'].evidence
    $images = $State.steps['Immutable workload images'].evidence
    $runtime = $State.steps['Gateway runtime deployment'].evidence
    if ([string]$foundation.deploymentOwnershipId -cne $canonicalOwnershipId -or
        [string]$images.deploymentOwnershipId -cne $canonicalOwnershipId -or
        [string]$runtime.deploymentOwnershipId -cne $canonicalOwnershipId -or
        [string]$foundation.sourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint -or
        [string]$images.sourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint -or
        [string]$runtime.sourceFingerprint -cne [string]$State.acceptedPlan.sourceFingerprint -or
        [string]$runtime.apiImage -cne [string]$images.api -or
        [string]$runtime.workerImage -cne [string]$images.worker -or
        [string]$images.api -cnotmatch '@sha256:[0-9a-f]{64}$' -or
        [string]$images.worker -cnotmatch '@sha256:[0-9a-f]{64}$') {
        throw 'The exact foundation, immutable image, or runtime evidence no longer matches the accepted bootstrap boundary.'
    }

    $acceptedPlanRecordFingerprint = Get-BootstrapObjectFingerprint -InputObject $State.acceptedPlan
    $manualPlanRecordFingerprint = Get-BootstrapObjectFingerprint -InputObject $manualPlan
    $stableBoundary = [ordered]@{
        schemaVersion = [int]$State.schemaVersion
        bootstrapVersion = [string]$State.bootstrapVersion
        configurationFingerprint = [string]$State.configurationFingerprint
        deploymentOwnershipId = $canonicalOwnershipId
        acceptedBootstrapPlanFingerprint = [string]$State.acceptedPlan.planFingerprint
        acceptedBootstrapPlanRecordFingerprint = $acceptedPlanRecordFingerprint
        originalSourceFingerprint = [string]$State.acceptedPlan.sourceFingerprint
        manualDatabaseRepairPlanFingerprint = [string]$manualPlan.planFingerprint
        manualDatabaseRepairPlanRecordFingerprint = $manualPlanRecordFingerprint
        gatewayDatabaseEvidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $database
        prerequisiteSteps = @($stepBoundary)
    }
    return [ordered]@{
        ownershipId = $canonicalOwnershipId
        acceptedPlanRecordFingerprint = $acceptedPlanRecordFingerprint
        manualPlanRecordFingerprint = $manualPlanRecordFingerprint
        stateBoundaryFingerprint = Get-BootstrapObjectFingerprint -InputObject $stableBoundary
        foundationEvidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $foundation
        imagesEvidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $images
        runtimeEvidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $runtime
        databaseEvidenceFingerprint = Get-BootstrapObjectFingerprint -InputObject $database
        foundation = $foundation
        images = $images
        runtime = $runtime
        database = $database
        manualPlan = $manualPlan
    }
}

function Get-ApiAttestationCorrectionSourceMetadata {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)

    $acceptedRoot = Resolve-BootstrapAcceptedSourceRoot -State $State
    $manifest = @(Get-BootstrapSourceManifest -Root $acceptedRoot)
    if ((Get-BootstrapObjectFingerprint -InputObject $manifest) -cne [string]$State.acceptedPlan.sourceFingerprint) {
        throw 'The original accepted source manifest no longer matches its preserved fingerprint.'
    }
    $byPath = @{}
    foreach ($entry in $manifest) {
        $path = [string]$entry.path
        if ($byPath.ContainsKey($path)) { throw 'The accepted source manifest contains a duplicate path.' }
        $byPath[$path] = [string]$entry.sha256
    }

    $correctedManifest = [Collections.Generic.List[object]]::new()
    foreach ($entry in $manifest) {
        $correctedManifest.Add([ordered]@{ path = [string]$entry.path; sha256 = [string]$entry.sha256 })
    }
    foreach ($overlay in $ApiAttestationCorrectionOverlayContract) {
        $path = [string]$overlay.path
        if (-not $byPath.ContainsKey($path) -or [string]$byPath[$path] -cne [string]$overlay.acceptedSha256) {
            throw "The original accepted hash for reviewed API overlay '$path' is not exact."
        }
        $currentPath = Join-Path $ApiAttestationCorrectionRepositoryRoot $path
        if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
            throw "The reviewed corrected API overlay '$path' is absent."
        }
        $currentHash = (Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentHash -cne [string]$overlay.correctedSha256) {
            throw "The reviewed corrected hash for API overlay '$path' is not exact."
        }
        foreach ($correctedEntry in $correctedManifest) {
            if ([string]$correctedEntry.path -ceq $path) {
                $correctedEntry.sha256 = $currentHash
                break
            }
        }
    }
    $toolFingerprint = "sha256:$((Get-FileHash -LiteralPath $ApiAttestationCorrectionToolPath -Algorithm SHA256).Hash.ToLowerInvariant())"
    $synthesizedFingerprint = Get-BootstrapObjectFingerprint -InputObject @($correctedManifest)
    $executionDependencies = @(Get-ApiAttestationCorrectionExecutionDependencyMetadata)
    Assert-BootstrapFingerprintValue -Value $toolFingerprint -Label 'API-attestation correction tool fingerprint'
    Assert-BootstrapFingerprintValue -Value $synthesizedFingerprint -Label 'Synthesized API build-source fingerprint'
    $sourceContract = [ordered]@{
        originalSourceFingerprint = [string]$State.acceptedPlan.sourceFingerprint
        overlays = ConvertTo-BootstrapCanonicalValue -Value $ApiAttestationCorrectionOverlayContract
        synthesizedBuildSourceFingerprint = $synthesizedFingerprint
        toolFingerprint = $toolFingerprint
        executionDependencies = ConvertTo-BootstrapCanonicalValue -Value $executionDependencies
    }
    return [ordered]@{
        acceptedSourceRoot = $acceptedRoot
        acceptedManifest = $manifest
        synthesizedBuildSourceFingerprint = $synthesizedFingerprint
        toolFingerprint = $toolFingerprint
        executionDependencies = $executionDependencies
        sourceContract = $sourceContract
        sourceContractFingerprint = Get-BootstrapObjectFingerprint -InputObject $sourceContract
    }
}

function New-ApiAttestationCorrectionSynthesizedSource {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$SourceMetadata)

    $temporaryRoot = [IO.Directory]::CreateTempSubdirectory('a365gw-api-attestation-source-').FullName
    try {
        foreach ($entry in @($SourceMetadata.acceptedManifest)) {
            $relativePath = [string]$entry.path
            Assert-BootstrapSourcePathIsRegular -Root ([string]$SourceMetadata.acceptedSourceRoot) -RelativePath $relativePath | Out-Null
            $source = Join-Path ([string]$SourceMetadata.acceptedSourceRoot) $relativePath
            if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry.sha256) {
                throw 'The original accepted source changed while the correction source was being synthesized.'
            }
            $destination = Join-Path $temporaryRoot $relativePath
            [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            [IO.File]::Copy($source, $destination, $true)
        }
        foreach ($overlay in $ApiAttestationCorrectionOverlayContract) {
            $source = Join-Path $ApiAttestationCorrectionRepositoryRoot ([string]$overlay.path)
            $destination = Join-Path $temporaryRoot ([string]$overlay.path)
            if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$overlay.correctedSha256) {
                throw 'A reviewed corrected API overlay changed while source was being synthesized.'
            }
            [IO.File]::SetAttributes($destination, [IO.FileAttributes]::Normal)
            [IO.File]::Copy($source, $destination, $true)
        }
        if ((Get-BootstrapSourceFingerprint -Root $temporaryRoot) -cne [string]$SourceMetadata.synthesizedBuildSourceFingerprint) {
            throw 'The synthesized API build source does not match its exact reviewed fingerprint.'
        }
        return $temporaryRoot
    }
    catch {
        if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
        throw
    }
}

function Get-ApiAttestationCorrectionDescriptor {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Boundary,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SourceMetadata
    )

    $locatorFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
        operation = $ApiAttestationCorrectionOperation
        subscriptionId = [string]$Config.subscriptionId
        tenantId = [string]$Config.tenantId
        resourceGroupName = [string]$Config.resourceGroupName
        deploymentOwnershipId = [string]$Boundary.ownershipId
        configurationFingerprint = [string]$State.configurationFingerprint
        acceptedBootstrapPlanRecordFingerprint = [string]$Boundary.acceptedPlanRecordFingerprint
        manualDatabaseRepairPlanRecordFingerprint = [string]$Boundary.manualPlanRecordFingerprint
        sourceContractFingerprint = [string]$SourceMetadata.sourceContractFingerprint
    })
    $intentId = Get-BootstrapDeterministicGuid -Material "$($Boundary.ownershipId)|$($State.configurationFingerprint)|$($SourceMetadata.sourceContractFingerprint)|api-attestation-correction"
    $tag = Get-BootstrapImageBuildIntentTag `
        -DeploymentOwnershipId ([string]$Boundary.ownershipId) `
        -SourceFingerprint ([string]$SourceMetadata.synthesizedBuildSourceFingerprint) `
        -IntentId $intentId
    $appName = "ca-gateway-api-$($Config.environment)"
    $revisionSuffix = "attest-$($locatorFingerprint.Substring(7, 12))"
    return [ordered]@{
        locatorFingerprint = $locatorFingerprint
        intentId = $intentId
        tag = $tag
        repository = 'gateway-api'
        dockerfile = 'src/Gateway.Api/Dockerfile'
        appName = $appName
        containerName = $appName
        revisionSuffix = $revisionSuffix
        targetRevisionName = "$appName--$revisionSuffix"
    }
}

function Get-ApiAttestationCorrectionNormalizedConfiguration {
    param([Parameter()][AllowNull()]$Configuration)
    $copy = ConvertTo-BootstrapCanonicalValue -Value $Configuration
    if ($copy -isnot [System.Collections.IDictionary]) { $copy = [ordered]@{} }
    foreach ($name in @('registries', 'secrets')) {
        if (-not $copy.Contains($name) -or $null -eq $copy[$name]) { $copy[$name] = @() }
        else { $copy[$name] = @($copy[$name]) }
    }
    if ($copy.Contains('ingress') -and $copy.ingress -is [System.Collections.IDictionary] -and $copy.ingress.Contains('traffic')) {
        foreach ($entry in @($copy.ingress.traffic)) {
            if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('revisionName') -and
                -not [string]::IsNullOrWhiteSpace([string]$entry.revisionName)) {
                $entry.revisionName = '__REVISION__'
            }
        }
    }
    return $copy
}

function Get-ApiAttestationCorrectionContainerAppSnapshot {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Boundary,
        [Parameter(Mandatory)][ValidateSet('Api', 'Worker')][string]$Role,
        [Parameter(Mandatory)][string]$ExpectedImage
    )

    $runtime = $Boundary.runtime
    $foundation = $Boundary.foundation
    $name = if ($Role -ceq 'Api') { "ca-gateway-api-$($Config.environment)" } else { "ca-gateway-worker-$($Config.environment)-v3" }
    $expectedPrincipal = if ($Role -ceq 'Api') { [string]$runtime.apiPrincipalId } else { [string]$runtime.workerPrincipalId }
    $app = Invoke-AzJson -Arguments @(
        'containerapp', 'show', '--subscription', [string]$Config.subscriptionId,
        '--resource-group', [string]$Config.resourceGroupName, '--name', $name)
    $containers = @($app.properties.template.containers)
    $identityNames = @(Get-ApiAttestationCorrectionDictionaryKeys -Value $app.identity.userAssignedIdentities)
    $registries = @($app.properties.configuration.registries)
    $secrets = @($app.properties.configuration.secrets)
    $ingress = $app.properties.configuration.ingress
    $expectedId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.App/containerApps/$name"
    if (-not ([string]$app.id).Equals($expectedId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$app.name -cne $name -or
        [string]$app.properties.provisioningState -cne 'Succeeded' -or
        [string]$app.tags.bootstrapOwnershipId -cne [string]$Boundary.ownershipId -or
        [string]$app.tags.bootstrapSourceFingerprint -cne [string]$Boundary.images.sourceFingerprint -or
        [string]$app.identity.principalId -cne $expectedPrincipal -or
        [string]$app.identity.type -cnotmatch '(?:^|, )SystemAssigned(?:,|$)' -or
        [string]$app.identity.type -cnotmatch '(?:^|, )UserAssigned(?:,|$)' -or
        $identityNames.Count -ne 1 -or
        -not ([string]$identityNames[0]).Equals([string]$foundation.runtimeImagePullIdentityId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$app.properties.configuration.activeRevisionsMode -cne 'Single' -or
        $registries.Count -ne 1 -or
        [string]$registries[0].server -cne [string]$foundation.acrLoginServer -or
        -not ([string]$registries[0].identity).Equals([string]$foundation.runtimeImagePullIdentityId, [StringComparison]::OrdinalIgnoreCase) -or
        $containers.Count -ne 1 -or
        [string]$containers[0].name -cne $name -or
        [string]$containers[0].image -cne $ExpectedImage -or
        $ExpectedImage -cnotmatch '@sha256:[0-9a-f]{64}$') {
        throw "The live $Role Container App is outside the exact ownership, identity, registry, source, or immutable-image boundary."
    }
    if ($Role -ceq 'Api') {
        if ($null -eq $ingress -or $ingress.external -ne $true -or $ingress.allowInsecure -ne $false -or
            [int]$ingress.targetPort -ne 8080 -or
            -not ([string]$ingress.transport).Equals('auto', [StringComparison]::OrdinalIgnoreCase) -or
            [string]$ingress.fqdn -cne [string]$runtime.apiFqdn) {
            throw 'The Gateway API ingress is not the exact external HTTPS-only contract.'
        }
    }
    elseif ($null -ne $ingress) {
        throw 'The workflow-v3 worker unexpectedly exposes ingress.'
    }

    $configuration = Get-ApiAttestationCorrectionNormalizedConfiguration -Configuration $app.properties.configuration
    $template = ConvertTo-BootstrapCanonicalValue -Value $app.properties.template
    $normalizedTemplate = ConvertTo-BootstrapCanonicalValue -Value $app.properties.template
    if ($normalizedTemplate -isnot [System.Collections.IDictionary] -or @($normalizedTemplate.containers).Count -ne 1) {
        throw "The live $Role Container App template cannot be normalized exactly."
    }
    $normalizedTemplate.containers[0].image = '__IMMUTABLE_API_IMAGE__'
    $null = $normalizedTemplate.Remove('revisionSuffix')
    $baseEnvelope = [ordered]@{
        id = ([string]$app.id).ToLowerInvariant()
        name = [string]$app.name
        location = [string]$app.location
        managedEnvironmentId = [string]$app.properties.managedEnvironmentId
        identity = ConvertTo-BootstrapCanonicalValue -Value $app.identity
        tags = ConvertTo-BootstrapCanonicalValue -Value $app.tags
        configuration = $configuration
    }
    return [ordered]@{
        id = [string]$app.id
        name = $name
        image = [string]$containers[0].image
        principalId = [string]$app.identity.principalId
        fqdn = if ($Role -ceq 'Api') { [string]$ingress.fqdn } else { '' }
        latestReadyRevisionName = [string]$app.properties.latestReadyRevisionName
        identityFingerprint = Get-BootstrapObjectFingerprint -InputObject $app.identity
        tagsFingerprint = Get-BootstrapObjectFingerprint -InputObject $app.tags
        configurationFingerprint = Get-BootstrapObjectFingerprint -InputObject $configuration
        templateWithoutRevisionAndImageFingerprint = Get-BootstrapObjectFingerprint -InputObject $normalizedTemplate
        normalizedEnvelopeFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{ app = $baseEnvelope; template = $normalizedTemplate })
        fullEnvelopeFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{ app = $baseEnvelope; template = $template })
        environmentEntryCount = @($containers[0].env).Count
        registryCount = $registries.Count
        secretCount = $secrets.Count
    }
}

function Get-ApiAttestationCorrectionQueueCounts {
    param([Parameter(Mandatory)]$Config)

    $namespace = "sb-$($Config.projectName)-$($Config.environment)"
    $queues = @(Invoke-AzJson -Arguments @(
        'servicebus', 'queue', 'list', '--subscription', [string]$Config.subscriptionId,
        '--resource-group', [string]$Config.resourceGroupName, '--namespace-name', $namespace,
        '--query', '[].{name:name,active:countDetails.activeMessageCount,scheduled:countDetails.scheduledMessageCount,deadLetter:countDetails.deadLetterMessageCount,transfer:countDetails.transferMessageCount,transferDeadLetter:countDetails.transferDeadLetterMessageCount}'))
    if ($queues.Count -eq 0) { throw 'The exact Gateway Service Bus namespace returned no queues.' }
    $result = [Collections.Generic.List[object]]::new()
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($queue in @($queues | Sort-Object name)) {
        if ([string]$queue.name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,259}$' -or
            -not $names.Add([string]$queue.name)) {
            throw 'Service Bus queue readback returned a malformed name.'
        }
        $entry = [ordered]@{ name = [string]$queue.name }
        foreach ($name in @('active', 'scheduled', 'deadLetter', 'transfer', 'transferDeadLetter')) {
            $count = 0L
            if (-not [long]::TryParse([string]$queue.$name, [ref]$count) -or $count -lt 0) {
                throw 'Service Bus queue readback returned a malformed nonnegative count.'
            }
            $entry[$name] = $count
        }
        $result.Add($entry)
    }
    return @($result)
}

function Assert-ApiAttestationCorrectionReadyContract {
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][byte[]]$Body
    )

    if ($StatusCode -ne 200 -or $Body.Length -gt 128) {
        throw 'Gateway API readiness did not return HTTP 200 within the bounded response size.'
    }
    $json = $null
    $statusElement = [Text.Json.JsonElement]::new()
    try {
        $json = [Text.Json.JsonDocument]::Parse([ReadOnlyMemory[byte]]::new($Body))
        $properties = @($json.RootElement.EnumerateObject())
        if ($json.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
            $properties.Count -ne 1 -or
            -not $json.RootElement.TryGetProperty('status', [ref]$statusElement) -or
            $statusElement.ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $statusElement.GetString() -cne 'Ready') {
            throw 'mismatch'
        }
    }
    catch {
        throw 'Gateway API readiness did not return the exact one-field Ready JSON contract.'
    }
    finally {
        if ($json) { $json.Dispose() }
    }
    return 'Ready'
}

function Test-ApiAttestationCorrectionHttp {
    param(
        [Parameter(Mandatory)][string]$Fqdn,
        [switch]$RequireAttestation
    )

    if ($Fqdn -cnotmatch '^[A-Za-z0-9.-]+$') { throw 'The Gateway API FQDN is not canonical.' }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        $checks = $client.GetAsync("https://$Fqdn/health/checks").GetAwaiter().GetResult()
        if ([int]$checks.StatusCode -lt 200 -or [int]$checks.StatusCode -gt 299) {
            throw 'Gateway API health checks did not return a 2xx status.'
        }
        if (-not $RequireAttestation) {
            return [ordered]@{ checksStatus = [int]$checks.StatusCode }
        }

        $ready = $client.GetAsync("https://$Fqdn/health/ready").GetAwaiter().GetResult()
        $readyBody = $ready.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $readyValue = Assert-ApiAttestationCorrectionReadyContract `
            -StatusCode ([int]$ready.StatusCode) -Body $readyBody

        $attestation = $client.GetAsync("https://$Fqdn/health/bootstrap-attestation").GetAwaiter().GetResult()
        $body = $attestation.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        if ([int]$attestation.StatusCode -ne 200 -or $body.Length -gt 512) {
            throw 'Gateway API database attestation did not return HTTP 200 within the bounded response size.'
        }
        $json = $null
        $statusElement = [Text.Json.JsonElement]::new()
        $contractElement = [Text.Json.JsonElement]::new()
        try {
            $json = [Text.Json.JsonDocument]::Parse([ReadOnlyMemory[byte]]::new($body))
            $properties = @($json.RootElement.EnumerateObject())
            if ($json.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
                $properties.Count -ne 2 -or
                -not $json.RootElement.TryGetProperty('status', [ref]$statusElement) -or
                -not $json.RootElement.TryGetProperty('contractVersion', [ref]$contractElement) -or
                $statusElement.ValueKind -ne [Text.Json.JsonValueKind]::String -or
                $statusElement.GetString() -cne 'Attested' -or
                $contractElement.ValueKind -ne [Text.Json.JsonValueKind]::Number -or
                $contractElement.GetInt32() -ne 1) {
                throw 'mismatch'
            }
        }
        catch {
            throw 'Gateway API database attestation did not return the exact v1 Attested JSON contract.'
        }
        finally {
            if ($json) { $json.Dispose() }
        }
        return [ordered]@{
            checksStatus = [int]$checks.StatusCode
            readyStatus = 200
            ready = $readyValue
            attestationStatus = 200
            attestation = 'Attested'
            contractVersion = 1
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-ApiAttestationCorrectionActiveRevision {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$TargetRevisionName,
        [Parameter(Mandatory)][string]$TargetImage,
        [int]$MaximumAttempts = 60
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $revisions = @(Invoke-AzJson -Arguments @(
            'containerapp', 'revision', 'list', '--subscription', [string]$Config.subscriptionId,
            '--resource-group', [string]$Config.resourceGroupName, '--name', $AppName,
            '--query', '[?properties.active==`true`].{name:name,active:properties.active,healthState:properties.healthState,runningState:properties.runningState,replicas:properties.replicas,image:properties.template.containers[0].image}'))
        if ($revisions.Count -eq 1 -and
            [string]$revisions[0].name -ceq $TargetRevisionName -and
            $revisions[0].active -eq $true -and
            [string]$revisions[0].healthState -ceq 'Healthy' -and
            [string]$revisions[0].runningState -in @('Running', 'RunningAtMaxScale') -and
            [int]$revisions[0].replicas -ge 1 -and
            [string]$revisions[0].image -ceq $TargetImage) {
            return [ordered]@{
                name = $TargetRevisionName
                image = $TargetImage
                replicas = [int]$revisions[0].replicas
                healthState = 'Healthy'
                runningState = [string]$revisions[0].runningState
            }
        }
        if ($attempt -lt $MaximumAttempts) { Start-Sleep -Seconds 5 }
    }
    throw 'The corrected API does not expose exactly one active, healthy, running, ready target revision.'
}

function Get-ApiAttestationCorrectionExactRevision {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$TargetRevisionName
    )
    return @(Invoke-AzJson -Arguments @(
        'containerapp', 'revision', 'list', '--subscription', [string]$Config.subscriptionId,
        '--resource-group', [string]$Config.resourceGroupName, '--name', $AppName,
        '--query', "[?name=='$TargetRevisionName'].{name:name,active:properties.active,image:properties.template.containers[0].image}"))
}

function Resolve-ApiAttestationCorrectionBuild {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][bool]$ReceiptCreatedThisInvocation,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SourceMetadata
    )

    $build = $Receipt.build
    $registry = [string]$Receipt.acceptedContract.foundation.acrName
    $loginServer = [string]$Receipt.acceptedContract.foundation.acrLoginServer
    $repository = [string]$build.repository
    $tag = [string]$build.tag
    if ([string]$build.state -ceq 'DigestCheckpointed') {
        if ([string]$build.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$' -or
            [string]$build.digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            [string]$build.image -cne "$loginServer/$repository@$($build.digest)") {
            throw 'The checkpointed corrected API build is not one exact immutable ACR result.'
        }
        $null = Assert-ApiAttestationCorrectionAcrProvenance -Registry $registry -Receipt $Receipt
        return [string]$build.image
    }

    $runs = @(Get-GatewayAcrExactImageRuns -Registry $registry -Repository $repository -Tag $tag)
    $adoptedRun = $false
    if ([string]$build.state -ceq 'IntentRecorded') {
        if (-not [string]::IsNullOrWhiteSpace([string]$build.runId)) {
            throw 'The uncheckpointed corrected API build intent unexpectedly contains an ACR run identifier.'
        }
        if ($runs.Count -eq 0) {
            if (-not $ReceiptCreatedThisInvocation) {
                throw 'The recovered corrected API build intent has no exact run or digest; automatic resubmission is forbidden.'
            }
            $synthesizedRoot = $null
            $buildContext = $null
            try {
                $synthesizedRoot = New-ApiAttestationCorrectionSynthesizedSource -SourceMetadata $SourceMetadata
                $buildContext = New-GatewayAcrBuildContext `
                    -RepositoryRoot $synthesizedRoot `
                    -SourceFingerprint ([string]$SourceMetadata.synthesizedBuildSourceFingerprint)
                $run = Invoke-AzJson -CaptureStdoutOnly -Arguments @(
                    'acr', 'build', '--subscription', [string]$Config.subscriptionId,
                    '--registry', $registry, '--image', "${repository}:$tag",
                    '--file', [string]$build.dockerfile, $buildContext, '--no-logs',
                    '--query', '{runId:runId,status:status,runType:runType,outputImages:not_null(outputImages, `[]`)[].{repository:repository,tag:tag,digest:digest}}')
                $run = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository $repository -Tag $tag
                $build['runId'] = [string]$run.runId
            }
            finally {
                if ($buildContext -and (Test-Path -LiteralPath $buildContext)) { Remove-Item -LiteralPath $buildContext -Recurse -Force }
                if ($synthesizedRoot -and (Test-Path -LiteralPath $synthesizedRoot)) { Remove-Item -LiteralPath $synthesizedRoot -Recurse -Force }
            }
        }
        elseif ($runs.Count -eq 1) {
            $build['runId'] = [string]$runs[0].runId
        }
        else {
            throw 'Corrected API build intent recovery found an ambiguous exact-tag ACR run set.'
        }
        $adoptedRun = $true
    }
    elseif ([string]$build.state -ceq 'RunQueued') {
        if ($runs.Count -ne 1 -or [string]$runs[0].runId -cne [string]$build.runId) {
            throw 'The queued corrected API build no longer has exactly its checkpointed ACR run identifier.'
        }
    }
    else {
        throw 'The corrected API build state is outside its resumable contract.'
    }
    if ([string]$build.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$') {
        throw 'The corrected API build did not produce one bounded ACR run identifier.'
    }
    if ($adoptedRun) {
        $build['state'] = 'RunQueued'
        $build['runCheckpointedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
        Save-ApiAttestationCorrectionReceipt -Receipt $Receipt -Path $ReceiptPath
    }

    $terminal = $null
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        $run = Get-GatewayAcrExactRunById -Registry $registry -Repository $repository -Tag $tag -RunId ([string]$build.runId)
        if ([string]$run.status -ceq 'Succeeded') { $terminal = $run; break }
        if ([string]$run.status -in @('Failed', 'Canceled', 'Error', 'Timeout')) {
            throw 'The exact corrected API ACR build reached terminal failure; automatic resubmission is forbidden.'
        }
        if ($attempt -lt 60) { Start-Sleep -Seconds 2 }
    }
    if (-not $terminal) {
        throw 'The exact corrected API build remains pending. Rerun this command later; no second build will be submitted.'
    }
    $digest = [string]@($terminal.outputImages)[0].digest
    $found = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $tag
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or -not $found -or [string]$found.digest -cne $digest) {
        throw 'The succeeded corrected API build did not reconcile to its exact tag and immutable digest.'
    }
    $build['state'] = 'DigestCheckpointed'
    $build['digest'] = $digest
    $build['image'] = "$loginServer/$repository@$digest"
    $build['digestCheckpointedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    Save-ApiAttestationCorrectionReceipt -Receipt $Receipt -Path $ReceiptPath
    return [string]$build.image
}

function Deploy-ApiAttestationCorrection {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Boundary,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][string]$TargetImage
    )

    $deployment = $Receipt.deployment
    $appName = [string]$deployment.appName
    $targetRevisionName = [string]$deployment.targetRevisionName
    if ([string]$Receipt.build.state -cne 'DigestCheckpointed' -or
        [string]$Receipt.build.image -cne $TargetImage) {
        throw 'The corrected API deployment target is not the exact checkpointed build image.'
    }
    if ([string]$deployment.state -cne 'Planned' -and
        [string]$deployment.targetImage -cne $TargetImage) {
        throw 'The recovered corrected API deployment intent names a different target image.'
    }
    $startedThisInvocation = $false
    if ([string]$deployment.state -ceq 'Planned') {
        $existingTarget = @(Get-ApiAttestationCorrectionExactRevision -Config $Config -AppName $appName -TargetRevisionName $targetRevisionName)
        if ($existingTarget.Count -ne 0) {
            throw 'Fresh corrected API deployment intent collides with an existing target revision.'
        }
        $current = Get-ApiAttestationCorrectionContainerAppSnapshot -Config $Config -Boundary $Boundary -Role Api -ExpectedImage ([string]$Receipt.acceptedContract.baseline.api.image)
        if ([string]$current.normalizedEnvelopeFingerprint -cne [string]$Receipt.acceptedContract.baseline.api.normalizedEnvelopeFingerprint) {
            throw 'The live API no longer matches the accepted correction baseline.'
        }
        $deployment['state'] = 'IntentRecorded'
        $deployment['targetImage'] = $TargetImage
        $deployment['intentRecordedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
        Save-ApiAttestationCorrectionReceipt -Receipt $Receipt -Path $ReceiptPath
        $startedThisInvocation = $true
    }

    $targetRevisions = @(Get-ApiAttestationCorrectionExactRevision -Config $Config -AppName $appName -TargetRevisionName $targetRevisionName)
    if ($targetRevisions.Count -gt 1 -or
        ($targetRevisions.Count -eq 1 -and [string]$targetRevisions[0].image -cne $TargetImage)) {
        throw 'Corrected API deployment recovery found an ambiguous or mismatched target revision.'
    }
    if ($targetRevisions.Count -eq 0) {
        if (-not $startedThisInvocation) {
            throw 'The recovered corrected API deployment intent has no exact target revision; automatic update replay is forbidden.'
        }
        $null = Invoke-AzJson -Arguments @(
            'containerapp', 'update', '--subscription', [string]$Config.subscriptionId,
            '--resource-group', [string]$Config.resourceGroupName,
            '--name', $appName, '--container-name', [string]$deployment.containerName,
            '--image', $TargetImage, '--revision-suffix', [string]$deployment.revisionSuffix)
    }
    $revision = Get-ApiAttestationCorrectionActiveRevision `
        -Config $Config -AppName $appName -TargetRevisionName $targetRevisionName -TargetImage $TargetImage
    $deployment['state'] = 'Succeeded'
    $deployment['completedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
    Save-ApiAttestationCorrectionReceipt -Receipt $Receipt -Path $ReceiptPath
    return $revision
}

function Assert-ApiAttestationCorrectionUnchangedSnapshot {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Before,
        [Parameter(Mandatory)][System.Collections.IDictionary]$After,
        [Parameter(Mandatory)][ValidateSet('Api', 'Worker')][string]$Role
    )
    $fields = if ($Role -ceq 'Api') {
        @('id', 'name', 'principalId', 'fqdn', 'identityFingerprint', 'tagsFingerprint', 'configurationFingerprint',
            'templateWithoutRevisionAndImageFingerprint', 'normalizedEnvelopeFingerprint', 'environmentEntryCount', 'registryCount', 'secretCount')
    }
    else {
        @('id', 'name', 'image', 'principalId', 'fqdn', 'latestReadyRevisionName', 'identityFingerprint', 'tagsFingerprint',
            'configurationFingerprint', 'templateWithoutRevisionAndImageFingerprint', 'normalizedEnvelopeFingerprint',
            'fullEnvelopeFingerprint', 'environmentEntryCount', 'registryCount', 'secretCount')
    }
    foreach ($field in $fields) {
        if ([string]$Before[$field] -cne [string]$After[$field]) {
            throw "$Role identity, configuration, environment, ingress, registry, secrets, tags, or immutable baseline changed during the API-only correction."
        }
    }
    return $true
}

function Assert-ApiAttestationCorrectionAcrProvenance {
    param(
        [Parameter(Mandatory)][string]$Registry,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt
    )

    $runs = @(Get-GatewayAcrExactImageRuns `
        -Registry $Registry `
        -Repository 'gateway-api' `
        -Tag ([string]$Receipt.build.tag))
    if ($runs.Count -ne 1 -or [string]$runs[0].runId -cne [string]$Receipt.build.runId) {
        throw 'The API correction does not have exactly its one receipt-bound ACR QuickRun.'
    }
    $run = Get-GatewayAcrExactRunById `
        -Registry $Registry `
        -Repository 'gateway-api' `
        -Tag ([string]$Receipt.build.tag) `
        -RunId ([string]$Receipt.build.runId)
    $run = Assert-GatewayAcrCompletedBuildContract -Run $run -Repository 'gateway-api' -Tag ([string]$Receipt.build.tag)
    if ([string]@($run.outputImages)[0].digest -cne [string]$Receipt.build.digest) {
        throw 'The receipt-bound corrected API QuickRun output digest changed or is mismatched.'
    }
    $tagDigest = Get-GatewayAcrExactTagDigest `
        -Registry $Registry `
        -Repository 'gateway-api' `
        -Tag ([string]$Receipt.build.tag)
    if (-not $tagDigest -or [string]$tagDigest.digest -cne [string]$Receipt.build.digest) {
        throw 'The corrected API deterministic tag no longer resolves to the receipt-bound immutable digest.'
    }
    return $true
}

function Assert-ApiAttestationCorrectionLiveReceipt {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Boundary,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Contract,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Baseline
    )

    $null = Assert-ApiAttestationCorrectionAcrProvenance `
        -Registry ([string]$Contract.foundation.acrName) -Receipt $Receipt

    $apiNow = Get-ApiAttestationCorrectionContainerAppSnapshot `
        -Config $Config -Boundary $Boundary -Role Api -ExpectedImage ([string]$Receipt.build.image)
    $workerNow = Get-ApiAttestationCorrectionContainerAppSnapshot `
        -Config $Config -Boundary $Boundary -Role Worker -ExpectedImage ([string]$Baseline.worker.image)
    $null = Assert-ApiAttestationCorrectionUnchangedSnapshot -Before $Baseline.api -After $apiNow -Role Api
    $null = Assert-ApiAttestationCorrectionUnchangedSnapshot -Before $Baseline.worker -After $workerNow -Role Worker
    if ([string]$apiNow.latestReadyRevisionName -cne [string]$Receipt.verification.targetRevisionName) {
        throw 'The live corrected API latest ready revision is not the exact receipt-bound target.'
    }
    $null = Get-ApiAttestationCorrectionActiveRevision `
        -Config $Config `
        -AppName ([string]$Contract.deployment.appName) `
        -TargetRevisionName ([string]$Receipt.verification.targetRevisionName) `
        -TargetImage ([string]$Receipt.build.image) `
        -MaximumAttempts 1
    $queuesNow = @(Get-ApiAttestationCorrectionQueueCounts -Config $Config)
    $baselineQueueNames = @($Baseline.queueCounts | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
    $currentQueueNames = @($queuesNow | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
    if ($baselineQueueNames.Count -ne @($Baseline.queueCounts).Count -or
        $currentQueueNames.Count -ne $queuesNow.Count -or
        ($baselineQueueNames -join '|') -cne ($currentQueueNames -join '|')) {
        throw 'Current Service Bus queue topology no longer matches the API-only correction baseline.'
    }
    $currentHttp = Test-ApiAttestationCorrectionHttp -Fqdn ([string]$Boundary.runtime.apiFqdn) -RequireAttestation
    if ([int]$currentHttp.checksStatus -lt 200 -or [int]$currentHttp.checksStatus -gt 299 -or
        [int]$currentHttp.readyStatus -ne 200 -or [string]$currentHttp.ready -cne 'Ready' -or
        [int]$currentHttp.attestationStatus -ne 200 -or [string]$currentHttp.attestation -cne 'Attested' -or
        [int]$currentHttp.contractVersion -ne 1) {
        throw 'Current Gateway API health, readiness, or database-attestation contract is not exact.'
    }
    return $true
}

function Assert-ApiAttestationCorrectionReceiptBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter()][AllowNull()][System.Collections.IDictionary]$Receipt,
        [switch]$AllowUnreconciledPredecessor,
        [switch]$AllowSchema2ProjectionUpgrade,
        [switch]$RequireVerified
    )

    if ($null -eq $Receipt) {
        $Receipt = Read-BootstrapApiAttestationCorrectionReceipt -Config $Config -State $State
    }
    if ($Receipt -isnot [System.Collections.IDictionary]) {
        throw 'No API-attestation correction receipt exists for this bootstrap state.'
    }
    $receiptKeys = @(
        'schemaVersion', 'operation', 'locatorFingerprint', 'contractFingerprint', 'receiptFingerprint',
        'acceptedContract', 'status', 'acceptedAtUtc', 'updatedAtUtc', 'verifiedAtUtc', 'build', 'deployment', 'verification')
    if ($Receipt.Contains('resumeReconciliation')) { $receiptKeys += 'resumeReconciliation' }
    if ($Receipt.Contains('acrProjectionReconciliation')) { $receiptKeys += 'acrProjectionReconciliation' }
    Assert-ApiAttestationCorrectionExactKeys -Value $Receipt -Label 'API-attestation correction receipt' -Expected $receiptKeys
    foreach ($name in @('locatorFingerprint', 'contractFingerprint', 'receiptFingerprint')) {
        Assert-BootstrapFingerprintValue -Value ([string]$Receipt[$name]) -Label "API-attestation correction $name"
    }
    if ([int]$Receipt.schemaVersion -notin @(1, 2, 3) -or
        [string]$Receipt.operation -cne $ApiAttestationCorrectionOperation -or
        $Receipt.acceptedContract -isnot [System.Collections.IDictionary] -or
        $Receipt.build -isnot [System.Collections.IDictionary] -or
        $Receipt.deployment -isnot [System.Collections.IDictionary] -or
        $Receipt.verification -isnot [System.Collections.IDictionary] -or
        (Get-BootstrapApiAttestationCorrectionReceiptFingerprint -Receipt $Receipt) -cne [string]$Receipt.receiptFingerprint -or
        (Get-BootstrapObjectFingerprint -InputObject $Receipt.acceptedContract) -cne [string]$Receipt.contractFingerprint) {
        throw 'The API-attestation correction receipt contract or canonical fingerprint is invalid.'
    }

    $boundary = Get-ApiAttestationCorrectionStateBoundary -Config $Config -State $State
    $source = Get-ApiAttestationCorrectionSourceMetadata -State $State
    $contract = $Receipt.acceptedContract
    $baseline = $contract.baseline
    Assert-ApiAttestationCorrectionExactKeys -Value $contract -Label 'Accepted API-attestation correction contract' -Expected @(
        'schemaVersion', 'operation', 'subscriptionId', 'tenantId', 'resourceGroupName', 'projectName', 'environment',
        'deploymentOwnershipId', 'configurationFingerprint', 'acceptedBootstrapPlanFingerprint',
        'acceptedBootstrapPlanRecordFingerprint', 'manualDatabaseRepairPlanFingerprint',
        'manualDatabaseRepairPlanRecordFingerprint', 'stateBoundaryFingerprint', 'foundationEvidenceFingerprint',
        'imagesEvidenceFingerprint', 'runtimeEvidenceFingerprint', 'databaseEvidenceFingerprint',
        'source', 'foundation', 'baseline', 'build', 'deployment')
    Assert-ApiAttestationCorrectionExactKeys -Value $contract.source -Label 'Accepted API correction source contract' -Expected @(
        'originalSourceFingerprint', 'overlays', 'synthesizedBuildSourceFingerprint', 'toolFingerprint',
        'executionDependencies')
    $dependencyBinding = Get-ApiAttestationCorrectionAcceptedDependencyBinding -SourceContract $contract.source
    $overlayBinding = Get-ApiAttestationCorrectionAcceptedOverlayBinding -SourceContract $contract.source
    $isPredecessorResume = [string]$dependencyBinding.mode -ceq 'ExactPredecessorNested' -and
        [string]$overlayBinding.mode -ceq 'ExactPredecessorNested'
    if ($isPredecessorResume) {
        $null = Assert-ApiAttestationCorrectionExactPredecessorReceipt `
            -Receipt $Receipt -DependencyBinding $dependencyBinding -OverlayBinding $overlayBinding -CurrentSource $source `
            -AllowUnreconciled:$AllowUnreconciledPredecessor `
            -AllowSchema2ProjectionUpgrade:$AllowSchema2ProjectionUpgrade
        $descriptorSource = [ordered]@{
            sourceContractFingerprint = Get-BootstrapObjectFingerprint -InputObject $contract.source
            synthesizedBuildSourceFingerprint = [string]$contract.source.synthesizedBuildSourceFingerprint
        }
    }
    else {
        if ([string]$dependencyBinding.mode -cne 'CurrentFlat' -or
            [string]$overlayBinding.mode -cne 'CurrentFlat' -or
            [int]$Receipt.schemaVersion -ne 1 -or
            $Receipt.Contains('resumeReconciliation') -or
            $Receipt.Contains('acrProjectionReconciliation')) {
            throw 'A current-source API correction receipt cannot carry predecessor resume reconciliation.'
        }
        $null = Assert-ApiAttestationCorrectionExecutionDependencyContract -Expected @($dependencyBinding.entries)
        $descriptorSource = $source
    }
    $descriptor = Get-ApiAttestationCorrectionDescriptor `
        -Config $Config -State $State -Boundary $boundary -SourceMetadata $descriptorSource
    Assert-ApiAttestationCorrectionExactKeys -Value $contract.foundation -Label 'Accepted API correction foundation' -Expected @(
        'acrName', 'acrLoginServer')
    Assert-ApiAttestationCorrectionExactKeys -Value $baseline -Label 'Accepted API correction baseline' -Expected @(
        'api', 'worker', 'queueCounts', 'queueCountsFingerprint')
    Assert-ApiAttestationCorrectionExactKeys -Value $contract.build -Label 'Accepted API correction build contract' -Expected @(
        'intentId', 'repository', 'dockerfile', 'tag')
    Assert-ApiAttestationCorrectionExactKeys -Value $contract.deployment -Label 'Accepted API correction deployment contract' -Expected @(
        'appName', 'containerName', 'revisionSuffix', 'targetRevisionName', 'mutation')
    $snapshotKeys = @(
        'id', 'name', 'image', 'principalId', 'fqdn', 'latestReadyRevisionName', 'identityFingerprint',
        'tagsFingerprint', 'configurationFingerprint', 'templateWithoutRevisionAndImageFingerprint',
        'normalizedEnvelopeFingerprint', 'fullEnvelopeFingerprint', 'environmentEntryCount', 'registryCount', 'secretCount')
    Assert-ApiAttestationCorrectionExactKeys -Value $baseline.api -Label 'Accepted API correction API snapshot' -Expected $snapshotKeys
    Assert-ApiAttestationCorrectionExactKeys -Value $baseline.worker -Label 'Accepted API correction worker snapshot' -Expected $snapshotKeys
    Assert-ApiAttestationCorrectionExactKeys -Value $Receipt.verification -Label 'API correction verification checkpoint' -Expected @(
        'state', 'completedAtUtc', 'stateBoundaryFingerprint', 'targetApiImage', 'targetRevisionName',
        'apiSnapshot', 'workerSnapshot', 'queueCountsAfter', 'http')
    $sourceContractMatches = if ($isPredecessorResume) {
        [string]$contract.source.originalSourceFingerprint -ceq [string]$State.acceptedPlan.sourceFingerprint -and
        [string]$contract.source.synthesizedBuildSourceFingerprint -ceq [string]$source.synthesizedBuildSourceFingerprint -and
        [string]$overlayBinding.normalizedFingerprint -ceq
            (Get-BootstrapObjectFingerprint -InputObject @($ApiAttestationCorrectionOverlayContract))
    }
    else {
        (Get-BootstrapObjectFingerprint -InputObject $contract.source) -ceq [string]$source.sourceContractFingerprint -and
        [string]$contract.source.synthesizedBuildSourceFingerprint -ceq [string]$source.synthesizedBuildSourceFingerprint -and
        [string]$contract.source.toolFingerprint -ceq [string]$source.toolFingerprint
    }
    if ([int]$contract.schemaVersion -ne 1 -or
        [string]$Receipt.locatorFingerprint -cne [string]$descriptor.locatorFingerprint -or
        [string]$contract.operation -cne $ApiAttestationCorrectionOperation -or
        [string]$contract.subscriptionId -cne [string]$Config.subscriptionId -or
        [string]$contract.tenantId -cne [string]$Config.tenantId -or
        [string]$contract.resourceGroupName -cne [string]$Config.resourceGroupName -or
        [string]$contract.projectName -cne [string]$Config.projectName -or
        [string]$contract.environment -cne [string]$Config.environment -or
        [string]$contract.deploymentOwnershipId -cne [string]$boundary.ownershipId -or
        [string]$contract.configurationFingerprint -cne [string]$State.configurationFingerprint -or
        [string]$contract.acceptedBootstrapPlanFingerprint -cne [string]$State.acceptedPlan.planFingerprint -or
        [string]$contract.acceptedBootstrapPlanRecordFingerprint -cne [string]$boundary.acceptedPlanRecordFingerprint -or
        [string]$contract.manualDatabaseRepairPlanFingerprint -cne [string]$boundary.manualPlan.planFingerprint -or
        [string]$contract.manualDatabaseRepairPlanRecordFingerprint -cne [string]$boundary.manualPlanRecordFingerprint -or
        [string]$contract.stateBoundaryFingerprint -cne [string]$boundary.stateBoundaryFingerprint -or
        [string]$contract.foundationEvidenceFingerprint -cne [string]$boundary.foundationEvidenceFingerprint -or
        [string]$contract.imagesEvidenceFingerprint -cne [string]$boundary.imagesEvidenceFingerprint -or
        [string]$contract.runtimeEvidenceFingerprint -cne [string]$boundary.runtimeEvidenceFingerprint -or
        [string]$contract.databaseEvidenceFingerprint -cne [string]$boundary.databaseEvidenceFingerprint -or
        -not $sourceContractMatches -or
        [string]$contract.foundation.acrName -cne [string]$boundary.foundation.acrName -or
        [string]$contract.foundation.acrLoginServer -cne [string]$boundary.foundation.acrLoginServer -or
        [string]$baseline.api.image -cne [string]$boundary.images.api -or
        [string]$baseline.worker.image -cne [string]$boundary.images.worker -or
        [string]$contract.build.intentId -cne [string]$descriptor.intentId -or
        [string]$contract.build.tag -cne [string]$descriptor.tag -or
        [string]$contract.build.repository -cne 'gateway-api' -or
        [string]$contract.build.dockerfile -cne 'src/Gateway.Api/Dockerfile' -or
        [string]$contract.deployment.appName -cne [string]$descriptor.appName -or
        [string]$contract.deployment.containerName -cne [string]$descriptor.containerName -or
        [string]$contract.deployment.revisionSuffix -cne [string]$descriptor.revisionSuffix -or
        [string]$contract.deployment.targetRevisionName -cne [string]$descriptor.targetRevisionName -or
        [string]$contract.deployment.mutation -cne 'DirectContainerAppImmutableImageUpdateOnly' -or
        [string]$baseline.queueCountsFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject @($baseline.queueCounts))) {
        throw 'The API-attestation correction receipt belongs to a different state, source, owner, scope, baseline, build, or deployment contract.'
    }
    Assert-ApiAttestationCorrectionExactKeys -Value $Receipt.build -Label 'API-attestation correction build checkpoint' -Expected @(
        'intentId', 'repository', 'dockerfile', 'tag', 'state', 'runId', 'digest', 'image',
        'intentRecordedAtUtc', 'runCheckpointedAtUtc', 'digestCheckpointedAtUtc')
    Assert-ApiAttestationCorrectionExactKeys -Value $Receipt.deployment -Label 'API-attestation correction deployment checkpoint' -Expected @(
        'appName', 'containerName', 'revisionSuffix', 'targetRevisionName', 'targetImage', 'state', 'intentRecordedAtUtc', 'completedAtUtc')
    if ([string]$Receipt.build.intentId -cne [string]$descriptor.intentId -or
        [string]$Receipt.build.repository -cne 'gateway-api' -or
        [string]$Receipt.build.dockerfile -cne 'src/Gateway.Api/Dockerfile' -or
        [string]$Receipt.build.tag -cne [string]$descriptor.tag -or
        [string]$Receipt.build.state -notin @('IntentRecorded', 'RunQueued', 'DigestCheckpointed') -or
        [string]$Receipt.deployment.appName -cne [string]$descriptor.appName -or
        [string]$Receipt.deployment.targetRevisionName -cne [string]$descriptor.targetRevisionName -or
        [string]$Receipt.deployment.state -notin @('Planned', 'IntentRecorded', 'Succeeded') -or
        [string]$Receipt.status -notin @('Accepted', 'NeedsAttention', 'Verified')) {
        throw 'The mutable API-attestation correction checkpoints are outside the accepted contract.'
    }
    if ([string]$Receipt.build.state -ceq 'DigestCheckpointed') {
        $targetPattern = "^$([regex]::Escape([string]$boundary.foundation.acrLoginServer))/gateway-api@sha256:[0-9a-f]{64}$"
        if ([string]$Receipt.build.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$' -or
            [string]$Receipt.build.digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            [string]$Receipt.build.image -cnotmatch $targetPattern -or
            [string]$Receipt.build.image -ceq [string]$baseline.api.image) {
            throw 'The corrected API digest checkpoint is malformed or did not change the accepted API image.'
        }
    }
    elseif ([string]$Receipt.build.state -ceq 'RunQueued' -and
        [string]$Receipt.build.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$') {
        throw 'The queued corrected API build checkpoint has no exact ACR run identifier.'
    }
    elseif ([string]$Receipt.build.state -ceq 'IntentRecorded' -and
        -not [string]::IsNullOrWhiteSpace([string]$Receipt.build.runId)) {
        throw 'The uncheckpointed corrected API build intent unexpectedly contains an ACR run identifier.'
    }
    if ([string]$Receipt.deployment.state -in @('IntentRecorded', 'Succeeded') -and
        ([string]$Receipt.build.state -cne 'DigestCheckpointed' -or
            [string]$Receipt.deployment.targetImage -cne [string]$Receipt.build.image)) {
        throw 'The corrected API deployment advanced without one immutable build digest.'
    }
    if ([string]$Receipt.deployment.state -ceq 'Planned' -and
        -not [string]::IsNullOrWhiteSpace([string]$Receipt.deployment.targetImage)) {
        throw 'The unstarted corrected API deployment unexpectedly contains a target image checkpoint.'
    }
    if (-not $RequireVerified) {
        return [ordered]@{
            receipt = $Receipt
            boundary = $boundary
            source = $source
            descriptor = $descriptor
            contract = $contract
            baseline = $baseline
            isPredecessorResume = $isPredecessorResume
        }
    }
    if ([string]$Receipt.status -cne 'Verified') {
        throw 'The API-attestation correction receipt has not reached Verified.'
    }
    Assert-ApiAttestationCorrectionExactKeys -Value $Receipt.verification.apiSnapshot -Label 'Verified corrected API snapshot' -Expected $snapshotKeys
    Assert-ApiAttestationCorrectionExactKeys -Value $Receipt.verification.workerSnapshot -Label 'Verified unchanged worker snapshot' -Expected $snapshotKeys
    Assert-ApiAttestationCorrectionExactKeys -Value $Receipt.verification.http -Label 'Verified API correction HTTP contract' -Expected @(
        'checksStatus', 'readyStatus', 'ready', 'attestationStatus', 'attestation', 'contractVersion')
    $verifiedAt = [DateTimeOffset]::MinValue
    if ([string]$Receipt.build.state -cne 'DigestCheckpointed' -or
        [string]$Receipt.deployment.state -cne 'Succeeded' -or
        [string]$Receipt.verification.state -cne 'Succeeded' -or
        [string]$Receipt.verification.targetRevisionName -cne [string]$descriptor.targetRevisionName -or
        [string]$Receipt.verification.targetApiImage -cne [string]$Receipt.build.image -or
        [string]$Receipt.verification.stateBoundaryFingerprint -cne [string]$boundary.stateBoundaryFingerprint -or
        [string]$Receipt.verification.apiSnapshot.normalizedEnvelopeFingerprint -cne [string]$baseline.api.normalizedEnvelopeFingerprint -or
        [string]$Receipt.verification.workerSnapshot.fullEnvelopeFingerprint -cne [string]$baseline.worker.fullEnvelopeFingerprint -or
        (Get-BootstrapObjectFingerprint -InputObject @($Receipt.verification.queueCountsAfter)) -cne [string]$baseline.queueCountsFingerprint -or
        [int]$Receipt.verification.http.checksStatus -lt 200 -or
        [int]$Receipt.verification.http.checksStatus -gt 299 -or
        [int]$Receipt.verification.http.readyStatus -ne 200 -or
        [string]$Receipt.verification.http.ready -cne 'Ready' -or
        [int]$Receipt.verification.http.attestationStatus -ne 200 -or
        [string]$Receipt.verification.http.attestation -cne 'Attested' -or
        [int]$Receipt.verification.http.contractVersion -ne 1 -or
        -not [DateTimeOffset]::TryParse([string]$Receipt.verifiedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$verifiedAt) -or
        $verifiedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        throw 'The API-attestation correction receipt does not contain one exact verified revision, invariant set, queue snapshot, and v1 attestation result.'
    }

    $null = Assert-ApiAttestationCorrectionLiveReceipt `
        -Config $Config -Receipt $Receipt -Boundary $boundary -Contract $contract -Baseline $baseline
    return [ordered]@{
        receiptFingerprint = [string]$Receipt.receiptFingerprint
        contractFingerprint = [string]$Receipt.contractFingerprint
        baselineApiImage = [string]$baseline.api.image
        baselineWorkerImage = [string]$baseline.worker.image
        targetApiImage = [string]$Receipt.build.image
        targetRevisionName = [string]$Receipt.verification.targetRevisionName
        synthesizedBuildSourceFingerprint = [string]$contract.source.synthesizedBuildSourceFingerprint
        verifiedAtUtc = $verifiedAt.ToUniversalTime().ToString('O')
    }
}

function Initialize-ApiAttestationCorrectionResumeReconciliation {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$ReceiptPath
    )

    $binding = Assert-ApiAttestationCorrectionReceiptBoundary `
        -Config $Config -State $State -Receipt $Receipt -AllowUnreconciledPredecessor `
        -AllowSchema2ProjectionUpgrade
    if ([bool]$binding.isPredecessorResume -and -not $Receipt.Contains('resumeReconciliation')) {
        $candidate = ConvertTo-BootstrapCanonicalValue -Value $Receipt
        $reconciliation = New-ApiAttestationCorrectionResumeReconciliation -CurrentSource $binding.source
        $candidate['schemaVersion'] = 2
        $candidate['resumeReconciliation'] = $reconciliation
        $candidate['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
        $candidate['receiptFingerprint'] = Get-BootstrapApiAttestationCorrectionReceiptFingerprint -Receipt $candidate
        $binding = Assert-ApiAttestationCorrectionReceiptBoundary -Config $Config -State $State -Receipt $candidate
        Write-ApiAttestationCorrectionReceiptAtomic -Receipt $candidate -Path $ReceiptPath
    }
    elseif ([bool]$binding.isPredecessorResume -and
        [int]$Receipt.schemaVersion -eq 2 -and
        $Receipt.Contains('resumeReconciliation') -and
        -not $Receipt.Contains('acrProjectionReconciliation') -and
        [string]$Receipt.receiptFingerprint -ceq [string]$ApiAttestationCorrectionAcrProjectionResume.schema2ReceiptFingerprint) {
        $candidate = ConvertTo-ApiAttestationCorrectionSchema3Receipt -Receipt $Receipt -CurrentSource $binding.source
        $candidate['updatedAtUtc'] = [DateTimeOffset]::UtcNow.ToString('O')
        $candidate['receiptFingerprint'] = Get-BootstrapApiAttestationCorrectionReceiptFingerprint -Receipt $candidate
        $binding = Assert-ApiAttestationCorrectionReceiptBoundary -Config $Config -State $State -Receipt $candidate
        Write-ApiAttestationCorrectionReceiptAtomic -Receipt $candidate -Path $ReceiptPath
    }
    return $binding
}

function Assert-BootstrapApiAttestationCorrectionReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter()][AllowNull()][System.Collections.IDictionary]$Receipt
    )
    return Assert-ApiAttestationCorrectionReceiptBoundary `
        -Config $Config -State $State -Receipt $Receipt -RequireVerified
}

function Invoke-ApiAttestationCorrectionCanonicalFinalVerification {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$OriginalAcceptedSourceRoot,
        [switch]$NonInteractive
    )

    Set-BootstrapExecutionSourceRoot -Path $OriginalAcceptedSourceRoot
    $foundation = $State.steps['Azure foundation'].evidence
    $identity = $State.steps['Gateway API identity'].evidence
    $images = $State.steps['Immutable workload images'].evidence
    $blueprint = $State.steps['Agent 365 seed blueprint'].evidence
    $sqlPrivateEndpoint = $State.steps['SQL private endpoint'].evidence
    $database = $State.steps['Gateway database'].evidence
    $adminIdentity = $State.steps['Admin UI identity'].evidence
    $adminCredential = $State.steps['Admin UI Key Vault credential'].evidence
    $runtime = $State.steps['Gateway runtime deployment'].evidence
    $adminUi = $State.steps['Admin UI deployment'].evidence
    $verification = Invoke-BootstrapStateStep `
        -Name 'End-to-end deployment verification' `
        -State $State `
        -StatePath $StatePath `
        -AlwaysRun `
        -Action {
            Test-GatewayBootstrapDeployment `
                -Config $Config -Foundation $foundation -Identity $identity -Blueprint $blueprint `
                -Runtime $runtime -Database $database -SqlPrivateEndpoint $sqlPrivateEndpoint `
                -AdminUi $adminUi -Images $images -AdminIdentity $adminIdentity -AdminCredential $adminCredential `
                -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) `
                -ManualDatabaseRepairPlan $State.manualDatabaseRepairPlan `
                -State $State `
                -NonInteractive:$NonInteractive
        }
    Set-BootstrapExecutionSourceRoot -Path $OriginalAcceptedSourceRoot
    $State.outputs['verification'] = $verification
    $State.outputs['adminUiUrl'] = [string]$adminUi.adminUiUrl
    $State.outputs['apiUrl'] = "https://$($runtime.apiFqdn)"
    Save-BootstrapState -State $State -Path $StatePath
    return $verification
}

function Invoke-BootstrapApiAttestationCorrection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$Yes,
        [switch]$NonInteractive
    )

    if (-not $Yes) {
        throw 'API-attestation correction requires --yes before any build or deployment mutation.'
    }
    Import-ApiAttestationCorrectionModules
    $configuration = Read-BootstrapConfig -Path $ConfigPath
    $statePath = Get-BootstrapStatePath -Config $configuration
    $lock = Enter-BootstrapLock -StatePath $statePath
    $receipt = $null
    $receiptPath = ''
    try {
        $state = Read-BootstrapState -Path $statePath -Config $configuration
        $boundary = Get-ApiAttestationCorrectionStateBoundary -Config $configuration -State $state
        $source = Get-ApiAttestationCorrectionSourceMetadata -State $state
        $discoveredReceiptPath = Get-BootstrapApiAttestationCorrectionReceiptPath -Config $configuration -State $state
        if ($discoveredReceiptPath) {
            $receiptPath = $discoveredReceiptPath
            $loadedReceipt = Read-BootstrapApiAttestationCorrectionReceipt -Path $receiptPath
            $resumeBinding = Initialize-ApiAttestationCorrectionResumeReconciliation `
                -Config $configuration -State $state -Receipt $loadedReceipt -ReceiptPath $receiptPath
            $receipt = $resumeBinding.receipt
            $source = $resumeBinding.source
            $descriptor = $resumeBinding.descriptor
            $expectedReceiptPath = Get-BootstrapApiAttestationCorrectionReceiptPath `
                -Config $configuration -State $state -LocatorFingerprint ([string]$receipt.locatorFingerprint)
            if ([IO.Path]::GetFullPath($receiptPath) -cne [IO.Path]::GetFullPath($expectedReceiptPath)) {
                throw 'The API-attestation correction receipt exists outside its exact preserved locator.'
            }
        }
        else {
            $descriptor = Get-ApiAttestationCorrectionDescriptor `
                -Config $configuration -State $state -Boundary $boundary -SourceMetadata $source
            $receiptPath = Get-BootstrapApiAttestationCorrectionReceiptPath `
                -Config $configuration -State $state -LocatorFingerprint ([string]$descriptor.locatorFingerprint)
        }

        $finalStep = $state.steps['End-to-end deployment verification']
        if (-not $receipt -and
            ($finalStep -isnot [System.Collections.IDictionary] -or [string]$finalStep.status -cne 'Failed' -or
                ($state.outputs -is [System.Collections.IDictionary] -and $state.outputs.Contains('verification')))) {
            throw 'Fresh API-attestation correction requires the preserved failed final verification step and no claimed verification output.'
        }

        $null = Connect-BootstrapAzure -Config $configuration -NonInteractive:$NonInteractive
        $null = Assert-BootstrapAzureContext -Config $configuration
        $resourceGroup = Invoke-AzJson -Arguments @(
            'group', 'show', '--subscription', [string]$configuration.subscriptionId,
            '--name', [string]$configuration.resourceGroupName,
            '--query', '{id:id,name:name,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint}')
        $expectedGroupId = "/subscriptions/$($configuration.subscriptionId)/resourceGroups/$($configuration.resourceGroupName)"
        if (-not ([string]$resourceGroup.id).Equals($expectedGroupId, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$resourceGroup.name -cne [string]$configuration.resourceGroupName -or
            [string]$resourceGroup.ownershipId -cne [string]$boundary.ownershipId -or
            [string]$resourceGroup.sourceFingerprint -cne [string]$state.acceptedPlan.sourceFingerprint) {
            throw 'The live resource group is outside the exact accepted subscription, resource-group, ownership, and source boundary.'
        }

        $createdReceipt = $false
        if ($receipt) {
            if ([string]$receipt.status -ceq 'Verified') {
                $null = Assert-BootstrapApiAttestationCorrectionReceipt -Config $configuration -State $state -Receipt $receipt
                $verification = Invoke-ApiAttestationCorrectionCanonicalFinalVerification `
                    -Config $configuration -State $state -StatePath $statePath `
                    -OriginalAcceptedSourceRoot ([string]$source.acceptedSourceRoot) -NonInteractive:$NonInteractive
                Write-Host "Gateway bootstrap verified after bounded API correction: $($state.outputs.adminUiUrl)"
                Write-Host "Safe correction receipt: $receiptPath"
                return $verification
            }
            # Partial receipts are validated below after all exact local bindings are re-established.
        }
        else {
            $null = Test-GatewaySubscriptionDeploymentEvidence -Config $configuration -Evidence $boundary.foundation -DeploymentOwnershipId ([string]$boundary.ownershipId) -SourceFingerprint ([string]$state.acceptedPlan.sourceFingerprint)
            $null = Test-GatewayImmutableImageEvidence -Evidence $boundary.images -SourceFingerprint ([string]$state.acceptedPlan.sourceFingerprint) -DeploymentOwnershipId ([string]$boundary.ownershipId)
            $null = Test-GatewayGroupDeploymentEvidence -Config $configuration -Foundation $boundary.foundation -Identity $state.steps['Gateway API identity'].evidence -Evidence $boundary.runtime -DeploymentOwnershipId ([string]$boundary.ownershipId) -SourceFingerprint ([string]$state.acceptedPlan.sourceFingerprint) -ApiImage ([string]$boundary.images.api) -WorkerImage ([string]$boundary.images.worker) -Database $boundary.database
            $apiBefore = Get-ApiAttestationCorrectionContainerAppSnapshot -Config $configuration -Boundary $boundary -Role Api -ExpectedImage ([string]$boundary.images.api)
            $workerBefore = Get-ApiAttestationCorrectionContainerAppSnapshot -Config $configuration -Boundary $boundary -Role Worker -ExpectedImage ([string]$boundary.images.worker)
            $queuesBefore = @(Get-ApiAttestationCorrectionQueueCounts -Config $configuration)
            $null = Test-ApiAttestationCorrectionHttp -Fqdn ([string]$boundary.runtime.apiFqdn)
            $preexistingTag = Get-GatewayAcrExactTagDigest -Registry ([string]$boundary.foundation.acrName) -Repository 'gateway-api' -Tag ([string]$descriptor.tag)
            $preexistingRuns = @(Get-GatewayAcrExactImageRuns -Registry ([string]$boundary.foundation.acrName) -Repository 'gateway-api' -Tag ([string]$descriptor.tag))
            $preexistingRevision = @(Get-ApiAttestationCorrectionExactRevision -Config $configuration -AppName ([string]$descriptor.appName) -TargetRevisionName ([string]$descriptor.targetRevisionName))
            if ($preexistingTag -or $preexistingRuns.Count -ne 0 -or $preexistingRevision.Count -ne 0) {
                throw 'Fresh API-attestation correction intent collides with preexisting ACR or Container Apps provider state.'
            }

            $acceptedContract = [ordered]@{
                schemaVersion = 1
                operation = $ApiAttestationCorrectionOperation
                subscriptionId = [string]$configuration.subscriptionId
                tenantId = [string]$configuration.tenantId
                resourceGroupName = [string]$configuration.resourceGroupName
                projectName = [string]$configuration.projectName
                environment = [string]$configuration.environment
                deploymentOwnershipId = [string]$boundary.ownershipId
                configurationFingerprint = [string]$state.configurationFingerprint
                acceptedBootstrapPlanFingerprint = [string]$state.acceptedPlan.planFingerprint
                acceptedBootstrapPlanRecordFingerprint = [string]$boundary.acceptedPlanRecordFingerprint
                manualDatabaseRepairPlanFingerprint = [string]$boundary.manualPlan.planFingerprint
                manualDatabaseRepairPlanRecordFingerprint = [string]$boundary.manualPlanRecordFingerprint
                stateBoundaryFingerprint = [string]$boundary.stateBoundaryFingerprint
                foundationEvidenceFingerprint = [string]$boundary.foundationEvidenceFingerprint
                imagesEvidenceFingerprint = [string]$boundary.imagesEvidenceFingerprint
                runtimeEvidenceFingerprint = [string]$boundary.runtimeEvidenceFingerprint
                databaseEvidenceFingerprint = [string]$boundary.databaseEvidenceFingerprint
                source = ConvertTo-BootstrapCanonicalValue -Value $source.sourceContract
                foundation = [ordered]@{
                    acrName = [string]$boundary.foundation.acrName
                    acrLoginServer = [string]$boundary.foundation.acrLoginServer
                }
                baseline = [ordered]@{
                    api = $apiBefore
                    worker = $workerBefore
                    queueCounts = $queuesBefore
                    queueCountsFingerprint = Get-BootstrapObjectFingerprint -InputObject $queuesBefore
                }
                build = [ordered]@{
                    intentId = [string]$descriptor.intentId
                    repository = 'gateway-api'
                    dockerfile = 'src/Gateway.Api/Dockerfile'
                    tag = [string]$descriptor.tag
                }
                deployment = [ordered]@{
                    appName = [string]$descriptor.appName
                    containerName = [string]$descriptor.containerName
                    revisionSuffix = [string]$descriptor.revisionSuffix
                    targetRevisionName = [string]$descriptor.targetRevisionName
                    mutation = 'DirectContainerAppImmutableImageUpdateOnly'
                }
            }
            $receipt = [ordered]@{
                schemaVersion = 1
                operation = $ApiAttestationCorrectionOperation
                locatorFingerprint = [string]$descriptor.locatorFingerprint
                contractFingerprint = Get-BootstrapObjectFingerprint -InputObject $acceptedContract
                receiptFingerprint = ''
                acceptedContract = ConvertTo-BootstrapCanonicalValue -Value $acceptedContract
                status = 'Accepted'
                acceptedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                updatedAtUtc = ''
                verifiedAtUtc = ''
                build = [ordered]@{
                    intentId = [string]$descriptor.intentId
                    repository = 'gateway-api'
                    dockerfile = 'src/Gateway.Api/Dockerfile'
                    tag = [string]$descriptor.tag
                    state = 'IntentRecorded'
                    runId = ''
                    digest = ''
                    image = ''
                    intentRecordedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                    runCheckpointedAtUtc = ''
                    digestCheckpointedAtUtc = ''
                }
                deployment = [ordered]@{
                    appName = [string]$descriptor.appName
                    containerName = [string]$descriptor.containerName
                    revisionSuffix = [string]$descriptor.revisionSuffix
                    targetRevisionName = [string]$descriptor.targetRevisionName
                    targetImage = ''
                    state = 'Planned'
                    intentRecordedAtUtc = ''
                    completedAtUtc = ''
                }
                verification = [ordered]@{
                    state = 'Pending'
                    completedAtUtc = ''
                    stateBoundaryFingerprint = ''
                    targetApiImage = ''
                    targetRevisionName = ''
                    apiSnapshot = [ordered]@{}
                    workerSnapshot = [ordered]@{}
                    queueCountsAfter = @()
                    http = [ordered]@{}
                }
            }
            Save-ApiAttestationCorrectionReceipt -Receipt $receipt -Path $receiptPath
            $createdReceipt = $true
        }

        # Partial receipts must bind exactly before any resumed mutation.
        if (-not $createdReceipt) {
            try {
                $null = Assert-ApiAttestationCorrectionReceiptBoundary `
                    -Config $configuration -State $state -Receipt $receipt
            }
            catch {
                throw 'The recovered API-attestation correction receipt is outside its exact state, source, build, or deployment boundary.'
            }
        }

        $currentSource = Get-ApiAttestationCorrectionSourceMetadata -State $state
        if ([string]$currentSource.sourceContractFingerprint -cne [string]$source.sourceContractFingerprint) {
            throw 'The reviewed API correction source or tool changed after intent acceptance.'
        }
        $targetImage = Resolve-ApiAttestationCorrectionBuild `
            -Config $configuration -Receipt $receipt -ReceiptPath $receiptPath `
            -ReceiptCreatedThisInvocation:$createdReceipt -SourceMetadata $source
        $preDeploySource = Get-ApiAttestationCorrectionSourceMetadata -State $state
        if ([string]$preDeploySource.sourceContractFingerprint -cne [string]$source.sourceContractFingerprint) {
            throw 'The reviewed API correction source, tool, or executable dependencies changed before deployment.'
        }
        $revision = Deploy-ApiAttestationCorrection `
            -Config $configuration -Boundary $boundary -Receipt $receipt -ReceiptPath $receiptPath -TargetImage $targetImage

        $apiAfter = Get-ApiAttestationCorrectionContainerAppSnapshot -Config $configuration -Boundary $boundary -Role Api -ExpectedImage $targetImage
        $workerAfter = Get-ApiAttestationCorrectionContainerAppSnapshot -Config $configuration -Boundary $boundary -Role Worker -ExpectedImage ([string]$receipt.acceptedContract.baseline.worker.image)
        $null = Assert-ApiAttestationCorrectionUnchangedSnapshot -Before $receipt.acceptedContract.baseline.api -After $apiAfter -Role Api
        $null = Assert-ApiAttestationCorrectionUnchangedSnapshot -Before $receipt.acceptedContract.baseline.worker -After $workerAfter -Role Worker
        if ([string]$apiAfter.latestReadyRevisionName -cne [string]$descriptor.targetRevisionName) {
            throw 'The corrected API latest ready revision is not the exact receipt-bound target.'
        }
        $queuesAfter = @(Get-ApiAttestationCorrectionQueueCounts -Config $configuration)
        if ((Get-BootstrapObjectFingerprint -InputObject $queuesAfter) -cne [string]$receipt.acceptedContract.baseline.queueCountsFingerprint) {
            throw 'Service Bus queue counts changed during the API-only correction.'
        }
        $http = Test-ApiAttestationCorrectionHttp -Fqdn ([string]$boundary.runtime.apiFqdn) -RequireAttestation
        $stateAfter = Read-BootstrapState -Path $statePath -Config $configuration
        $boundaryAfter = Get-ApiAttestationCorrectionStateBoundary -Config $configuration -State $stateAfter
        if ([string]$boundaryAfter.stateBoundaryFingerprint -cne [string]$boundary.stateBoundaryFingerprint) {
            throw 'The accepted bootstrap state boundary changed during the separate API-only correction.'
        }
        $null = Get-ApiAttestationCorrectionActiveRevision -Config $configuration -AppName ([string]$descriptor.appName) -TargetRevisionName ([string]$descriptor.targetRevisionName) -TargetImage $targetImage -MaximumAttempts 1

        $receipt.verification = [ordered]@{
            state = 'Succeeded'
            completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            stateBoundaryFingerprint = [string]$boundary.stateBoundaryFingerprint
            targetApiImage = $targetImage
            targetRevisionName = [string]$revision.name
            apiSnapshot = $apiAfter
            workerSnapshot = $workerAfter
            queueCountsAfter = $queuesAfter
            http = $http
        }
        $receipt.status = 'Verified'
        $receipt.verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Save-ApiAttestationCorrectionReceipt -Receipt $receipt -Path $receiptPath
        $null = Assert-BootstrapApiAttestationCorrectionReceipt -Config $configuration -State $stateAfter -Receipt $receipt

        $verification = Invoke-ApiAttestationCorrectionCanonicalFinalVerification `
            -Config $configuration -State $stateAfter -StatePath $statePath `
            -OriginalAcceptedSourceRoot ([string]$source.acceptedSourceRoot) -NonInteractive:$NonInteractive
        Write-Host "Gateway bootstrap verified after bounded API correction: $($stateAfter.outputs.adminUiUrl)"
        Write-Host "Corrected API image: $targetImage"
        Write-Host "Safe correction receipt: $receiptPath"
        return $verification
    }
    catch {
        if ($receipt -is [System.Collections.IDictionary] -and
            -not [string]::IsNullOrWhiteSpace($receiptPath) -and
            [string]$receipt.status -cne 'Verified') {
            $receipt.status = 'NeedsAttention'
            try { Save-ApiAttestationCorrectionReceipt -Receipt $receipt -Path $receiptPath } catch { }
        }
        throw 'The bounded API-attestation correction stopped safely. Provider details were withheld; rerun the same command to reconcile the recorded intent.'
    }
    finally {
        Clear-BootstrapAzureSubscriptionContext
        if ($lock) { $lock.Dispose() }
    }
}

if ($MyInvocation.InvocationName -cne '.') {
    Invoke-BootstrapApiAttestationCorrection -ConfigPath $Config -Yes:$Yes -NonInteractive:$NonInteractive | Out-Null
}
