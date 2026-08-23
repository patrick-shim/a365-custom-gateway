#Requires -Version 7.0

<#
.SYNOPSIS
    Creates an Entra ID app registration for the A365 Custom Gateway.

.DESCRIPTION
    Registers an Azure AD (Entra ID) application with the required OAuth2
    permission scopes and app roles for the A365 Gateway. If the application
    already exists (matched by display name), the script outputs the existing
    app details and skips creation.

    The app registration includes:
    - Two OAuth2 permission scopes (access_as_user, agent_access)
    - Five app roles matching the gateway role model
    - A service principal for the application
    - Gateway.Administrator role assignment for the current user

.PARAMETER Environment
    Target deployment environment. Determines the identifier URI and default
    display name. Must be one of: dev, staging, prod.

.PARAMETER DisplayName
    Display name for the Entra ID app registration. Defaults to
    "A365 Gateway - <Environment>".

.EXAMPLE
    .\setup-entra.ps1 -Environment dev

    Creates a dev app registration named "A365 Gateway - dev" with
    identifier URI "api://a365-gateway-dev".

.EXAMPLE
    .\setup-entra.ps1 -Environment prod -DisplayName "A365 Gateway Production"

    Creates a prod app registration with a custom display name.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [Parameter()]
    [string]$DisplayName = "A365 Gateway - $Environment"
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_common.ps1')

