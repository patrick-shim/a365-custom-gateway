#Requires -Version 7.0

<#
.SYNOPSIS
    Applies Entity Framework Core migrations to the A365 Gateway database.

.DESCRIPTION
    Installs EF Core tooling if needed, creates an initial migration when none
    exist, adds a temporary Azure SQL firewall rule for the caller's public IP,
    applies the migration, then cleans up.

    Authentication uses Active Directory Default, which picks up the caller's
    current az login session (or managed identity in hosted environments).

.PARAMETER SqlServerFqdn
    Fully qualified domain name of the Azure SQL logical server.
    Example: sql-a365gw-dev.database.windows.net

.PARAMETER DatabaseName
    Name of the target database. Defaults to GatewayDb.

.PARAMETER ResourceGroup
    Azure resource group that contains the SQL server. Defaults to rg-agent-gateway.

.EXAMPLE
    ./apply-migrations.ps1 -SqlServerFqdn sql-a365gw-dev.database.windows.net

.EXAMPLE
    ./apply-migrations.ps1 -SqlServerFqdn sql-a365gw-dev.database.windows.net -DatabaseName GatewayDb-Staging -ResourceGroup rg-agent-gateway-staging
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SqlServerFqdn,

    [string]$DatabaseName = 'GatewayDb',

    [string]$ResourceGroup = 'rg-agent-gateway'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_common.ps1')

$removeDesignPkg = $false
$SqlServerName = ($SqlServerFqdn -split '\.')[0]

try {
    # ------------------------------------------------------------------ #
    # 1. Prerequisites
    # ------------------------------------------------------------------ #
    Write-StepHeader 'Checking prerequisites'

    Assert-Command 'dotnet' 'https://dot.net'
    Write-Success 'dotnet CLI is available.'

    Assert-Command 'az' 'https://aka.ms/installazurecli'
    Assert-AzLogin

    # ------------------------------------------------------------------ #
    # 2. EF Core tooling
    # ------------------------------------------------------------------ #
    Write-StepHeader 'Ensuring dotnet-ef tool is installed'

    $efCheck = & dotnet ef --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Info 'dotnet-ef not found. Installing globally...'
        & dotnet tool install --global dotnet-ef
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to install dotnet-ef global tool.'
        }
        Write-Success 'dotnet-ef installed.'
    }
    else {
        Write-Success "dotnet-ef is installed (version: $($efCheck | Out-String)".Trim() + ').'
    }

    # ------------------------------------------------------------------ #
    # 3. Project paths
    # ------------------------------------------------------------------ #
    $InfraProject  = Join-Path $RepoRoot 'src' 'Gateway.Infrastructure'
    $StartupProject = Join-Path $RepoRoot 'src' 'Gateway.Api'
    $ApiCsproj     = Join-Path $StartupProject 'Gateway.Api.csproj'
    $MigrationsDir = Join-Path $InfraProject 'Migrations'

    Write-Info "Infrastructure project: $InfraProject"
    Write-Info "Startup project:        $StartupProject"

    # ------------------------------------------------------------------ #
    # 4. Ensure Microsoft.EntityFrameworkCore.Design is referenced
    # ------------------------------------------------------------------ #
    Write-StepHeader 'Checking for EntityFrameworkCore.Design package'

    $hasDesignPkg = Select-String -Path $ApiCsproj -Pattern 'EntityFrameworkCore.Design' -Quiet
    if (-not $hasDesignPkg) {
        Write-Info 'Adding Microsoft.EntityFrameworkCore.Design package...'
        & dotnet add $ApiCsproj package Microsoft.EntityFrameworkCore.Design --version 10.0.0
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to add Microsoft.EntityFrameworkCore.Design package.'
        }
        $removeDesignPkg = $true
        Write-Success 'Design package added (will be removed after migration).'
    }
    else {
        Write-Success 'EntityFrameworkCore.Design is already referenced.'
    }

    # ------------------------------------------------------------------ #
    # 5. Create initial migration if none exist
    # ------------------------------------------------------------------ #
    Write-StepHeader 'Checking for existing migrations'

    $hasMigrations = (Test-Path $MigrationsDir) -and
                     ((Get-ChildItem -Path $MigrationsDir -Filter '*.cs' -ErrorAction SilentlyContinue).Count -gt 0)

    if (-not $hasMigrations) {
        Write-Info 'No migrations found. Creating InitialCreate migration...'
        & dotnet ef migrations add InitialCreate `
            --project $InfraProject `
            --startup-project $StartupProject `
            --output-dir Migrations
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to create InitialCreate migration.'
        }
        Write-Success 'InitialCreate migration created.'
    }
    else {
        $count = (Get-ChildItem -Path $MigrationsDir -Filter '*.cs').Count
        Write-Success "Found $count migration file(s) in $MigrationsDir."
    }

    # ------------------------------------------------------------------ #
    # 6. Temporary firewall rule
    # ------------------------------------------------------------------ #
    Write-StepHeader 'Adding temporary SQL firewall rule'

    $MyIp = Get-MyPublicIp
    Write-Info "Public IP: $MyIp"

    Invoke-AzCommand -Arguments @(
        'sql', 'server', 'firewall-rule', 'create',
        '--resource-group', $ResourceGroup,
        '--server', $SqlServerName,
        '--name', 'temp-bootstrap',
        '--start-ip-address', $MyIp,
        '--end-ip-address', $MyIp
    ) -ErrorMessage 'Failed to create temporary firewall rule.'

    Write-Success "Firewall rule 'temp-bootstrap' created for $MyIp."

    # ------------------------------------------------------------------ #
    # 7. Apply migrations
    # ------------------------------------------------------------------ #
    Write-StepHeader 'Applying EF Core migrations'

    $ConnStr = "Server=tcp:$SqlServerFqdn,1433;Database=$DatabaseName;Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

    Write-Info "Target: $SqlServerFqdn / $DatabaseName"

    & dotnet ef database update `
        --project $InfraProject `
        --startup-project $StartupProject `
        --connection $ConnStr
    if ($LASTEXITCODE -ne 0) {
        throw 'EF Core database update failed.'
    }

    Write-Success 'Migrations applied successfully.'
    exit 0
}
catch {
    Write-Failure $_.Exception.Message
    exit 1
}
finally {
    # ------------------------------------------------------------------ #
    # Cleanup
    # ------------------------------------------------------------------ #
    Write-StepHeader 'Cleanup'

    # Remove temporary firewall rule
    try {
        Write-Info "Removing firewall rule 'temp-bootstrap'..."
        Invoke-AzCommand -Arguments @(
            'sql', 'server', 'firewall-rule', 'delete',
            '--resource-group', $ResourceGroup,
            '--server', $SqlServerName,
            '--name', 'temp-bootstrap',
            '--yes'
        ) -ErrorMessage 'Failed to remove temporary firewall rule.'
        Write-Success 'Firewall rule removed.'
    }
    catch {
        Write-Warn "Could not remove firewall rule 'temp-bootstrap': $($_.Exception.Message)"
    }

    # Remove Design package if we added it
    if ($removeDesignPkg) {
        try {
            Write-Info 'Removing Microsoft.EntityFrameworkCore.Design package...'
            & dotnet remove $ApiCsproj package Microsoft.EntityFrameworkCore.Design
            if ($LASTEXITCODE -ne 0) {
                Write-Warn 'dotnet remove for Design package returned non-zero exit code.'
            }
            else {
                Write-Success 'Design package removed.'
            }
        }
        catch {
            Write-Warn "Could not remove Design package: $($_.Exception.Message)"
        }
    }
}
