Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-GatewayDatabaseBootstrapLocationEquivalent {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ActualLocation,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedLocation
    )

    if ($ActualLocation -notmatch '^[A-Za-z0-9 ]+$' -or
        $ExpectedLocation -notmatch '^[A-Za-z0-9 ]+$') {
        return $false
    }
    $normalizedActual = $ActualLocation.Replace(' ', '')
    $normalizedExpected = $ExpectedLocation.Replace(' ', '')
    if ([string]::IsNullOrEmpty($normalizedActual) -or
        [string]::IsNullOrEmpty($normalizedExpected)) {
        return $false
    }
    return [string]::Equals(
        $normalizedActual,
        $normalizedExpected,
        [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-GatewayDatabaseBootstrapCollection {
    param([Parameter()][AllowNull()]$Value)

    foreach ($entry in @($Value)) {
        if ($null -ne $entry) {
            $entry
        }
    }
}

function Get-ManagedIdentityClientId {
    param([Parameter(Mandatory)][string]$PrincipalObjectId)
    Assert-GuidValue -Value $PrincipalObjectId -Label 'Managed identity principal object ID'
    $canonicalObjectId = ([guid]$PrincipalObjectId).ToString('D')
    if ($PrincipalObjectId -cne $canonicalObjectId) {
        throw 'Managed identity principal object ID must use canonical lowercase GUID form.'
    }
    $principal = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/${canonicalObjectId}?`$select=id,appId,displayName")
    Assert-GuidValue -Value ([string]$principal.appId) -Label "Managed identity $PrincipalObjectId client ID"
    if ([string]$principal.id -cne $canonicalObjectId) {
        throw 'Managed identity service-principal readback did not echo the exact requested object ID.'
    }
    return [ordered]@{
        objectId = $canonicalObjectId
        clientId = ([guid][string]$principal.appId).ToString('D')
        displayName = [string]$principal.displayName
    }
}

function Get-GatewayDatabaseEvidenceSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Records,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$AcceptedSourceFingerprint,
        [Parameter(Mandatory)][string]$ExecutionIntentId,
        [Parameter(Mandatory)]$ApiPrincipal,
        [Parameter(Mandatory)]$WorkerPrincipal,
        [Parameter()][AllowEmptyString()][string]$RequiredRecoveryMode = ''
    )
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    $canonicalExecutionIntentId = ([guid]$ExecutionIntentId).ToString('D')
    if ($ExecutionIntentId -cne $canonicalExecutionIntentId) {
        throw 'Database-bootstrap execution intent ID must use canonical lowercase GUID form.'
    }
    if (@($Records | Where-Object {
        [string]$_.ExecutionIntentId -cne $canonicalExecutionIntentId
    }).Count -ne 0) {
        throw 'Database evidence is not exactly bound to the authorized execution intent.'
    }
    $initialize = @($Records | Where-Object {
        [string]$_.Phase -ceq 'initialize' -and
        [string]$_.Server -ceq $SqlServerFqdn -and
        [string]$_.Database -ceq 'GatewayDb' -and
        $_.Verification.CurrentEfModelReady -eq $true -and
        $_.Verification.WorkflowV2Ready -eq $true -and
        [string]$_.InitializationIntent.DeploymentOwnershipId -ceq $canonicalOwnershipId -and
        [string]$_.InitializationIntent.AcceptedSourceFingerprint -ceq $AcceptedSourceFingerprint -and
        $_.InitializationIntent.ExactReadbackVerified -eq $true
    })
    if ($initialize.Count -ne 1) {
        throw 'Database initialization did not produce one exact ownership/source-bound schema-attestation record.'
    }
    $intent = $initialize[0].InitializationIntent
    $reportedRecoveryMode = if ($intent -is [System.Collections.IDictionary]) {
        if ($intent.Contains('RecoveryMode')) { [string]$intent.RecoveryMode } else { '' }
    }
    elseif ($null -ne $intent.PSObject.Properties['RecoveryMode']) { [string]$intent.RecoveryMode }
    else { '' }
    if (-not [string]::IsNullOrWhiteSpace($RequiredRecoveryMode) -and
        $reportedRecoveryMode -cne $RequiredRecoveryMode) {
        throw 'Database recovery did not report the exact authorized resume-after-schema mode.'
    }
    $schemaFingerprint = [string]$initialize[0].Verification.CurrentSchemaFingerprint
    Assert-BootstrapFingerprintValue -Value $schemaFingerprint -Label 'Gateway database schema fingerprint'
    if ([int]$intent.SchemaVersion -ne 1 -or
        [string]$intent.MarkerName -cne 'A365GatewayBootstrapInitializationIntent' -or
        [string]$intent.Server -cne $SqlServerFqdn -or
        [string]$intent.Database -cne 'GatewayDb' -or
        [string]$intent.DatabaseCollation -cne 'SQL_Latin1_General_CP1_CI_AS' -or
        [string]$intent.CatalogCollation -cne 'SQL_Latin1_General_CP1_CI_AS' -or
        [string]$intent.DatabaseOwnerSidSha256 -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Database initialization intent did not preserve the full exact database identity boundary.'
    }

    foreach ($principal in @(
        [ordered]@{ evidence = $ApiPrincipal; expectedPermission = 'VIEW DEFINITION' },
        [ordered]@{ evidence = $WorkerPrincipal; expectedPermission = '' }
    )) {
        $matches = @($Records | Where-Object {
            [string]$_.Phase -ceq 'principal' -and
            [string]$_.Server -ceq $SqlServerFqdn -and
            [string]$_.Database -ceq 'GatewayDb' -and
            [string]$_.RuntimePrincipal.Name -ceq [string]$principal.evidence.displayName -and
            [string]$_.RuntimePrincipal.ClientId -ceq ([guid][string]$principal.evidence.clientId).ToString('D') -and
            [string]$_.Verification.CurrentSchemaFingerprint -ceq $schemaFingerprint -and
            $_.Verification.CurrentEfModelReady -eq $true -and
            $_.Verification.WorkflowV2Ready -eq $true
        })
        if ($matches.Count -ne 1) {
            throw 'Database runtime-principal setup did not produce one exact current-schema evidence record.'
        }
        $roles = @($matches[0].RuntimePrincipal.DatabaseRoles | ForEach-Object { [string]$_ } | Sort-Object)
        $permissions = @($matches[0].RuntimePrincipal.DirectPermissions | ForEach-Object { [string]$_ } | Sort-Object)
        $expectedPermissions = if ([string]::IsNullOrWhiteSpace([string]$principal.expectedPermission)) { @() } else { @([string]$principal.expectedPermission) }
        if (($roles -join '|') -cne 'db_datareader|db_datawriter' -or
            ($permissions -join '|') -cne ($expectedPermissions -join '|')) {
            throw 'Database runtime-principal evidence does not match the exact least-privilege role/metadata contract.'
        }
    }

    return [ordered]@{
        schemaFingerprint = $schemaFingerprint
        initializationIntent = [ordered]@{
            markerName = [string]$intent.MarkerName
            schemaVersion = [int]$intent.SchemaVersion
            deploymentOwnershipId = [string]$intent.DeploymentOwnershipId
            acceptedSourceFingerprint = [string]$intent.AcceptedSourceFingerprint
            server = [string]$intent.Server
            database = [string]$intent.Database
            databaseCollation = [string]$intent.DatabaseCollation
            catalogCollation = [string]$intent.CatalogCollation
            databaseOwnerSidSha256 = [string]$intent.DatabaseOwnerSidSha256
            exactReadbackVerified = $true
            recoveryMode = $reportedRecoveryMode
        }
    }
}

function Save-GatewayPrivateDatabaseBootstrapRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)][string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ".$([IO.Path]::GetFileName($fullPath)).$PID.$([guid]::NewGuid().ToString('N')).tmp"
    $bytes = $null
    $json = ''
    try {
        $json = ConvertTo-Json -InputObject $Record -Depth 50
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        [IO.File]::Move($temporaryPath, $fullPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

function Read-GatewayPrivateDatabaseBootstrapRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $convertParameters = @{
            AsHashtable = $true
            Depth = 50
            ErrorAction = 'Stop'
        }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $convertParameters.DateKind = 'String'
        }
        $record = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json @convertParameters
    }
    catch {
        throw 'The private database-bootstrap recovery record is malformed. Preserve it and do not repeat the job or SQL administrator mutation.'
    }
    if ($record -isnot [System.Collections.IDictionary]) {
        throw 'The private database-bootstrap recovery record is not an object. Preserve it and do not repeat the job or SQL administrator mutation.'
    }
    # PowerShell releases before ConvertFrom-Json -DateKind may eagerly convert
    # ISO timestamps. Normalize only the reviewed timestamp fields back to UTC
    # strings so a receipt round-trip never becomes locale dependent.
    foreach ($name in @(
        'deploymentIntentAtUtc', 'deploymentVerifiedAtUtc', 'administratorSwapIntentAtUtc',
        'administratorSwappedAtUtc', 'jobStartIntentAtUtc', 'executionStartedAtUtc',
        'executionSucceededAtUtc', 'evidenceRecoveredAtUtc', 'administratorRestoredAtUtc', 'completedAtUtc'
    )) {
        if ($record.Contains($name) -and $record[$name] -is [DateTime]) {
            $record[$name] = ([DateTimeOffset][DateTime]$record[$name]).ToUniversalTime().ToString('O')
        }
        elseif ($record.Contains($name) -and $record[$name] -is [DateTimeOffset]) {
            $record[$name] = ([DateTimeOffset]$record[$name]).ToUniversalTime().ToString('O')
        }
    }
    return $record
}

function ConvertFrom-GatewayDatabaseEvidenceJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json)

    try {
        $convertParameters = @{
            AsHashtable = $true
            Depth = 50
            ErrorAction = 'Stop'
        }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $convertParameters.DateKind = 'String'
        }
        $records = @($Json | ConvertFrom-Json @convertParameters)
        Convert-BootstrapParsedJsonDatesToStrings -Value $records
    }
    catch {
        throw 'The private database-bootstrap evidence payload was not bounded canonical UTF-8 JSON.'
    }
    return @($records)
}

function Assert-GatewayPrivateDatabaseBootstrapRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$JobName,
        [Parameter(Mandatory)][string]$JobImage,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$OriginalAdministratorObjectId,
        [Parameter(Mandatory)][string]$OriginalAdministratorLogin,
        [Parameter(Mandatory)]$SqlPrivateEndpoint
    )

    $addressTuple = Assert-GatewaySqlPrivateEndpointAddressEvidenceTuple `
        -Config $Config -SqlServerFqdn $SqlServerFqdn -Evidence $SqlPrivateEndpoint

    $expectedKeys = @(
        'schemaVersion', 'subscriptionId', 'tenantId', 'resourceGroupName', 'server', 'database',
        'deploymentOwnershipId', 'acceptedSourceFingerprint', 'jobDeploymentName', 'jobName', 'jobImage',
        'privateEndpointNetworkInterfaceId', 'privateEndpointIpv4Address', 'privateDnsARecordSetId',
        'privateDnsARecordName', 'privateDnsARecordIpv4Address',
        'originalAdministratorObjectId', 'originalAdministratorLogin', 'jobPrincipalId', 'executionIntentId',
        'deploymentIntentAtUtc', 'deploymentVerifiedAtUtc', 'administratorSwapIntentAtUtc',
        'administratorSwappedAtUtc', 'jobStartIntentAtUtc', 'executionName', 'executionStartedAtUtc',
        'executionSucceededAtUtc', 'evidenceFingerprint', 'evidenceRecoveredAtUtc',
        'administratorRestoredAtUtc', 'completedAtUtc'
    )
    $actualKeys = @($Record.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    if (($actualKeys -join '|') -cne (($expectedKeys | Sort-Object) -join '|') -or
        [int]$Record.schemaVersion -ne 2 -or
        [string]$Record.subscriptionId -cne ([guid][string]$Config.subscriptionId).ToString('D') -or
        [string]$Record.tenantId -cne ([guid][string]$Config.tenantId).ToString('D') -or
        [string]$Record.resourceGroupName -cne [string]$Config.resourceGroupName -or
        [string]$Record.server -cne $SqlServerFqdn -or
        [string]$Record.database -cne 'GatewayDb' -or
        [string]$Record.deploymentOwnershipId -cne ([guid]$DeploymentOwnershipId).ToString('D') -or
        [string]$Record.acceptedSourceFingerprint -cne $SourceFingerprint -or
        [string]$Record.jobDeploymentName -cne "a365gw-$($Config.projectName)-bootstrap-database-job-$($Config.environment)" -or
        [string]$Record.jobName -cne $JobName -or
        [string]$Record.jobImage -cne $JobImage -or
        [string]$Record.privateEndpointNetworkInterfaceId -cne [string]$addressTuple.privateEndpointNetworkInterfaceId -or
        [string]$Record.privateEndpointIpv4Address -cne [string]$addressTuple.privateEndpointIpv4Address -or
        [string]$Record.privateDnsARecordSetId -cne [string]$addressTuple.privateDnsARecordSetId -or
        [string]$Record.privateDnsARecordName -cne [string]$addressTuple.privateDnsARecordName -or
        [string]$Record.privateDnsARecordIpv4Address -cne [string]$addressTuple.privateDnsARecordIpv4Address -or
        [string]$Record.originalAdministratorObjectId -cne ([guid]$OriginalAdministratorObjectId).ToString('D') -or
        [string]$Record.originalAdministratorLogin -cne $OriginalAdministratorLogin -or
        [string]$Record.executionIntentId -cne ([guid][string]$Record.executionIntentId).ToString('D') -or
        [guid][string]$Record.executionIntentId -eq [guid]::Empty) {
        throw 'The private database-bootstrap recovery record does not match the exact subscription, database, source, job, or original administrator boundary.'
    }

    foreach ($name in @(
        'deploymentIntentAtUtc', 'deploymentVerifiedAtUtc', 'administratorSwapIntentAtUtc',
        'administratorSwappedAtUtc', 'jobStartIntentAtUtc', 'executionStartedAtUtc',
        'executionSucceededAtUtc', 'evidenceRecoveredAtUtc', 'administratorRestoredAtUtc', 'completedAtUtc'
    )) {
        $value = [string]$Record[$name]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParseExact(
            $value, 'O', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
            throw 'The private database-bootstrap recovery record contains an invalid UTC timestamp.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Record.jobPrincipalId)) {
        Assert-GuidValue -Value ([string]$Record.jobPrincipalId) -Label 'Database-bootstrap job principal ID'
        if ([string]$Record.jobPrincipalId -cne ([guid][string]$Record.jobPrincipalId).ToString('D')) {
            throw 'The database-bootstrap job principal ID in recovery is not canonical.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Record.executionName) -and
        [string]$Record.executionName -cnotmatch "^$([regex]::Escape($JobName))-[a-z0-9]{5,16}$") {
        throw 'The private database-bootstrap recovery record contains an invalid execution name.'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Record.evidenceFingerprint)) {
        Assert-BootstrapFingerprintValue -Value ([string]$Record.evidenceFingerprint) -Label 'Private database-bootstrap evidence fingerprint'
    }
    return $true
}

function Assert-GatewayPrivateDatabaseRecoveryRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$JobImage,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$OriginalSourceFingerprint,
        [Parameter(Mandatory)][string]$RecoverySourceFingerprint,
        [Parameter(Mandatory)][string]$RecoveryPlanFingerprint,
        [Parameter(Mandatory)][string]$ExpectedExecutionIntentId,
        [Parameter(Mandatory)]$FailedJob,
        [ValidateSet(1, 2)][int]$RecoveryAttemptNumber = 1,
        [Parameter()][AllowNull()][System.Collections.IDictionary]$PriorFailedRecovery,
        [Parameter(Mandatory)][string]$OriginalAdministratorObjectId,
        [Parameter(Mandatory)][string]$OriginalAdministratorLogin,
        [Parameter(Mandatory)]$SqlPrivateEndpoint
    )

    Assert-GuidValue -Value $ExpectedExecutionIntentId -Label 'Accepted database recovery execution intent ID'
    $canonicalExpectedExecutionIntentId = ([guid]$ExpectedExecutionIntentId).ToString('D')
    if ($ExpectedExecutionIntentId -cne $canonicalExpectedExecutionIntentId) {
        throw 'The accepted database recovery execution intent ID must be a canonical lowercase GUID.'
    }
    $addressTuple = Assert-GatewaySqlPrivateEndpointAddressEvidenceTuple -Config $Config -SqlServerFqdn $SqlServerFqdn -Evidence $SqlPrivateEndpoint
    $contract = Get-GatewayDatabaseRecoveryAttemptContract -Config $Config -AttemptNumber $RecoveryAttemptNumber
    $jobName = [string]$contract.jobName
    $expectedKeys = @(
        'schemaVersion', 'subscriptionId', 'tenantId', 'resourceGroupName', 'server', 'database',
        'deploymentOwnershipId', 'acceptedSourceFingerprint', 'recoverySourceFingerprint', 'recoveryPlanFingerprint',
        'originalFailedJobName', 'originalFailedExecutionName', 'originalFailedExecutionIntentId', 'originalFailedBoundaryFingerprint',
        'jobDeploymentName', 'jobName', 'jobImage',
        'privateEndpointNetworkInterfaceId', 'privateEndpointIpv4Address', 'privateDnsARecordSetId',
        'privateDnsARecordName', 'privateDnsARecordIpv4Address',
        'originalAdministratorObjectId', 'originalAdministratorLogin', 'jobPrincipalId', 'executionIntentId',
        'deploymentIntentAtUtc', 'deploymentVerifiedAtUtc', 'administratorSwapIntentAtUtc',
        'administratorSwappedAtUtc', 'jobStartIntentAtUtc', 'executionName', 'executionStartedAtUtc',
        'executionSucceededAtUtc', 'evidenceFingerprint', 'evidenceRecoveredAtUtc',
        'administratorRestoredAtUtc', 'completedAtUtc'
    )
    $actualKeys = @($Record.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    if ($RecoveryAttemptNumber -eq 2) {
        $expectedKeys += @(
            'recoveryAttemptNumber', 'priorFailedRecoveryJobName', 'priorFailedRecoveryExecutionName',
            'priorFailedRecoveryExecutionIntentId', 'priorFailedRecoveryPlanFingerprint',
            'priorFailedRecoverySourceFingerprint', 'priorFailedRecoveryBoundaryFingerprint'
        )
        if ($PriorFailedRecovery -isnot [System.Collections.IDictionary]) {
            throw 'The second database recovery receipt requires the exact prior failed recovery boundary.'
        }
    }
    if (($actualKeys -join '|') -cne (($expectedKeys | Sort-Object) -join '|') -or
        [int]$Record.schemaVersion -ne $(if ($RecoveryAttemptNumber -eq 2) { 4 } else { 3 }) -or
        [string]$Record.subscriptionId -cne ([guid][string]$Config.subscriptionId).ToString('D') -or
        [string]$Record.tenantId -cne ([guid][string]$Config.tenantId).ToString('D') -or
        [string]$Record.resourceGroupName -cne [string]$Config.resourceGroupName -or
        [string]$Record.server -cne $SqlServerFqdn -or [string]$Record.database -cne 'GatewayDb' -or
        [string]$Record.deploymentOwnershipId -cne ([guid]$DeploymentOwnershipId).ToString('D') -or
        [string]$Record.acceptedSourceFingerprint -cne $OriginalSourceFingerprint -or
        [string]$Record.recoverySourceFingerprint -cne $RecoverySourceFingerprint -or
        [string]$Record.recoveryPlanFingerprint -cne $RecoveryPlanFingerprint -or
        [string]$Record.originalFailedJobName -cne [string]$FailedJob.jobName -or
        [string]$Record.originalFailedExecutionName -cne [string]$FailedJob.executionName -or
        [string]$Record.originalFailedExecutionIntentId -cne [string]$FailedJob.executionIntentId -or
        [string]$Record.originalFailedBoundaryFingerprint -cne [string]$FailedJob.boundaryFingerprint -or
        [string]$Record.jobDeploymentName -cne [string]$contract.deploymentName -or
        [string]$Record.jobName -cne $jobName -or [string]$Record.jobImage -cne $JobImage -or
        [string]$Record.privateEndpointNetworkInterfaceId -cne [string]$addressTuple.privateEndpointNetworkInterfaceId -or
        [string]$Record.privateEndpointIpv4Address -cne [string]$addressTuple.privateEndpointIpv4Address -or
        [string]$Record.privateDnsARecordSetId -cne [string]$addressTuple.privateDnsARecordSetId -or
        [string]$Record.privateDnsARecordName -cne [string]$addressTuple.privateDnsARecordName -or
        [string]$Record.privateDnsARecordIpv4Address -cne [string]$addressTuple.privateDnsARecordIpv4Address -or
        [string]$Record.originalAdministratorObjectId -cne ([guid]$OriginalAdministratorObjectId).ToString('D') -or
        [string]$Record.originalAdministratorLogin -cne $OriginalAdministratorLogin -or
        [string]$Record.executionIntentId -cne $canonicalExpectedExecutionIntentId) {
        throw 'The private database recovery receipt does not match its exact original failure, corrected source, image, job, network, or administrator boundary.'
    }
    if ($RecoveryAttemptNumber -eq 2 -and (
        [int]$Record.recoveryAttemptNumber -ne 2 -or
        [string]$Record.priorFailedRecoveryJobName -cne [string]$PriorFailedRecovery.jobName -or
        [string]$Record.priorFailedRecoveryExecutionName -cne [string]$PriorFailedRecovery.executionName -or
        [string]$Record.priorFailedRecoveryExecutionIntentId -cne [string]$PriorFailedRecovery.executionIntentId -or
        [string]$Record.priorFailedRecoveryPlanFingerprint -cne [string]$PriorFailedRecovery.recoveryPlanFingerprint -or
        [string]$Record.priorFailedRecoverySourceFingerprint -cne [string]$PriorFailedRecovery.recoverySourceFingerprint -or
        [string]$Record.priorFailedRecoveryBoundaryFingerprint -cne [string]$PriorFailedRecovery.boundaryFingerprint)) {
        throw 'The second database recovery receipt does not match the exact prior failed recovery attempt.'
    }
    foreach ($fingerprint in @($RecoverySourceFingerprint, $RecoveryPlanFingerprint, [string]$FailedJob.boundaryFingerprint)) {
        Assert-BootstrapFingerprintValue -Value $fingerprint -Label 'Private database recovery fingerprint'
    }
    if ($RecoveryAttemptNumber -eq 2) {
        foreach ($fingerprint in @(
            [string]$PriorFailedRecovery.recoveryPlanFingerprint,
            [string]$PriorFailedRecovery.recoverySourceFingerprint,
            [string]$PriorFailedRecovery.boundaryFingerprint
        )) {
            Assert-BootstrapFingerprintValue -Value $fingerprint -Label 'Prior failed database recovery fingerprint'
        }
    }
    foreach ($name in @(
        'deploymentIntentAtUtc', 'deploymentVerifiedAtUtc', 'administratorSwapIntentAtUtc',
        'administratorSwappedAtUtc', 'jobStartIntentAtUtc', 'executionStartedAtUtc',
        'executionSucceededAtUtc', 'evidenceRecoveredAtUtc', 'administratorRestoredAtUtc', 'completedAtUtc'
    )) {
        $value = [string]$Record[$name]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParseExact($value, 'O', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
            throw 'The private database recovery receipt contains an invalid UTC timestamp.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Record.jobPrincipalId)) {
        Assert-GuidValue -Value ([string]$Record.jobPrincipalId) -Label 'Database recovery Job principal ID'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Record.executionName) -and
        [string]$Record.executionName -cnotmatch "^$([regex]::Escape($jobName))-[a-z0-9]{5,16}$") {
        throw 'The private database recovery receipt contains an invalid execution name.'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Record.evidenceFingerprint)) {
        Assert-BootstrapFingerprintValue -Value ([string]$Record.evidenceFingerprint) -Label 'Private database recovery evidence fingerprint'
    }
    return $true
}

function Get-GatewayDatabaseRecoveryAttemptNumber {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$RecoveryPlan)

    $attemptNumber = if ($RecoveryPlan.Contains('attemptNumber')) { [int]$RecoveryPlan.attemptNumber } else { 1 }
    if ($attemptNumber -notin @(1, 2)) {
        throw 'Database recovery is capped at exactly two independently planned attempts.'
    }
    return $attemptNumber
}

function Assert-GatewaySqlPrivateEndpointAddressEvidenceTuple {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)]$Evidence
    )

    $serverName = $SqlServerFqdn.Split('.')[0]
    if ($SqlServerFqdn -cne "$serverName.database.windows.net" -or
        $serverName -cne "sql-$($Config.projectName)-$($Config.environment)") {
        throw 'The SQL private-endpoint address evidence server boundary is malformed.'
    }
    $providerPrefix = ("/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers").ToLowerInvariant()
    $nicPrefix = "$providerPrefix/microsoft.network/networkinterfaces/pe-$serverName.nic."
    $nicId = [string]$Evidence.privateEndpointNetworkInterfaceId
    if ($nicId -cne $nicId.ToLowerInvariant() -or
        -not $nicId.StartsWith($nicPrefix, [StringComparison]::Ordinal)) {
        throw 'The SQL private-endpoint address evidence NIC boundary is malformed.'
    }
    $nicGuidText = $nicId.Substring($nicPrefix.Length)
    $nicGuid = [guid]::Empty
    if (-not [guid]::TryParse($nicGuidText, [ref]$nicGuid) -or $nicGuid -eq [guid]::Empty -or
        $nicGuidText -cne $nicGuid.ToString('D')) {
        throw 'The SQL private-endpoint address evidence NIC suffix is malformed.'
    }
    $expectedRecordSetId = "$providerPrefix/microsoft.network/privatednszones/privatelink.database.windows.net/a/$serverName"
    if ([string]$Evidence.privateDnsARecordSetId -cne $expectedRecordSetId -or
        [string]$Evidence.privateDnsARecordName -cne $serverName) {
        throw 'The SQL private-endpoint address evidence A-record boundary is malformed.'
    }
    $privateEndpointIpv4Address = [string]$Evidence.privateEndpointIpv4Address
    $privateDnsARecordIpv4Address = [string]$Evidence.privateDnsARecordIpv4Address
    Assert-BootstrapIpv4Value -Value $privateEndpointIpv4Address -Label 'Expected SQL private-endpoint IPv4 address'
    Assert-BootstrapIpv4Value -Value $privateDnsARecordIpv4Address -Label 'Expected SQL private DNS A-record IPv4 address'
    if ($privateEndpointIpv4Address -cne $privateDnsARecordIpv4Address) {
        throw 'The SQL private-endpoint address evidence does not bind the A-record to the sole NIC IPv4 address.'
    }
    return [ordered]@{
        privateEndpointNetworkInterfaceId = $nicId
        privateEndpointIpv4Address = $privateEndpointIpv4Address
        privateDnsARecordSetId = $expectedRecordSetId
        privateDnsARecordName = $serverName
        privateDnsARecordIpv4Address = $privateDnsARecordIpv4Address
    }
}

