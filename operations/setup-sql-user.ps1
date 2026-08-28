#Requires -Version 7.0

<#
.SYNOPSIS
    Creates Azure SQL database users for Container App managed identities.

.DESCRIPTION
    Connects to an Azure SQL database using the caller's Entra ID access token and
    creates database users for the Gateway API and Provisioning Worker managed
    identities. Each identity is granted db_datareader and db_datawriter roles.

    The script uses CREATE USER ... FROM EXTERNAL PROVIDER to create Entra ID-backed
    database principals for system-assigned managed identities.

    Prerequisites:
    - Caller must be authenticated with Azure CLI (az login).
    - Caller must be an Entra ID admin on the target SQL Server (configured via
      the sql-database.bicep module's entraAdminLogin/entraAdminObjectId parameters).
    - The target Container Apps must already exist so their system-assigned managed
      identities are registered in Entra ID.

.PARAMETER SqlServerFqdn
    Fully qualified domain name of the Azure SQL Server
    (e.g., sql-a365gw-dev.database.windows.net).

.PARAMETER DatabaseName
    Name of the database to create users in. Default: GatewayDb.

.PARAMETER ApiManagedIdentityName
    Name of the API Container App whose system-assigned managed identity will be
    granted database access (e.g., ca-gateway-api-dev).

.PARAMETER WorkerManagedIdentityName
    Name of the Worker Container App whose system-assigned managed identity will be
    granted database access (e.g., ca-gateway-worker-dev).

.EXAMPLE
    ./setup-sql-user.ps1 -SqlServerFqdn sql-a365gw-dev.database.windows.net -ApiManagedIdentityName ca-gateway-api-dev -WorkerManagedIdentityName ca-gateway-worker-dev

.EXAMPLE
    ./setup-sql-user.ps1 -SqlServerFqdn sql-a365gw-prod.database.windows.net -DatabaseName GatewayDb -ApiManagedIdentityName ca-gateway-api-prod -WorkerManagedIdentityName ca-gateway-worker-prod
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SqlServerFqdn,

    [Parameter(Mandatory = $false)]
    [string]$DatabaseName = 'GatewayDb',

    [Parameter(Mandatory = $true)]
    [string]$ApiManagedIdentityName,

    [Parameter(Mandatory = $true)]
    [string]$WorkerManagedIdentityName
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Helper Functions
# ============================================================================

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Failure {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor White
}

# ============================================================================
# Step 1: Acquire Access Token
# ============================================================================

function Get-SqlAccessToken {
    Write-Info 'Acquiring access token for Azure SQL (https://database.windows.net/)...'

    $token = $null
    try {
        $token = (& az account get-access-token --resource 'https://database.windows.net/' --query accessToken --output tsv 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "az CLI returned exit code $LASTEXITCODE. Output: $token"
        }
    }
    catch {
        Write-Failure "Failed to acquire SQL access token: $($_.Exception.Message)"
        Write-Failure 'Ensure you are logged in with an account that is the Entra ID admin on the SQL Server.'
        throw
    }

    $tokenStr = ($token | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($tokenStr)) {
        throw 'Acquired SQL access token is empty.'
    }

    Write-Success 'Access token acquired.'
    return $tokenStr
}

# ============================================================================
# Step 2: Execute SQL Command
# ============================================================================

function Invoke-SqlCommand {
    param(
        [string]$ConnectionString,
        [string]$AccessToken,
        [string]$CommandText,
        [string]$Description,
        [switch]$ReturnResults
    )

    $connection = $null
    $command = $null
    try {
        $connection = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
        $connection.AccessToken = $AccessToken
        $connection.Open()

        $command = $connection.CreateCommand()
        $command.CommandText = $CommandText
        $command.CommandTimeout = 30

        if ($ReturnResults) {
            $adapter = [System.Data.SqlClient.SqlDataAdapter]::new($command)
            $dataTable = [System.Data.DataTable]::new()
            [void]$adapter.Fill($dataTable)
            return $dataTable
        }
        else {
            [void]$command.ExecuteNonQuery()
        }
    }
    catch {
        Write-Failure "SQL command failed ($Description): $($_.Exception.Message)"
        throw
    }
    finally {
        if ($command) { $command.Dispose() }
        if ($connection -and $connection.State -eq 'Open') { $connection.Close() }
        if ($connection) { $connection.Dispose() }
    }
}

# ============================================================================
# Step 3: Create Database User for a Managed Identity
# ============================================================================

function New-ManagedIdentityDbUser {
    param(
        [string]$ConnectionString,
        [string]$AccessToken,
        [string]$IdentityName
    )

    Write-Info "Processing managed identity: $IdentityName"

    # Create the user if it does not already exist.
    # Note: sys.database_principals check and CREATE USER must use dynamic SQL
    # because CREATE USER does not support parameterized identity names.
    $createUserSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$IdentityName')
BEGIN
    EXEC('CREATE USER [$IdentityName] FROM EXTERNAL PROVIDER');
    PRINT 'Created user [$IdentityName].';
END
ELSE
BEGIN
    PRINT 'User [$IdentityName] already exists.';
END
"@

    Write-Info "  Ensuring database user [$IdentityName] exists..."
    Invoke-SqlCommand `
        -ConnectionString $ConnectionString `
        -AccessToken $AccessToken `
        -CommandText $createUserSql `
        -Description "Create user [$IdentityName]"

    # Grant db_datareader role
    $addReaderSql = @"
IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members rm
    INNER JOIN sys.database_principals rp ON rm.role_principal_id = rp.principal_id
    INNER JOIN sys.database_principals mp ON rm.member_principal_id = mp.principal_id
    WHERE rp.name = 'db_datareader' AND mp.name = N'$IdentityName'
)
BEGIN
    ALTER ROLE db_datareader ADD MEMBER [$IdentityName];
    PRINT 'Added [$IdentityName] to db_datareader.';
END
ELSE
BEGIN
    PRINT '[$IdentityName] is already a member of db_datareader.';
END
"@

    Write-Info "  Granting db_datareader to [$IdentityName]..."
    Invoke-SqlCommand `
        -ConnectionString $ConnectionString `
        -AccessToken $AccessToken `
        -CommandText $addReaderSql `
        -Description "Grant db_datareader to [$IdentityName]"

    # Grant db_datawriter role
    $addWriterSql = @"
IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members rm
    INNER JOIN sys.database_principals rp ON rm.role_principal_id = rp.principal_id
    INNER JOIN sys.database_principals mp ON rm.member_principal_id = mp.principal_id
    WHERE rp.name = 'db_datawriter' AND mp.name = N'$IdentityName'
)
BEGIN
    ALTER ROLE db_datawriter ADD MEMBER [$IdentityName];
    PRINT 'Added [$IdentityName] to db_datawriter.';
