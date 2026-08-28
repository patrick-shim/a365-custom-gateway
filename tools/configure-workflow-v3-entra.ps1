#Requires -Version 7.0

<#
.SYNOPSIS
    Configures the exact Microsoft Entra boundary required by workflow v3.

.DESCRIPTION
    Plans or applies three narrowly scoped changes:

    1. Adds the two documented delegated AgentRegistration scopes to the Gateway
       API application's requiredResourceAccess without removing existing entries.
    2. Creates or verifies one managed-identity federated credential on that app and
       grants only the two required scopes through the existing tenant-wide Graph
       oauth2PermissionGrant (preserving any already-consented scopes).
    3. Removes the two obsolete AgentRegistration application-role assignments from
       the workflow-v3 worker managed identity.

    The script never acquires, prints, or persists an access token or credential.
    It deliberately does not invoke blanket `az ad app permission admin-consent`.
    Without -Apply it is read-only and reports the exact pending change categories.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [guid]$ExpectedSubscriptionId,

    [Parameter(Mandatory = $true)]
    [guid]$ExpectedTenantId,

    [Parameter(Mandatory = $true)]
    [guid]$GatewayApiApplicationClientId,

    [Parameter(Mandatory = $true)]
    [guid]$GatewayApiManagedIdentityPrincipalId,

    [Parameter(Mandatory = $true)]
    [guid]$WorkerManagedIdentityPrincipalId,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$')]
    [string]$FederatedCredentialName = 'a365gw-api-obo-dev',

    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$GraphApplicationId = [guid]'00000003-0000-0000-c000-000000000000'
$TokenExchangeAudience = 'api://AzureADTokenExchange'
$RequiredDelegatedScopes = @(
    'AgentRegistration.Read.All',
    'AgentRegistration.ReadWrite.All'
)
$ObsoleteWorkerApplicationRoles = @(
    'AgentRegistration.Read.All',
    'AgentRegistration.ReadWrite.All'
)

function Write-Stage {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n[STAGE] $Message" -ForegroundColor Cyan
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Plan {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[PLAN] $Message" -ForegroundColor Yellow
}

function Invoke-AzJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    # The Windows Azure CLI entry point is a .cmd wrapper. PowerShell's legacy
    # native argument marshalling can let URL query separators (`&`) escape into
    # cmd.exe instead of preserving the URL as one argument. Invoke the bundled
    # CLI Python module directly on Windows so Graph query URLs remain intact.
    $azCommand = Get-Command az -ErrorAction Stop
    $azPython = if ($IsWindows -and $azCommand.Source.EndsWith(
            '.cmd',
            [System.StringComparison]::OrdinalIgnoreCase)) {
        Join-Path (Split-Path $azCommand.Source -Parent) '..\python.exe'
    }
    else {
        $null
    }

    $output = if ($null -ne $azPython -and (Test-Path -LiteralPath $azPython)) {
        & $azPython -IBm azure.cli @Arguments --only-show-errors 2>&1
    }
    else {
        & az @Arguments --only-show-errors 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI operation failed without rendering its response. Command category: $($Arguments[0..([math]::Min(2, $Arguments.Count - 1))] -join ' ')."
    }

    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text | ConvertFrom-Json -Depth 100
}

function Invoke-AzMutation {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $null = Invoke-AzJson -Arguments (@($Arguments) + @('--output', 'none'))
}

function Get-SingleGraphObject {
    param(
        [Parameter(Mandatory = $true)][string]$Resource,
        [Parameter(Mandatory = $true)][guid]$ApplicationId,
        [Parameter(Mandatory = $true)][string]$Select,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $url = "https://graph.microsoft.com/v1.0/${Resource}?`$filter=appId%20eq%20'$($ApplicationId.ToString('D'))'&`$select=$Select"
    $result = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', $url)
    $matches = @($result.value)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one $Label for the supplied application ID."
    }

    return $matches[0]
}