function Get-GatewaySqlEntraAdministrator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ServerName
    )

    $administrators = @(Invoke-AzJson -Arguments @(
        'sql', 'server', 'ad-admin', 'list',
        '--resource-group', [string]$Config.resourceGroupName,
        '--server-name', $ServerName,
        '--query', '[].{administratorType:administratorType,login:login,sid:sid,tenantId:tenantId}'
    ))
    if ($administrators.Count -ne 1 -or
        [string]$administrators[0].administratorType -cne 'ActiveDirectory' -or
        [string]::IsNullOrWhiteSpace([string]$administrators[0].login)) {
        throw 'Azure SQL did not return exactly one singular ActiveDirectory administrator.'
    }
    Assert-GuidValue -Value ([string]$administrators[0].sid) -Label 'Azure SQL Entra administrator object ID'
    Assert-GuidValue -Value ([string]$administrators[0].tenantId) -Label 'Azure SQL Entra administrator tenant ID'
    return [ordered]@{
        administratorType = 'ActiveDirectory'
        login = [string]$administrators[0].login
        objectId = ([guid][string]$administrators[0].sid).ToString('D')
        tenantId = ([guid][string]$administrators[0].tenantId).ToString('D')
    }
}

function Wait-GatewaySqlEntraAdministrator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$ExpectedObjectId,
        [Parameter(Mandatory)][string]$ExpectedLogin,
        [int]$MaximumAttempts = 36,
        [int]$PollIntervalSeconds = 5
    )

    $canonicalExpectedObjectId = ([guid]$ExpectedObjectId).ToString('D')
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $administrator = Get-GatewaySqlEntraAdministrator -Config $Config -ServerName $ServerName
            if ([string]$administrator.objectId -cne $canonicalExpectedObjectId -or
                [string]$administrator.login -cne $ExpectedLogin -or
                [string]$administrator.tenantId -cne ([guid][string]$Config.tenantId).ToString('D')) {
                if ($attempt -eq $MaximumAttempts) { return $false }
                Start-Sleep -Seconds $PollIntervalSeconds
                continue
            }
            return $true
        }
        catch {
            if ($attempt -eq $MaximumAttempts) { return $false }
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }
    return $false
}

function Set-GatewaySqlEntraAdministratorExact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$ObjectId,
        [Parameter(Mandatory)][string]$Login
    )

    $canonicalObjectId = ([guid]$ObjectId).ToString('D')
    if ($ObjectId -cne $canonicalObjectId -or [string]::IsNullOrWhiteSpace($Login) -or
        $Login.Length -gt 256 -or $Login -match '[\r\n]') {
        throw 'The requested Azure SQL Entra administrator binding is malformed.'
    }
    Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @(
        'sql', 'server', 'ad-admin', 'update',
        '--resource-group', [string]$Config.resourceGroupName,
        '--server-name', $ServerName,
        '--display-name', $Login,
        '--object-id', $canonicalObjectId,
        '--output', 'none', '--only-show-errors'
    ) -NoCapture | Out-Null
    if (-not (Wait-GatewaySqlEntraAdministrator -Config $Config -ServerName $ServerName -ExpectedObjectId $canonicalObjectId -ExpectedLogin $Login)) {
        throw 'Azure SQL did not read back the exact requested singular Entra administrator within the bounded wait.'
    }
}

function Get-GatewayDatabaseBootstrapJobArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$ExpectedPrivateEndpointIpv4Address,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)]$ApiPrincipal,
        [Parameter(Mandatory)]$WorkerPrincipal,
        [switch]$Recovery
    )

    Assert-BootstrapIpv4Value -Value $ExpectedPrivateEndpointIpv4Address -Label 'Expected SQL private-endpoint IPv4 address'

    $arguments = @(
        '--server', $SqlServerFqdn,
        '--expected-private-endpoint-ip', $ExpectedPrivateEndpointIpv4Address,
        '--database', 'GatewayDb',
        '--phase', 'bootstrap'
    )
    if ($Recovery) {
        $arguments += @('--required-recovery-mode', 'ResumeAfterSchemaCompleted')
    }
    $arguments += @(
        '--repeat', '1',
        '--repository-root', '/app',
        '--deployment-ownership-id', ([guid]$DeploymentOwnershipId).ToString('D'),
        '--accepted-source-fingerprint', $SourceFingerprint,
        '--expected-api-principal-name', [string]$ApiPrincipal.displayName,
        '--expected-api-principal-client-id', ([guid][string]$ApiPrincipal.clientId).ToString('D'),
        '--expected-worker-principal-name', [string]$WorkerPrincipal.displayName,
        '--expected-worker-principal-client-id', ([guid][string]$WorkerPrincipal.clientId).ToString('D'),
        '--evidence-stdout', 'true'
    )
    return $arguments
}

function Get-GatewayDatabaseBootstrapJobEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$ExpectedPrivateEndpointIpv4Address,
        [Parameter(Mandatory)][string]$JobImage,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)]$ApiPrincipal,
        [Parameter(Mandatory)]$WorkerPrincipal,
        [Parameter(Mandatory)][string]$ExecutionIntentId,
        [switch]$Recovery,
        [ValidateSet(1, 2)][int]$RecoveryAttemptNumber = 1,
        [Parameter()][string]$RecoverySourceFingerprint = '',
        [Parameter()][string]$RecoveryPlanFingerprint = '',
        [Parameter()][string]$OriginalFailedBoundaryFingerprint = '',
        [Parameter()][string]$PriorFailedRecoveryBoundaryFingerprint = ''
    )

    Assert-GuidValue -Value $ExecutionIntentId -Label 'Database-bootstrap execution intent identifier'
    $canonicalExecutionIntentId = ([guid]$ExecutionIntentId).ToString('D')
    if ($ExecutionIntentId -cne $canonicalExecutionIntentId -or
        [guid]$ExecutionIntentId -eq [guid]::Empty) {
        throw 'The database-bootstrap execution intent identifier must be a nonempty canonical lowercase GUID.'
    }
    $recoveryContract = if ($Recovery) { Get-GatewayDatabaseRecoveryAttemptContract -Config $Config -AttemptNumber $RecoveryAttemptNumber } else { $null }
    $jobName = if ($Recovery) { [string]$recoveryContract.jobName } else { "job-$($Config.projectName)-db-init-$($Config.environment)" }
    $containerName = if ($Recovery) { [string]$recoveryContract.containerName } else { 'database-bootstrap' }
    $workloadTag = if ($Recovery) { [string]$recoveryContract.workloadTag } else { 'database-bootstrap' }
    if ($Recovery) {
        Assert-BootstrapFingerprintValue -Value $RecoverySourceFingerprint -Label 'Database recovery source fingerprint'
        Assert-BootstrapFingerprintValue -Value $RecoveryPlanFingerprint -Label 'Database recovery plan fingerprint'
        if ($RecoveryAttemptNumber -eq 2) {
            Assert-BootstrapFingerprintValue -Value $OriginalFailedBoundaryFingerprint -Label 'Original failed database boundary fingerprint'
            Assert-BootstrapFingerprintValue -Value $PriorFailedRecoveryBoundaryFingerprint -Label 'Prior failed recovery boundary fingerprint'
        }
    }
    $job = Invoke-AzJson -Arguments @(
        'containerapp', 'job', 'show',
        '--resource-group', [string]$Config.resourceGroupName,
        '--name', $jobName
    )
    $expectedJobId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.App/jobs/$jobName"
    $expectedArguments = @(Get-GatewayDatabaseBootstrapJobArguments `
        -SqlServerFqdn $SqlServerFqdn `
        -ExpectedPrivateEndpointIpv4Address $ExpectedPrivateEndpointIpv4Address `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $SourceFingerprint `
        -ApiPrincipal $ApiPrincipal `
        -WorkerPrincipal $WorkerPrincipal `
        -Recovery:$Recovery)
    $containers = @(ConvertTo-GatewayDatabaseBootstrapCollection -Value $job.properties.template.containers)
    $initContainers = @(if ($null -ne $job.properties.template.PSObject.Properties['initContainers']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $job.properties.template.initContainers
    })
    $volumes = @(if ($null -ne $job.properties.template.PSObject.Properties['volumes']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $job.properties.template.volumes
    })
    $registries = @(ConvertTo-GatewayDatabaseBootstrapCollection -Value $job.properties.configuration.registries)
    $secrets = @(ConvertTo-GatewayDatabaseBootstrapCollection -Value $job.properties.configuration.secrets)
    $identitySettings = @(ConvertTo-GatewayDatabaseBootstrapCollection -Value $job.properties.configuration.identitySettings)
    $identityIds = @($job.identity.userAssignedIdentities.PSObject.Properties.Name)
    $containerCommands = @(if ($containers.Count -eq 1 -and $null -ne $containers[0].PSObject.Properties['command']) { $containers[0].command | ForEach-Object { [string]$_ } })
    $containerArguments = @(if ($containers.Count -eq 1 -and $null -ne $containers[0].PSObject.Properties['args']) { $containers[0].args | ForEach-Object { [string]$_ } })
    $containerEnvironment = @(if ($containers.Count -eq 1 -and $null -ne $containers[0].PSObject.Properties['env']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $containers[0].env
    })
    $containerEnvironmentSecretReference = ''
    if ($containerEnvironment.Count -eq 1 -and
        $null -ne $containerEnvironment[0].PSObject.Properties['secretRef']) {
        $containerEnvironmentSecretReference = [string]$containerEnvironment[0].secretRef
    }
    $containerVolumeMounts = @(if ($containers.Count -eq 1 -and $null -ne $containers[0].PSObject.Properties['volumeMounts']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $containers[0].volumeMounts
    })
    $containerProbes = @(if ($containers.Count -eq 1 -and $null -ne $containers[0].PSObject.Properties['probes']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $containers[0].probes
    })
    $identityType = ([string]$job.identity.type).Replace(' ', '')
    if (-not $job -or
        -not ([string]$job.id).Equals($expectedJobId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$job.name -cne $jobName -or
        -not (Test-GatewayDatabaseBootstrapLocationEquivalent `
            -ActualLocation ([string]$job.location) `
            -ExpectedLocation ([string]$Config.location)) -or
        [string]$job.properties.provisioningState -cne 'Succeeded' -or
        -not ([string]$job.properties.environmentId).Equals([string]$Foundation.containerAppsEnvironmentId, [StringComparison]::OrdinalIgnoreCase) -or
        $identityType -cne 'SystemAssigned,UserAssigned' -or
        [string]$job.identity.tenantId -cne ([guid][string]$Config.tenantId).ToString('D') -or
        [string]$job.identity.principalId -cne ([guid][string]$job.identity.principalId).ToString('D') -or
        $identityIds.Count -ne 1 -or
        -not ([string]$identityIds[0]).Equals([string]$Foundation.runtimeImagePullIdentityId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$job.properties.configuration.triggerType -cne 'Manual' -or
        [int]$job.properties.configuration.replicaTimeout -ne 1800 -or
        [int]$job.properties.configuration.replicaRetryLimit -ne 0 -or
        [int]$job.properties.configuration.manualTriggerConfig.parallelism -ne 1 -or
        [int]$job.properties.configuration.manualTriggerConfig.replicaCompletionCount -ne 1 -or
        $registries.Count -ne 1 -or
        [string]$registries[0].server -cne [string]$Foundation.acrLoginServer -or
        -not ([string]$registries[0].identity).Equals([string]$Foundation.runtimeImagePullIdentityId, [StringComparison]::OrdinalIgnoreCase) -or
        $secrets.Count -ne 0 -or
        $identitySettings.Count -ne 2 -or
        @($identitySettings | Where-Object { [string]$_.identity -ceq 'system' -and [string]$_.lifecycle -ceq 'Main' }).Count -ne 1 -or
        @($identitySettings | Where-Object { [string]$_.identity -ieq [string]$Foundation.runtimeImagePullIdentityId -and [string]$_.lifecycle -ceq 'None' }).Count -ne 1 -or
        $initContainers.Count -ne 0 -or
        $volumes.Count -ne 0 -or
        $containers.Count -ne 1 -or
        [string]$containers[0].name -cne $containerName -or
        [string]$containers[0].image -cne $JobImage -or
        ($containerCommands -join '|') -cne 'dotnet|Gateway.DatabaseMigrator.dll' -or
        ($containerArguments -join '|') -cne ($expectedArguments -join '|') -or
        $containerEnvironment.Count -ne 1 -or
        [string]$containerEnvironment[0].name -cne 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID' -or
        [string]$containerEnvironment[0].value -cne $canonicalExecutionIntentId -or
        -not [string]::IsNullOrWhiteSpace($containerEnvironmentSecretReference) -or
        $containerVolumeMounts.Count -ne 0 -or
        $containerProbes.Count -ne 0 -or
        [decimal]$containers[0].resources.cpu -ne [decimal]0.5 -or
        [string]$containers[0].resources.memory -cne '1Gi' -or
        [string]$job.tags.bootstrapOwnershipId -cne ([guid]$DeploymentOwnershipId).ToString('D') -or
        [string]$job.tags.bootstrapSourceFingerprint -cne $SourceFingerprint -or
        [string]$job.tags.workload -cne $workloadTag -or
        ($Recovery -and (
            [string]$job.tags.recoverySourceFingerprint -cne $RecoverySourceFingerprint -or
            [string]$job.tags.recoveryPlanFingerprint -cne $RecoveryPlanFingerprint -or
            ($RecoveryAttemptNumber -eq 2 -and (
                [string]$job.tags.recoveryAttempt -cne '2' -or
                [string]$job.tags.originalFailedDatabaseBoundaryFingerprint -cne $OriginalFailedBoundaryFingerprint -or
                [string]$job.tags.priorFailedRecoveryBoundaryFingerprint -cne $PriorFailedRecoveryBoundaryFingerprint))))) {
        throw 'The private database-bootstrap job does not match the exact dormant, identity, image, network, trigger, or argument contract.'
    }
    return [ordered]@{
        jobId = $expectedJobId
        jobName = $jobName
        jobPrincipalId = ([guid][string]$job.identity.principalId).ToString('D')
        jobImage = $JobImage
        containerName = $containerName
        executionIntentId = $canonicalExecutionIntentId
        recoverySourceFingerprint = $RecoverySourceFingerprint
        recoveryPlanFingerprint = $RecoveryPlanFingerprint
        recoveryAttemptNumber = if ($Recovery) { $RecoveryAttemptNumber } else { 0 }
        originalFailedBoundaryFingerprint = $OriginalFailedBoundaryFingerprint
        priorFailedRecoveryBoundaryFingerprint = $PriorFailedRecoveryBoundaryFingerprint
    }
}

function Deploy-GatewayDatabaseBootstrapJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$ExpectedPrivateEndpointIpv4Address,
        [Parameter(Mandatory)][string]$JobImage,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)]$ApiPrincipal,
        [Parameter(Mandatory)]$WorkerPrincipal,
        [Parameter(Mandatory)][string]$ExecutionIntentId,
        [Parameter(Mandatory)][bool]$FreshIntent,
        [switch]$Recovery,
        [ValidateSet(1, 2)][int]$RecoveryAttemptNumber = 1,
        [Parameter()][string]$RecoverySourceFingerprint = '',
        [Parameter()][string]$RecoveryPlanFingerprint = '',
        [Parameter()][string]$OriginalFailedBoundaryFingerprint = '',
        [Parameter()][string]$PriorFailedRecoveryBoundaryFingerprint = ''
    )

    Assert-BootstrapIpv4Value -Value $ExpectedPrivateEndpointIpv4Address -Label 'Expected SQL private-endpoint IPv4 address'

    Assert-GuidValue -Value $ExecutionIntentId -Label 'Database-bootstrap execution intent identifier'
    $canonicalExecutionIntentId = ([guid]$ExecutionIntentId).ToString('D')
    if ($ExecutionIntentId -cne $canonicalExecutionIntentId -or
        [guid]$ExecutionIntentId -eq [guid]::Empty) {
        throw 'The database-bootstrap execution intent identifier must be a nonempty canonical lowercase GUID.'
    }
    $root = Get-BootstrapExecutionSourceRoot
    $recoveryContract = if ($Recovery) { Get-GatewayDatabaseRecoveryAttemptContract -Config $Config -AttemptNumber $RecoveryAttemptNumber } else { $null }
    $jobName = if ($Recovery) { [string]$recoveryContract.jobName } else { "job-$($Config.projectName)-db-init-$($Config.environment)" }
    $deploymentName = if ($Recovery) { [string]$recoveryContract.deploymentName } else { "a365gw-$($Config.projectName)-bootstrap-database-job-$($Config.environment)" }
    if ($Recovery) {
        Assert-BootstrapFingerprintValue -Value $RecoverySourceFingerprint -Label 'Database recovery source fingerprint'
        Assert-BootstrapFingerprintValue -Value $RecoveryPlanFingerprint -Label 'Database recovery plan fingerprint'
        Assert-BootstrapFingerprintValue -Value $OriginalFailedBoundaryFingerprint -Label 'Original failed database boundary fingerprint'
        if ($RecoveryAttemptNumber -eq 2) {
            Assert-BootstrapFingerprintValue -Value $PriorFailedRecoveryBoundaryFingerprint -Label 'Prior failed recovery boundary fingerprint'
        }
    }
    $expectedJobId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.App/jobs/$jobName"
    $digestSeparator = $JobImage.LastIndexOf('@')
    if ($digestSeparator -le 0) { throw 'The private database-bootstrap image is not digest pinned.' }
    $imageDigest = $JobImage.Substring($digestSeparator + 1)
    $existingJobs = @(Invoke-AzJson -Arguments @(
        'resource', 'list', '--resource-group', [string]$Config.resourceGroupName,
        '--resource-type', 'Microsoft.App/jobs', '--name', $jobName,
        '--query', '[].{id:id}'
    ))
    $existingDeployments = @(Invoke-AzJson -Arguments @(
        'deployment', 'group', 'list', '--resource-group', [string]$Config.resourceGroupName,
        '--query', "[?name=='$deploymentName'].{name:name}"
    ))
    if ($existingJobs.Count -gt 1 -or $existingDeployments.Count -gt 1 -or
        ($existingJobs.Count -eq 1 -and
            -not ([string]$existingJobs[0].id).Equals($expectedJobId, [StringComparison]::OrdinalIgnoreCase))) {
        throw 'The private database-bootstrap deployment intent found an ambiguous deterministic job or deployment record.'
    }
    $bothAbsent = $existingJobs.Count -eq 0 -and $existingDeployments.Count -eq 0
    $bothPresent = $existingJobs.Count -eq 1 -and $existingDeployments.Count -eq 1
    if (-not $bothAbsent -and -not $bothPresent) {
        throw 'The private database-bootstrap deployment intent found a partial job/deployment outcome; no deployment replay was attempted.'
    }

    if ($bothAbsent) {
        if (-not $FreshIntent) {
            throw 'The previously verified private database-bootstrap job deployment is absent; no deployment replay was attempted.'
        }
        $deploymentParameters = @(
            "location=$($Config.location)",
            "environment=$($Config.environment)",
            "projectName=$($Config.projectName)",
            "containerAppsEnvironmentId=$($Foundation.containerAppsEnvironmentId)",
            "databaseMigratorImageDigest=$imageDigest",
            "acrLoginServer=$($Foundation.acrLoginServer)",
            "imagePullIdentityResourceId=$($Foundation.runtimeImagePullIdentityId)",
            "sqlServerFqdn=$SqlServerFqdn",
            "expectedPrivateEndpointIp=$ExpectedPrivateEndpointIpv4Address",
            "deploymentOwnershipId=$(([guid]$DeploymentOwnershipId).ToString('D'))",
            "apiDatabasePrincipalName=$($ApiPrincipal.displayName)",
            "apiDatabasePrincipalClientId=$(([guid][string]$ApiPrincipal.clientId).ToString('D'))",
            "workerDatabasePrincipalName=$($WorkerPrincipal.displayName)",
            "workerDatabasePrincipalClientId=$(([guid][string]$WorkerPrincipal.clientId).ToString('D'))"
        )
        if ($Recovery) {
            $deploymentParameters += @(
                "originalAcceptedSourceFingerprint=$SourceFingerprint",
                "recoverySourceFingerprint=$RecoverySourceFingerprint",
                "recoveryPlanFingerprint=$RecoveryPlanFingerprint",
                "recoveryExecutionIntentId=$canonicalExecutionIntentId",
                "recoveryAttemptNumber=$RecoveryAttemptNumber",
                "originalFailedDatabaseBoundaryFingerprint=$OriginalFailedBoundaryFingerprint",
                "priorFailedRecoveryBoundaryFingerprint=$PriorFailedRecoveryBoundaryFingerprint",
                'replicaTimeoutSeconds=1800'
            )
        }
        else {
            $deploymentParameters += @(
                "bootstrapSourceFingerprint=$SourceFingerprint",
                "executionIntentId=$canonicalExecutionIntentId"
            )
        }
        $deployment = Invoke-AzJson -Arguments (@(
            'deployment', 'group', 'create',
            '--resource-group', [string]$Config.resourceGroupName,
            '--name', $deploymentName,
            '--template-file', (Join-Path $root $(if ($Recovery) { 'bootstrap/infra/database-migrator-recovery-job.bicep' } else { 'bootstrap/infra/database-migrator-job.bicep' })),
            '--parameters') + $deploymentParameters)
    }
    else {
        $deployment = Invoke-AzJson -Arguments @(
            'deployment', 'group', 'show',
            '--resource-group', [string]$Config.resourceGroupName,
            '--name', $deploymentName
        )
    }
    if (-not $deployment -or [string]$deployment.name -cne $deploymentName -or
        [string]$deployment.properties.provisioningState -cne 'Succeeded' -or
        [string]$deployment.properties.parameters.location.value -cne [string]$Config.location -or
        [string]$deployment.properties.parameters.environment.value -cne [string]$Config.environment -or
        [string]$deployment.properties.parameters.projectName.value -cne [string]$Config.projectName -or
        -not ([string]$deployment.properties.parameters.containerAppsEnvironmentId.value).Equals([string]$Foundation.containerAppsEnvironmentId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$deployment.properties.parameters.databaseMigratorImageDigest.value -cne $imageDigest -or
        [string]$deployment.properties.parameters.acrLoginServer.value -cne [string]$Foundation.acrLoginServer -or
        -not ([string]$deployment.properties.parameters.imagePullIdentityResourceId.value).Equals([string]$Foundation.runtimeImagePullIdentityId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$deployment.properties.parameters.sqlServerFqdn.value -cne $SqlServerFqdn -or
        [string]$deployment.properties.parameters.expectedPrivateEndpointIp.value -cne $ExpectedPrivateEndpointIpv4Address -or
        [string]$deployment.properties.parameters.deploymentOwnershipId.value -cne ([guid]$DeploymentOwnershipId).ToString('D') -or
        (-not $Recovery -and [string]$deployment.properties.parameters.bootstrapSourceFingerprint.value -cne $SourceFingerprint) -or
        ($Recovery -and (
            [string]$deployment.properties.parameters.originalAcceptedSourceFingerprint.value -cne $SourceFingerprint -or
            [string]$deployment.properties.parameters.recoverySourceFingerprint.value -cne $RecoverySourceFingerprint -or
            [string]$deployment.properties.parameters.recoveryPlanFingerprint.value -cne $RecoveryPlanFingerprint -or
            [int]$deployment.properties.parameters.recoveryAttemptNumber.value -ne $RecoveryAttemptNumber -or
            [string]$deployment.properties.parameters.originalFailedDatabaseBoundaryFingerprint.value -cne $OriginalFailedBoundaryFingerprint -or
            [string]$deployment.properties.parameters.priorFailedRecoveryBoundaryFingerprint.value -cne $PriorFailedRecoveryBoundaryFingerprint)) -or
        [string]$deployment.properties.parameters.apiDatabasePrincipalName.value -cne [string]$ApiPrincipal.displayName -or
        [string]$deployment.properties.parameters.apiDatabasePrincipalClientId.value -cne ([guid][string]$ApiPrincipal.clientId).ToString('D') -or
        [string]$deployment.properties.parameters.workerDatabasePrincipalName.value -cne [string]$WorkerPrincipal.displayName -or
        [string]$deployment.properties.parameters.workerDatabasePrincipalClientId.value -cne ([guid][string]$WorkerPrincipal.clientId).ToString('D') -or
        (-not $Recovery -and [string]$deployment.properties.parameters.executionIntentId.value -cne $canonicalExecutionIntentId) -or
        ($Recovery -and (
            [string]$deployment.properties.parameters.recoveryExecutionIntentId.value -cne $canonicalExecutionIntentId -or
            [int]$deployment.properties.parameters.replicaTimeoutSeconds.value -ne 1800))) {
        throw 'The private database-bootstrap job deployment is absent, nonterminal, or outside its exact source, identity, image, and network contract.'
    }

    return Get-GatewayDatabaseBootstrapJobEvidence `
        -Config $Config `
        -Foundation $Foundation `
        -SqlServerFqdn $SqlServerFqdn `
        -ExpectedPrivateEndpointIpv4Address $ExpectedPrivateEndpointIpv4Address `
        -JobImage $JobImage `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $SourceFingerprint `
        -ApiPrincipal $ApiPrincipal `
        -WorkerPrincipal $WorkerPrincipal `
        -ExecutionIntentId $canonicalExecutionIntentId `
        -Recovery:$Recovery `
        -RecoveryAttemptNumber $RecoveryAttemptNumber `
        -RecoverySourceFingerprint $RecoverySourceFingerprint `
        -RecoveryPlanFingerprint $RecoveryPlanFingerprint `
        -OriginalFailedBoundaryFingerprint $OriginalFailedBoundaryFingerprint `
        -PriorFailedRecoveryBoundaryFingerprint $PriorFailedRecoveryBoundaryFingerprint
}

function Get-GatewayDatabaseBootstrapExecutions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$JobName
    )

    return @(Invoke-AzJson -Arguments @(
        'containerapp', 'job', 'execution', 'list',
        '--resource-group', [string]$Config.resourceGroupName,
        '--name', $JobName,
        '--query', '[].{name:name,status:properties.status,startTime:properties.startTime,endTime:properties.endTime}'
    ))
}

function Start-GatewayDatabaseBootstrapExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$JobName,
        [switch]$Recovery,
        [ValidateSet(1, 2)][int]$RecoveryAttemptNumber = 1
    )

    $expectedJobName = if ($Recovery) { [string](Get-GatewayDatabaseRecoveryAttemptContract -Config $Config -AttemptNumber $RecoveryAttemptNumber).jobName } else { "job-$($Config.projectName)-db-init-$($Config.environment)" }
    if ($JobName -cne $expectedJobName) {
        throw 'The database-bootstrap start target does not match the deterministic Job name.'
    }
    return Invoke-AzJson -Arguments @(
        'containerapp', 'job', 'start',
        '--resource-group', [string]$Config.resourceGroupName,
        '--name', $JobName
    ) -CaptureStdoutOnly
}

function Get-GatewayDatabaseBootstrapExecutionsBounded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$JobName,
        [int]$MaximumAttempts = 420,
        [int]$PollIntervalSeconds = 5
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $executions = @()
        try {
            $executions = @(Get-GatewayDatabaseBootstrapExecutions -Config $Config -JobName $JobName)
        }
        catch {
            if ($attempt -eq $MaximumAttempts) {
                $exception = [InvalidOperationException]::new(
                    'The private database-bootstrap execution list could not be read through the full job-timeout recovery window.')
                $exception.Data['A365GatewayDatabaseRecoveryWindowConsumed'] = $true
                throw $exception
            }
            Start-Sleep -Seconds $PollIntervalSeconds
            continue
        }
        if ($executions.Count -gt 1) {
            $exception = [InvalidOperationException]::new(
                'The dedicated private database-bootstrap job has more than one execution; automatic recovery is forbidden.')
            $exception.Data['A365GatewayDatabaseRecoveryWindowConsumed'] = $true
            throw $exception
        }
        if ($executions.Count -eq 1) { return $executions }
        if ($attempt -lt $MaximumAttempts) { Start-Sleep -Seconds $PollIntervalSeconds }
    }
    return @()
}

function Wait-GatewayDatabaseBootstrapExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$JobName,
        [Parameter(Mandatory)][string]$ExecutionName,
        [int]$MaximumAttempts = 420,
        [int]$PollIntervalSeconds = 5
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $execution = $null
        try {
            $execution = Invoke-AzJson -Arguments @(
                'containerapp', 'job', 'execution', 'show',
                '--resource-group', [string]$Config.resourceGroupName,
                '--name', $JobName,
                '--job-execution-name', $ExecutionName
            )
        }
        catch {
            if ($attempt -eq $MaximumAttempts) {
                $exception = [InvalidOperationException]::new(
                    'The exact private database-bootstrap execution could not be read back through the full job-timeout recovery window.')
                $exception.Data['A365GatewayDatabaseRecoveryWindowConsumed'] = $true
                throw $exception
            }
            Start-Sleep -Seconds $PollIntervalSeconds
            continue
        }
        if (-not $execution -or [string]$execution.name -cne $ExecutionName) {
            $exception = [InvalidOperationException]::new(
                'The exact private database-bootstrap execution could not be read back.')
            $exception.Data['A365GatewayDatabaseRecoveryWindowConsumed'] = $true
            throw $exception
        }
        $status = [string]$execution.properties.status
        if ($status -ceq 'Succeeded') { return $execution }
        if ($status -in @('Failed', 'Stopped', 'Degraded')) {
            $exception = [InvalidOperationException]::new(
                'The one authorized private database-bootstrap execution reached a terminal unsuccessful state; it will not be repeated.')
            $exception.Data['A365GatewayDatabaseRecoveryWindowConsumed'] = $true
            throw $exception
        }
        if ($status -notin @('Running', 'Processing', 'Pending', 'Scheduled', 'Unknown')) {
            $exception = [InvalidOperationException]::new(
                'The private database-bootstrap execution returned an unsupported state; it will not be repeated.')
            $exception.Data['A365GatewayDatabaseRecoveryWindowConsumed'] = $true
            throw $exception
        }
        if ($attempt -lt $MaximumAttempts) { Start-Sleep -Seconds $PollIntervalSeconds }
    }
    $exception = [InvalidOperationException]::new(
        'The private database-bootstrap execution did not reach a terminal state within the bounded wait; it will not be repeated.')
    $exception.Data['A365GatewayDatabaseRecoveryWindowConsumed'] = $true
    throw $exception
}

function Complete-GatewayDatabaseBootstrapExecutionRecoveryWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$JobName,
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][string]$ReceiptPath
    )

    if ([string]::IsNullOrWhiteSpace([string]$Receipt.jobStartIntentAtUtc)) {
        return $true
    }

    $executionName = [string]$Receipt.executionName
    if ([string]::IsNullOrWhiteSpace($executionName)) {
        try {
            $executions = @(Get-GatewayDatabaseBootstrapExecutionsBounded `
                -Config $Config -JobName $JobName)
            if ($executions.Count -ne 1) { return $false }
            $executionName = [string]$executions[0].name
        }
        catch {
            # The bounded discovery helper has already exhausted the recovery
            # window (or found an unsafe multi-execution state). Restoration must
            # still proceed so this persistent identity is not left SQL admin.
            return $false
        }
    }
    if ($executionName -cnotmatch "^$([regex]::Escape($JobName))-[a-z0-9]{5,16}$" -or
        (-not [string]::IsNullOrWhiteSpace([string]$Receipt.executionName) -and
            [string]$Receipt.executionName -cne $executionName)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace([string]$Receipt.executionName)) {
        $Receipt.executionName = $executionName
        try {
            Save-GatewayPrivateDatabaseBootstrapRecord -Record $Receipt -Path $ReceiptPath
        }
        catch {
            # A local checkpoint failure must not skip the execution recovery
            # window before SQL administrator restoration.
        }
    }

    try {
        $null = Wait-GatewayDatabaseBootstrapExecution `
            -Config $Config -JobName $JobName -ExecutionName $executionName
        return $true
    }
    catch {
        # Wait either observed a terminal unsuccessful execution or exhausted the
        # full retry/job-timeout window. In both cases restoration proceeds and
        # the caller fails closed without another start.
        return $false
    }
}

function Get-GatewayDatabaseBootstrapExecutionEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$JobName,
        [Parameter(Mandatory)][string]$ExecutionName,
        [Parameter(Mandatory)][string]$JobImage,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$ExpectedPrivateEndpointIpv4Address,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)]$ApiPrincipal,
        [Parameter(Mandatory)]$WorkerPrincipal,
        [Parameter(Mandatory)][string]$ExecutionIntentId,
        [switch]$Recovery,
        [ValidateSet(1, 2)][int]$RecoveryAttemptNumber = 1
    )

    $canonicalExecutionIntentId = ([guid]$ExecutionIntentId).ToString('D')
    $expectedContainerName = if ($Recovery) { [string](Get-GatewayDatabaseRecoveryAttemptContract -Config $Config -AttemptNumber $RecoveryAttemptNumber).containerName } else { 'database-bootstrap' }
    if ($ExecutionIntentId -cne $canonicalExecutionIntentId -or [guid]$ExecutionIntentId -eq [guid]::Empty -or
        $ExecutionName -cnotmatch "^$([regex]::Escape($JobName))-[a-z0-9]{5,16}$") {
        throw 'The exact private database-bootstrap execution boundary is malformed.'
    }
    $execution = Invoke-AzJson -Arguments @(
        'containerapp', 'job', 'execution', 'show',
        '--resource-group', [string]$Config.resourceGroupName,
        '--name', $JobName,
        '--job-execution-name', $ExecutionName
    )
    if (-not $execution -or [string]$execution.name -cne $ExecutionName) {
        throw 'The exact private database-bootstrap execution could not be read back.'
    }
    $containers = @(ConvertTo-GatewayDatabaseBootstrapCollection -Value $execution.properties.template.containers)
    $initContainers = @(if ($null -ne $execution.properties.template.PSObject.Properties['initContainers']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $execution.properties.template.initContainers
    })
    $volumes = @(if ($null -ne $execution.properties.template.PSObject.Properties['volumes']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $execution.properties.template.volumes
    })
    $environment = @(if ($containers.Count -eq 1 -and $null -ne $containers[0].PSObject.Properties['env']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $containers[0].env
    })
    $environmentSecretReference = ''
    if ($environment.Count -eq 1 -and
        $null -ne $environment[0].PSObject.Properties['secretRef']) {
        $environmentSecretReference = [string]$environment[0].secretRef
    }
    $volumeMounts = @(if ($containers.Count -eq 1 -and $null -ne $containers[0].PSObject.Properties['volumeMounts']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $containers[0].volumeMounts
    })
    $probes = @(if ($containers.Count -eq 1 -and $null -ne $containers[0].PSObject.Properties['probes']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $containers[0].probes
    })
    $expectedArguments = @(Get-GatewayDatabaseBootstrapJobArguments `
        -SqlServerFqdn $SqlServerFqdn -DeploymentOwnershipId $DeploymentOwnershipId `
        -ExpectedPrivateEndpointIpv4Address $ExpectedPrivateEndpointIpv4Address `
        -SourceFingerprint $SourceFingerprint -ApiPrincipal $ApiPrincipal -WorkerPrincipal $WorkerPrincipal `
        -Recovery:$Recovery)
    $executionStart = [DateTimeOffset]::MinValue
    $executionEnd = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
            [string]$execution.properties.startTime,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$executionStart) -or
        -not [DateTimeOffset]::TryParse(
            [string]$execution.properties.endTime,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$executionEnd) -or
        $executionStart -eq [DateTimeOffset]::MinValue -or
        $executionEnd -lt $executionStart -or
        [string]$execution.properties.status -cne 'Succeeded' -or
        $initContainers.Count -ne 0 -or $volumes.Count -ne 0 -or
        $containers.Count -ne 1 -or [string]$containers[0].name -cne $expectedContainerName -or
        [string]$containers[0].image -cne $JobImage -or
        (@($containers[0].command | ForEach-Object { [string]$_ }) -join '|') -cne 'dotnet|Gateway.DatabaseMigrator.dll' -or
        (@($containers[0].args | ForEach-Object { [string]$_ }) -join '|') -cne ($expectedArguments -join '|') -or
        $environment.Count -ne 1 -or
        [string]$environment[0].name -cne 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID' -or
        [string]$environment[0].value -cne $canonicalExecutionIntentId -or
        -not [string]::IsNullOrWhiteSpace($environmentSecretReference) -or
        $volumeMounts.Count -ne 0 -or
        $probes.Count -ne 0 -or
        [decimal]$containers[0].resources.cpu -ne [decimal]0.5 -or
        [string]$containers[0].resources.memory -cne '1Gi') {
        throw 'The successful private database-bootstrap execution does not match the exact immutable image, intent, process, environment, volume, and resource contract.'
    }
    return [ordered]@{
        executionName = $ExecutionName
        executionIntentId = $canonicalExecutionIntentId
        status = 'Succeeded'
        image = $JobImage
        startTimeUtc = $executionStart.ToUniversalTime().ToString('O')
        endTimeUtc = $executionEnd.ToUniversalTime().ToString('O')
    }
}

function ConvertFrom-GatewayDatabaseBootstrapEvidenceLogLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$LogLines,
        [Parameter(Mandatory)][string]$ExecutionIntentId
    )

    $canonicalExecutionIntentId = ([guid]$ExecutionIntentId).ToString('D')
    if ($ExecutionIntentId -cne $canonicalExecutionIntentId -or [guid]$ExecutionIntentId -eq [guid]::Empty) {
        throw 'Database-bootstrap execution intent ID must use canonical lowercase non-empty GUID form.'
    }
    if ($LogLines.Count -eq 0 -or $LogLines.Count -gt 128) {
        throw 'The successful private database-bootstrap execution did not expose a bounded evidence chunk set.'
    }

    $pattern = '^A365GW_DB_EVIDENCE\|([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\|([1-9][0-9]{0,2})\|([1-9][0-9]{0,2})\|(sha256:[0-9a-f]{64})\|([A-Za-z0-9+/]+={0,2})$'
    $chunks = [Collections.Generic.Dictionary[int,string]]::new()
    $expectedTotal = 0
    $expectedDigest = ''
    foreach ($line in $LogLines) {
        $match = [regex]::Match([string]$line, $pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if (-not $match.Success -or [string]$match.Groups[1].Value -cne $canonicalExecutionIntentId) {
            throw 'A private database-bootstrap evidence chunk was malformed or bound to another execution intent.'
        }
        $index = [int]$match.Groups[2].Value
        $total = [int]$match.Groups[3].Value
        $digest = [string]$match.Groups[4].Value
        $chunk = [string]$match.Groups[5].Value
        if ($total -lt 1 -or $total -gt 128 -or $index -gt $total -or $chunk.Length -gt 6000 -or
            ($expectedTotal -ne 0 -and $total -ne $expectedTotal) -or
            (-not [string]::IsNullOrWhiteSpace($expectedDigest) -and $digest -cne $expectedDigest) -or
            -not $chunks.TryAdd($index, $chunk)) {
            throw 'The private database-bootstrap evidence chunk set is duplicated, inconsistent, or outside its bounds.'
        }
        $expectedTotal = $total
        $expectedDigest = $digest
    }
    if ($chunks.Count -ne $expectedTotal) {
        throw 'The private database-bootstrap evidence chunk set is incomplete.'
    }
    $encoded = [Text.StringBuilder]::new()
    for ($index = 1; $index -le $expectedTotal; $index++) {
        $chunk = ''
        if (-not $chunks.TryGetValue($index, [ref]$chunk)) {
            throw 'The private database-bootstrap evidence chunk sequence is incomplete.'
        }
        $null = $encoded.Append($chunk)
    }
    if ($encoded.Length -eq 0 -or $encoded.Length -gt 699052) {
        throw 'The private database-bootstrap evidence payload exceeded its bounded encoded size.'
    }

    $bytes = $null
    $json = ''
    try {
        $bytes = [Convert]::FromBase64String($encoded.ToString())
        if ($bytes.Length -eq 0 -or $bytes.Length -gt 524288) { throw 'invalid length' }
        $actualDigest = "sha256:$([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant())"
        if ($actualDigest -cne $expectedDigest) { throw 'invalid digest' }
        $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $records = @(ConvertFrom-GatewayDatabaseEvidenceJson -Json $json)
    }
    catch {
        throw 'The private database-bootstrap evidence payload was not bounded canonical UTF-8 JSON.'
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    if ($records.Count -ne 3) {
        throw 'The private database-bootstrap job did not return exactly three schema/principal evidence records.'
    }
    if (@($records | Where-Object { [string]$_.ExecutionIntentId -cne $canonicalExecutionIntentId }).Count -ne 0) {
        throw 'The private database-bootstrap evidence records are not exactly bound to their durable execution intent.'
    }
    return [ordered]@{
        records = @($records)
        fingerprint = Get-BootstrapObjectFingerprint -InputObject @($records)
    }
}

function Get-GatewayDatabaseBootstrapEvidenceFromLogs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][string]$JobName,
        [Parameter(Mandatory)][string]$ExecutionName,
        [Parameter(Mandatory)][string]$ExecutionIntentId,
        [int]$MaximumAttempts = 36,
        [int]$PollIntervalSeconds = 10
    )

    $canonicalExecutionIntentId = ([guid]$ExecutionIntentId).ToString('D')
    if ($ExecutionIntentId -cne $canonicalExecutionIntentId -or [guid]$ExecutionIntentId -eq [guid]::Empty -or
        $ExecutionName -cnotmatch "^$([regex]::Escape($JobName))-[a-z0-9]{5,16}$") {
        throw 'The durable database-bootstrap log query boundary is malformed.'
    }
    $workspace = Invoke-AzJson -Arguments @(
        'monitor', 'log-analytics', 'workspace', 'show',
        '--resource-group', [string]$Config.resourceGroupName,
        '--workspace-name', [string]$Foundation.logAnalyticsWorkspaceName,
        '--query', '{id:id,name:name,customerId:customerId}'
    )
    $expectedWorkspaceId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.OperationalInsights/workspaces/$($Foundation.logAnalyticsWorkspaceName)"
    Assert-GuidValue -Value ([string]$workspace.customerId) -Label 'Database-bootstrap Log Analytics customer ID'
    if (-not ([string]$workspace.id).Equals($expectedWorkspaceId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$workspace.name -cne [string]$Foundation.logAnalyticsWorkspaceName -or
        [string]$workspace.customerId -cne ([guid][string]$workspace.customerId).ToString('D')) {
        throw 'The database-bootstrap Log Analytics workspace is outside the exact deployment boundary.'
    }

    $query = "ContainerAppConsoleLogs_CL | where ContainerGroupName_s startswith '$ExecutionName' | where Log_s startswith 'A365GW_DB_EVIDENCE|$canonicalExecutionIntentId|' | project Log_s"
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $lines = @()
        try {
            $lines = @(Invoke-AzJson -Arguments @(
                'monitor', 'log-analytics', 'query',
                '--workspace', [string]$workspace.customerId,
                '--analytics-query', $query,
                '--query', '[].Log_s'
            ) -CaptureStdoutOnly | ForEach-Object { [string]$_ })
        }
        catch { $lines = @() }
        if ($lines.Count -gt 0) {
            try {
                return ConvertFrom-GatewayDatabaseBootstrapEvidenceLogLines `
                    -LogLines $lines -ExecutionIntentId $canonicalExecutionIntentId
            }
            catch {
                if ($attempt -eq $MaximumAttempts) { throw }
            }
        }
        if ($attempt -lt $MaximumAttempts) { Start-Sleep -Seconds $PollIntervalSeconds }
    }
    throw 'Durable Log Analytics did not expose the complete exact-execution database-bootstrap evidence within the bounded wait; the job will not be repeated.'
}

