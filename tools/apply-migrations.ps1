#Requires -Version 7.0

<#
.SYNOPSIS
    Initializes an empty Gateway database or applies the reviewed SQL upgrade steps.

.DESCRIPTION
    Uses the current Azure CLI identity through AzureCliCredential. Initialize may
    create the current EF schema only when the database has zero user tables; all
    nonempty databases must pass read-back verification or fail. Other steps apply
    only checked-in SQL. The script never reads a SQL password, generates EF
    migrations, or modifies a project file. A live GatewayDb target requires the
    explicit AllowLiveDatabase switch. Public SQL access can be opened for the
    caller's current IP only for this command and is restored in finally.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9-]+\.database\.windows\.net$')]
    [string]$SqlServerFqdn,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$DatabaseName,

    [string]$ResourceGroup = 'rg-agent-gateway',

    [ValidateSet('Initialize', 'Baseline', 'Prepare', 'Finalize', 'Verify')]
    [string]$Phase = 'Prepare',

    [ValidateRange(1, 2)]
    [int]$Repeat = 1,

    [switch]$AllowLiveDatabase,

    [switch]$TemporarilyEnablePublicNetwork,

    [switch]$RequireInitiallyDisabledPublicNetwork,

    [guid]$NetworkOperationId,

    [guid]$DeploymentOwnershipId,

    [ValidatePattern('^sha256:[0-9a-f]{64}$')]
    [string]$AcceptedSourceFingerprint,

    [Parameter(Mandatory)]
    [string]$ExpectedClientIpv4,

    [string]$EvidenceDirectory,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string]$ApiPrincipalName,

    [guid]$ApiPrincipalClientId,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string]$WorkerPrincipalName,

    [guid]$WorkerPrincipalClientId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$null = Get-A365GatewayBootstrapSubscriptionId -Required
$parsedExpectedClientIpv4 = $null
if (-not [Net.IPAddress]::TryParse($ExpectedClientIpv4, [ref]$parsedExpectedClientIpv4) -or
    $parsedExpectedClientIpv4.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    $parsedExpectedClientIpv4.ToString() -cne $ExpectedClientIpv4) {
    throw 'ExpectedClientIpv4 must be the canonical IPv4 address bound into the accepted bootstrap plan.'
}
$publicNetworkPropagationMaximumAttempts = 36
$publicNetworkPropagationPollIntervalSeconds = 5

function Wait-SqlPublicNetworkAccessState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$ServerName,

        [Parameter(Mandatory)]
        [ValidateSet('Enabled', 'Disabled')]
        [string]$ExpectedState,

        [Parameter(Mandatory)]
        [ValidateRange(1, 120)]
        [int]$MaximumAttempts,

        [Parameter(Mandatory)]
        [ValidateRange(1, 30)]
        [int]$PollIntervalSeconds
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $currentState = $null
        try {
            $currentState = (Invoke-AzCommand -Arguments @(
                'sql', 'server', 'show',
                '--resource-group', $ResourceGroupName,
                '--name', $ServerName,
                '--query', 'publicNetworkAccess',
                '--output', 'tsv',
                '--only-show-errors'
            ) -ErrorMessage 'Azure SQL public-network state polling failed.' | Out-String).Trim()
        }
        catch {
            $currentState = $null
        }
        if ($currentState -eq $ExpectedState) {
            return $true
        }

        if ($attempt -lt $MaximumAttempts) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }

    return $false
}