function Get-RequiredPermissionObjects {
    param(
        [Parameter(Mandatory = $true)][object]$GraphServicePrincipal,
        [Parameter(Mandatory = $true)][string[]]$Values,
        [Parameter(Mandatory = $true)][ValidateSet('Scope', 'Role')][string]$Type
    )

    $published = if ($Type -eq 'Scope') {
        @($GraphServicePrincipal.oauth2PermissionScopes | Where-Object { $_.isEnabled })
    }
    else {
        @($GraphServicePrincipal.appRoles | Where-Object {
            $_.isEnabled -and $_.allowedMemberTypes -contains 'Application'
        })
    }

    $resolved = foreach ($value in $Values) {
        $matches = @($published | Where-Object { $_.value -eq $value })
        if ($matches.Count -ne 1) {
            throw "Microsoft Graph does not publish exactly one enabled $Type named '$value' in this tenant."
        }

        [pscustomobject]@{
            id = [guid]$matches[0].id
            value = $value
            type = $Type
        }
    }

    return @($resolved)
}

Write-Stage 'Pinned Azure account'
$account = Invoke-AzJson -Arguments @(
    'account', 'show',
    '--query', '{subscription:id,tenant:tenantId}',
    '--output', 'json'
)
if ([guid]$account.subscription -ne $ExpectedSubscriptionId -or
    [guid]$account.tenant -ne $ExpectedTenantId) {
    throw 'The active Azure CLI account does not match the pinned subscription and tenant.'
}
Write-Pass 'Azure subscription and tenant match the pinned development scope.'

Write-Stage 'Resolve exact Gateway API and Microsoft Graph objects'
$gatewayApplication = Get-SingleGraphObject `
    -Resource 'applications' `
    -ApplicationId $GatewayApiApplicationClientId `
    -Select 'id,appId,requiredResourceAccess' `
    -Label 'Gateway API application'
$gatewayServicePrincipal = Get-SingleGraphObject `
    -Resource 'servicePrincipals' `
    -ApplicationId $GatewayApiApplicationClientId `
    -Select 'id,appId' `
    -Label 'Gateway API service principal'
$graphServicePrincipal = Get-SingleGraphObject `
    -Resource 'servicePrincipals' `
    -ApplicationId $GraphApplicationId `
    -Select 'id,appId,oauth2PermissionScopes,appRoles' `
    -Label 'Microsoft Graph service principal'
$requiredScopes = Get-RequiredPermissionObjects `
    -GraphServicePrincipal $graphServicePrincipal `
    -Values $RequiredDelegatedScopes `
    -Type Scope
$obsoleteRoles = Get-RequiredPermissionObjects `
    -GraphServicePrincipal $graphServicePrincipal `
    -Values $ObsoleteWorkerApplicationRoles `
    -Type Role
Write-Pass 'Resolved the two documented delegated scopes and two obsolete worker roles by tenant-published IDs.'

Write-Stage 'Gateway API requested delegated permissions'
$requiredResourceAccess = @(
    foreach ($entry in @($gatewayApplication.requiredResourceAccess)) {
        [pscustomobject]@{
            resourceAppId = [string]$entry.resourceAppId
            resourceAccess = @(
                foreach ($access in @($entry.resourceAccess)) {
                    [pscustomobject]@{
                        id = [string]$access.id
                        type = [string]$access.type
                    }
                }
            )
        }
    }
)
$graphEntries = @($requiredResourceAccess | Where-Object {
    [guid]$_.resourceAppId -eq $GraphApplicationId
})
if ($graphEntries.Count -gt 1) {
    throw 'The Gateway API application contains duplicate Microsoft Graph requiredResourceAccess entries.'
}
if ($graphEntries.Count -eq 0) {
    $graphEntry = [pscustomobject]@{
        resourceAppId = $GraphApplicationId.ToString('D')
        resourceAccess = @()
    }
    $requiredResourceAccess += $graphEntry
}
else {
    $graphEntry = $graphEntries[0]
}