function Get-GatewayFailedDatabaseBootstrapBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$SqlPrivateEndpoint,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$OriginalJobImage,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$OriginalSourceFingerprint,
        [Parameter(Mandatory)]$ApiPrincipal,
        [Parameter(Mandatory)]$WorkerPrincipal,
        [Parameter(Mandatory)][string]$OriginalAdministratorObjectId,
        [Parameter(Mandatory)][string]$OriginalAdministratorLogin
    )

    $evidenceDirectory = Join-Path (Get-RepositoryRoot) ".bootstrap/evidence/$($Config.resourceGroupName)/database"
    $receiptPath = Join-Path $evidenceDirectory 'private-database-bootstrap-receipt.json'
    $receipt = Read-GatewayPrivateDatabaseBootstrapRecord -Path $receiptPath
    if ($null -eq $receipt) {
        throw 'Database recovery requires the preserved original private database-bootstrap receipt.'
    }
    $jobName = "job-$($Config.projectName)-db-init-$($Config.environment)"
    Assert-GatewayPrivateDatabaseBootstrapRecord `
        -Record $receipt -Config $Config -SqlServerFqdn $SqlServerFqdn `
        -JobName $jobName -JobImage $OriginalJobImage `
        -DeploymentOwnershipId $DeploymentOwnershipId -SourceFingerprint $OriginalSourceFingerprint `
        -OriginalAdministratorObjectId $OriginalAdministratorObjectId `
        -OriginalAdministratorLogin $OriginalAdministratorLogin `
        -SqlPrivateEndpoint $SqlPrivateEndpoint | Out-Null
    if ([string]::IsNullOrWhiteSpace([string]$receipt.jobStartIntentAtUtc) -or
        [string]::IsNullOrWhiteSpace([string]$receipt.executionName) -or
        [string]::IsNullOrWhiteSpace([string]$receipt.administratorRestoredAtUtc) -or
        -not [string]::IsNullOrWhiteSpace([string]$receipt.executionSucceededAtUtc) -or
        -not [string]::IsNullOrWhiteSpace([string]$receipt.evidenceFingerprint) -or
        -not [string]::IsNullOrWhiteSpace([string]$receipt.evidenceRecoveredAtUtc) -or
        -not [string]::IsNullOrWhiteSpace([string]$receipt.completedAtUtc)) {
        throw 'The original private database-bootstrap receipt is not the exact failed-before-evidence, administrator-restored boundary required for recovery.'
    }
    $job = Get-GatewayDatabaseBootstrapJobEvidence `
        -Config $Config -Foundation $Foundation -SqlServerFqdn $SqlServerFqdn `
        -ExpectedPrivateEndpointIpv4Address ([string]$SqlPrivateEndpoint.privateEndpointIpv4Address) `
        -JobImage $OriginalJobImage -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $OriginalSourceFingerprint -ApiPrincipal $ApiPrincipal -WorkerPrincipal $WorkerPrincipal `
        -ExecutionIntentId ([string]$receipt.executionIntentId)
    if ([string]$job.jobPrincipalId -cne [string]$receipt.jobPrincipalId) {
        throw 'The original failed database-bootstrap Job identity changed after its preserved receipt.'
    }
    $executions = @(Get-GatewayDatabaseBootstrapExecutions -Config $Config -JobName $jobName)
    if ($executions.Count -ne 1 -or
        [string]$executions[0].name -cne [string]$receipt.executionName -or
        [string]$executions[0].status -cne 'Failed') {
        throw 'Database recovery requires exactly the one preserved failed original Job execution.'
    }
    $execution = Invoke-AzJson -Arguments @(
        'containerapp', 'job', 'execution', 'show',
        '--resource-group', [string]$Config.resourceGroupName,
        '--name', $jobName,
        '--job-execution-name', [string]$receipt.executionName
    )
    $containers = @(ConvertTo-GatewayDatabaseBootstrapCollection -Value $execution.properties.template.containers)
    $environment = @(if ($containers.Count -eq 1) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $containers[0].env
    })
    if ([string]$execution.name -cne [string]$receipt.executionName -or
        [string]$execution.properties.status -cne 'Failed' -or
        $containers.Count -ne 1 -or
        [string]$containers[0].name -cne 'database-bootstrap' -or
        [string]$containers[0].image -cne $OriginalJobImage -or
        $environment.Count -ne 1 -or
        [string]$environment[0].name -cne 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID' -or
        [string]$environment[0].value -cne [string]$receipt.executionIntentId) {
        throw 'The original failed database-bootstrap execution no longer matches its immutable image and intent boundary.'
    }
    $currentAdministrator = Get-GatewaySqlEntraAdministrator -Config $Config -ServerName $SqlServerFqdn.Split('.')[0]
    if ([string]$currentAdministrator.objectId -cne ([guid]$OriginalAdministratorObjectId).ToString('D') -or
        [string]$currentAdministrator.login -cne $OriginalAdministratorLogin -or
        [string]$currentAdministrator.tenantId -cne ([guid][string]$Config.tenantId).ToString('D')) {
        throw 'The original Azure SQL Entra administrator is not restored before database recovery.'
    }
    $boundary = [ordered]@{
        jobId = [string]$job.jobId
        jobName = $jobName
        jobPrincipalId = [string]$job.jobPrincipalId
        jobImage = $OriginalJobImage
        executionName = [string]$receipt.executionName
        executionIntentId = [string]$receipt.executionIntentId
        executionStatus = 'Failed'
        originalReceiptPath = $receiptPath
        originalAdministratorObjectId = ([guid]$OriginalAdministratorObjectId).ToString('D')
        originalAdministratorLogin = $OriginalAdministratorLogin
    }
    $boundary['boundaryFingerprint'] = Get-BootstrapObjectFingerprint -InputObject $boundary
    return $boundary
}