function Get-TemporarySqlFirewallRule {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$RuleName
    )

    if ($RuleName -cnotmatch '^temp-a365gw-migration-[0-9a-f]{24}$') {
        throw 'Temporary Azure SQL firewall-rule name is outside the bootstrap-owned namespace.'
    }
    try {
        $raw = (Invoke-AzCommand -Arguments @(
            'sql', 'server', 'firewall-rule', 'list',
            '--resource-group', $ResourceGroupName,
            '--server', $ServerName,
            '--query', "[?name=='$RuleName'].{name:name,startIpAddress:startIpAddress,endIpAddress:endIpAddress}",
            '--output', 'json',
            '--only-show-errors'
        ) -ErrorMessage 'Azure SQL firewall-rule discovery failed.' | Out-String).Trim()
    }
    catch {
        throw 'Azure SQL firewall-rule discovery was unavailable; absence was not proven.'
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'Azure SQL firewall-rule discovery was unavailable; absence was not proven.'
    }
    try { $matches = @($raw | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw 'Azure SQL returned malformed metadata for the bootstrap-owned temporary firewall rule.' }
    if ($matches.Count -gt 1) { throw 'Azure SQL returned duplicate exact-name temporary firewall rules.' }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Get-TemporarySqlFirewallRuleName {
    param(
        [Parameter(Mandatory)][guid]$OperationId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$TargetDatabaseName
    )
    if ($OperationId -eq [guid]::Empty) { throw 'The SQL network operation ID must be a non-empty GUID.' }
    $material = "$($OperationId.ToString('D').ToLowerInvariant())|$($ResourceGroupName.ToLowerInvariant())|$($ServerName.ToLowerInvariant())|$($TargetDatabaseName.ToLowerInvariant())"
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($material))).ToLowerInvariant()
    return "temp-a365gw-migration-$($hash.Substring(0, 24))"
}

function Remove-TemporarySqlFirewallRuleExact {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$RuleName
    )

    $rule = Get-TemporarySqlFirewallRule -ResourceGroupName $ResourceGroupName -ServerName $ServerName -RuleName $RuleName
    if ($rule) {
        if ([string]$rule.name -cne $RuleName) { throw 'Azure SQL returned a different firewall rule than the exact bootstrap cleanup target.' }
        $null = Invoke-AzCommand -Arguments @(
            'sql', 'server', 'firewall-rule', 'delete',
            '--resource-group', $ResourceGroupName, '--server', $ServerName,
            '--name', $RuleName, '--yes', '--output', 'none'
        ) -ErrorMessage 'Could not remove the exact bootstrap-owned temporary Azure SQL firewall rule.'
    }
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $remaining = Get-TemporarySqlFirewallRule -ResourceGroupName $ResourceGroupName -ServerName $ServerName -RuleName $RuleName
        if (-not $remaining) { return $true }
        if ($attempt -lt 18) { Start-Sleep -Seconds 5 }
    }
    throw 'The exact bootstrap-owned temporary Azure SQL firewall rule could not be proven removed.'
}

function Save-SqlNetworkRecoveryRecord {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Record)
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ".$([IO.Path]::GetFileName($Path)).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $Record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryPath -Encoding utf8NoBOM
        $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $stream.Flush($true) } finally { $stream.Dispose() }
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

