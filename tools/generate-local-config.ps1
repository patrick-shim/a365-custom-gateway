#Requires -Version 7.0

<#
.SYNOPSIS
    Generates appsettings.Local.json files for local development by querying deployed Azure resources.

.DESCRIPTION
    Queries the target Azure resource group for SQL Server, Service Bus, Blob Storage,
    Application Insights, Key Vault, and Entra ID configuration, then writes
    appsettings.Local.json files for both the Gateway API and the Provisioning Worker.

    Optionally adds a temporary SQL firewall rule for the developer's public IP.

    The generated files are already listed in .gitignore and must not be committed.

.PARAMETER Environment
    The target environment (dev, staging, or prod). Used to resolve the Entra app
    registration and audience URI.

.PARAMETER ResourceGroup
    The Azure resource group containing the deployed gateway infrastructure.
    Defaults to 'rg-agent-gateway'.

.PARAMETER ReviewedPublicIpv4
    Exact canonical public IPv4 address reviewed by the developer for the optional
    local SQL firewall rule. The script never authorizes an IP returned by an
    unauthenticated discovery service.

.EXAMPLE
    .\generate-local-config.ps1 -Environment dev -ReviewedPublicIpv4 192.0.2.10

.EXAMPLE
    .\generate-local-config.ps1 -Environment staging -ResourceGroup rg-agent-gateway-staging -ReviewedPublicIpv4 192.0.2.10

.NOTES
    Requires: Azure CLI (az), an active az login session, and PowerShell 7+.
    Dot-sources _common.ps1 for shared helper functions.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [Parameter()]
    [string]$ResourceGroup = 'rg-agent-gateway',

    [Parameter(Mandatory)]
    [string]$ReviewedPublicIpv4
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_common.ps1')

$parsedReviewedPublicIpv4 = $null
if (-not [Net.IPAddress]::TryParse($ReviewedPublicIpv4, [ref]$parsedReviewedPublicIpv4) -or
    $parsedReviewedPublicIpv4.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    $parsedReviewedPublicIpv4.ToString() -cne $ReviewedPublicIpv4) {
    throw 'ReviewedPublicIpv4 must be one canonical IPv4 address explicitly reviewed before this script starts.'
}