$missingRequestedScopes = @(
    foreach ($scope in $requiredScopes) {
        $exists = @($graphEntry.resourceAccess | Where-Object {
            [guid]$_.id -eq $scope.id -and $_.type -eq 'Scope'
        }).Count -gt 0
        if (-not $exists) {
            $scope
        }
    }
)
if ($missingRequestedScopes.Count -gt 0) {
    Write-Plan "Add $($missingRequestedScopes.Count) delegated Registry scope(s) to requiredResourceAccess."
    if ($Apply) {
        $graphEntry.resourceAccess = @($graphEntry.resourceAccess) + @(
            $missingRequestedScopes | ForEach-Object {
                [pscustomobject]@{
                    id = $_.id.ToString('D')
                    type = 'Scope'
                }
            }
        )
        $body = @{
            requiredResourceAccess = $requiredResourceAccess
        } | ConvertTo-Json -Depth 10 -Compress
        Invoke-AzMutation -Arguments @(
            'rest', '--method', 'PATCH',
            '--url', "https://graph.microsoft.com/v1.0/applications/$($gatewayApplication.id)",
            '--headers', 'Content-Type=application/json',
            '--body', $body
        )
    }
}
else {
    Write-Pass 'Gateway API requiredResourceAccess already includes both delegated Registry scopes.'
}

Write-Stage 'Gateway API managed-identity federated credential'
$issuer = "https://login.microsoftonline.com/$($ExpectedTenantId.ToString('D'))/v2.0"
$ficUrl = "https://graph.microsoft.com/v1.0/applications/$($gatewayApplication.id)/federatedIdentityCredentials"
$fics = Invoke-AzJson -Arguments @(
    'rest', '--method', 'GET',
    '--url', "${ficUrl}?`$select=id,name,issuer,subject,audiences"
)
$namedFics = @($fics.value | Where-Object { $_.name -eq $FederatedCredentialName })
if ($namedFics.Count -gt 1) {
    throw "More than one federated credential is named '$FederatedCredentialName'."
}
if ($namedFics.Count -eq 1) {
    $fic = $namedFics[0]
    $audiences = @($fic.audiences)
    if ($fic.issuer -ne $issuer -or
        $fic.subject -ne $GatewayApiManagedIdentityPrincipalId.ToString('D') -or
        $audiences.Count -ne 1 -or
        $audiences[0] -ne $TokenExchangeAudience) {
        throw 'The named Gateway API federated credential exists with a conflicting issuer, subject, or audience.'
    }
    Write-Pass 'Gateway API federated credential matches the exact system-managed-identity OBO boundary.'
}
else {
    Write-Plan "Create federated credential '$FederatedCredentialName' for the API managed identity."
    if ($Apply) {
        $body = @{
            name = $FederatedCredentialName
            issuer = $issuer
            subject = $GatewayApiManagedIdentityPrincipalId.ToString('D')
            audiences = @($TokenExchangeAudience)
        } | ConvertTo-Json -Depth 5 -Compress
        Invoke-AzMutation -Arguments @(
            'rest', '--method', 'POST',
            '--url', $ficUrl,
            '--headers', 'Content-Type=application/json',
            '--body', $body
        )
    }
}