if ($DatabaseName.Equals('master', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The migration runner refuses to target master.'
}
if ($DatabaseName.Equals('GatewayDb', [System.StringComparison]::OrdinalIgnoreCase) -and
    -not $AllowLiveDatabase) {
    throw 'Targeting GatewayDb requires -AllowLiveDatabase after a verified recovery copy exists.'
}

[bool[]]$principalArgumentsProvided = @(
    (-not [string]::IsNullOrWhiteSpace($ApiPrincipalName))
    ($ApiPrincipalClientId -ne [guid]::Empty)
    (-not [string]::IsNullOrWhiteSpace($WorkerPrincipalName))
    ($WorkerPrincipalClientId -ne [guid]::Empty)
)
$principalArgumentCount = @($principalArgumentsProvided | Where-Object { $_ }).Count
if ($principalArgumentCount -notin @(0, 4)) {
    throw 'API and worker principal names/client IDs must be supplied together.'
}

[bool[]]$bootstrapBindingArgumentsProvided = @(
    ($DeploymentOwnershipId -ne [guid]::Empty)
    (-not [string]::IsNullOrWhiteSpace($AcceptedSourceFingerprint))
)
$bootstrapBindingArgumentCount = @($bootstrapBindingArgumentsProvided | Where-Object { $_ }).Count
if ($bootstrapBindingArgumentCount -notin @(0, 2)) {
    throw 'DeploymentOwnershipId and AcceptedSourceFingerprint must be supplied together.'
}
$hasBootstrapDatabaseBinding = $bootstrapBindingArgumentCount -eq 2
if ($Phase -eq 'Initialize' -and -not $hasBootstrapDatabaseBinding) {
    throw 'Initialize requires the exact deployment ownership ID and accepted source fingerprint for durable database recovery.'
}
if ($hasBootstrapDatabaseBinding -and $DeploymentOwnershipId -eq [guid]::Empty) {
    throw 'DeploymentOwnershipId must be a non-empty GUID.'
}
if ($hasBootstrapDatabaseBinding -and
    $principalArgumentCount -ne 4) {
    throw 'Bootstrap-bound database work requires the exact API and worker principal contracts.'
}
if ($Phase -eq 'Initialize' -and $NetworkOperationId -ne $DeploymentOwnershipId) {
    throw 'The SQL network operation and durable database initialization marker must use the same deployment ownership ID.'
}

Assert-Command 'az' 'https://aka.ms/installazurecli'
Assert-Command 'dotnet' 'https://dot.net'
$null = Assert-AzLogin

$sqlServerName = ($SqlServerFqdn -split '\.')[0]
if ($NetworkOperationId -eq [guid]::Empty) {
    throw 'NetworkOperationId is required so temporary SQL network mutations and recovery cleanup are bound to one exact operation.'
}
$firewallRuleName = Get-TemporarySqlFirewallRuleName `
    -OperationId $NetworkOperationId `
    -ResourceGroupName $ResourceGroup `
    -ServerName $sqlServerName `
    -TargetDatabaseName $DatabaseName

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $RepoRoot 'artifacts' 'migration-evidence'
}
$EvidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory)
[IO.Directory]::CreateDirectory($EvidenceDirectory) | Out-Null
$recoveryPath = Join-Path $EvidenceDirectory "${DatabaseName}-network-recovery.json"

if (Test-Path -LiteralPath $recoveryPath) {
    try { $recovery = Get-Content -LiteralPath $recoveryPath -Raw | ConvertFrom-Json -Depth 10 -ErrorAction Stop }
    catch { throw 'The Azure SQL network recovery record is malformed. Preserve it and review the exact temporary rule before continuing.' }
    $expectedRecoverySchemaVersion = if ($hasBootstrapDatabaseBinding) { 2 } else { 1 }
    if ([int]$recovery.schemaVersion -ne $expectedRecoverySchemaVersion -or
        -not ([string]$recovery.operationId).Equals($NetworkOperationId.ToString('D'), [StringComparison]::OrdinalIgnoreCase) -or
        [string]$recovery.resourceGroup -cne $ResourceGroup -or
        [string]$recovery.serverName -cne $sqlServerName -or
        [string]$recovery.databaseName -cne $DatabaseName -or
        [string]$recovery.firewallRuleName -cne $firewallRuleName -or
        ($null -ne $recovery.PSObject.Properties['expectedClientIpv4'] -and
            [string]$recovery.expectedClientIpv4 -cne $ExpectedClientIpv4) -or
        ($RequireInitiallyDisabledPublicNetwork -and $recovery.restorePublicNetworkToDisabled -ne $true) -or
        ($hasBootstrapDatabaseBinding -and
            ([string]$recovery.deploymentOwnershipId -cne $DeploymentOwnershipId.ToString('D') -or
             [string]$recovery.acceptedSourceFingerprint -cne $AcceptedSourceFingerprint))) {
        throw 'The Azure SQL network recovery record does not match this exact migration target; refusing cleanup or mutation.'
    }
    Remove-TemporarySqlFirewallRuleExact -ResourceGroupName $ResourceGroup -ServerName $sqlServerName -RuleName ([string]$recovery.firewallRuleName) | Out-Null
    if ($recovery.restorePublicNetworkToDisabled -eq $true) {
        $null = Invoke-AzCommand -Arguments @(
            'sql', 'server', 'update', '--resource-group', $ResourceGroup,
            '--name', $sqlServerName, '--enable-public-network', 'false', '--output', 'none'
        ) -ErrorMessage 'Could not restore Azure SQL public network access from the recorded recovery operation.'
        if (-not (Wait-SqlPublicNetworkAccessState -ResourceGroupName $ResourceGroup -ServerName $sqlServerName -ExpectedState 'Disabled' -MaximumAttempts $publicNetworkPropagationMaximumAttempts -PollIntervalSeconds $publicNetworkPropagationPollIntervalSeconds)) {
            throw 'Azure SQL public network access was not verified as Disabled while reconciling the prior recovery operation.'
        }
    }
    Remove-Item -LiteralPath $recoveryPath -Force
}

