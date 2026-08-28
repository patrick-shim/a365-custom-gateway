#Requires -Version 7.0

<#
.SYNOPSIS
    Initializes an empty Gateway database or applies the reviewed SQL upgrade phases.

.DESCRIPTION
    Uses the current Azure CLI identity through AzureCliCredential. Initialize may
    create the current EF schema only when the database has zero user tables; all
    nonempty databases must pass read-back verification or fail. Other phases apply
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
        $currentState = (& az sql server show `
            --resource-group $ResourceGroupName `
            --name $ServerName `
            --query publicNetworkAccess `
            --output tsv 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $currentState -eq $ExpectedState) {
            return $true
        }

        if ($attempt -lt $MaximumAttempts) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }

    return $false
}

if ($DatabaseName.Equals('master', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The migration runner refuses to target master.'
}
if ($DatabaseName.Equals('GatewayDb', [System.StringComparison]::OrdinalIgnoreCase) -and
    -not $AllowLiveDatabase) {
    throw 'Targeting GatewayDb requires -AllowLiveDatabase after a verified recovery copy exists.'
}

$principalArgumentsProvided = @(
    -not [string]::IsNullOrWhiteSpace($ApiPrincipalName),
    $ApiPrincipalClientId -ne [guid]::Empty,
    -not [string]::IsNullOrWhiteSpace($WorkerPrincipalName),
    $WorkerPrincipalClientId -ne [guid]::Empty
)
if (($principalArgumentsProvided | Where-Object { $_ }).Count -notin @(0, 4)) {
    throw 'API and worker principal names/client IDs must be supplied together.'
}

Assert-Command 'az' 'https://aka.ms/installazurecli'
Assert-Command 'dotnet' 'https://dot.net'
$null = Assert-AzLogin

$sqlServerName = ($SqlServerFqdn -split '\.')[0]
$null = Invoke-AzCommand -Arguments @(
    'sql', 'db', 'show',
    '--resource-group', $ResourceGroup,
    '--server', $sqlServerName,
    '--name', $DatabaseName,
    '--output', 'none'
) -ErrorMessage "Azure SQL database '$DatabaseName' was not found."

$server = (Invoke-AzCommand -Arguments @(
    'sql', 'server', 'show',
    '--resource-group', $ResourceGroup,
    '--name', $sqlServerName,
    '--output', 'json'
) -ErrorMessage "Azure SQL logical server '$sqlServerName' was not found." | Out-String) |
    ConvertFrom-Json

$originalPublicNetworkAccess = [string]$server.publicNetworkAccess
$firewallRuleName = "temp-a365gw-migration-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
$firewallCreated = $false
$publicNetworkRestoreRequired = $false

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $RepoRoot 'artifacts' 'migration-evidence'
}
$evidencePath = Join-Path $EvidenceDirectory (
    "{0}-{1}-{2}.json" -f $DatabaseName, $Phase.ToLowerInvariant(),
    (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))

try {
    if ($originalPublicNetworkAccess -eq 'Disabled') {
        if (-not $TemporarilyEnablePublicNetwork) {
            throw 'Azure SQL public network access is disabled. Run inside the VNet or explicitly use -TemporarilyEnablePublicNetwork.'
        }

        Write-Info 'Temporarily enabling Azure SQL public network access for the bounded migration session.'
        # Set this before the mutation so an interrupted or ambiguous CLI outcome
        # still forces the fail-closed restore path.
        $publicNetworkRestoreRequired = $true
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

    $callerIp = Get-MyPublicIp
    $parsedCallerIp = $null
    if (-not [System.Net.IPAddress]::TryParse($callerIp, [ref]$parsedCallerIp)) {
        throw 'The caller public IP could not be validated.'
    }

    $null = Invoke-AzCommand -Arguments @(
        'sql', 'server', 'firewall-rule', 'create',
        '--resource-group', $ResourceGroup,
        '--server', $sqlServerName,
        '--name', $firewallRuleName,
        '--start-ip-address', $callerIp,
        '--end-ip-address', $callerIp,
        '--output', 'none'
    ) -ErrorMessage 'Could not create the temporary caller-only Azure SQL firewall rule.'
    $firewallCreated = $true

    $migratorProject = Join-Path $RepoRoot 'tools' 'Gateway.DatabaseMigrator' 'Gateway.DatabaseMigrator.csproj'
    & dotnet run --project $migratorProject --configuration Release -- `
        --server $SqlServerFqdn `
        --database $DatabaseName `
        --phase $Phase.ToLowerInvariant() `
        --repeat $Repeat `
        --repository-root $RepoRoot `
        --evidence $evidencePath
    if ($LASTEXITCODE -ne 0) {
        throw "The database migration runner failed with exit code $LASTEXITCODE."
    }

    if (($principalArgumentsProvided | Where-Object { $_ }).Count -eq 4) {
        foreach ($principal in @(
            @{ Name = $ApiPrincipalName; ClientId = $ApiPrincipalClientId },
            @{ Name = $WorkerPrincipalName; ClientId = $WorkerPrincipalClientId }
        )) {
            $principalEvidencePath = Join-Path $EvidenceDirectory (
                "{0}-principal-{1}-{2}.json" -f $DatabaseName, $principal.Name,
                (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
            & dotnet run --project $migratorProject --configuration Release -- `
                --server $SqlServerFqdn `
                --database $DatabaseName `
                --phase principal `
                --repeat 1 `
                --principal-name $principal.Name `
                --principal-client-id $principal.ClientId.ToString('D') `
                --repository-root $RepoRoot `
                --evidence $principalEvidencePath
            if ($LASTEXITCODE -ne 0) {
                throw "Database principal setup failed for '$($principal.Name)'."
            }
        }
    }

    Write-Success "Database phase '$Phase' verified for '$DatabaseName'."
    Write-Info "Non-secret evidence: $evidencePath"
}
finally {
    if ($firewallCreated) {
        & az sql server firewall-rule delete `
            --resource-group $ResourceGroup `
            --server $sqlServerName `
            --name $firewallRuleName `
            --yes `
            --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Temporary firewall rule '$firewallRuleName' could not be removed automatically."
        }
    }

    if ($publicNetworkRestoreRequired) {
        & az sql server update `
            --resource-group $ResourceGroup `
            --name $sqlServerName `
            --enable-public-network false `
            --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn 'Azure SQL public network access could not be restored to Disabled automatically.'
        }

        $publicNetworkRestored = Wait-SqlPublicNetworkAccessState `
            -ResourceGroupName $ResourceGroup `
            -ServerName $sqlServerName `
            -ExpectedState 'Disabled' `
            -MaximumAttempts $publicNetworkPropagationMaximumAttempts `
            -PollIntervalSeconds $publicNetworkPropagationPollIntervalSeconds
        if (-not $publicNetworkRestored) {
            throw 'Azure SQL public network access was not verified as Disabled after the bounded cleanup wait.'
        }
    }
}