Write-Stage 'Exact tenant-wide delegated Microsoft Graph consent'
$grantFilter = "clientId%20eq%20'$($gatewayServicePrincipal.id)'%20and%20resourceId%20eq%20'$($graphServicePrincipal.id)'%20and%20consentType%20eq%20'AllPrincipals'"
$grants = Invoke-AzJson -Arguments @(
    'rest', '--method', 'GET',
    '--url', "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=$grantFilter&`$select=id,clientId,resourceId,consentType,scope"
)
$matchingGrants = @($grants.value)
if ($matchingGrants.Count -gt 1) {
    throw 'More than one tenant-wide Microsoft Graph delegated grant exists for the Gateway API.'
}
$existingConsentScopes = @()
if ($matchingGrants.Count -eq 1) {
    $existingConsentScopes = @(
        ([string]$matchingGrants[0].scope).Split(
            ' ',
            [System.StringSplitOptions]::RemoveEmptyEntries -bor
                [System.StringSplitOptions]::TrimEntries)
    )
}
$desiredConsentScopes = @(
    $existingConsentScopes + $RequiredDelegatedScopes |
        Sort-Object -Unique
)
$missingConsentScopes = @($RequiredDelegatedScopes | Where-Object {
    $existingConsentScopes -notcontains $_
})
if ($missingConsentScopes.Count -gt 0) {
    Write-Plan "Add $($missingConsentScopes.Count) delegated Registry scope(s) to the existing tenant-wide Graph grant only."
    if ($Apply) {
        $scopeValue = $desiredConsentScopes -join ' '
        if ($matchingGrants.Count -eq 0) {
            $body = @{
                clientId = [string]$gatewayServicePrincipal.id
                consentType = 'AllPrincipals'
                resourceId = [string]$graphServicePrincipal.id
                scope = $scopeValue
            } | ConvertTo-Json -Depth 5 -Compress
            Invoke-AzMutation -Arguments @(
                'rest', '--method', 'POST',
                '--url', 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants',
                '--headers', 'Content-Type=application/json',
                '--body', $body
            )
        }
        else {
            $body = @{ scope = $scopeValue } | ConvertTo-Json -Compress
            Invoke-AzMutation -Arguments @(
                'rest', '--method', 'PATCH',
                '--url', "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($matchingGrants[0].id)",
                '--headers', 'Content-Type=application/json',
                '--body', $body
            )
        }
    }
}
else {
    Write-Pass 'Tenant-wide Graph consent already includes both delegated Registry scopes.'
}

Write-Stage 'Remove obsolete worker app-only Registry permissions'
$assignments = Invoke-AzJson -Arguments @(
    'rest', '--method', 'GET',
    '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$($WorkerManagedIdentityPrincipalId.ToString('D'))/appRoleAssignments?`$select=id,resourceId,appRoleId"
)
$obsoleteRoleIds = @($obsoleteRoles | ForEach-Object { $_.id.ToString('D') })
$obsoleteAssignments = @($assignments.value | Where-Object {
    $_.resourceId -eq [string]$graphServicePrincipal.id -and
    $obsoleteRoleIds -contains [string]$_.appRoleId
})
if ($obsoleteAssignments.Count -gt 0) {
    Write-Plan "Remove $($obsoleteAssignments.Count) obsolete worker AgentRegistration application-role assignment(s)."
    if ($Apply) {
        foreach ($assignment in $obsoleteAssignments) {
            Invoke-AzMutation -Arguments @(
                'rest', '--method', 'DELETE',
                '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$($WorkerManagedIdentityPrincipalId.ToString('D'))/appRoleAssignments/$($assignment.id)"
            )
        }
    }
}
else {
    Write-Pass 'Worker has no obsolete AgentRegistration application-role assignment.'
}

if (-not $Apply -and
    ($missingRequestedScopes.Count -gt 0 -or
     $namedFics.Count -eq 0 -or
     $missingConsentScopes.Count -gt 0 -or
     $obsoleteAssignments.Count -gt 0)) {
    Write-Host ''
    Write-Plan 'Read-only plan complete. Re-run with -Apply only for the pinned development tenant.'
    exit 0
}

if ($Apply) {
    Write-Host ''
    Write-Pass 'Requested workflow-v3 Entra changes were applied. Run the read-only provisioning preflight for independent read-back verification.'
}
else {
    Write-Host ''
    Write-Pass 'Workflow-v3 Entra boundary is already configured; no mutation is required.'
}