function Get-GatewayFailedDatabaseRecoveryBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$SqlPrivateEndpoint,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RecoveryPlan,
        [Parameter(Mandatory)]$ApiPrincipal,
        [Parameter(Mandatory)]$WorkerPrincipal,
        [Parameter(Mandatory)][string]$OriginalAdministratorObjectId,
        [Parameter(Mandatory)][string]$OriginalAdministratorLogin,
        [switch]$ReturnNullUnlessFailed
    )

    $attemptNumber = Get-GatewayDatabaseRecoveryAttemptNumber -RecoveryPlan $RecoveryPlan
    $contract = Get-GatewayDatabaseRecoveryAttemptContract -Config $Config -AttemptNumber $attemptNumber
    $failedJob = $RecoveryPlan.failedJob
    $priorFailedRecovery = if ($attemptNumber -eq 2 -and $RecoveryPlan.Contains('priorFailedRecovery')) { $RecoveryPlan.priorFailedRecovery } else { $null }
    if ($failedJob -isnot [System.Collections.IDictionary] -or
        $RecoveryPlan.recoveryJob -isnot [System.Collections.IDictionary] -or
        $RecoveryPlan.correctedImage -isnot [System.Collections.IDictionary]) {
        throw 'The accepted database recovery plan is missing its exact original failure, image, or Job boundary.'
    }
    $jobImage = [string]$RecoveryPlan.correctedImage.image
    if ($jobImage -cnotmatch '^[a-z0-9.-]+/gateway-db-migrator@sha256:[0-9a-f]{64}$') {
        throw 'The accepted failed recovery image is not an immutable gateway-db-migrator digest.'
    }
    $databaseEvidenceRoot = Join-Path (Get-RepositoryRoot) ".bootstrap/evidence/$($Config.resourceGroupName)/database"
    $receiptPath = Join-Path $databaseEvidenceRoot ([string]$contract.receiptFileName)
    $receipt = Read-GatewayPrivateDatabaseBootstrapRecord -Path $receiptPath
    if ($null -eq $receipt) {
        throw 'Database recovery continuation requires the preserved prior recovery receipt.'
    }
    Assert-GatewayPrivateDatabaseRecoveryRecord `
        -Record $receipt -Config $Config -SqlServerFqdn $SqlServerFqdn -JobImage $jobImage `
        -DeploymentOwnershipId ([string]$RecoveryPlan.deploymentOwnershipId) `
        -OriginalSourceFingerprint ([string]$RecoveryPlan.originalSourceFingerprint) `
        -RecoverySourceFingerprint ([string]$RecoveryPlan.correctedSourceFingerprint) `
        -RecoveryPlanFingerprint ([string]$RecoveryPlan.planFingerprint) `
        -ExpectedExecutionIntentId ([string]$RecoveryPlan.recoveryJob.executionIntentId) `
        -FailedJob $failedJob -RecoveryAttemptNumber $attemptNumber -PriorFailedRecovery $priorFailedRecovery `
        -OriginalAdministratorObjectId $OriginalAdministratorObjectId `
        -OriginalAdministratorLogin $OriginalAdministratorLogin -SqlPrivateEndpoint $SqlPrivateEndpoint | Out-Null
    if ([string]::IsNullOrWhiteSpace([string]$receipt.jobStartIntentAtUtc) -or
        [string]::IsNullOrWhiteSpace([string]$receipt.executionName) -or
        [string]::IsNullOrWhiteSpace([string]$receipt.administratorRestoredAtUtc) -or
        -not [string]::IsNullOrWhiteSpace([string]$receipt.executionSucceededAtUtc) -or
        -not [string]::IsNullOrWhiteSpace([string]$receipt.evidenceFingerprint) -or
        -not [string]::IsNullOrWhiteSpace([string]$receipt.evidenceRecoveredAtUtc) -or
        -not [string]::IsNullOrWhiteSpace([string]$receipt.completedAtUtc)) {
        throw 'The prior database recovery receipt is not the exact failed-before-evidence, administrator-restored boundary.'
    }
    $evidenceDirectory = Join-Path $databaseEvidenceRoot ([string]$contract.evidenceDirectoryName)
    $evidenceFiles = @(if (Test-Path -LiteralPath $evidenceDirectory) {
        Get-ChildItem -LiteralPath $evidenceDirectory -Filter 'GatewayDb-*.json' -File
    })
    if ($evidenceFiles.Count -ne 0) {
        throw 'The prior failed recovery has local database evidence and cannot be continued automatically.'
    }

    $job = Get-GatewayDatabaseBootstrapJobEvidence `
        -Config $Config -Foundation $Foundation -SqlServerFqdn $SqlServerFqdn `
        -ExpectedPrivateEndpointIpv4Address ([string]$SqlPrivateEndpoint.privateEndpointIpv4Address) `
        -JobImage $jobImage -DeploymentOwnershipId ([string]$RecoveryPlan.deploymentOwnershipId) `
        -SourceFingerprint ([string]$RecoveryPlan.originalSourceFingerprint) -ApiPrincipal $ApiPrincipal -WorkerPrincipal $WorkerPrincipal `
        -ExecutionIntentId ([string]$RecoveryPlan.recoveryJob.executionIntentId) -Recovery `
        -RecoveryAttemptNumber $attemptNumber -RecoverySourceFingerprint ([string]$RecoveryPlan.correctedSourceFingerprint) `
        -RecoveryPlanFingerprint ([string]$RecoveryPlan.planFingerprint) `
        -OriginalFailedBoundaryFingerprint ([string]$failedJob.boundaryFingerprint) `
        -PriorFailedRecoveryBoundaryFingerprint $(if ($null -ne $priorFailedRecovery) { [string]$priorFailedRecovery.boundaryFingerprint } else { '' })
    if ([string]$job.jobPrincipalId -cne [string]$receipt.jobPrincipalId) {
        throw 'The prior recovery Job system identity changed after its preserved receipt.'
    }
    $executions = @(Get-GatewayDatabaseBootstrapExecutions -Config $Config -JobName ([string]$contract.jobName))
    if ($executions.Count -ne 1 -or [string]$executions[0].name -cne [string]$receipt.executionName) {
        throw 'Recovery continuation requires exactly the one preserved prior recovery Job execution.'
    }
    if ([string]$executions[0].status -cne 'Failed') {
        if ($ReturnNullUnlessFailed) { return $null }
        throw 'The prior recovery execution is not in the exact terminal Failed state required for continuation.'
    }
    $execution = Invoke-AzJson -Arguments @(
        'containerapp', 'job', 'execution', 'show',
        '--resource-group', [string]$Config.resourceGroupName,
        '--name', [string]$contract.jobName,
        '--job-execution-name', [string]$receipt.executionName
    )
    $containers = @(ConvertTo-GatewayDatabaseBootstrapCollection -Value $execution.properties.template.containers)
    $initContainers = @(if ($null -ne $execution.properties.template.PSObject.Properties['initContainers']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $execution.properties.template.initContainers
    })
    $volumes = @(if ($null -ne $execution.properties.template.PSObject.Properties['volumes']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $execution.properties.template.volumes
    })
    $environment = @(if ($containers.Count -eq 1 -and $null -ne $containers[0].PSObject.Properties['env']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $containers[0].env
    })
    $volumeMounts = @(if ($containers.Count -eq 1 -and $null -ne $containers[0].PSObject.Properties['volumeMounts']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $containers[0].volumeMounts
    })
    $probes = @(if ($containers.Count -eq 1 -and $null -ne $containers[0].PSObject.Properties['probes']) {
        ConvertTo-GatewayDatabaseBootstrapCollection -Value $containers[0].probes
    })
    $expectedArguments = @(Get-GatewayDatabaseBootstrapJobArguments `
        -SqlServerFqdn $SqlServerFqdn `
        -ExpectedPrivateEndpointIpv4Address ([string]$SqlPrivateEndpoint.privateEndpointIpv4Address) `
        -DeploymentOwnershipId ([string]$RecoveryPlan.deploymentOwnershipId) `
        -SourceFingerprint ([string]$RecoveryPlan.originalSourceFingerprint) `
        -ApiPrincipal $ApiPrincipal -WorkerPrincipal $WorkerPrincipal -Recovery)
    $executionStart = [DateTimeOffset]::MinValue
    $executionEnd = [DateTimeOffset]::MinValue
    $administratorRestoredAt = [DateTimeOffset]::MinValue
    $executionEndTimePresent = -not [string]::IsNullOrWhiteSpace([string]$execution.properties.endTime)
    $executionEndTimeValid = -not $executionEndTimePresent -or
        [DateTimeOffset]::TryParse(
            [string]$execution.properties.endTime,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$executionEnd)
    if (-not $execution -or [string]$execution.name -cne [string]$receipt.executionName -or
        [string]$execution.properties.status -cne 'Failed' -or
        -not [DateTimeOffset]::TryParse([string]$execution.properties.startTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$executionStart) -or
        -not $executionEndTimeValid -or
        $executionStart -eq [DateTimeOffset]::MinValue -or
        ($executionEndTimePresent -and $executionEnd -lt $executionStart) -or
        $initContainers.Count -ne 0 -or $volumes.Count -ne 0 -or $containers.Count -ne 1 -or
        [string]$containers[0].name -cne [string]$contract.containerName -or
        [string]$containers[0].image -cne $jobImage -or
        (@($containers[0].command | ForEach-Object { [string]$_ }) -join '|') -cne 'dotnet|Gateway.DatabaseMigrator.dll' -or
        (@($containers[0].args | ForEach-Object { [string]$_ }) -join '|') -cne ($expectedArguments -join '|') -or
        $environment.Count -ne 1 -or
        [string]$environment[0].name -cne 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID' -or
        [string]$environment[0].value -cne [string]$receipt.executionIntentId -or
        ($null -ne $environment[0].PSObject.Properties['secretRef'] -and -not [string]::IsNullOrWhiteSpace([string]$environment[0].secretRef)) -or
        $volumeMounts.Count -ne 0 -or $probes.Count -ne 0 -or
        [decimal]$containers[0].resources.cpu -ne [decimal]0.5 -or
        [string]$containers[0].resources.memory -cne '1Gi') {
        throw 'The prior failed recovery execution no longer matches its exact immutable image, arguments, or managed-identity intent.'
    }
    $intentAt = [DateTimeOffset]::ParseExact([string]$receipt.jobStartIntentAtUtc, 'O', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    if ($executionStart.ToUniversalTime() -lt $intentAt.ToUniversalTime().AddMinutes(-2) -or
        $executionStart.ToUniversalTime() -gt $intentAt.ToUniversalTime().AddMinutes(10) -or
        (-not [string]::IsNullOrWhiteSpace([string]$receipt.executionStartedAtUtc) -and
            [string]$receipt.executionStartedAtUtc -cne $executionStart.ToUniversalTime().ToString('O'))) {
        throw 'The prior failed recovery execution is outside its bounded durable start intent.'
    }
    if (-not [DateTimeOffset]::TryParseExact(
            [string]$receipt.administratorRestoredAtUtc,
            'O',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$administratorRestoredAt) -or
        $administratorRestoredAt -lt $executionStart -or
        ($executionEndTimePresent -and $administratorRestoredAt -lt $executionEnd)) {
        throw 'The prior failed recovery administrator-restoration checkpoint is outside the exact execution boundary.'
    }
    $currentAdministrator = Get-GatewaySqlEntraAdministrator -Config $Config -ServerName $SqlServerFqdn.Split('.')[0]
    if ([string]$currentAdministrator.objectId -cne ([guid]$OriginalAdministratorObjectId).ToString('D') -or
        [string]$currentAdministrator.login -cne $OriginalAdministratorLogin -or
        [string]$currentAdministrator.tenantId -cne ([guid][string]$Config.tenantId).ToString('D')) {
        throw 'The original Azure SQL Entra administrator is not restored after the failed recovery attempt.'
    }
    $boundary = [ordered]@{
        attemptNumber = $attemptNumber
        recoveryPlanFingerprint = [string]$RecoveryPlan.planFingerprint
        recoverySourceFingerprint = [string]$RecoveryPlan.correctedSourceFingerprint
        originalFailedBoundaryFingerprint = [string]$failedJob.boundaryFingerprint
        jobId = [string]$job.jobId
        jobName = [string]$contract.jobName
        jobPrincipalId = [string]$job.jobPrincipalId
        jobImage = $jobImage
        executionName = [string]$receipt.executionName
        executionIntentId = [string]$receipt.executionIntentId
        executionStatus = 'Failed'
        executionStartedAtUtc = $executionStart.ToUniversalTime().ToString('O')
        executionEndTimePresent = $executionEndTimePresent
        executionFailedAtUtc = if ($executionEndTimePresent) { $executionEnd.ToUniversalTime().ToString('O') } else { '' }
        administratorRestoredAtUtc = $administratorRestoredAt.ToUniversalTime().ToString('O')
        receiptPath = $receiptPath
        receiptFingerprint = Get-BootstrapObjectFingerprint -InputObject $receipt
        originalAdministratorObjectId = ([guid]$OriginalAdministratorObjectId).ToString('D')
        originalAdministratorLogin = $OriginalAdministratorLogin
    }
    $boundary['boundaryFingerprint'] = Get-BootstrapObjectFingerprint -InputObject $boundary
    return $boundary
}

function Initialize-GatewayDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$SqlPrivateEndpoint,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$ApiPrincipalId,
        [Parameter(Mandatory)][string]$WorkerPrincipalId,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$DatabaseMigratorImage,
        [Parameter(Mandatory)][string]$OriginalEntraAdministratorObjectId,
        [Parameter(Mandatory)][string]$OriginalEntraAdministratorLogin,
        [Parameter(Mandatory)][string]$BootstrapClientIpv4,
        [Parameter()][AllowNull()][System.Collections.IDictionary]$RecoveryPlan
    )
    $repositoryRoot = Get-RepositoryRoot
    $root = Get-BootstrapExecutionSourceRoot
    $executionSourceFingerprint = Get-BootstrapSourceFingerprint -Root $root
    $isRecovery = $null -ne $RecoveryPlan
    $acceptedSourceFingerprint = if ($isRecovery) { [string]$RecoveryPlan.originalSourceFingerprint } else { $executionSourceFingerprint }
    $recoverySourceFingerprint = if ($isRecovery) { [string]$RecoveryPlan.correctedSourceFingerprint } else { '' }
    $recoveryPlanFingerprint = if ($isRecovery) { [string]$RecoveryPlan.planFingerprint } else { '' }
    $failedJob = if ($isRecovery) { $RecoveryPlan.failedJob } else { $null }
    $recoveryAttemptNumber = if ($isRecovery) { Get-GatewayDatabaseRecoveryAttemptNumber -RecoveryPlan $RecoveryPlan } else { 0 }
    $recoveryContract = if ($isRecovery) { Get-GatewayDatabaseRecoveryAttemptContract -Config $Config -AttemptNumber $recoveryAttemptNumber } else { $null }
    $priorFailedRecovery = if ($isRecovery -and $recoveryAttemptNumber -eq 2 -and $RecoveryPlan.Contains('priorFailedRecovery')) { $RecoveryPlan.priorFailedRecovery } else { $null }
    $recoveryExecutionIntentId = ''
    Assert-BootstrapFingerprintValue -Value $acceptedSourceFingerprint -Label 'Accepted database-bootstrap source fingerprint'
    if ($isRecovery) {
        Assert-BootstrapFingerprintValue -Value $recoverySourceFingerprint -Label 'Database recovery source fingerprint'
        Assert-BootstrapFingerprintValue -Value $recoveryPlanFingerprint -Label 'Database recovery plan fingerprint'
        if ($RecoveryPlan.recoveryJob -isnot [System.Collections.IDictionary]) {
            throw 'Database recovery requires the exact accepted recovery Job contract.'
        }
        $recoveryExecutionIntentId = [string]$RecoveryPlan.recoveryJob.executionIntentId
        Assert-GuidValue -Value $recoveryExecutionIntentId -Label 'Accepted database recovery execution intent ID'
        $canonicalRecoveryExecutionIntentId = ([guid]$recoveryExecutionIntentId).ToString('D')
        if ($executionSourceFingerprint -cne $recoverySourceFingerprint -or
            $RecoveryPlan -isnot [System.Collections.IDictionary] -or
            $failedJob -isnot [System.Collections.IDictionary] -or
            [string]$RecoveryPlan.recoveryJob.name -cne [string]$recoveryContract.jobName -or
            [string]$RecoveryPlan.recoveryJob.recoveryMode -cne 'ResumeAfterSchemaCompleted' -or
            [int]$RecoveryPlan.recoveryJob.replicaRetryLimit -ne 0 -or
            [int]$RecoveryPlan.recoveryJob.maximumExecutions -ne 1 -or
            ($recoveryAttemptNumber -eq 2 -and $priorFailedRecovery -isnot [System.Collections.IDictionary]) -or
            $recoveryExecutionIntentId -cne $canonicalRecoveryExecutionIntentId -or
            [string]$RecoveryPlan.deploymentOwnershipId -cne ([guid]$DeploymentOwnershipId).ToString('D')) {
            throw 'Database recovery execution source, original failure, or ownership does not match its accepted plan.'
        }
    }
    Assert-GuidValue -Value $DeploymentOwnershipId -Label 'Database bootstrap operation identifier'
    Assert-GuidValue -Value $OriginalEntraAdministratorObjectId -Label 'Original Azure SQL Entra administrator object ID'
    Assert-BootstrapIpv4Value -Value $BootstrapClientIpv4 -Label 'Legacy accepted-plan client IPv4 metadata'
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    $canonicalOriginalAdministratorObjectId = ([guid]$OriginalEntraAdministratorObjectId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId -or
        $OriginalEntraAdministratorObjectId -cne $canonicalOriginalAdministratorObjectId -or
        [string]::IsNullOrWhiteSpace($OriginalEntraAdministratorLogin) -or
        $OriginalEntraAdministratorLogin.Length -gt 256 -or
        $OriginalEntraAdministratorLogin -match '[\r\n]') {
        throw 'The private database-bootstrap ownership or original Entra administrator contract is malformed.'
    }
    $databaseEvidenceRoot = Join-Path $repositoryRoot ".bootstrap/evidence/$($Config.resourceGroupName)/database"
    $evidenceDirectory = if ($isRecovery) { Join-Path $databaseEvidenceRoot ([string]$recoveryContract.evidenceDirectoryName) } else { $databaseEvidenceRoot }
    [IO.Directory]::CreateDirectory($evidenceDirectory) | Out-Null
    $serverName = $SqlServerFqdn.Split('.')[0]
    if ($SqlServerFqdn -cnotmatch '^[A-Za-z0-9-]+\.database\.windows\.net$' -or
        $serverName -cne "sql-$($Config.projectName)-$($Config.environment)") {
        throw 'The private database-bootstrap SQL server does not match the deterministic deployment server.'
    }
    $privateEndpointAddressTuple = Assert-GatewaySqlPrivateEndpointAddressEvidenceTuple `
        -Config $Config -SqlServerFqdn $SqlServerFqdn -Evidence $SqlPrivateEndpoint
    $publicRecoveryPath = Join-Path $databaseEvidenceRoot 'GatewayDb-network-recovery.json'
    $jobName = if ($isRecovery) { [string]$recoveryContract.jobName } else { "job-$($Config.projectName)-db-init-$($Config.environment)" }
    $receiptPath = if ($isRecovery) { Join-Path $databaseEvidenceRoot ([string]$recoveryContract.receiptFileName) } else { Join-Path $databaseEvidenceRoot 'private-database-bootstrap-receipt.json' }
    $receipt = Read-GatewayPrivateDatabaseBootstrapRecord -Path $receiptPath
    $freshIntent = $null -eq $receipt
    if (-not $freshIntent) {
        if ($isRecovery) {
            Assert-GatewayPrivateDatabaseRecoveryRecord `
                -Record $receipt -Config $Config -SqlServerFqdn $SqlServerFqdn -JobImage $DatabaseMigratorImage `
                -DeploymentOwnershipId $canonicalOwnershipId -OriginalSourceFingerprint $acceptedSourceFingerprint `
                -RecoverySourceFingerprint $recoverySourceFingerprint -RecoveryPlanFingerprint $recoveryPlanFingerprint `
                -ExpectedExecutionIntentId $recoveryExecutionIntentId `
                -FailedJob $failedJob -RecoveryAttemptNumber $recoveryAttemptNumber -PriorFailedRecovery $priorFailedRecovery `
                -OriginalAdministratorObjectId $canonicalOriginalAdministratorObjectId `
                -OriginalAdministratorLogin $OriginalEntraAdministratorLogin -SqlPrivateEndpoint $privateEndpointAddressTuple | Out-Null
        }
        else {
            Assert-GatewayPrivateDatabaseBootstrapRecord `
                -Record $receipt -Config $Config -SqlServerFqdn $SqlServerFqdn `
                -JobName $jobName -JobImage $DatabaseMigratorImage `
                -DeploymentOwnershipId $canonicalOwnershipId -SourceFingerprint $acceptedSourceFingerprint `
                -OriginalAdministratorObjectId $canonicalOriginalAdministratorObjectId `
                -OriginalAdministratorLogin $OriginalEntraAdministratorLogin `
                -SqlPrivateEndpoint $privateEndpointAddressTuple | Out-Null
        }
    }

    $preparationFailure = $null
    try {
    $api = Get-ManagedIdentityClientId -PrincipalObjectId $ApiPrincipalId
    $worker = Get-ManagedIdentityClientId -PrincipalObjectId $WorkerPrincipalId
    $expectedApiPrincipalName = "ca-gateway-api-$($Config.environment)"
    $expectedWorkerPrincipalName = "ca-gateway-worker-$($Config.environment)-v3"
    if ([string]$api.objectId -ne $ApiPrincipalId -or
        [string]$worker.objectId -ne $WorkerPrincipalId -or
        [string]$api.displayName -cne $expectedApiPrincipalName -or
        [string]$worker.displayName -cne $expectedWorkerPrincipalName) {
        throw 'Managed-identity service-principal readback does not match the exact API/worker database-principal naming contract.'
    }
    $expectedImagePrefix = "$($Foundation.acrLoginServer)/gateway-db-migrator@"
    if (-not $DatabaseMigratorImage.StartsWith($expectedImagePrefix, [StringComparison]::Ordinal) -or
        $DatabaseMigratorImage.Substring($expectedImagePrefix.Length) -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'The private database-bootstrap image is not the exact deployment-ACR gateway-db-migrator digest.'
    }
    if ([string]$Foundation.deploymentOwnershipId -cne $canonicalOwnershipId -or
        [string]$Foundation.sourceFingerprint -cne $acceptedSourceFingerprint -or
        [string]$Foundation.resourceGroupName -cne [string]$Config.resourceGroupName -or
        [string]$Foundation.runtimeImagePullIdentityId -cnotmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/.+/providers/Microsoft.ManagedIdentity/userAssignedIdentities/.+$') {
        throw 'The private database-bootstrap foundation does not match the exact owner/source-bound ACR, environment, and pull identity.'
    }
    $publicNetworkAccess = Invoke-AzTsv -Arguments @(
        'sql', 'server', 'show', '--resource-group', [string]$Config.resourceGroupName,
        '--name', $serverName, '--query', 'publicNetworkAccess'
    )
    $azureAdOnlyAuthentication = Invoke-AzTsv -Arguments @(
        'sql', 'server', 'ad-only-auth', 'get', '--resource-group', [string]$Config.resourceGroupName,
        '--name', $serverName, '--query', 'azureAdOnlyAuthentication'
    )
    if ($publicNetworkAccess -cne 'Disabled' -or $azureAdOnlyAuthentication -cne 'true') {
        throw 'Private database bootstrap requires Azure SQL public access Disabled and Entra-only authentication enabled before any Job or administrator mutation.'
    }
    $operationMaterial = "$((([guid]$DeploymentOwnershipId).ToString('D')).ToLowerInvariant())|$(([string]$Config.resourceGroupName).ToLowerInvariant())|$($serverName.ToLowerInvariant())|gatewaydb"
    $operationHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($operationMaterial))).ToLowerInvariant()
    $firewallRuleName = "temp-a365gw-migration-$($operationHash.Substring(0, 24))"
    $allFirewallRules = @(Invoke-AzJson -Arguments @(
        'sql', 'server', 'firewall-rule', 'list',
        '--resource-group', [string]$Config.resourceGroupName,
        '--server', $serverName,
        '--query', '[].{name:name}'
    ))
    if ($allFirewallRules.Count -ne 0) {
        throw 'Private database bootstrap requires the fresh Azure SQL server to have exactly zero firewall rules.'
    }

    if (Test-Path -LiteralPath $publicRecoveryPath) {
        throw 'A legacy public-network database recovery record exists; refusing to mix it with the private job path.'
    }

    if ($isRecovery) {
        $liveFailedJob = Get-GatewayFailedDatabaseBootstrapBoundary `
            -Config $Config -Foundation $Foundation -SqlPrivateEndpoint $privateEndpointAddressTuple `
            -SqlServerFqdn $SqlServerFqdn -OriginalJobImage ([string]$failedJob.jobImage) `
            -DeploymentOwnershipId $canonicalOwnershipId -OriginalSourceFingerprint $acceptedSourceFingerprint `
            -ApiPrincipal $api -WorkerPrincipal $worker `
            -OriginalAdministratorObjectId $canonicalOriginalAdministratorObjectId `
            -OriginalAdministratorLogin $OriginalEntraAdministratorLogin
        if ([string]$liveFailedJob.boundaryFingerprint -cne [string]$failedJob.boundaryFingerprint) {
            throw 'The original failed Job/execution/intent boundary changed after database recovery plan acceptance. No mutation was started.'
        }
        if ($recoveryAttemptNumber -eq 2) {
            $livePriorFailure = Get-GatewayFailedDatabaseRecoveryBoundary `
                -Config $Config -Foundation $Foundation -SqlPrivateEndpoint $privateEndpointAddressTuple `
                -SqlServerFqdn $SqlServerFqdn -RecoveryPlan $RecoveryPlan.previousRecoveryPlan `
                -ApiPrincipal $api -WorkerPrincipal $worker `
                -OriginalAdministratorObjectId $canonicalOriginalAdministratorObjectId `
                -OriginalAdministratorLogin $OriginalEntraAdministratorLogin
            if ([string]$livePriorFailure.boundaryFingerprint -cne [string]$priorFailedRecovery.boundaryFingerprint) {
                throw 'The prior failed recovery Job/execution/intent boundary changed after continuation-plan acceptance. No mutation was started.'
            }
        }
    }

    if ($freshIntent) {
        $originalAdministrator = Get-GatewaySqlEntraAdministrator -Config $Config -ServerName $serverName
        if ([string]$originalAdministrator.objectId -cne $canonicalOriginalAdministratorObjectId -or
            [string]$originalAdministrator.login -cne $OriginalEntraAdministratorLogin -or
            [string]$originalAdministrator.tenantId -cne ([guid][string]$Config.tenantId).ToString('D')) {
            throw 'The singular Azure SQL Entra administrator does not exactly match the authenticated bootstrap administrator before private initialization.'
        }
        $receipt = [ordered]@{
            schemaVersion = if ($isRecovery -and $recoveryAttemptNumber -eq 2) { 4 } elseif ($isRecovery) { 3 } else { 2 }
            subscriptionId = ([guid][string]$Config.subscriptionId).ToString('D')
            tenantId = ([guid][string]$Config.tenantId).ToString('D')
            resourceGroupName = [string]$Config.resourceGroupName
            server = $SqlServerFqdn
            database = 'GatewayDb'
            deploymentOwnershipId = $canonicalOwnershipId
            acceptedSourceFingerprint = $acceptedSourceFingerprint
            jobDeploymentName = if ($isRecovery) { [string]$recoveryContract.deploymentName } else { "a365gw-$($Config.projectName)-bootstrap-database-job-$($Config.environment)" }
            jobName = $jobName
            jobImage = $DatabaseMigratorImage
            privateEndpointNetworkInterfaceId = [string]$privateEndpointAddressTuple.privateEndpointNetworkInterfaceId
            privateEndpointIpv4Address = [string]$privateEndpointAddressTuple.privateEndpointIpv4Address
            privateDnsARecordSetId = [string]$privateEndpointAddressTuple.privateDnsARecordSetId
            privateDnsARecordName = [string]$privateEndpointAddressTuple.privateDnsARecordName
            privateDnsARecordIpv4Address = [string]$privateEndpointAddressTuple.privateDnsARecordIpv4Address
            originalAdministratorObjectId = $canonicalOriginalAdministratorObjectId
            originalAdministratorLogin = $OriginalEntraAdministratorLogin
            jobPrincipalId = ''
            executionIntentId = if ($isRecovery) { $recoveryExecutionIntentId } else { [guid]::NewGuid().ToString('D') }
            deploymentIntentAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            deploymentVerifiedAtUtc = ''
            administratorSwapIntentAtUtc = ''
            administratorSwappedAtUtc = ''
            jobStartIntentAtUtc = ''
            executionName = ''
            executionStartedAtUtc = ''
            executionSucceededAtUtc = ''
            evidenceFingerprint = ''
            evidenceRecoveredAtUtc = ''
            administratorRestoredAtUtc = ''
            completedAtUtc = ''
        }
        if ($isRecovery) {
            $receipt.Insert(8, 'recoverySourceFingerprint', $recoverySourceFingerprint)
            $receipt.Insert(9, 'recoveryPlanFingerprint', $recoveryPlanFingerprint)
            $receipt.Insert(10, 'originalFailedJobName', [string]$failedJob.jobName)
            $receipt.Insert(11, 'originalFailedExecutionName', [string]$failedJob.executionName)
            $receipt.Insert(12, 'originalFailedExecutionIntentId', [string]$failedJob.executionIntentId)
            $receipt.Insert(13, 'originalFailedBoundaryFingerprint', [string]$failedJob.boundaryFingerprint)
            if ($recoveryAttemptNumber -eq 2) {
                $receipt.Insert(14, 'recoveryAttemptNumber', 2)
                $receipt.Insert(15, 'priorFailedRecoveryJobName', [string]$priorFailedRecovery.jobName)
                $receipt.Insert(16, 'priorFailedRecoveryExecutionName', [string]$priorFailedRecovery.executionName)
                $receipt.Insert(17, 'priorFailedRecoveryExecutionIntentId', [string]$priorFailedRecovery.executionIntentId)
                $receipt.Insert(18, 'priorFailedRecoveryPlanFingerprint', [string]$priorFailedRecovery.recoveryPlanFingerprint)
                $receipt.Insert(19, 'priorFailedRecoverySourceFingerprint', [string]$priorFailedRecovery.recoverySourceFingerprint)
                $receipt.Insert(20, 'priorFailedRecoveryBoundaryFingerprint', [string]$priorFailedRecovery.boundaryFingerprint)
            }
        }
        Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath
    }
    if ($isRecovery) {
        Assert-GatewayPrivateDatabaseRecoveryRecord `
            -Record $receipt -Config $Config -SqlServerFqdn $SqlServerFqdn -JobImage $DatabaseMigratorImage `
            -DeploymentOwnershipId $canonicalOwnershipId -OriginalSourceFingerprint $acceptedSourceFingerprint `
            -RecoverySourceFingerprint $recoverySourceFingerprint -RecoveryPlanFingerprint $recoveryPlanFingerprint `
            -ExpectedExecutionIntentId $recoveryExecutionIntentId `
            -FailedJob $failedJob -RecoveryAttemptNumber $recoveryAttemptNumber -PriorFailedRecovery $priorFailedRecovery `
            -OriginalAdministratorObjectId $canonicalOriginalAdministratorObjectId `
            -OriginalAdministratorLogin $OriginalEntraAdministratorLogin -SqlPrivateEndpoint $privateEndpointAddressTuple | Out-Null
    }
    else {
        Assert-GatewayPrivateDatabaseBootstrapRecord `
            -Record $receipt -Config $Config -SqlServerFqdn $SqlServerFqdn `
            -JobName $jobName -JobImage $DatabaseMigratorImage `
            -DeploymentOwnershipId $canonicalOwnershipId -SourceFingerprint $acceptedSourceFingerprint `
            -OriginalAdministratorObjectId $canonicalOriginalAdministratorObjectId `
            -OriginalAdministratorLogin $OriginalEntraAdministratorLogin `
            -SqlPrivateEndpoint $privateEndpointAddressTuple | Out-Null
    }

    $jobEvidence = Deploy-GatewayDatabaseBootstrapJob `
        -Config $Config -Foundation $Foundation -SqlServerFqdn $SqlServerFqdn `
        -ExpectedPrivateEndpointIpv4Address ([string]$privateEndpointAddressTuple.privateEndpointIpv4Address) `
        -JobImage $DatabaseMigratorImage -DeploymentOwnershipId $canonicalOwnershipId `
        -SourceFingerprint $acceptedSourceFingerprint -ApiPrincipal $api -WorkerPrincipal $worker `
        -ExecutionIntentId ([string]$receipt.executionIntentId) `
        -FreshIntent:([string]::IsNullOrWhiteSpace([string]$receipt.deploymentVerifiedAtUtc)) `
        -Recovery:$isRecovery -RecoveryAttemptNumber $(if ($isRecovery) { $recoveryAttemptNumber } else { 1 }) `
        -RecoverySourceFingerprint $recoverySourceFingerprint -RecoveryPlanFingerprint $recoveryPlanFingerprint `
        -OriginalFailedBoundaryFingerprint $(if ($isRecovery) { [string]$failedJob.boundaryFingerprint } else { '' }) `
        -PriorFailedRecoveryBoundaryFingerprint $(if ($null -ne $priorFailedRecovery) { [string]$priorFailedRecovery.boundaryFingerprint } else { '' })
    if (-not [string]::IsNullOrWhiteSpace([string]$receipt.jobPrincipalId) -and
        [string]$receipt.jobPrincipalId -cne [string]$jobEvidence.jobPrincipalId) {
        throw 'The database-bootstrap job system identity changed after its durable recovery checkpoint.'
    }
    if ([string]$jobEvidence.executionIntentId -cne [string]$receipt.executionIntentId) {
        throw 'The database-bootstrap job execution intent changed after its durable recovery checkpoint.'
    }
    $receipt.jobPrincipalId = [string]$jobEvidence.jobPrincipalId
    if ([string]::IsNullOrWhiteSpace([string]$receipt.deploymentVerifiedAtUtc)) {
        $receipt.deploymentVerifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath
    }
    }
    catch { $preparationFailure = $_ }
    if ($null -ne $preparationFailure) {
        if ($null -ne $receipt -and -not [string]::IsNullOrWhiteSpace([string]$receipt.jobPrincipalId)) {
            try {
                $null = Complete-GatewayDatabaseBootstrapExecutionRecoveryWindow `
                    -Config $Config -JobName $jobName -Receipt $receipt -ReceiptPath $receiptPath
                $currentAdministrator = Get-GatewaySqlEntraAdministrator -Config $Config -ServerName $serverName
                if ([string]$currentAdministrator.objectId -ceq [string]$receipt.jobPrincipalId -and
                    [string]$currentAdministrator.login -ceq $jobName) {
                    Set-GatewaySqlEntraAdministratorExact `
                        -Config $Config -ServerName $serverName `
                        -ObjectId $canonicalOriginalAdministratorObjectId `
                        -Login $OriginalEntraAdministratorLogin
                }
                elseif ([string]$currentAdministrator.objectId -cne $canonicalOriginalAdministratorObjectId -or
                    [string]$currentAdministrator.login -cne $OriginalEntraAdministratorLogin -or
                    [string]$currentAdministrator.tenantId -cne ([guid][string]$Config.tenantId).ToString('D')) {
                    throw 'The singular Azure SQL administrator is outside both exact recovery identities.'
                }
                $receipt.administratorRestoredAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath
            }
            catch {
                throw 'Private database bootstrap preparation failed and exact restoration of the original Azure SQL Entra administrator could not be proved. The recovery receipt was preserved; no job start was repeated.'
            }
        }
        throw $preparationFailure
    }

    $evidenceFiles = [ordered]@{
        initialize = Join-Path $evidenceDirectory 'GatewayDb-private-initialize.json'
        api = Join-Path $evidenceDirectory 'GatewayDb-private-principal-api.json'
        worker = Join-Path $evidenceDirectory 'GatewayDb-private-principal-worker.json'
    }
    $currentRecords = @()
    $primaryFailure = $null
    $restoreFailure = $null
    $executionRecoveryWindowObserved = $false
    try {
        $hasDurableStartIntent = -not [string]::IsNullOrWhiteSpace([string]$receipt.jobStartIntentAtUtc)
        $executions = @(if ($hasDurableStartIntent) {
            Get-GatewayDatabaseBootstrapExecutionsBounded -Config $Config -JobName $jobName
        }
        else {
            Get-GatewayDatabaseBootstrapExecutions -Config $Config -JobName $jobName
        })
        if ($executions.Count -gt 1) {
            throw 'The dedicated private database-bootstrap job has more than one execution; automatic recovery is forbidden.'
        }

        if ($executions.Count -eq 0) {
            if (-not [string]::IsNullOrWhiteSpace([string]$receipt.jobStartIntentAtUtc)) {
                $executionRecoveryWindowObserved = $true
                throw 'The one recorded database-bootstrap job start has an unknown provider outcome after the full job-timeout recovery window. It will not be repeated.'
            }
            else {
                $preStartJobEvidence = Get-GatewayDatabaseBootstrapJobEvidence `
                    -Config $Config -Foundation $Foundation -SqlServerFqdn $SqlServerFqdn `
                    -ExpectedPrivateEndpointIpv4Address ([string]$privateEndpointAddressTuple.privateEndpointIpv4Address) `
                    -JobImage $DatabaseMigratorImage -DeploymentOwnershipId $canonicalOwnershipId `
                    -SourceFingerprint $acceptedSourceFingerprint -ApiPrincipal $api -WorkerPrincipal $worker `
                    -ExecutionIntentId ([string]$receipt.executionIntentId) `
                    -Recovery:$isRecovery -RecoveryAttemptNumber $(if ($isRecovery) { $recoveryAttemptNumber } else { 1 }) `
                    -RecoverySourceFingerprint $recoverySourceFingerprint -RecoveryPlanFingerprint $recoveryPlanFingerprint `
                    -OriginalFailedBoundaryFingerprint $(if ($isRecovery) { [string]$failedJob.boundaryFingerprint } else { '' }) `
                    -PriorFailedRecoveryBoundaryFingerprint $(if ($null -ne $priorFailedRecovery) { [string]$priorFailedRecovery.boundaryFingerprint } else { '' })
                if ([string]$preStartJobEvidence.jobPrincipalId -cne [string]$jobEvidence.jobPrincipalId -or
                    [string]$preStartJobEvidence.executionIntentId -cne [string]$receipt.executionIntentId) {
                    throw 'The database-bootstrap Job changed immediately before the SQL administrator boundary.'
                }
                $preStartExecutions = @(Get-GatewayDatabaseBootstrapExecutions -Config $Config -JobName $jobName)
                if ($preStartExecutions.Count -ne 0) {
                    throw 'The database-bootstrap execution set changed immediately before the SQL administrator boundary.'
                }
                $preAdministratorAddressTuple = Get-GatewaySqlPrivateEndpointReadyAddressEvidence `
                    -Config $Config -Foundation $Foundation -SqlServerFqdn $SqlServerFqdn
                foreach ($propertyName in @(
                    'privateEndpointNetworkInterfaceId', 'privateEndpointIpv4Address',
                    'privateDnsARecordSetId', 'privateDnsARecordName', 'privateDnsARecordIpv4Address'
                )) {
                    if ([string]$preAdministratorAddressTuple[$propertyName] -cne
                        [string]$privateEndpointAddressTuple[$propertyName]) {
                        throw 'The persisted SQL private-endpoint NIC and private-DNS A-record tuple changed immediately before the SQL administrator boundary.'
                    }
                }
                $currentAdministrator = Get-GatewaySqlEntraAdministrator -Config $Config -ServerName $serverName
                if ([string]$currentAdministrator.objectId -cne $canonicalOriginalAdministratorObjectId -or
                    [string]$currentAdministrator.login -cne $OriginalEntraAdministratorLogin -or
                    [string]$currentAdministrator.tenantId -cne ([guid][string]$Config.tenantId).ToString('D')) {
                    throw 'Azure SQL administrator state changed before the private job start intent was recorded.'
                }
                $receipt.administratorSwapIntentAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath
                Set-GatewaySqlEntraAdministratorExact `
                    -Config $Config -ServerName $serverName `
                    -ObjectId ([string]$jobEvidence.jobPrincipalId) -Login $jobName
                $receipt.administratorSwappedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath

                $receipt.jobStartIntentAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath
                try {
                    $startedExecution = Start-GatewayDatabaseBootstrapExecution -Config $Config -JobName $jobName -Recovery:$isRecovery -RecoveryAttemptNumber $(if ($isRecovery) { $recoveryAttemptNumber } else { 1 })
                    if ($startedExecution -and [string]$startedExecution.name -notmatch "^$([regex]::Escape($jobName))-[a-z0-9]{5,16}$") {
                        throw 'Azure returned a malformed database-bootstrap execution identifier.'
                    }
                    if ($startedExecution -and -not [string]::IsNullOrWhiteSpace([string]$startedExecution.name)) {
                        $receipt.executionName = [string]$startedExecution.name
                        Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath
                    }
                }
                catch {
                    # The durable intent precedes the external start. Discover its
                    # exact intent-bound outcome below; never issue a second start.
                }
                $executions = @(Get-GatewayDatabaseBootstrapExecutionsBounded -Config $Config -JobName $jobName)
                if ($executions.Count -eq 0) {
                    $executionRecoveryWindowObserved = $true
                    throw 'The one authorized database-bootstrap job start has an unknown provider outcome after the full job-timeout recovery window. It will not be repeated.'
                }
            }
        }

        if ($executions.Count -ne 1) {
            throw 'Private database-bootstrap recovery did not resolve exactly one execution.'
        }
        $execution = $executions[0]
        $executionName = [string]$execution.name
        if ($executionName -cnotmatch "^$([regex]::Escape($jobName))-[a-z0-9]{5,16}$") {
            throw 'The private database-bootstrap execution name is outside the deterministic job boundary.'
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$receipt.executionName) -and
            [string]$receipt.executionName -cne $executionName) {
            throw 'The private database-bootstrap execution changed after its durable checkpoint.'
        }
        $intentTime = [DateTimeOffset]::ParseExact(
            [string]$receipt.jobStartIntentAtUtc, 'O', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
        $receipt.executionName = $executionName
        Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath

        $executionStatus = [string]$execution.status
        if ($executionStatus -in @('Failed', 'Stopped', 'Degraded')) {
            $executionRecoveryWindowObserved = $true
            throw 'The one authorized private database-bootstrap execution reached a terminal unsuccessful state; SQL administrator elevation will not be repeated.'
        }
        if ($executionStatus -notin @('Succeeded', 'Running', 'Processing', 'Pending', 'Scheduled', 'Unknown')) {
            $executionRecoveryWindowObserved = $true
            throw 'The private database-bootstrap execution returned an unsupported state; SQL administrator elevation will not be repeated.'
        }
        if ($executionStatus -cne 'Succeeded') {
            $currentAdministrator = Get-GatewaySqlEntraAdministrator -Config $Config -ServerName $serverName
            if ([string]$currentAdministrator.objectId -ceq $canonicalOriginalAdministratorObjectId -and
                [string]$currentAdministrator.login -ceq $OriginalEntraAdministratorLogin) {
                Set-GatewaySqlEntraAdministratorExact `
                    -Config $Config -ServerName $serverName `
                    -ObjectId ([string]$jobEvidence.jobPrincipalId) -Login $jobName
                $receipt.administratorSwappedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
                Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath
            }
            elseif ([string]$currentAdministrator.objectId -cne [string]$jobEvidence.jobPrincipalId -or
                [string]$currentAdministrator.login -cne $jobName) {
                throw 'The singular Azure SQL administrator is neither the recorded original administrator nor the exact database job identity.'
            }
        }

        try {
            $null = Wait-GatewayDatabaseBootstrapExecution `
                -Config $Config -JobName $jobName -ExecutionName $executionName
            $executionRecoveryWindowObserved = $true
        }
        catch {
            if ($_.Exception.Data['A365GatewayDatabaseRecoveryWindowConsumed'] -eq $true) {
                $executionRecoveryWindowObserved = $true
            }
            throw
        }
        $executionEvidence = Get-GatewayDatabaseBootstrapExecutionEvidence `
            -Config $Config -JobName $jobName -ExecutionName $executionName `
            -JobImage $DatabaseMigratorImage -SqlServerFqdn $SqlServerFqdn `
            -ExpectedPrivateEndpointIpv4Address ([string]$privateEndpointAddressTuple.privateEndpointIpv4Address) `
            -DeploymentOwnershipId $canonicalOwnershipId -SourceFingerprint $acceptedSourceFingerprint `
            -ApiPrincipal $api -WorkerPrincipal $worker `
            -ExecutionIntentId ([string]$receipt.executionIntentId) -Recovery:$isRecovery `
            -RecoveryAttemptNumber $(if ($isRecovery) { $recoveryAttemptNumber } else { 1 })
        $verifiedExecutionStart = [DateTimeOffset]::ParseExact(
            [string]$executionEvidence.startTimeUtc, 'O', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
        if ($verifiedExecutionStart -lt $intentTime.ToUniversalTime().AddMinutes(-2) -or
            $verifiedExecutionStart -gt $intentTime.ToUniversalTime().AddMinutes(10)) {
            throw 'The successful private database-bootstrap execution is outside its bounded durable start intent.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$receipt.executionStartedAtUtc)) {
            $receipt.executionStartedAtUtc = [string]$executionEvidence.startTimeUtc
            Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath
        }
        elseif ([string]$receipt.executionStartedAtUtc -cne [string]$executionEvidence.startTimeUtc) {
            throw 'The successful private database-bootstrap execution start time changed after its durable checkpoint.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$receipt.executionSucceededAtUtc)) {
            $receipt.executionSucceededAtUtc = [string]$executionEvidence.endTimeUtc
            Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath
        }
        elseif ([string]$receipt.executionSucceededAtUtc -cne [string]$executionEvidence.endTimeUtc) {
            throw 'The successful private database-bootstrap execution end time changed after its durable checkpoint.'
        }

        $hasEvidenceFingerprint = -not [string]::IsNullOrWhiteSpace([string]$receipt.evidenceFingerprint)
        $hasEvidenceRecoveryTime = -not [string]::IsNullOrWhiteSpace([string]$receipt.evidenceRecoveredAtUtc)
        if ($hasEvidenceFingerprint -ne $hasEvidenceRecoveryTime) {
            throw 'The durable database-bootstrap evidence checkpoint is partial; automatic recovery is forbidden.'
        }
        if ($hasEvidenceFingerprint) {
            $actualEvidenceFiles = @(Get-ChildItem -LiteralPath $evidenceDirectory -Filter 'GatewayDb-*.json' -File | Sort-Object Name)
            $expectedEvidenceNames = @($evidenceFiles.Values | ForEach-Object { [IO.Path]::GetFileName([string]$_) } | Sort-Object)
            if ($actualEvidenceFiles.Count -ne 3 -or
                (@($actualEvidenceFiles.Name) -join '|') -cne ($expectedEvidenceNames -join '|')) {
                throw 'Durable private database-bootstrap recovery does not contain exactly the three expected local evidence files.'
            }
            foreach ($path in @($evidenceFiles.Values)) {
                $parsedRecords = @(ConvertFrom-GatewayDatabaseEvidenceJson -Json (Get-Content -LiteralPath $path -Raw))
                if ($parsedRecords.Count -ne 1) {
                    throw 'A durable private database-bootstrap evidence file does not contain exactly one record.'
                }
                $currentRecords += $parsedRecords[0]
            }
            if ([string]$receipt.evidenceFingerprint -cne (Get-BootstrapObjectFingerprint -InputObject @($currentRecords))) {
                throw 'Durable private database-bootstrap evidence no longer matches its exact fingerprint.'
            }
        }
        else {
            $payload = Get-GatewayDatabaseBootstrapEvidenceFromLogs `
                -Config $Config -Foundation $Foundation -JobName $jobName `
                -ExecutionName $executionName -ExecutionIntentId ([string]$receipt.executionIntentId)
            $currentRecords = @($payload.records)
            $initializeRecord = @($currentRecords | Where-Object { [string]$_.Phase -ceq 'initialize' })
            $apiRecord = @($currentRecords | Where-Object { [string]$_.Phase -ceq 'principal' -and [string]$_.RuntimePrincipal.Name -ceq $expectedApiPrincipalName })
            $workerRecord = @($currentRecords | Where-Object { [string]$_.Phase -ceq 'principal' -and [string]$_.RuntimePrincipal.Name -ceq $expectedWorkerPrincipalName })
            if ($initializeRecord.Count -ne 1 -or $apiRecord.Count -ne 1 -or $workerRecord.Count -ne 1) {
                throw 'The private database-bootstrap evidence cannot be partitioned into the exact initialization/API/worker records.'
            }
            Save-GatewayPrivateDatabaseBootstrapRecord -Record (ConvertTo-BootstrapCanonicalValue -Value $initializeRecord[0]) -Path $evidenceFiles.initialize
            Save-GatewayPrivateDatabaseBootstrapRecord -Record (ConvertTo-BootstrapCanonicalValue -Value $apiRecord[0]) -Path $evidenceFiles.api
            Save-GatewayPrivateDatabaseBootstrapRecord -Record (ConvertTo-BootstrapCanonicalValue -Value $workerRecord[0]) -Path $evidenceFiles.worker
            $receipt.evidenceFingerprint = [string]$payload.fingerprint
            $receipt.evidenceRecoveredAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath
        }
        $databaseSummary = Get-GatewayDatabaseEvidenceSummary `
            -Records $currentRecords -SqlServerFqdn $SqlServerFqdn `
            -DeploymentOwnershipId $canonicalOwnershipId `
            -AcceptedSourceFingerprint $acceptedSourceFingerprint `
            -ExecutionIntentId ([string]$receipt.executionIntentId) `
            -ApiPrincipal $api -WorkerPrincipal $worker `
            -RequiredRecoveryMode $(if ($isRecovery) { 'ResumeAfterSchemaCompleted' } else { '' })
    }
    catch {
        if ($_.Exception.Data['A365GatewayDatabaseRecoveryWindowConsumed'] -eq $true) {
            $executionRecoveryWindowObserved = $true
        }
        $primaryFailure = $_
    }
    finally {
        try {
            if (-not $executionRecoveryWindowObserved) {
                $null = Complete-GatewayDatabaseBootstrapExecutionRecoveryWindow `
                    -Config $Config -JobName $jobName -Receipt $receipt -ReceiptPath $receiptPath
            }
            $currentAdministrator = Get-GatewaySqlEntraAdministrator -Config $Config -ServerName $serverName
            if ([string]$currentAdministrator.objectId -ceq [string]$jobEvidence.jobPrincipalId -and
                [string]$currentAdministrator.login -ceq $jobName) {
                Set-GatewaySqlEntraAdministratorExact `
                    -Config $Config -ServerName $serverName `
                    -ObjectId $canonicalOriginalAdministratorObjectId `
                    -Login $OriginalEntraAdministratorLogin
            }
            elseif ([string]$currentAdministrator.objectId -cne $canonicalOriginalAdministratorObjectId -or
                [string]$currentAdministrator.login -cne $OriginalEntraAdministratorLogin -or
                [string]$currentAdministrator.tenantId -cne ([guid][string]$Config.tenantId).ToString('D')) {
                throw 'The singular Azure SQL administrator is outside both exact recovery identities.'
            }
            $receipt.administratorRestoredAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath
        }
        catch { $restoreFailure = $_ }
    }
    if ($null -ne $restoreFailure) {
        throw 'Private database bootstrap did not prove exact restoration of the original Azure SQL Entra administrator. The recovery receipt was preserved; no job start will be repeated.'
    }
    if ($null -ne $primaryFailure) { throw $primaryFailure }

    $publicNetworkAccess = Invoke-AzTsv -Arguments @(
        'sql', 'server', 'show', '--resource-group', [string]$Config.resourceGroupName,
        '--name', $serverName, '--query', 'publicNetworkAccess'
    )
    $azureAdOnlyAuthentication = Invoke-AzTsv -Arguments @(
        'sql', 'server', 'ad-only-auth', 'get', '--resource-group', [string]$Config.resourceGroupName,
        '--name', $serverName, '--query', 'azureAdOnlyAuthentication'
    )
    $allFirewallRules = @(Invoke-AzJson -Arguments @(
        'sql', 'server', 'firewall-rule', 'list',
        '--resource-group', [string]$Config.resourceGroupName,
        '--server', $serverName, '--query', '[].{name:name}'
    ))
    $finalAdministrator = Get-GatewaySqlEntraAdministrator -Config $Config -ServerName $serverName
    if ($publicNetworkAccess -cne 'Disabled' -or $azureAdOnlyAuthentication -cne 'true' -or $allFirewallRules.Count -ne 0 -or
        [string]$finalAdministrator.objectId -cne $canonicalOriginalAdministratorObjectId -or
        [string]$finalAdministrator.login -cne $OriginalEntraAdministratorLogin -or
        [string]$finalAdministrator.tenantId -cne ([guid][string]$Config.tenantId).ToString('D') -or
        (Test-Path -LiteralPath $publicRecoveryPath)) {
        throw 'Private database bootstrap did not prove the exact final SQL network and Entra administrator boundary.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$receipt.completedAtUtc)) {
        $receipt.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Save-GatewayPrivateDatabaseBootstrapRecord -Record $receipt -Path $receiptPath
    }

    $databaseSummary = Get-GatewayDatabaseEvidenceSummary `
        -Records $currentRecords `
        -SqlServerFqdn $SqlServerFqdn `
        -DeploymentOwnershipId $canonicalOwnershipId `
        -AcceptedSourceFingerprint $acceptedSourceFingerprint `
        -ExecutionIntentId ([string]$receipt.executionIntentId) `
        -ApiPrincipal $api `
        -WorkerPrincipal $worker `
        -RequiredRecoveryMode $(if ($isRecovery) { 'ResumeAfterSchemaCompleted' } else { '' })
    $databaseEvidence = [ordered]@{
        server = $SqlServerFqdn
        database = 'GatewayDb'
        schema = 'CurrentEfModel'
        apiPrincipalClientId = [string]$api.clientId
        workerPrincipalClientId = [string]$worker.clientId
        apiPrincipalObjectId = ([guid][string]$api.objectId).ToString('D')
        workerPrincipalObjectId = ([guid][string]$worker.objectId).ToString('D')
        networkMode = 'PrivateContainerAppsJob'
        privateNetworkExecutionVerified = $true
        publicNetworkRestoredToDisabled = $true
        temporaryFirewallRuleAbsenceVerified = $true
        networkRecoveryRecordCleared = $true
        networkOperationId = $canonicalOwnershipId
        deploymentOwnershipId = $canonicalOwnershipId
        acceptedSourceFingerprint = $acceptedSourceFingerprint
        schemaFingerprint = [string]$databaseSummary.schemaFingerprint
        initializationIntent = $databaseSummary.initializationIntent
        apiPrincipalName = [string]$api.displayName
        workerPrincipalName = [string]$worker.displayName
        apiDirectPermissions = @('VIEW DEFINITION')
        workerDirectPermissions = @()
        bootstrapClientIpv4 = $BootstrapClientIpv4
        legacyPublicBootstrapClientIpv4Unused = $true
        temporaryFirewallRuleName = $firewallRuleName
        evidenceDirectory = $evidenceDirectory
        databaseBootstrapJobId = [string]$jobEvidence.jobId
        databaseBootstrapJobName = [string]$jobEvidence.jobName
        databaseBootstrapJobPrincipalId = [string]$jobEvidence.jobPrincipalId
        databaseBootstrapJobImage = [string]$jobEvidence.jobImage
        databaseBootstrapExecutionName = [string]$receipt.executionName
        databaseBootstrapExecutionIntentId = [string]$receipt.executionIntentId
        databaseBootstrapEvidenceFingerprint = [string]$receipt.evidenceFingerprint
        databaseBootstrapCompletionReceipt = $receiptPath
        privateEndpointNetworkInterfaceId = [string]$privateEndpointAddressTuple.privateEndpointNetworkInterfaceId
        privateEndpointIpv4Address = [string]$privateEndpointAddressTuple.privateEndpointIpv4Address
        privateDnsARecordSetId = [string]$privateEndpointAddressTuple.privateDnsARecordSetId
        privateDnsARecordName = [string]$privateEndpointAddressTuple.privateDnsARecordName
        privateDnsARecordIpv4Address = [string]$privateEndpointAddressTuple.privateDnsARecordIpv4Address
        originalSqlAdministratorObjectId = $canonicalOriginalAdministratorObjectId
        originalSqlAdministratorLogin = $OriginalEntraAdministratorLogin
        originalSqlAdministratorRestored = $true
    }
    if ($isRecovery) {
        $databaseEvidence['databaseRecoveryAttemptNumber'] = $recoveryAttemptNumber
        $databaseEvidence['databaseRecoveryMode'] = 'ResumeAfterSchemaCompleted'
        $databaseEvidence['databaseRecoveryPlanFingerprint'] = $recoveryPlanFingerprint
        $databaseEvidence['recoverySourceFingerprint'] = $recoverySourceFingerprint
        $databaseEvidence['originalFailedDatabaseBootstrapJobName'] = [string]$failedJob.jobName
        $databaseEvidence['originalFailedDatabaseBootstrapExecutionName'] = [string]$failedJob.executionName
        $databaseEvidence['originalFailedDatabaseBootstrapExecutionIntentId'] = [string]$failedJob.executionIntentId
        $databaseEvidence['originalFailedDatabaseBootstrapBoundaryFingerprint'] = [string]$failedJob.boundaryFingerprint
        if ($recoveryAttemptNumber -eq 2) {
            $databaseEvidence['priorFailedDatabaseRecoveryJobName'] = [string]$priorFailedRecovery.jobName
            $databaseEvidence['priorFailedDatabaseRecoveryExecutionName'] = [string]$priorFailedRecovery.executionName
            $databaseEvidence['priorFailedDatabaseRecoveryExecutionIntentId'] = [string]$priorFailedRecovery.executionIntentId
            $databaseEvidence['priorFailedDatabaseRecoveryPlanFingerprint'] = [string]$priorFailedRecovery.recoveryPlanFingerprint
            $databaseEvidence['priorFailedDatabaseRecoverySourceFingerprint'] = [string]$priorFailedRecovery.recoverySourceFingerprint
            $databaseEvidence['priorFailedDatabaseRecoveryBoundaryFingerprint'] = [string]$priorFailedRecovery.boundaryFingerprint
        }
    }
    return $databaseEvidence
}

Export-ModuleMember -Function *