try {
    # ── Step 1: Verify Azure CLI login ──────────────────────────────────
    Write-StepHeader 'Verifying Azure CLI login'
    Assert-AzLogin

    # ── Step 2: Build identifier URI ────────────────────────────────────
    $IdentifierUri = "api://a365-gateway-$Environment"
    Write-Info "Identifier URI: $IdentifierUri"
    Write-Info "Display name:   $DisplayName"

    # ── Step 3: Check if app already exists ─────────────────────────────
    Write-StepHeader 'Checking for existing app registration'

    $existingAppId = (Invoke-AzCommand -Arguments @(
        'ad', 'app', 'list',
        '--display-name', $DisplayName,
        '--query', '[0].appId', '-o', 'tsv'
    ) -ErrorMessage 'Failed to query existing app registrations.' | Out-String).Trim()

    if ($existingAppId) {
        Write-Warn "App registration '$DisplayName' already exists."
        Write-Info "Client ID: $existingAppId"
        Write-Info "Audience:  $IdentifierUri"
        Write-Success 'Skipping creation — returning existing app details.'

        return @{
            ClientId = $existingAppId
            Audience = $IdentifierUri
        }
    }

    Write-Info 'No existing app found. Proceeding with creation.'

    # ── Step 4: Create app registration via Microsoft Graph ─────────────
    Write-StepHeader 'Creating Entra ID app registration'

    $body = @{
        displayName    = $DisplayName
        signInAudience = 'AzureADMyOrg'
        identifierUris = @($IdentifierUri)
        api            = @{
            oauth2PermissionScopes = @(
                @{
                    id                      = [guid]::NewGuid().ToString()
                    adminConsentDisplayName = 'Access as user'
                    adminConsentDescription = 'Allows the app to access the A365 Gateway on behalf of the signed-in user.'
                    userConsentDisplayName  = 'Access as user'
                    userConsentDescription  = 'Allows you to access the A365 Gateway.'
                    value                   = 'access_as_user'
                    type                    = 'User'
                    isEnabled               = $true
                }
                @{
                    id                      = [guid]::NewGuid().ToString()
                    adminConsentDisplayName = 'Agent access'
                    adminConsentDescription = 'Allows an external agent to call the A365 Gateway data-plane APIs.'
                    userConsentDisplayName  = 'Agent access'
                    userConsentDescription  = 'Allows agent access to the A365 Gateway.'
                    value                   = 'agent_access'
                    type                    = 'Admin'
                    isEnabled               = $true
                }
            )
        }
        appRoles       = @(
            @{
                id                 = [guid]::NewGuid().ToString()
                displayName        = 'Gateway Administrator'
                description        = 'Full control-plane access.'
                value              = 'Gateway.Administrator'
                allowedMemberTypes = @('User', 'Application')
                isEnabled          = $true
            }
            @{
                id                 = [guid]::NewGuid().ToString()
                displayName        = 'Gateway Operator'
                description        = 'Enable/disable agents, retry operations.'
                value              = 'Gateway.Operator'
                allowedMemberTypes = @('User')
                isEnabled          = $true
            }
            @{
                id                 = [guid]::NewGuid().ToString()
                displayName        = 'Gateway Auditor'
                description        = 'Read-only audit and config history.'
                value              = 'Gateway.Auditor'
                allowedMemberTypes = @('User')
                isEnabled          = $true
            }
            @{
                id                 = [guid]::NewGuid().ToString()
                displayName        = 'Gateway Support Reader'
                description        = 'Health/diagnostics with redaction.'
                value              = 'Gateway.SupportReader'
                allowedMemberTypes = @('User')
                isEnabled          = $true
            }
            @{
                id                 = [guid]::NewGuid().ToString()
                displayName        = 'External Agent'
                description        = 'Data-plane only, bound to single agent.'
                value              = 'ExternalAgent'
                allowedMemberTypes = @('Application')
                isEnabled          = $true
            }
        )
    } | ConvertTo-Json -Depth 10 -Compress

    try {
        $response = Invoke-AzCommand -Arguments @(
            'rest', '--method', 'POST',
            '--uri', 'https://graph.microsoft.com/v1.0/applications',
            '--headers', 'Content-Type=application/json',
            '--body', $body
        ) -ErrorMessage 'Failed to create app registration.'
    }
    catch {
        if ($_.Exception.Message -match '403' -or $_.Exception.Message -match 'Forbidden') {
            Write-Failure 'Permission denied when creating the app registration.'
            Write-Info 'Your account needs the Application Administrator directory role'
            Write-Info 'or the Application.ReadWrite.All Microsoft Graph permission.'
        }
        throw
    }

    $app = ($response | Out-String) | ConvertFrom-Json
    $AppId = $app.appId
    $AppObjectId = $app.id
    Write-Success "App registration created: $AppId (object ID: $AppObjectId)"

    # ── Step 5: Create service principal ────────────────────────────────
    Write-StepHeader 'Creating service principal'

    $spOutput = Invoke-AzCommand -Arguments @(
        'ad', 'sp', 'create', '--id', $AppId
    ) -ErrorMessage 'Failed to create service principal.'

    $sp = ($spOutput | Out-String) | ConvertFrom-Json
    $SpId = $sp.id
    Write-Success "Service principal created: $SpId"

    # ── Step 6: Assign Gateway.Administrator role to current user ───────
    Write-StepHeader 'Assigning Gateway.Administrator role to current user'

    $currentUserId = Get-CurrentUserObjectId
    Write-Info "Current user object ID: $currentUserId"

    $adminRole = $app.appRoles | Where-Object { $_.value -eq 'Gateway.Administrator' }
    $assignmentBody = @{
        principalId = $currentUserId
        resourceId  = $SpId
        appRoleId   = $adminRole.id
    } | ConvertTo-Json -Compress

    try {
        Invoke-AzCommand -Arguments @(
            'rest', '--method', 'POST',
            '--uri', "https://graph.microsoft.com/v1.0/servicePrincipals/$SpId/appRoleAssignedTo",
            '--headers', 'Content-Type=application/json',
            '--body', $assignmentBody
        ) -ErrorMessage 'Failed to assign Gateway.Administrator role.'
    }
    catch {
        if ($_.Exception.Message -match '403' -or $_.Exception.Message -match 'Forbidden') {
            Write-Failure 'Permission denied when assigning the app role.'
            Write-Info 'Your account needs the Application Administrator directory role'
            Write-Info 'or the Application.ReadWrite.All Microsoft Graph permission.'
        }
        throw
    }

    Write-Success 'Gateway.Administrator role assigned to current user.'

    # ── Step 7: Output results ──────────────────────────────────────────
    Write-StepHeader 'Setup complete'
    Write-Info "Client ID: $AppId"
    Write-Info "Audience:  $IdentifierUri"

    return @{
        ClientId = $AppId
        Audience = $IdentifierUri
    }
}
catch {
    Write-Failure "Entra ID setup failed: $_"
    exit 1
}

exit 0