END
ELSE
BEGIN
    PRINT '[$IdentityName] is already a member of db_datawriter.';
END
"@

    Write-Info "  Granting db_datawriter to [$IdentityName]..."
    Invoke-SqlCommand `
        -ConnectionString $ConnectionString `
        -AccessToken $AccessToken `
        -CommandText $addWriterSql `
        -Description "Grant db_datawriter to [$IdentityName]"

    Write-Success "Managed identity [$IdentityName] configured."
}

# ============================================================================
# Step 4: Verify Users
# ============================================================================

function Confirm-ManagedIdentityUsers {
    param(
        [string]$ConnectionString,
        [string]$AccessToken,
        [string[]]$IdentityNames
    )

    Write-Info 'Verifying database users...'

    # Build a comma-separated list of quoted names for the IN clause
    $nameList = ($IdentityNames | ForEach-Object { "N'$_'" }) -join ', '

    $verifySql = @"
SELECT name, type_desc, create_date
FROM sys.database_principals
WHERE name IN ($nameList)
ORDER BY name;
"@

    $results = Invoke-SqlCommand `
        -ConnectionString $ConnectionString `
        -AccessToken $AccessToken `
        -CommandText $verifySql `
        -Description 'Verify database users' `
        -ReturnResults

    if ($null -eq $results -or $results.Rows.Count -eq 0) {
        Write-Failure 'No managed identity users found in the database.'
        throw 'User verification failed: no matching database principals.'
    }

    $foundNames = @()
    foreach ($row in $results.Rows) {
        $foundNames += $row['name']
        Write-Success "  Verified: $($row['name']) | Type: $($row['type_desc']) | Created: $($row['create_date'])"
    }

    # Check for any missing identities
    foreach ($expected in $IdentityNames) {
        if ($expected -notin $foundNames) {
            Write-Failure "  Missing: $expected was not found in sys.database_principals."
            throw "User verification failed: '$expected' not found."
        }
    }

    Write-Success 'All managed identity users verified successfully.'
}

# ============================================================================
# Main Execution
# ============================================================================

try {
    Write-Host ''
    Write-Host '  A365 Custom Gateway - SQL Managed Identity User Setup' -ForegroundColor Cyan
    Write-Host "  Server:   $SqlServerFqdn" -ForegroundColor Cyan
    Write-Host "  Database: $DatabaseName" -ForegroundColor Cyan
    Write-Host "  API:      $ApiManagedIdentityName" -ForegroundColor Cyan
    Write-Host "  Worker:   $WorkerManagedIdentityName" -ForegroundColor Cyan
    Write-Host ''

    # Acquire access token
    $accessToken = Get-SqlAccessToken

    # Build connection string (token-based auth, no user/password)
    $connectionString = "Server=tcp:$SqlServerFqdn,1433;Database=$DatabaseName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

    # Create users for each managed identity
    $identityNames = @($ApiManagedIdentityName, $WorkerManagedIdentityName)

    foreach ($identity in $identityNames) {
        New-ManagedIdentityDbUser `
            -ConnectionString $connectionString `
            -AccessToken $accessToken `
            -IdentityName $identity
    }

    # Verify both users
    Confirm-ManagedIdentityUsers `
        -ConnectionString $connectionString `
        -AccessToken $accessToken `
        -IdentityNames $identityNames

    Write-Host ''
    Write-Success 'SQL managed identity user setup complete.'
    exit 0
}
catch {
    Write-Failure "SQL user setup failed: $($_.Exception.Message)"
    Write-Failure "Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