try {
    # ── Step 1: Verify Azure login ──────────────────────────────────────
    Write-StepHeader 'Verifying Azure CLI login'
    Assert-AzLogin

    # ── Step 2: Query deployed Azure resources ──────────────────────────
    Write-StepHeader "Querying deployed resources in '$ResourceGroup'"

    Write-Info 'Fetching SQL Server FQDN...'
    $sqlFqdn = (Invoke-AzCommand -Arguments @(
            'sql', 'server', 'list',
            '--resource-group', $ResourceGroup,
            '--query', '[0].fullyQualifiedDomainName',
            '-o', 'tsv'
        ) -ErrorMessage 'Failed to query SQL Server.' | Out-String).Trim()
    Write-Success "SQL Server: $sqlFqdn"

    Write-Info 'Fetching Service Bus namespace...'
    $sbName = (Invoke-AzCommand -Arguments @(
            'servicebus', 'namespace', 'list',
            '--resource-group', $ResourceGroup,
            '--query', '[0].name',
            '-o', 'tsv'
        ) -ErrorMessage 'Failed to query Service Bus namespace.' | Out-String).Trim()
    $sbFqdn = "$sbName.servicebus.windows.net"
    Write-Success "Service Bus: $sbFqdn"

    Write-Info 'Fetching Blob Storage endpoint...'
    $blobEndpoint = (Invoke-AzCommand -Arguments @(
            'storage', 'account', 'list',
            '--resource-group', $ResourceGroup,
            '--query', '[0].primaryEndpoints.blob',
            '-o', 'tsv'
        ) -ErrorMessage 'Failed to query Storage Account.' | Out-String).Trim()
    Write-Success "Blob Storage: $blobEndpoint"

    Write-Info 'Fetching Application Insights connection string...'
    $appInsightsCs = (Invoke-AzCommand -Arguments @(
            'monitor', 'app-insights', 'component', 'show',
            '--resource-group', $ResourceGroup,
            '--query', '[0].connectionString',
            '-o', 'tsv'
        ) -ErrorMessage 'Failed to query Application Insights.' | Out-String).Trim()
    Write-Success 'Application Insights connection string retrieved.'

    Write-Info 'Fetching Key Vault URI...'
    $keyVaultUri = (Invoke-AzCommand -Arguments @(
            'keyvault', 'list',
            '--resource-group', $ResourceGroup,
            '--query', '[0].properties.vaultUri',
            '-o', 'tsv'
        ) -ErrorMessage 'Failed to query Key Vault.' | Out-String).Trim()
    Write-Success "Key Vault: $keyVaultUri"

    Write-Info 'Fetching Tenant ID...'
    $tenantId = (Invoke-AzCommand -Arguments @(
            'account', 'show',
            '--query', 'tenantId',
            '-o', 'tsv'
        ) -ErrorMessage 'Failed to query tenant ID.' | Out-String).Trim()
    Write-Success "Tenant ID: $tenantId"

    # ── Step 3: Resolve Entra app client ID ─────────────────────────────
    Write-StepHeader 'Resolving Entra ID app registration'

    if ($env:ENTRA_CLIENT_ID) {
        $clientId = $env:ENTRA_CLIENT_ID
        Write-Info "Using client ID from ENTRA_CLIENT_ID environment variable."
    }
    else {
        $appDisplayName = "A365 Gateway - $Environment"
        Write-Info "Looking up Entra app registration '$appDisplayName'..."
        $clientId = (Invoke-AzCommand -Arguments @(
                'ad', 'app', 'list',
                '--display-name', $appDisplayName,
                '--query', '[0].appId',
                '-o', 'tsv'
            ) -ErrorMessage "Failed to find Entra app '$appDisplayName'." | Out-String).Trim()
    }
    Write-Success "Client ID: $clientId"

    # ── Step 4: Derive audience URI ─────────────────────────────────────
    $Audience = "api://a365-gateway-$Environment"
    Write-Info "Audience: $Audience"

    # ── Step 5: Build API configuration ─────────────────────────────────
    Write-StepHeader 'Generating appsettings.Local.json for Gateway.Api'

    $apiConfig = [ordered]@{
        ConnectionStrings = [ordered]@{
            GatewayDb = "Server=tcp:${sqlFqdn},1433;Database=GatewayDb;Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;"
        }
        EntraId            = [ordered]@{
            Instance = 'https://login.microsoftonline.com/'
            TenantId = $tenantId
            ClientId = $clientId
            Audience = $Audience
        }
        ServiceBus         = [ordered]@{
            ConnectionString = $sbFqdn
            QueueName        = 'gateway-provisioning'
        }
        BlobStorage        = [ordered]@{
            ServiceUri    = $blobEndpoint
            ContainerName = 'a365-gateway-interactions'
        }
        Observability      = [ordered]@{
            ApplicationInsightsConnectionString = $appInsightsCs
        }
        Agent365           = [ordered]@{
            TenantId = $tenantId
        }
        Purview            = [ordered]@{
            Enabled = $false
        }
        KeyVault           = [ordered]@{
            VaultUri = $keyVaultUri
        }
    }

    # ── Step 6: Write API config ────────────────────────────────────────
    $apiConfigPath = Join-Path $RepoRoot 'src' 'Gateway.Api' 'appsettings.Local.json'
    $apiConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $apiConfigPath -Encoding utf8NoBOM
    Write-Success "Written: $apiConfigPath"

    # ── Step 7: Build and write Worker configuration ────────────────────
    Write-StepHeader 'Generating appsettings.Local.json for Gateway.Provisioning.Worker'

    $workerConfig = [ordered]@{
        ConnectionStrings = [ordered]@{
            GatewayDb = "Server=tcp:${sqlFqdn},1433;Database=GatewayDb;Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;"
        }
        ServiceBus        = [ordered]@{
            ConnectionString = $sbFqdn
            QueueName        = 'gateway-provisioning'
        }
        BlobStorage       = [ordered]@{
            ServiceUri    = $blobEndpoint
            ContainerName = 'a365-gateway-interactions'
        }
        Observability     = [ordered]@{
            ApplicationInsightsConnectionString = $appInsightsCs
        }
        Agent365          = [ordered]@{
            TenantId = $tenantId
        }
        Purview           = [ordered]@{
            Enabled = $false
        }
        KeyVault          = [ordered]@{
            VaultUri = $keyVaultUri
        }
    }

    $workerConfigPath = Join-Path $RepoRoot 'src' 'Gateway.Provisioning.Worker' 'appsettings.Local.json'
    $workerConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $workerConfigPath -Encoding utf8NoBOM
    Write-Success "Written: $workerConfigPath"

    # ── Step 8: Add temporary SQL firewall rule ─────────────────────────
    Write-StepHeader 'Adding SQL firewall rule for local development'

    $publicIp = $ReviewedPublicIpv4
    Write-Info "Using the explicitly reviewed public IPv4 address: $publicIp"

    $ruleName = "local-dev-$(Get-CurrentUserUpn)-$(Get-Date -Format 'yyyyMMdd')"
    # Sanitize the rule name: firewall rule names allow alphanumerics, hyphens, and underscores
    $ruleName = $ruleName -replace '[^a-zA-Z0-9\-_]', '-'

    $sqlServerName = $sqlFqdn -replace '\.database\.windows\.net$', ''

    Write-Info "Creating firewall rule '$ruleName' on SQL Server '$sqlServerName'..."
    Invoke-AzCommand -Arguments @(
        'sql', 'server', 'firewall-rule', 'create',
        '--resource-group', $ResourceGroup,
        '--server', $sqlServerName,
        '--name', $ruleName,
        '--start-ip-address', $publicIp,
        '--end-ip-address', $publicIp
    ) -ErrorMessage 'Failed to create SQL firewall rule.' | Out-Null
    Write-Success "Firewall rule created for IP $publicIp."

    # ── Step 9: Print run instructions ──────────────────────────────────
    Write-StepHeader 'Local development ready'

    Write-Info 'Start the services with:'
    Write-Host ''
    Write-Host '  dotnet run --project src/Gateway.Api' -ForegroundColor Yellow
    Write-Host '  dotnet run --project src/Gateway.Provisioning.Worker' -ForegroundColor Yellow
    Write-Host '  Admin UI: dotnet run --project src/Gateway.AdminUi (no config needed -- standalone Blazor app)' -ForegroundColor Yellow
    Write-Host ''
    Write-Info "Environment: $Environment | Resource Group: $ResourceGroup"
    Write-Info "SQL firewall rule '$ruleName' allows your current IP ($publicIp)."
    Write-Warn 'Remember to remove the firewall rule when no longer needed.'
    Write-Host ''

    exit 0
}
catch {
    Write-Failure "Local config generation failed: $_"
    exit 1
}