try {
    $server = (Invoke-AzCommand -Arguments @(
        'sql', 'server', 'show', '--resource-group', $ResourceGroup,
        '--name', $sqlServerName, '--output', 'json'
    ) -ErrorMessage "Azure SQL logical server '$sqlServerName' was not found." | Out-String) |
        ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw 'Azure SQL logical-server discovery failed or returned malformed metadata; provider output was suppressed.'
}
$originalPublicNetworkAccess = [string]$server.publicNetworkAccess
if ($originalPublicNetworkAccess -notin @('Enabled', 'Disabled')) {
    throw 'Azure SQL returned an unsupported public-network state.'
}

# Reconcile the deterministic bootstrap-owned rule before any target-database
# assertion or initial-network-state rejection. This remains safe when the
# durable recovery file was lost because only this operation's exact rule name
# can be removed; ambiguous public-network state is never changed without the
# matching durable restore record.
Remove-TemporarySqlFirewallRuleExact -ResourceGroupName $ResourceGroup -ServerName $sqlServerName -RuleName $firewallRuleName | Out-Null
if ($RequireInitiallyDisabledPublicNetwork -and $originalPublicNetworkAccess -ne 'Disabled') {
    throw 'Clean bootstrap requires Azure SQL public network access to start Disabled. The exact operation-owned firewall rule was proven absent, but no matching recovery record authorized changing the still-public server; disable it through a separately reviewed recovery action before Resume.'
}
if ($originalPublicNetworkAccess -eq 'Disabled' -and -not $TemporarilyEnablePublicNetwork) {
    throw 'Azure SQL public network access is disabled. Run inside the VNet or explicitly use -TemporarilyEnablePublicNetwork.'
}
$publicNetworkRestoreRequired = $originalPublicNetworkAccess -eq 'Disabled'
$networkCleanupRequired = $true

$null = Invoke-AzCommand -Arguments @(
    'sql', 'db', 'show',
    '--resource-group', $ResourceGroup,
    '--server', $sqlServerName,
    '--name', $DatabaseName,
    '--output', 'none'
) -ErrorMessage "Azure SQL database '$DatabaseName' was not found."

$networkRecoveryRecord = [ordered]@{
    schemaVersion = if ($hasBootstrapDatabaseBinding) { 2 } else { 1 }
    operationId = $NetworkOperationId.ToString('D')
    resourceGroup = $ResourceGroup
    serverName = $sqlServerName
    databaseName = $DatabaseName
    firewallRuleName = $firewallRuleName
    expectedClientIpv4 = $ExpectedClientIpv4
    restorePublicNetworkToDisabled = $publicNetworkRestoreRequired
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
}
if ($hasBootstrapDatabaseBinding) {
    $networkRecoveryRecord.deploymentOwnershipId = $DeploymentOwnershipId.ToString('D')
    $networkRecoveryRecord.acceptedSourceFingerprint = $AcceptedSourceFingerprint
}
Save-SqlNetworkRecoveryRecord -Path $recoveryPath -Record $networkRecoveryRecord

