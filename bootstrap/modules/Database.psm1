Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ManagedIdentityClientId {
    param([Parameter(Mandatory)][string]$PrincipalObjectId)
    Assert-GuidValue -Value $PrincipalObjectId -Label 'Managed identity principal object ID'
    $canonicalObjectId = ([guid]$PrincipalObjectId).ToString('D')
    if ($PrincipalObjectId -cne $canonicalObjectId) {
        throw 'Managed identity principal object ID must use canonical lowercase GUID form.'
    }
    $principal = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$canonicalObjectId?`$select=id,appId,displayName")
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
        [Parameter(Mandatory)]$ApiPrincipal,
        [Parameter(Mandatory)]$WorkerPrincipal
    )
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
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
        }
    }
}

function Initialize-GatewayDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$ApiPrincipalId,
        [Parameter(Mandatory)][string]$WorkerPrincipalId,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$BootstrapClientIpv4
    )
    $repositoryRoot = Get-RepositoryRoot
    $root = Get-BootstrapExecutionSourceRoot
    $acceptedSourceFingerprint = Get-BootstrapSourceFingerprint -Root $root
    Assert-BootstrapFingerprintValue -Value $acceptedSourceFingerprint -Label 'Accepted database-bootstrap source fingerprint'
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
    $evidenceDirectory = Join-Path $repositoryRoot ".bootstrap/evidence/$($Config.resourceGroupName)/database"
    Assert-GuidValue -Value $DeploymentOwnershipId -Label 'Database network operation identifier'
    Assert-BootstrapIpv4Value -Value $BootstrapClientIpv4 -Label 'SQL bootstrap client IPv4'
    $migrationScript = Join-Path $root 'tools/apply-migrations.ps1'
    $pwsh = (Get-Process -Id $PID).Path
    $arguments = @(
        '-NoLogo', '-NoProfile', '-File', $migrationScript,
        '-SqlServerFqdn', $SqlServerFqdn,
        '-DatabaseName', 'GatewayDb',
        '-ResourceGroup', [string]$Config.resourceGroupName,
        '-Phase', 'Initialize',
        '-Repeat', '1',
        '-AllowLiveDatabase',
        '-TemporarilyEnablePublicNetwork',
        '-RequireInitiallyDisabledPublicNetwork',
        '-NetworkOperationId', ([guid]$DeploymentOwnershipId).ToString('D'),
        '-DeploymentOwnershipId', ([guid]$DeploymentOwnershipId).ToString('D'),
        '-AcceptedSourceFingerprint', $acceptedSourceFingerprint,
        '-ExpectedClientIpv4', $BootstrapClientIpv4,
        '-EvidenceDirectory', $evidenceDirectory,
        '-ApiPrincipalName', $expectedApiPrincipalName,
        '-ApiPrincipalClientId', ([guid]$api.clientId).ToString('D'),
        '-WorkerPrincipalName', $expectedWorkerPrincipalName,
        '-WorkerPrincipalClientId', ([guid]$worker.clientId).ToString('D')
    )
    $migrationStartedAtUtc = [DateTimeOffset]::UtcNow
    Invoke-BootstrapCommand -FilePath $pwsh -ArgumentList $arguments | Out-Null
    $serverName = $SqlServerFqdn.Split('.')[0]
    $publicNetworkAccess = Invoke-AzTsv -Arguments @(
        'sql', 'server', 'show', '--resource-group', [string]$Config.resourceGroupName,
        '--name', $serverName, '--query', 'publicNetworkAccess'
    )
    if ($publicNetworkAccess -cne 'Disabled') {
        throw 'Azure SQL public network access was not independently read back as Disabled after database initialization.'
    }
    $operationMaterial = "$((([guid]$DeploymentOwnershipId).ToString('D')).ToLowerInvariant())|$(([string]$Config.resourceGroupName).ToLowerInvariant())|$($serverName.ToLowerInvariant())|gatewaydb"
    $operationHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($operationMaterial))).ToLowerInvariant()
    $firewallRuleName = "temp-a365gw-migration-$($operationHash.Substring(0, 24))"
    $remainingRules = @(Invoke-AzJson -Arguments @(
        'sql', 'server', 'firewall-rule', 'list',
        '--resource-group', [string]$Config.resourceGroupName,
        '--server', $serverName,
        '--query', "[?name=='$firewallRuleName'].{name:name}"
    ))
    if ($remainingRules.Count -ne 0) {
        throw 'The exact bootstrap-owned temporary Azure SQL firewall rule remained after database initialization.'
    }
    $recoveryPath = Join-Path $evidenceDirectory 'GatewayDb-network-recovery.json'
    if (Test-Path -LiteralPath $recoveryPath) {
        throw 'The Azure SQL network recovery record remained after database initialization; cleanup is not proven.'
    }
    $currentRecords = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $evidenceDirectory -Filter 'GatewayDb-*.json' -File)) {
        $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 50 -ErrorAction Stop
        $verifiedAtUtc = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$record.VerifiedAtUtc, [ref]$verifiedAtUtc) -and
            $verifiedAtUtc -ge $migrationStartedAtUtc.AddSeconds(-5)) {
            $currentRecords += $record
        }
    }
    $databaseSummary = Get-GatewayDatabaseEvidenceSummary `
        -Records $currentRecords `
        -SqlServerFqdn $SqlServerFqdn `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -AcceptedSourceFingerprint $acceptedSourceFingerprint `
        -ApiPrincipal $api `
        -WorkerPrincipal $worker
    return [ordered]@{
        server = $SqlServerFqdn
        database = 'GatewayDb'
        schema = 'CurrentEfModel'
        apiPrincipalClientId = [string]$api.clientId
        workerPrincipalClientId = [string]$worker.clientId
        apiPrincipalObjectId = ([guid][string]$api.objectId).ToString('D')
        workerPrincipalObjectId = ([guid][string]$worker.objectId).ToString('D')
        publicNetworkRestoredToDisabled = $true
        temporaryFirewallRuleAbsenceVerified = $true
        networkRecoveryRecordCleared = $true
        networkOperationId = ([guid]$DeploymentOwnershipId).ToString('D')
        deploymentOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
        acceptedSourceFingerprint = $acceptedSourceFingerprint
        schemaFingerprint = [string]$databaseSummary.schemaFingerprint
        initializationIntent = $databaseSummary.initializationIntent
        apiPrincipalName = [string]$api.displayName
        workerPrincipalName = [string]$worker.displayName
        apiDirectPermissions = @('VIEW DEFINITION')
        workerDirectPermissions = @()
        bootstrapClientIpv4 = $BootstrapClientIpv4
        temporaryFirewallRuleName = $firewallRuleName
        evidenceDirectory = $evidenceDirectory
    }
}

Export-ModuleMember -Function *