$evidencePath = Join-Path $EvidenceDirectory (
    "{0}-{1}-{2}.json" -f $DatabaseName, $Phase.ToLowerInvariant(),
    (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))

try {
    if ($originalPublicNetworkAccess -eq 'Disabled') {
        Write-Info 'Temporarily enabling Azure SQL public network access for the bounded migration session.'
        $null = Invoke-AzCommand -Arguments @(
            'sql', 'server', 'update',
            '--resource-group', $ResourceGroup,
            '--name', $sqlServerName,
            '--enable-public-network', 'true',
            '--output', 'none'
        ) -ErrorMessage 'Could not temporarily enable Azure SQL public network access.'

        $publicEndpointReady = Wait-SqlPublicNetworkAccessState `
            -ResourceGroupName $ResourceGroup `
            -ServerName $sqlServerName `
            -ExpectedState 'Enabled' `
            -MaximumAttempts $publicNetworkPropagationMaximumAttempts `
            -PollIntervalSeconds $publicNetworkPropagationPollIntervalSeconds
        if (-not $publicEndpointReady) {
            throw 'Azure SQL did not report its public endpoint enabled within the bounded wait.'
        }
    }

    $null = Invoke-AzCommand -Arguments @(
        'sql', 'server', 'firewall-rule', 'create',
        '--resource-group', $ResourceGroup,
        '--server', $sqlServerName,
        '--name', $firewallRuleName,
        '--start-ip-address', $ExpectedClientIpv4,
        '--end-ip-address', $ExpectedClientIpv4,
        '--output', 'none'
    ) -ErrorMessage 'Could not create the temporary caller-only Azure SQL firewall rule.'
    $createdRule = Get-TemporarySqlFirewallRule -ResourceGroupName $ResourceGroup -ServerName $sqlServerName -RuleName $firewallRuleName
    if (-not $createdRule -or [string]$createdRule.name -cne $firewallRuleName -or
        [string]$createdRule.startIpAddress -cne $ExpectedClientIpv4 -or
        [string]$createdRule.endIpAddress -cne $ExpectedClientIpv4) {
        throw 'The exact caller-only Azure SQL firewall rule could not be verified after creation.'
    }

    $migratorProject = Join-Path $RepoRoot 'tools' 'Gateway.DatabaseMigrator' 'Gateway.DatabaseMigrator.csproj'
    $migrationArguments = @(
        'run', '--project', $migratorProject, '--configuration', 'Release', '--',
        '--server', $SqlServerFqdn,
        '--database', $DatabaseName,
        '--phase', $Phase.ToLowerInvariant(),
        '--repeat', $Repeat,
        '--repository-root', $RepoRoot,
        '--evidence', $evidencePath
    )
    if ($hasBootstrapDatabaseBinding) {
        $migrationArguments += @(
            '--deployment-ownership-id', $DeploymentOwnershipId.ToString('D'),
            '--accepted-source-fingerprint', $AcceptedSourceFingerprint
        )
    }
    if ($principalArgumentCount -eq 4) {
        $migrationArguments += @(
            '--expected-api-principal-name', $ApiPrincipalName,
            '--expected-api-principal-client-id', $ApiPrincipalClientId.ToString('D'),
            '--expected-worker-principal-name', $WorkerPrincipalName,
            '--expected-worker-principal-client-id', $WorkerPrincipalClientId.ToString('D')
        )
    }
    & dotnet @migrationArguments 2>&1 | Out-Null
    $migrationExitCode = $LASTEXITCODE
    if ($migrationExitCode -ne 0) {
        throw "The database migration runner failed in phase '$Phase'; exit code: $migrationExitCode. Child provider output was suppressed."
    }

    if ($principalArgumentCount -eq 4) {
        foreach ($principal in @(
            @{ Name = $ApiPrincipalName; ClientId = $ApiPrincipalClientId; RequireAllAfter = $false },
            @{ Name = $WorkerPrincipalName; ClientId = $WorkerPrincipalClientId; RequireAllAfter = $true }
        )) {
            $principalEvidencePath = Join-Path $EvidenceDirectory (
                "{0}-principal-{1}-{2}.json" -f $DatabaseName, $principal.Name,
                (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
            $principalMigrationArguments = @(
                'run', '--project', $migratorProject, '--configuration', 'Release', '--',
                '--server', $SqlServerFqdn,
                '--database', $DatabaseName,
                '--phase', 'principal',
                '--repeat', 1,
                '--principal-name', $principal.Name,
                '--principal-client-id', $principal.ClientId.ToString('D'),
                '--repository-root', $RepoRoot,
                '--evidence', $principalEvidencePath
            )
            if ($hasBootstrapDatabaseBinding) {
                $principalMigrationArguments += @(
                    '--deployment-ownership-id', $DeploymentOwnershipId.ToString('D'),
                    '--accepted-source-fingerprint', $AcceptedSourceFingerprint
                )
            }
            $principalMigrationArguments += @(
                '--expected-api-principal-name', $ApiPrincipalName,
                '--expected-api-principal-client-id', $ApiPrincipalClientId.ToString('D'),
                '--expected-worker-principal-name', $WorkerPrincipalName,
                '--expected-worker-principal-client-id', $WorkerPrincipalClientId.ToString('D')
            )
            if ($principal.RequireAllAfter) {
                $principalMigrationArguments += @(
                    '--require-all-expected-principals-after-mutation', 'true'
                )
            }
            & dotnet @principalMigrationArguments 2>&1 | Out-Null
            $principalExitCode = $LASTEXITCODE
            if ($principalExitCode -ne 0) {
                throw "Database principal setup failed for the expected workload principal category; exit code: $principalExitCode. Child provider output was suppressed."
            }
        }
    }

    Write-Success "Database phase '$Phase' verified for '$DatabaseName'."
    Write-Info "Non-secret evidence: $evidencePath"
}
finally {
    $cleanupFailures = [Collections.Generic.List[string]]::new()
    try {
        Remove-TemporarySqlFirewallRuleExact -ResourceGroupName $ResourceGroup -ServerName $sqlServerName -RuleName $firewallRuleName | Out-Null
    }
    catch { $cleanupFailures.Add('temporary firewall rule absence was not proven') }

    if ($publicNetworkRestoreRequired) {
        try {
            $null = Invoke-AzCommand -Arguments @(
                'sql', 'server', 'update', '--resource-group', $ResourceGroup,
                '--name', $sqlServerName, '--enable-public-network', 'false', '--output', 'none'
            ) -ErrorMessage 'Azure SQL public network access could not be restored to Disabled.'
            $publicNetworkRestored = Wait-SqlPublicNetworkAccessState `
                -ResourceGroupName $ResourceGroup `
                -ServerName $sqlServerName `
                -ExpectedState 'Disabled' `
                -MaximumAttempts $publicNetworkPropagationMaximumAttempts `
                -PollIntervalSeconds $publicNetworkPropagationPollIntervalSeconds
            if (-not $publicNetworkRestored) { throw 'restore not proven' }
        }
        catch { $cleanupFailures.Add('public network Disabled state was not proven') }
    }

    if ($cleanupFailures.Count -eq 0) {
        if (Test-Path -LiteralPath $recoveryPath) { Remove-Item -LiteralPath $recoveryPath -Force }
        $networkCleanupRequired = $false
    }
    else {
        throw "Azure SQL temporary network cleanup is incomplete ($($cleanupFailures -join '; ')). The safe recovery record was preserved; rerun the exact command or bootstrap Resume before any further deployment work."
    }
}
