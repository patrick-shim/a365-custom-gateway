#Requires -Version 7.0

<#
.SYNOPSIS
    Runs the clean-subscription data-plane canary as the assigned Gateway Administrator.

.DESCRIPTION
    Creates one registration-bound, credential-free public client and one
    principal-specific access_as_user grant, invokes Gateway.LiveCanary through
    InteractiveBrowserCredential, then removes the grant, service principal, and
    active application in reverse order only after exact Gateway-key revocation.
    A nonzero child result preserves that identity for an explicit RevokeOnly
    recovery invocation. Provider bodies, tokens, clear Gateway keys, and
    authorization headers are never rendered or persisted.

    This script never broadens Gateway.Administrator to applications and never
    grants delegated permission to Azure CLI. It performs no queue or message
    operation. Microsoft Entra application DELETE is a recoverable soft delete;
    absence proof here is against the active applications collection.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')]
    [string]$ExpectedSubscriptionId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')]
    [string]$ExpectedTenantId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9]{2,19}$')]
    [string]$ProjectName,

    [Parameter(Mandatory)]
    [ValidateSet('dev')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._()\-]{1,90}$')]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [ValidatePattern('^https://[^/?#]+/$')]
    [string]$ApiBaseUrl,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')]
    [string]$GatewayApiApplicationClientId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')]
    [string]$AgentRegistrationId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:\-]{0,255}$')]
    [string]$ExternalAgentId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')]
    [string]$TenantUserObjectId,

    [switch]$ExpectPromptShieldEnabled,

    [switch]$ExpectPurviewEnabled,

    [AllowEmptyString()]
    [string]$RecoveryCredentialId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$helperRelativePaths = @(
    'bootstrap/modules/Common.psm1',
    'bootstrap/modules/Azure.psm1',
    'bootstrap/modules/Entra.psm1',
    'operations/BoundedUserCanaryState.psm1'
)
$helperManifest = @($helperRelativePaths | Sort-Object | ForEach-Object {
    $relativePath = [string]$_
    $fullPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $relativePath))
    $file = Get-Item -LiteralPath $fullPath -ErrorAction Stop
    if (-not $file.PSIsContainer -and
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
        $fullPath.StartsWith("$repositoryRoot$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::Ordinal)) {
        "$($relativePath.Replace('\', '/'))=sha256:$((Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant())"
    }
    else {
        throw 'The bounded canary helper bundle contains a missing, redirected, or out-of-root source file.'
    }
}) -join "`n"
$helperManifestBytes = [Text.UTF8Encoding]::new($false).GetBytes($helperManifest)
$helperHasher = [Security.Cryptography.SHA256]::Create()
$helperHashBytes = $null
try {
    $helperHashBytes = $helperHasher.ComputeHash($helperManifestBytes)
    $helperBundleSha256 = "sha256:$(([BitConverter]::ToString($helperHashBytes)).Replace('-', '').ToLowerInvariant())"
}
finally {
    if ($null -ne $helperHashBytes) { [Array]::Clear($helperHashBytes, 0, $helperHashBytes.Length) }
    $helperHasher.Dispose()
    [Array]::Clear($helperManifestBytes, 0, $helperManifestBytes.Length)
}
Import-Module (Join-Path $repositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'bootstrap/modules/Azure.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'bootstrap/modules/Entra.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'operations/BoundedUserCanaryState.psm1') -Force

$temporaryApplicationId = ''
$temporaryApplicationClientId = ''
$temporaryServicePrincipalId = ''
$temporaryGrantId = ''
$temporaryDisplayName = ''
$preChildDisplayName = ''
$childArmedDisplayName = ''
$executionTag = ''
$recoveryMode = -not [string]::IsNullOrWhiteSpace($RecoveryCredentialId)
$preserveTemporaryIdentity = $recoveryMode
$recoveryBoundaryArmed = $recoveryMode
$issuedCredentialId = ''
$canaryState = $null
$canaryBindings = $null
$canaryStatePath = ''
$canaryLock = $null
$completedTombstone = $false
$operationFailure = $null
$cleanupFailures = [Collections.Generic.List[string]]::new()

function Assert-CanonicalNonEmptyGuid {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Label)

    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($Value, 'D', [ref]$parsed) -or
        $parsed -eq [guid]::Empty -or
        $Value -cne $parsed.ToString('D')) {
        throw "$Label must be one canonical lowercase non-empty GUID."
    }
}

function Assert-BoundedOpaqueIdentifier {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Label)

    if ($Value -cnotmatch '^[A-Za-z0-9_-]{1,256}$') {
        throw "$Label is not a bounded opaque identifier."
    }
}

function Get-ApplicationsByExactDisplayName {
    param([Parameter(Mandatory)][string]$DisplayName)

    $escaped = $DisplayName.Replace("'", "''")
    $filter = [uri]::EscapeDataString("displayName eq '$escaped'")
    return @(Get-BoundedGraphCollection -InitialUrl (
        "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&" +
        '$select=id,appId,displayName,signInAudience,identifierUris,tags,api,appRoles,' +
        'requiredResourceAccess,passwordCredentials,keyCredentials,web,spa,publicClient,isFallbackPublicClient'))
}

function Get-ApplicationsByExactClientId {
    param([Parameter(Mandatory)][string]$ClientId)

    $filter = [uri]::EscapeDataString("appId eq '$ClientId'")
    return @(Get-BoundedGraphCollection -InitialUrl (
        "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&" +
        '$select=id,appId,displayName,signInAudience,identifierUris,tags,api,appRoles,' +
        'requiredResourceAccess,passwordCredentials,keyCredentials,web,spa,publicClient,isFallbackPublicClient'))
}

function Get-CanaryGrants {
    param([Parameter(Mandatory)][string]$ClientServicePrincipalId)

    $filter = [uri]::EscapeDataString("clientId eq '$ClientServicePrincipalId'")
    return @(Get-BoundedGraphCollection -InitialUrl (
        "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=$filter&" +
        '$select=id,clientId,resourceId,consentType,principalId,scope'))
}

function Invoke-ExactCanaryGraphGetOrNull {
    param([Parameter(Mandatory)][string]$Url)

    try {
        return Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', $Url)
    }
    catch {
        if ([string]$_.Exception.Message -ceq
            'Microsoft Graph request returned HTTP 404; provider body was suppressed.') {
            return $null
        }
        throw
    }
}

function Get-ExactCanaryGrantById {
    param([Parameter(Mandatory)][string]$GrantId)

    Assert-BoundedOpaqueIdentifier -Value $GrantId -Label 'Temporary delegated grant ID'
    return Invoke-ExactCanaryGraphGetOrNull -Url (
        "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/${GrantId}?" +
        '$select=id,clientId,resourceId,consentType,principalId,scope')
}

function Get-ExactCanaryServicePrincipalById {
    param([Parameter(Mandatory)][string]$ServicePrincipalId)

    Assert-CanonicalNonEmptyGuid -Value $ServicePrincipalId -Label 'Temporary service principal object ID'
    return Invoke-ExactCanaryGraphGetOrNull -Url (
        "https://graph.microsoft.com/v1.0/servicePrincipals/${ServicePrincipalId}?" +
        '$select=id,appId,displayName,appRoles,oauth2PermissionScopes,passwordCredentials,' +
        'keyCredentials,accountEnabled,appRoleAssignmentRequired,servicePrincipalType,' +
        'servicePrincipalNames,tags,alternativeNames')
}

function Get-ExactCanaryApplicationById {
    param([Parameter(Mandatory)][string]$ApplicationObjectId)

    Assert-CanonicalNonEmptyGuid -Value $ApplicationObjectId -Label 'Temporary application object ID'
    return Invoke-ExactCanaryGraphGetOrNull -Url (
        "https://graph.microsoft.com/v1.0/applications/${ApplicationObjectId}?" +
        '$select=id,appId,displayName,signInAudience,identifierUris,tags,api,appRoles,' +
        'requiredResourceAccess,passwordCredentials,keyCredentials,web,spa,publicClient,isFallbackPublicClient')
}

function Wait-ExactCanaryObjectAbsent {
    param(
        [Parameter(Mandatory)][scriptblock]$ReadExact,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $consecutiveAbsent = 0
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $observed = & $ReadExact
        if ($null -eq $observed) {
            $consecutiveAbsent++
            if ($consecutiveAbsent -ge 2) { return }
        }
        else {
            $consecutiveAbsent = 0
        }
        if ($attempt -lt 18) { Start-Sleep -Seconds 2 }
    }
    throw $FailureMessage
}

function Wait-ExactApplicationByName {
    param([Parameter(Mandatory)][string]$DisplayName)

    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $applications = @(Get-ApplicationsByExactDisplayName -DisplayName $DisplayName)
        if ($applications.Count -gt 1) {
            throw 'The execution-bound canary application name resolved ambiguously.'
        }
        if ($applications.Count -eq 1) { return $applications[0] }
        if ($attempt -lt 18) { Start-Sleep -Seconds 2 }
    }
    return $null
}

function Wait-ExactServicePrincipalByClientId {
    param([Parameter(Mandatory)][string]$ClientId)

    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $principal = Get-ServicePrincipalByAppId -AppId $ClientId
        if ($principal) { return $principal }
        if ($attempt -lt 18) { Start-Sleep -Seconds 2 }
    }
    return $null
}

function Wait-ExactGrantByClientId {
    param([Parameter(Mandatory)][string]$ClientServicePrincipalId)

    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $grants = @(Get-CanaryGrants -ClientServicePrincipalId $ClientServicePrincipalId)
        if ($grants.Count -gt 1) {
            throw 'The execution-bound canary delegated grant resolved ambiguously.'
        }
        if ($grants.Count -eq 1) { return $grants[0] }
        if ($attempt -lt 18) { Start-Sleep -Seconds 2 }
    }
    return $null
}

function Assert-ExactGatewayApiApplication {
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)][string]$ExpectedScopeBaseUri
    )

    $expectedRoleValues = @(
        'Gateway.Administrator',
        'Gateway.Auditor',
        'Gateway.Operator',
        'Gateway.SupportReader'
    )
    $actualRoleValues = @($Application.appRoles | ForEach-Object { [string]$_.value } | Sort-Object)
    $applicationTags = @($Application.tags | ForEach-Object { [string]$_ })
    $ownershipTags = @($applicationTags | Where-Object {
        $_ -cmatch '^A365GatewayOwnership:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    })
    Assert-ExactApplicationAuthenticationSurface `
        -Application $Application `
        -ApplicationLabel 'Gateway API application' | Out-Null
    $allScopes = @($Application.api.oauth2PermissionScopes)
    $scope = @($allScopes | Where-Object {
        [string]$_.value -ceq 'access_as_user'
    })
    if ([string]$Application.appId -cne $GatewayApiApplicationClientId -or
        [string]$Application.signInAudience -cne 'AzureADMyOrg' -or
        @($Application.identifierUris).Count -ne 1 -or
        [string]$Application.identifierUris[0] -cne $ExpectedScopeBaseUri -or
        $applicationTags.Count -ne 2 -or
        $applicationTags -cnotcontains 'A365GatewayBootstrap' -or
        $ownershipTags.Count -ne 1 -or
        [int]$Application.api.requestedAccessTokenVersion -ne 2 -or
        $allScopes.Count -ne 1 -or
        $scope.Count -ne 1 -or $scope[0].isEnabled -ne $true -or
        [string]$scope[0].type -cne 'Admin' -or
        @($Application.appRoles).Count -ne 4 -or
        (@($actualRoleValues) -join '|') -cne (@($expectedRoleValues | Sort-Object) -join '|') -or
        @($Application.appRoles | Where-Object {
            $_.isEnabled -ne $true -or
            @($_.allowedMemberTypes).Count -ne 1 -or
            [string]$_.allowedMemberTypes[0] -cne 'User'
        }).Count -ne 0 -or
        @($Application.passwordCredentials).Count -ne 0 -or
        @($Application.keyCredentials).Count -ne 0 -or
        @($Application.web.redirectUris).Count -ne 0 -or
        -not [string]::IsNullOrWhiteSpace([string]$Application.web.logoutUrl) -or
        -not [string]::IsNullOrWhiteSpace([string]$Application.web.homePageUrl) -or
        @($Application.spa.redirectUris).Count -ne 0 -or
        @($Application.publicClient.redirectUris).Count -ne 0) {
        throw 'The Gateway API application does not match the exact v2, scope, credential, and user-only role boundary.'
    }
    $deploymentOwnershipId = [string]$ownershipTags[0].Substring('A365GatewayOwnership:'.Length)
    Assert-CanonicalNonEmptyGuid -Value $deploymentOwnershipId -Label 'Gateway deployment ownership ID'
    return [pscustomobject]@{
        scopeId = [string]$scope[0].id
        administratorRoleId = [string](@($Application.appRoles | Where-Object {
            [string]$_.value -ceq 'Gateway.Administrator'
        })[0].id)
        deploymentOwnershipId = $deploymentOwnershipId
    }
}

function Assert-ExactTemporaryApplication {
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)][string]$ExpectedDisplayName,
        [Parameter(Mandatory)][string]$ExpectedTag,
        [Parameter(Mandatory)][string]$ExpectedScopeId
    )

    Assert-ExactApplicationAuthenticationSurface `
        -Application $Application `
        -ApplicationLabel 'Temporary canary application' | Out-Null
    $requiredAccess = @($Application.requiredResourceAccess)
    $resourceAccess = if ($requiredAccess.Count -eq 1) { @($requiredAccess[0].resourceAccess) } else { @() }
    if ([string]$Application.displayName -cne $ExpectedDisplayName -or
        [string]$Application.signInAudience -cne 'AzureADMyOrg' -or
        @($Application.tags).Count -ne 1 -or [string]$Application.tags[0] -cne $ExpectedTag -or
        @($Application.identifierUris).Count -ne 0 -or
        @($Application.passwordCredentials).Count -ne 0 -or
        @($Application.keyCredentials).Count -ne 0 -or
        @($Application.appRoles).Count -ne 0 -or
        @($Application.api.oauth2PermissionScopes).Count -ne 0 -or
        @($Application.web.redirectUris).Count -ne 0 -or
        -not [string]::IsNullOrWhiteSpace([string]$Application.web.logoutUrl) -or
        -not [string]::IsNullOrWhiteSpace([string]$Application.web.homePageUrl) -or
        @($Application.spa.redirectUris).Count -ne 0 -or
        @($Application.publicClient.redirectUris).Count -ne 1 -or
        [string]$Application.publicClient.redirectUris[0] -cne 'http://localhost' -or
        $Application.isFallbackPublicClient -ne $false -or
        $requiredAccess.Count -ne 1 -or
        [string]$requiredAccess[0].resourceAppId -cne $GatewayApiApplicationClientId -or
        $resourceAccess.Count -ne 1 -or
        [string]$resourceAccess[0].id -cne $ExpectedScopeId -or
        [string]$resourceAccess[0].type -cne 'Scope') {
        throw 'The temporary canary application does not match the exact credential-free public-client boundary.'
    }
}

function Get-TemporaryApplicationOwnerIds {
    param([Parameter(Mandatory)][string]$ApplicationObjectId)

    Assert-CanonicalNonEmptyGuid -Value $ApplicationObjectId -Label 'Temporary application object ID'
    return @(Get-BoundedGraphCollection -InitialUrl (
        "https://graph.microsoft.com/v1.0/applications/$ApplicationObjectId/owners?`$select=id") |
        ForEach-Object { [string]$_.id })
}

function Assert-ExactTemporaryApplicationOwner {
    param([Parameter(Mandatory)][string]$ApplicationObjectId)

    $ownerIds = @(Get-TemporaryApplicationOwnerIds -ApplicationObjectId $ApplicationObjectId)
    if ($ownerIds.Count -ne 1 -or
        -not $ownerIds[0].Equals($TenantUserObjectId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The temporary canary application must have exactly the pinned administrator as owner.'
    }
}

function Assert-ExactTemporaryServicePrincipal {
    param(
        [Parameter(Mandatory)]$Principal,
        [Parameter(Mandatory)][string]$ExpectedClientId,
        [Parameter(Mandatory)][string]$ExpectedTag
    )

    Assert-ExactBootstrapServicePrincipalBoundary `
        -ServicePrincipal $Principal `
        -ExpectedId ([string]$Principal.id) `
        -ExpectedAppId $ExpectedClientId `
        -ServicePrincipalLabel 'Temporary canary service principal' `
        -ExpectedServicePrincipalNames @($ExpectedClientId) `
        -ExpectedTags @($ExpectedTag) `
        -ExpectedAppRoles @() `
        -ExpectedOauth2PermissionScopes @() | Out-Null
}

function Assert-ExactTemporaryGrant {
    param(
        [Parameter(Mandatory)]$Grant,
        [Parameter(Mandatory)][string]$ExpectedClientServicePrincipalId,
        [Parameter(Mandatory)][string]$ExpectedResourceServicePrincipalId
    )

    if ([string]$Grant.clientId -cne $ExpectedClientServicePrincipalId -or
        [string]$Grant.resourceId -cne $ExpectedResourceServicePrincipalId -or
        [string]$Grant.consentType -cne 'Principal' -or
        [string]$Grant.principalId -cne $TenantUserObjectId -or
        [string]$Grant.scope -cne 'access_as_user' -or
        [string]$Grant.id -cnotmatch '^[A-Za-z0-9_-]{1,256}$') {
        throw 'The temporary canary delegated grant does not match the exact user and access_as_user boundary.'
    }
}

function Remove-ExactTemporaryGrant {
    if ([string]::IsNullOrWhiteSpace($temporaryServicePrincipalId) -or
        [string]::IsNullOrWhiteSpace($temporaryGrantId)) { return }
    $exactGrant = Get-ExactCanaryGrantById -GrantId $temporaryGrantId
    $grants = @(Get-CanaryGrants -ClientServicePrincipalId $temporaryServicePrincipalId)
    if ($null -eq $exactGrant) {
        if ($grants.Count -ne 0) {
            throw 'The exact temporary grant is absent but different client authority remains; refusing cleanup.'
        }
        Wait-ExactCanaryObjectAbsent `
            -ReadExact { Get-ExactCanaryGrantById -GrantId $temporaryGrantId } `
            -FailureMessage 'The temporary delegated grant absence was not stable.'
        return
    }
    if ($grants.Count -ne 1 -or [string]$grants[0].id -cne $temporaryGrantId -or
        [string]$exactGrant.id -cne $temporaryGrantId) {
        throw 'The temporary delegated grant changed authority before cleanup; refusing targeted deletion.'
    }
    Assert-ExactTemporaryGrant `
        -Grant $exactGrant `
        -ExpectedClientServicePrincipalId $temporaryServicePrincipalId `
        -ExpectedResourceServicePrincipalId $script:gatewayApiServicePrincipalId
    try {
        Invoke-AzJson -Arguments @(
            'rest', '--method', 'DELETE', '--url',
            "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$temporaryGrantId"
        ) | Out-Null
    }
    catch { }
    Wait-ExactCanaryObjectAbsent `
        -ReadExact { Get-ExactCanaryGrantById -GrantId $temporaryGrantId } `
        -FailureMessage 'The temporary delegated grant could not be proven absent by exact ID after deletion.'
    if (@(Get-CanaryGrants -ClientServicePrincipalId $temporaryServicePrincipalId).Count -ne 0) {
        throw 'Different delegated authority remains after exact temporary grant deletion.'
    }
}

function Remove-ExactTemporaryServicePrincipal {
    if ([string]::IsNullOrWhiteSpace($temporaryApplicationClientId) -or
        [string]::IsNullOrWhiteSpace($temporaryServicePrincipalId)) { return }
    $exactPrincipal = Get-ExactCanaryServicePrincipalById -ServicePrincipalId $temporaryServicePrincipalId
    $principalByClientId = Get-ServicePrincipalByAppId -AppId $temporaryApplicationClientId
    if ($null -eq $exactPrincipal) {
        if ($null -ne $principalByClientId) {
            throw 'The exact temporary service principal is absent but different client authority remains.'
        }
        Wait-ExactCanaryObjectAbsent `
            -ReadExact { Get-ExactCanaryServicePrincipalById -ServicePrincipalId $temporaryServicePrincipalId } `
            -FailureMessage 'The temporary service-principal absence was not stable.'
        return
    }
    if ($null -eq $principalByClientId -or
        [string]$principalByClientId.id -cne $temporaryServicePrincipalId -or
        [string]$exactPrincipal.id -cne $temporaryServicePrincipalId) {
        throw 'The temporary service principal changed authority before cleanup; refusing deletion.'
    }
    Assert-ExactTemporaryServicePrincipal `
        -Principal $exactPrincipal `
        -ExpectedClientId $temporaryApplicationClientId `
        -ExpectedTag $executionTag
    try {
        Invoke-AzJson -Arguments @(
            'rest', '--method', 'DELETE', '--url',
            "https://graph.microsoft.com/v1.0/servicePrincipals/$temporaryServicePrincipalId"
        ) | Out-Null
    }
    catch { }
    Wait-ExactCanaryObjectAbsent `
        -ReadExact { Get-ExactCanaryServicePrincipalById -ServicePrincipalId $temporaryServicePrincipalId } `
        -FailureMessage 'The temporary service principal could not be proven absent by exact ID after deletion.'
    if ($null -ne (Get-ServicePrincipalByAppId -AppId $temporaryApplicationClientId)) {
        throw 'Different service-principal authority remains after exact temporary principal deletion.'
    }
}

function Remove-ExactTemporaryApplication {
    if ([string]::IsNullOrWhiteSpace($temporaryDisplayName) -or
        [string]::IsNullOrWhiteSpace($temporaryApplicationId) -or
        [string]::IsNullOrWhiteSpace($temporaryApplicationClientId)) { return }
    $exactApplication = Get-ExactCanaryApplicationById -ApplicationObjectId $temporaryApplicationId
    $applicationsByClientId = @(Get-ApplicationsByExactClientId -ClientId $temporaryApplicationClientId)
    $applicationsByName = @(Get-ApplicationsByExactDisplayName -DisplayName $temporaryDisplayName)
    if ($null -eq $exactApplication) {
        if ($applicationsByClientId.Count -ne 0 -or $applicationsByName.Count -ne 0) {
            throw 'The exact temporary application is absent but different client or name authority remains.'
        }
        Wait-ExactCanaryObjectAbsent `
            -ReadExact { Get-ExactCanaryApplicationById -ApplicationObjectId $temporaryApplicationId } `
            -FailureMessage 'The temporary application absence was not stable.'
        return
    }
    if ($applicationsByClientId.Count -ne 1 -or $applicationsByName.Count -ne 1 -or
        [string]$applicationsByClientId[0].id -cne $temporaryApplicationId -or
        [string]$applicationsByName[0].id -cne $temporaryApplicationId -or
        [string]$exactApplication.id -cne $temporaryApplicationId -or
        [string]$exactApplication.appId -cne $temporaryApplicationClientId) {
        throw 'The temporary application changed authority before cleanup; refusing deletion.'
    }
    Assert-ExactTemporaryApplication `
        -Application $exactApplication `
        -ExpectedDisplayName $temporaryDisplayName `
        -ExpectedTag $executionTag `
        -ExpectedScopeId $script:gatewayApiAccessScopeId
    Assert-ExactTemporaryApplicationOwner -ApplicationObjectId $temporaryApplicationId
    try {
        Invoke-AzJson -Arguments @(
            'rest', '--method', 'DELETE', '--url',
            "https://graph.microsoft.com/v1.0/applications/$temporaryApplicationId"
        ) | Out-Null
    }
    catch { }
    Wait-ExactCanaryObjectAbsent `
        -ReadExact { Get-ExactCanaryApplicationById -ApplicationObjectId $temporaryApplicationId } `
        -FailureMessage 'The temporary application could not be proven absent by exact ID after deletion.'
    if (@(Get-ApplicationsByExactClientId -ClientId $temporaryApplicationClientId).Count -ne 0 -or
        @(Get-ApplicationsByExactDisplayName -DisplayName $temporaryDisplayName).Count -ne 0) {
        throw 'Different application authority remains after exact temporary application deletion.'
    }
}

function Adopt-ExactTemporaryAuthority {
    param(
        [Parameter()][AllowNull()]$Application,
        [Parameter(Mandatory)][string]$ExpectedDisplayName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [switch]$RequireComplete
    )

    $script:temporaryDisplayName = $ExpectedDisplayName
    $recordedApplicationId = [string]$State.temporaryApplicationObjectId
    $recordedClientId = [string]$State.temporaryApplicationClientId
    $recordedPrincipalId = [string]$State.temporaryServicePrincipalId
    $recordedGrantId = [string]$State.temporaryGrantId

    if ($null -ne $Application) {
        Assert-ExactTemporaryApplication `
            -Application $Application `
            -ExpectedDisplayName $ExpectedDisplayName `
            -ExpectedTag $executionTag `
            -ExpectedScopeId $script:gatewayApiAccessScopeId
        $observedApplicationId = [string]$Application.id
        $observedClientId = [string]$Application.appId
        Assert-CanonicalNonEmptyGuid -Value $observedApplicationId -Label 'Temporary application object ID'
        Assert-CanonicalNonEmptyGuid -Value $observedClientId -Label 'Temporary application client ID'
        Assert-ExactTemporaryApplicationOwner -ApplicationObjectId $observedApplicationId
        if ((-not [string]::IsNullOrEmpty($recordedApplicationId) -and
             $recordedApplicationId -cne $observedApplicationId) -or
            (-not [string]::IsNullOrEmpty($recordedClientId) -and
             $recordedClientId -cne $observedClientId)) {
            throw 'The temporary application does not match its durable canary-state binding.'
        }
        $script:temporaryApplicationId = $observedApplicationId
        $script:temporaryApplicationClientId = $observedClientId
    }
    elseif ($RequireComplete) {
        throw 'The complete temporary canary application was not observable.'
    }
    else {
        $script:temporaryApplicationId = $recordedApplicationId
        $script:temporaryApplicationClientId = $recordedClientId
    }

    if ([string]::IsNullOrEmpty($script:temporaryApplicationClientId)) {
        if ($RequireComplete) { throw 'The complete temporary application client ID is absent.' }
        return
    }

    $principal = Get-ServicePrincipalByAppId -AppId $script:temporaryApplicationClientId
    if ($null -ne $principal) {
        Assert-ExactTemporaryServicePrincipal `
            -Principal $principal `
            -ExpectedClientId $script:temporaryApplicationClientId `
            -ExpectedTag $executionTag
        $observedPrincipalId = [string]$principal.id
        Assert-CanonicalNonEmptyGuid -Value $observedPrincipalId -Label 'Temporary service principal object ID'
        if (-not [string]::IsNullOrEmpty($recordedPrincipalId) -and
            $recordedPrincipalId -cne $observedPrincipalId) {
            throw 'The temporary service principal does not match its durable canary-state binding.'
        }
        $script:temporaryServicePrincipalId = $observedPrincipalId
    }
    elseif ($RequireComplete) {
        throw 'The complete temporary canary service principal was not observable.'
    }
    else {
        $script:temporaryServicePrincipalId = $recordedPrincipalId
    }

    if ([string]::IsNullOrEmpty($script:temporaryServicePrincipalId)) {
        if ($RequireComplete) { throw 'The complete temporary service-principal ID is absent.' }
        return
    }

    $grants = @(Get-CanaryGrants -ClientServicePrincipalId $script:temporaryServicePrincipalId)
    if ($grants.Count -gt 1) {
        throw 'The temporary canary delegated grant resolved ambiguously.'
    }
    if ($grants.Count -eq 1) {
        Assert-ExactTemporaryGrant `
            -Grant $grants[0] `
            -ExpectedClientServicePrincipalId $script:temporaryServicePrincipalId `
            -ExpectedResourceServicePrincipalId $script:gatewayApiServicePrincipalId
        $observedGrantId = [string]$grants[0].id
        Assert-BoundedOpaqueIdentifier -Value $observedGrantId -Label 'Temporary delegated grant ID'
        if (-not [string]::IsNullOrEmpty($recordedGrantId) -and
            $recordedGrantId -cne $observedGrantId) {
            throw 'The temporary delegated grant does not match its durable canary-state binding.'
        }
        $script:temporaryGrantId = $observedGrantId
    }
    elseif ($RequireComplete) {
        throw 'The complete temporary delegated grant was not observable.'
    }
    else {
        $script:temporaryGrantId = $recordedGrantId
    }
}

foreach ($guidInput in @(
    @{ value = $ExpectedSubscriptionId; label = 'Expected subscription ID' },
    @{ value = $ExpectedTenantId; label = 'Expected tenant ID' },
    @{ value = $GatewayApiApplicationClientId; label = 'Gateway API application client ID' },
    @{ value = $AgentRegistrationId; label = 'Agent registration ID' },
    @{ value = $TenantUserObjectId; label = 'Tenant user object ID' }
)) {
    Assert-CanonicalNonEmptyGuid -Value $guidInput.value -Label $guidInput.label
}
if ($recoveryMode) {
    Assert-CanonicalNonEmptyGuid -Value $RecoveryCredentialId -Label 'Recovery credential ID'
}

$expectedScopeBaseUri = "api://a365-gateway-$ProjectName-$Environment"
$parsedApiBaseUrl = [uri]$ApiBaseUrl
if ($parsedApiBaseUrl.Scheme -cne 'https' -or
    -not $parsedApiBaseUrl.IsDefaultPort -or
    -not [string]::IsNullOrEmpty($parsedApiBaseUrl.UserInfo) -or
    -not [string]::IsNullOrEmpty($parsedApiBaseUrl.Query) -or
    -not [string]::IsNullOrEmpty($parsedApiBaseUrl.Fragment) -or
    $parsedApiBaseUrl.AbsolutePath -cne '/') {
    throw 'API base URL must be one canonical public HTTPS origin with a trailing slash.'
}

$registrationToken = $AgentRegistrationId.Replace('-', '')
$identityStem = "A365 Gateway Bounded Canary - $ProjectName-$Environment-$registrationToken"
$preChildDisplayName = "$identityStem - PreChild"
$childArmedDisplayName = "$identityStem - ChildArmed"
$executionTag = "a365gw:bounded-user-canary:$registrationToken"
$canaryOutput = Join-Path $repositoryRoot 'tools/Gateway.LiveCanary/bin/Release/net10.0'
$canaryAssembly = Join-Path $canaryOutput 'Gateway.LiveCanary.dll'
if (-not (Test-Path -LiteralPath $canaryAssembly -PathType Leaf)) {
    throw 'The reviewed Release Gateway.LiveCanary assembly is absent. Build it before any live canary action.'
}
$wrapperSha256 = "sha256:$((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant())"
$canaryRuntimeFiles = @(Get-ChildItem -LiteralPath $canaryOutput -Recurse -File | Where-Object {
    $_.Extension -ceq '.dll' -or
    $_.Name -ceq 'Gateway.LiveCanary.deps.json' -or
    $_.Name -ceq 'Gateway.LiveCanary.runtimeconfig.json'
} | ForEach-Object {
    $relativePath = [IO.Path]::GetRelativePath($canaryOutput, $_.FullName).Replace('\', '/')
    [pscustomobject]@{ File = $_; RelativePath = $relativePath }
} | Sort-Object RelativePath)
foreach ($requiredRuntimeFile in @(
    'Gateway.LiveCanary.dll',
    'Gateway.LiveCanary.deps.json',
    'Gateway.LiveCanary.runtimeconfig.json'
)) {
    if (@($canaryRuntimeFiles | Where-Object RelativePath -CEQ $requiredRuntimeFile).Count -ne 1) {
        throw 'The reviewed Release Gateway.LiveCanary runtime bundle is incomplete or ambiguous.'
    }
}
$canaryBundleManifest = @($canaryRuntimeFiles | ForEach-Object {
    if ($_.RelativePath.Length -gt 512 -or
        $_.RelativePath -cnotmatch '^[A-Za-z0-9_.\-/]+$' -or
        $_.RelativePath -cmatch '(^|/)\.\.(/|$)' -or
        ($_.File.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The reviewed Release Gateway.LiveCanary runtime bundle contains an unsafe file entry.'
    }
    "$($_.RelativePath)=sha256:$((Get-FileHash -LiteralPath $_.File.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
}) -join "`n"
$canaryBundleSha256 = Get-BootstrapSha256 -Text $canaryBundleManifest
$canaryBindings = [ordered]@{
    subscriptionId = $ExpectedSubscriptionId
    tenantId = $ExpectedTenantId
    projectName = $ProjectName
    environment = $Environment
    resourceGroup = $ResourceGroup
    apiBaseUrl = $ApiBaseUrl
    gatewayApiApplicationClientId = $GatewayApiApplicationClientId
    agentRegistrationId = $AgentRegistrationId
    externalAgentId = $ExternalAgentId
    tenantUserObjectId = $TenantUserObjectId
    promptShieldExpected = ([bool]$ExpectPromptShieldEnabled).ToString().ToLowerInvariant()
    purviewExpected = ([bool]$ExpectPurviewEnabled).ToString().ToLowerInvariant()
    wrapperSha256 = $wrapperSha256
    helperBundleSha256 = $helperBundleSha256
    canaryBundleSha256 = $canaryBundleSha256
    preChildDisplayName = $preChildDisplayName
    childArmedDisplayName = $childArmedDisplayName
    executionTag = $executionTag
}
Assert-BoundedUserCanaryBindings -Bindings $canaryBindings
$canaryStatePath = Join-Path $repositoryRoot ".bootstrap/canary/$ExpectedSubscriptionId-$AgentRegistrationId.json"

try {
    $canaryLock = Enter-BootstrapLock -StatePath $canaryStatePath
    $canaryState = Read-BoundedUserCanaryState -Path $canaryStatePath -Bindings $canaryBindings
    if ($null -eq $canaryState) {
        if ($recoveryMode) {
            throw 'RevokeOnly requires the exact durable canary state that observed this credential ID.'
        }
        $canaryState = New-BoundedUserCanaryState -Bindings $canaryBindings
        Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
    }

    if (Test-BoundedUserCanaryStateRequiresPreservation -State $canaryState -Bindings $canaryBindings) {
        $preserveTemporaryIdentity = $true
    }
    if (@('ArmStarted', 'ChildArmed', 'ChildLaunchStarted', 'CredentialObserved') -ccontains
        [string]$canaryState.status) {
        $recoveryBoundaryArmed = $true
    }

    if ([string]$canaryState.status -ceq 'Completed') {
        if ($recoveryMode) {
            throw 'The exact bounded canary is already Completed; a second recovery revocation is not authorized.'
        }
        $completedTombstone = $true
    }
    elseif ($recoveryMode) {
        if ([string]$canaryState.status -cne 'CredentialObserved' -or
            [string]$canaryState.recoveryCredentialId -cne $RecoveryCredentialId) {
            throw 'RevokeOnly requires the exact credential ID durably observed for this registration-bound canary.'
        }
    }
    elseif (@('ChildLaunchStarted', 'CredentialObserved') -ccontains [string]$canaryState.status) {
        throw 'The canary crossed the durable child-launch boundary. Full mode is forbidden; use the exact recorded recovery path or manual credential inspection.'
    }

    $azureIdentity = Connect-BootstrapAzure -Config ([pscustomobject]@{
        subscriptionId = $ExpectedSubscriptionId
        tenantId = $ExpectedTenantId
    }) -NonInteractive
    if ([string]$azureIdentity.subscriptionId -cne $ExpectedSubscriptionId -or
        [string]$azureIdentity.tenantId -cne $ExpectedTenantId) {
        throw 'The Azure CLI could not be pinned to the exact canary subscription and tenant.'
    }
    if ([string]$azureIdentity.userObjectId -cne $TenantUserObjectId) {
        throw 'The active Graph user does not match the exact bootstrap Gateway Administrator.'
    }

    $containerApp = Invoke-AzJson -Arguments @(
        'containerapp', 'show',
        '--name', "ca-gateway-api-$Environment",
        '--resource-group', $ResourceGroup,
        '--subscription', $ExpectedSubscriptionId
    )
    if ([string]$containerApp.properties.configuration.ingress.fqdn -cne $parsedApiBaseUrl.Host -or
        $containerApp.properties.configuration.ingress.external -ne $true) {
        throw 'The canary API URL does not match the exact externally reachable Gateway API Container App.'
    }

    $gatewayApplications = @(Get-ApplicationsByExactClientId -ClientId $GatewayApiApplicationClientId)
    if ($gatewayApplications.Count -ne 1) {
        throw 'The Gateway API client ID did not resolve to exactly one application.'
    }
    $gatewayContract = Assert-ExactGatewayApiApplication `
        -Application $gatewayApplications[0] `
        -ExpectedScopeBaseUri $expectedScopeBaseUri
    $script:gatewayApiAccessScopeId = [string]$gatewayContract.scopeId
    Assert-BootstrapApplicationOwnership `
        -Application $gatewayApplications[0] `
        -DeploymentOwnershipId ([string]$gatewayContract.deploymentOwnershipId) `
        -OwnerObjectId $TenantUserObjectId | Out-Null
    $gatewayApiPrincipal = Get-ServicePrincipalByAppId -AppId $GatewayApiApplicationClientId
    if (-not $gatewayApiPrincipal) {
        throw 'The Gateway API service principal was not observable.'
    }
    $script:gatewayApiServicePrincipalId = [string]$gatewayApiPrincipal.id
    Assert-ExactBootstrapServicePrincipalBoundary `
        -ServicePrincipal $gatewayApiPrincipal `
        -ExpectedId $script:gatewayApiServicePrincipalId `
        -ExpectedAppId $GatewayApiApplicationClientId `
        -ServicePrincipalLabel 'Gateway API service principal' `
        -ExpectedServicePrincipalNames @($GatewayApiApplicationClientId, $expectedScopeBaseUri) `
        -ExpectedTags @(Get-BootstrapApplicationTags -DeploymentOwnershipId ([string]$gatewayContract.deploymentOwnershipId)) `
        -ExpectedAppRoles @($gatewayApplications[0].appRoles) `
        -ExpectedOauth2PermissionScopes @($gatewayApplications[0].api.oauth2PermissionScopes) `
        -ExpectedAppRoleAssigneePrincipalId $TenantUserObjectId `
        -ExpectedAppRoleId ([string]$gatewayContract.administratorRoleId) | Out-Null
    Assert-GatewayApiDelegatedPermissionBoundary -Identity ([ordered]@{
        gatewayApiApplicationObjectId = [string]$gatewayApplications[0].id
        gatewayApiClientId = $GatewayApiApplicationClientId
        gatewayApiServicePrincipalId = $script:gatewayApiServicePrincipalId
    }) -RequireComplete | Out-Null

    $preChildApplications = @(Get-ApplicationsByExactDisplayName -DisplayName $preChildDisplayName)
    $childArmedApplications = @(Get-ApplicationsByExactDisplayName -DisplayName $childArmedDisplayName)
    if ($preChildApplications.Count -gt 1 -or
        $childArmedApplications.Count -gt 1 -or
        ($preChildApplications.Count + $childArmedApplications.Count) -gt 1) {
        throw 'The registration-bound canary application stage resolved ambiguously.'
    }

    if ($completedTombstone) {
        if ($preChildApplications.Count -ne 0) {
            throw 'Completed canary state conflicts with a PreChild temporary application; refusing cleanup.'
        }
        $preserveTemporaryIdentity = $true
        $completedApplication = if ($childArmedApplications.Count -eq 1) {
            $childArmedApplications[0]
        }
        else {
            Get-ExactCanaryApplicationById `
                -ApplicationObjectId ([string]$canaryState.temporaryApplicationObjectId)
        }
        Adopt-ExactTemporaryAuthority `
            -Application $completedApplication `
            -ExpectedDisplayName $childArmedDisplayName `
            -State $canaryState
        $preserveTemporaryIdentity = $false
        Write-Host '[PASS] The registration-bound canary is already Completed; only exact leftover Entra cleanup will run.'
    }
    elseif ($recoveryMode) {
        if ($preChildApplications.Count -ne 0 -or $childArmedApplications.Count -ne 1) {
            throw 'RevokeOnly recovery requires exactly one ChildArmed registration-bound canary application.'
        }
        Adopt-ExactTemporaryAuthority `
            -Application $childArmedApplications[0] `
            -ExpectedDisplayName $childArmedDisplayName `
            -State $canaryState `
            -RequireComplete
        $recoveryBoundaryArmed = $true
        $preserveTemporaryIdentity = $true
    }
    else {
        # Every external mutation has its own durable Started marker. A Started
        # stage is GET-only on all later invocations; no unknown POST or PATCH is
        # ever repeated. Partial PreChild authority remains exact-bound in Entra.
        if ([string]$canaryState.status -ceq 'Prepared') {
            if ($preChildApplications.Count -ne 0 -or $childArmedApplications.Count -ne 0) {
                throw 'Prepared canary state conflicts with an existing registration-bound temporary application.'
            }
            $canaryState = Set-BoundedUserCanaryStateStatus `
                -State $canaryState `
                -Bindings $canaryBindings `
                -Status 'ApplicationCreateStarted'
            Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
            $preserveTemporaryIdentity = $true
            try {
                Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/applications' -Body @{
                    displayName = $preChildDisplayName
                    signInAudience = 'AzureADMyOrg'
                    identifierUris = @()
                    tags = @($executionTag)
                    isFallbackPublicClient = $false
                    api = @{
                        acceptMappedClaims = $false
                        knownClientApplications = @()
                        oauth2PermissionScopes = @()
                        preAuthorizedApplications = @()
                    }
                    publicClient = @{ redirectUris = @('http://localhost') }
                    web = @{ redirectUris = @(); implicitGrantSettings = @{
                        enableAccessTokenIssuance = $false
                        enableIdTokenIssuance = $false
                    } }
                    spa = @{ redirectUris = @() }
                    appRoles = @()
                    requiredResourceAccess = @(@{
                        resourceAppId = $GatewayApiApplicationClientId
                        resourceAccess = @(@{ id = $script:gatewayApiAccessScopeId; type = 'Scope' })
                    })
                } | Out-Null
            }
            catch { }
        }

        if ([string]$canaryState.status -ceq 'ApplicationCreateStarted') {
            $preserveTemporaryIdentity = $true
            if (@(Get-ApplicationsByExactDisplayName -DisplayName $childArmedDisplayName).Count -ne 0) {
                throw 'ApplicationCreateStarted conflicts with a ChildArmed application.'
            }
            $temporaryApplication = Wait-ExactApplicationByName -DisplayName $preChildDisplayName
            if (-not $temporaryApplication) {
                throw 'The application-create outcome remains unobservable. This Started stage is GET-only and the POST will not be repeated.'
            }
            Assert-ExactTemporaryApplication `
                -Application $temporaryApplication `
                -ExpectedDisplayName $preChildDisplayName `
                -ExpectedTag $executionTag `
                -ExpectedScopeId $script:gatewayApiAccessScopeId
            $temporaryDisplayName = $preChildDisplayName
            $temporaryApplicationId = [string]$temporaryApplication.id
            $temporaryApplicationClientId = [string]$temporaryApplication.appId
            Assert-CanonicalNonEmptyGuid -Value $temporaryApplicationId -Label 'Temporary application object ID'
            Assert-CanonicalNonEmptyGuid -Value $temporaryApplicationClientId -Label 'Temporary application client ID'
            $canaryState = Set-BoundedUserCanaryStateStatus `
                -State $canaryState `
                -Bindings $canaryBindings `
                -Status 'ApplicationObserved' `
                -TemporaryApplicationObjectId $temporaryApplicationId `
                -TemporaryApplicationClientId $temporaryApplicationClientId
            Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
        }

        if ([string]$canaryState.status -ceq 'ApplicationObserved') {
            $temporaryApplication = Wait-ExactApplicationByName -DisplayName $preChildDisplayName
            if (-not $temporaryApplication -or
                @(Get-ApplicationsByExactDisplayName -DisplayName $childArmedDisplayName).Count -ne 0) {
                throw 'ApplicationObserved state no longer resolves to its exact PreChild application.'
            }
            Assert-ExactTemporaryApplication `
                -Application $temporaryApplication `
                -ExpectedDisplayName $preChildDisplayName `
                -ExpectedTag $executionTag `
                -ExpectedScopeId $script:gatewayApiAccessScopeId
            $temporaryDisplayName = $preChildDisplayName
            $temporaryApplicationId = [string]$temporaryApplication.id
            $temporaryApplicationClientId = [string]$temporaryApplication.appId
            if ($temporaryApplicationId -cne [string]$canaryState.temporaryApplicationObjectId -or
                $temporaryApplicationClientId -cne [string]$canaryState.temporaryApplicationClientId -or
                $null -ne (Get-ServicePrincipalByAppId -AppId $temporaryApplicationClientId)) {
                throw 'ApplicationObserved found downstream authority before its durable Started marker.'
            }
            $ownerIds = @(Get-TemporaryApplicationOwnerIds -ApplicationObjectId $temporaryApplicationId)
            if ($ownerIds.Count -gt 1 -or
                ($ownerIds.Count -eq 1 -and
                 -not $ownerIds[0].Equals($TenantUserObjectId, [StringComparison]::OrdinalIgnoreCase))) {
                throw 'ApplicationObserved found an ambiguous or third-party temporary application owner.'
            }
            if ($ownerIds.Count -eq 0) {
                $canaryState = Set-BoundedUserCanaryStateStatus `
                    -State $canaryState `
                    -Bindings $canaryBindings `
                    -Status 'OwnerAddStarted'
                Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
                try {
                    Invoke-GraphJsonBody `
                        -Method 'POST' `
                        -Url "https://graph.microsoft.com/v1.0/applications/$temporaryApplicationId/owners/`$ref" `
                        -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$TenantUserObjectId" } | Out-Null
                }
                catch { }
            }
            else {
                $canaryState = Set-BoundedUserCanaryStateStatus `
                    -State $canaryState `
                    -Bindings $canaryBindings `
                    -Status 'OwnerObserved'
                Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
            }
        }

        if ([string]$canaryState.status -ceq 'OwnerAddStarted') {
            $temporaryApplication = Wait-ExactApplicationByName -DisplayName $preChildDisplayName
            if (-not $temporaryApplication -or
                [string]$temporaryApplication.id -cne [string]$canaryState.temporaryApplicationObjectId -or
                [string]$temporaryApplication.appId -cne [string]$canaryState.temporaryApplicationClientId -or
                @(Get-ApplicationsByExactDisplayName -DisplayName $childArmedDisplayName).Count -ne 0) {
                throw 'OwnerAddStarted no longer resolves to its exact PreChild application.'
            }
            Assert-ExactTemporaryApplication `
                -Application $temporaryApplication `
                -ExpectedDisplayName $preChildDisplayName `
                -ExpectedTag $executionTag `
                -ExpectedScopeId $script:gatewayApiAccessScopeId
            if ($null -ne (Get-ServicePrincipalByAppId -AppId ([string]$temporaryApplication.appId))) {
                throw 'OwnerAddStarted found downstream authority before its durable Started marker.'
            }
            $ownerIds = @(Get-TemporaryApplicationOwnerIds -ApplicationObjectId ([string]$temporaryApplication.id))
            if ($ownerIds.Count -ne 1 -or
                -not $ownerIds[0].Equals($TenantUserObjectId, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The owner-add outcome remains unobservable or mismatched. This Started stage is GET-only and the POST will not be repeated.'
            }
            $canaryState = Set-BoundedUserCanaryStateStatus `
                -State $canaryState `
                -Bindings $canaryBindings `
                -Status 'OwnerObserved'
            Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
        }

        if ([string]$canaryState.status -ceq 'OwnerObserved') {
            $temporaryApplication = Wait-ExactApplicationByName -DisplayName $preChildDisplayName
            if (-not $temporaryApplication -or
                @(Get-ApplicationsByExactDisplayName -DisplayName $childArmedDisplayName).Count -ne 0) {
                throw 'OwnerObserved no longer resolves to its exact PreChild application.'
            }
            Adopt-ExactTemporaryAuthority `
                -Application $temporaryApplication `
                -ExpectedDisplayName $preChildDisplayName `
                -State $canaryState
            if (-not [string]::IsNullOrEmpty($temporaryServicePrincipalId) -or
                -not [string]::IsNullOrEmpty($temporaryGrantId)) {
                throw 'OwnerObserved found downstream authority before its durable Started marker.'
            }
            $canaryState = Set-BoundedUserCanaryStateStatus `
                -State $canaryState `
                -Bindings $canaryBindings `
                -Status 'ServicePrincipalCreateStarted'
            Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
            try {
                Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/servicePrincipals' -Body @{
                    appId = $temporaryApplicationClientId
                    accountEnabled = $true
                    appRoleAssignmentRequired = $false
                    servicePrincipalNames = @($temporaryApplicationClientId)
                    tags = @($executionTag)
                } | Out-Null
            }
            catch { }
        }

        if ([string]$canaryState.status -ceq 'ServicePrincipalCreateStarted') {
            $temporaryApplication = Wait-ExactApplicationByName -DisplayName $preChildDisplayName
            if (-not $temporaryApplication -or
                @(Get-ApplicationsByExactDisplayName -DisplayName $childArmedDisplayName).Count -ne 0) {
                throw 'ServicePrincipalCreateStarted no longer resolves to its exact PreChild application.'
            }
            Adopt-ExactTemporaryAuthority `
                -Application $temporaryApplication `
                -ExpectedDisplayName $preChildDisplayName `
                -State $canaryState
            if ([string]::IsNullOrEmpty($temporaryServicePrincipalId)) {
                throw 'The service-principal-create outcome remains unobservable. This Started stage is GET-only and the POST will not be repeated.'
            }
            if (-not [string]::IsNullOrEmpty($temporaryGrantId)) {
                throw 'ServicePrincipalCreateStarted found a grant before its durable Started marker.'
            }
            $canaryState = Set-BoundedUserCanaryStateStatus `
                -State $canaryState `
                -Bindings $canaryBindings `
                -Status 'ServicePrincipalObserved' `
                -TemporaryServicePrincipalId $temporaryServicePrincipalId
            Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
        }

        if ([string]$canaryState.status -ceq 'ServicePrincipalObserved') {
            $temporaryApplication = Wait-ExactApplicationByName -DisplayName $preChildDisplayName
            if (-not $temporaryApplication -or
                @(Get-ApplicationsByExactDisplayName -DisplayName $childArmedDisplayName).Count -ne 0) {
                throw 'ServicePrincipalObserved no longer resolves to its exact PreChild application.'
            }
            Adopt-ExactTemporaryAuthority `
                -Application $temporaryApplication `
                -ExpectedDisplayName $preChildDisplayName `
                -State $canaryState
            if ([string]::IsNullOrEmpty($temporaryServicePrincipalId) -or
                -not [string]::IsNullOrEmpty($temporaryGrantId)) {
                throw 'ServicePrincipalObserved does not match its exact pre-grant authority boundary.'
            }
            $canaryState = Set-BoundedUserCanaryStateStatus `
                -State $canaryState `
                -Bindings $canaryBindings `
                -Status 'GrantCreateStarted'
            Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
            try {
                Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' -Body @{
                    clientId = $temporaryServicePrincipalId
                    consentType = 'Principal'
                    principalId = $TenantUserObjectId
                    resourceId = $script:gatewayApiServicePrincipalId
                    scope = 'access_as_user'
                } | Out-Null
            }
            catch { }
        }

        if ([string]$canaryState.status -ceq 'GrantCreateStarted') {
            $temporaryApplication = Wait-ExactApplicationByName -DisplayName $preChildDisplayName
            if (-not $temporaryApplication -or
                @(Get-ApplicationsByExactDisplayName -DisplayName $childArmedDisplayName).Count -ne 0) {
                throw 'GrantCreateStarted no longer resolves to its exact PreChild application.'
            }
            Adopt-ExactTemporaryAuthority `
                -Application $temporaryApplication `
                -ExpectedDisplayName $preChildDisplayName `
                -State $canaryState
            if ([string]::IsNullOrEmpty($temporaryGrantId)) {
                throw 'The delegated-grant-create outcome remains unobservable. This Started stage is GET-only and the POST will not be repeated.'
            }
            $canaryState = Set-BoundedUserCanaryStateStatus `
                -State $canaryState `
                -Bindings $canaryBindings `
                -Status 'AuthorityReady' `
                -TemporaryGrantId $temporaryGrantId
            Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
        }

        if ([string]$canaryState.status -ceq 'AuthorityReady') {
            $temporaryApplication = Wait-ExactApplicationByName -DisplayName $preChildDisplayName
            if (-not $temporaryApplication -or
                @(Get-ApplicationsByExactDisplayName -DisplayName $childArmedDisplayName).Count -ne 0) {
                throw 'AuthorityReady no longer resolves to its exact PreChild application.'
            }
            Adopt-ExactTemporaryAuthority `
                -Application $temporaryApplication `
                -ExpectedDisplayName $preChildDisplayName `
                -State $canaryState `
                -RequireComplete
            $canaryState = Set-BoundedUserCanaryStateStatus `
                -State $canaryState `
                -Bindings $canaryBindings `
                -Status 'ArmStarted'
            Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
            $recoveryBoundaryArmed = $true
            try {
                Invoke-GraphJsonBody `
                    -Method 'PATCH' `
                    -Url "https://graph.microsoft.com/v1.0/applications/$temporaryApplicationId" `
                    -Body @{ displayName = $childArmedDisplayName } | Out-Null
            }
            catch { }
        }

        if ([string]$canaryState.status -ceq 'ArmStarted') {
            $recoveryBoundaryArmed = $true
            $preserveTemporaryIdentity = $true
            $armedApplication = Wait-ExactApplicationByName -DisplayName $childArmedDisplayName
            $remainingPreChild = @(Get-ApplicationsByExactDisplayName -DisplayName $preChildDisplayName)
            if (-not $armedApplication) {
                if ($remainingPreChild.Count -eq 1) {
                    Adopt-ExactTemporaryAuthority `
                        -Application $remainingPreChild[0] `
                        -ExpectedDisplayName $preChildDisplayName `
                        -State $canaryState `
                        -RequireComplete
                }
                throw 'The arm PATCH outcome remains unobservable. This Started stage is GET-only and the PATCH will not be repeated.'
            }
            if ($remainingPreChild.Count -ne 0) {
                throw 'ArmStarted resolved both PreChild and ChildArmed application stages.'
            }
            Adopt-ExactTemporaryAuthority `
                -Application $armedApplication `
                -ExpectedDisplayName $childArmedDisplayName `
                -State $canaryState `
                -RequireComplete
            $temporaryDisplayName = $childArmedDisplayName
            $canaryState = Set-BoundedUserCanaryStateStatus `
                -State $canaryState `
                -Bindings $canaryBindings `
                -Status 'ChildArmed'
            Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
        }

        if ([string]$canaryState.status -ceq 'ChildArmed') {
            $recoveryBoundaryArmed = $true
            $preserveTemporaryIdentity = $true
            $armedApplications = @(Get-ApplicationsByExactDisplayName -DisplayName $childArmedDisplayName)
            if ($armedApplications.Count -ne 1 -or
                @(Get-ApplicationsByExactDisplayName -DisplayName $preChildDisplayName).Count -ne 0) {
                throw 'ChildArmed no longer resolves to one exact registration-bound application.'
            }
            Adopt-ExactTemporaryAuthority `
                -Application $armedApplications[0] `
                -ExpectedDisplayName $childArmedDisplayName `
                -State $canaryState `
                -RequireComplete
        }

        if ([string]$canaryState.status -cne 'ChildArmed') {
            throw 'The full canary did not reach the exact durable ChildArmed stage.'
        }
    }

    if (-not $completedTombstone) {
        if (-not $recoveryMode) {
            # Persist before process creation. If the process start or key issuance
            # is interrupted before an ID is observed, Full is permanently blocked.
            $canaryState = Set-BoundedUserCanaryStateStatus `
                -State $canaryState `
                -Bindings $canaryBindings `
                -Status 'ChildLaunchStarted'
            Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
        }
        $recoveryBoundaryArmed = $true
        $preserveTemporaryIdentity = $true

        $operationMode = if ($recoveryMode) { 'RevokeOnly' } else { 'Full' }
        $canaryArguments = @(
            $canaryAssembly,
            '--api-base-url', $ApiBaseUrl,
            '--api-application-client-id', $GatewayApiApplicationClientId,
            '--api-scope-base-uri', $expectedScopeBaseUri,
            '--tenant-id', $ExpectedTenantId,
            '--authentication-mode', 'InteractiveBrowserUser',
            '--authentication-client-id', $temporaryApplicationClientId,
            '--operation-mode', $operationMode,
            '--agent-registration-id', $AgentRegistrationId,
            '--external-agent-id', $ExternalAgentId,
            '--tenant-user-object-id', $TenantUserObjectId,
            '--expect-prompt-shield-enabled', ([bool]$ExpectPromptShieldEnabled).ToString().ToLowerInvariant(),
            '--expect-purview-enabled', ([bool]$ExpectPurviewEnabled).ToString().ToLowerInvariant()
        )
        if ($recoveryMode) {
            $canaryArguments += @('--recovery-credential-id', $RecoveryCredentialId)
        }

        & dotnet @canaryArguments 2>&1 | ForEach-Object {
            $childLine = [string]$_
            if ($childLine -cmatch '^\[PASS\] Temporary registration-bound credential issued: key ID ([0-9a-f-]{36})\.$') {
                if ($script:recoveryMode -or [string]$script:canaryState.status -cne 'ChildLaunchStarted') {
                    throw 'The canary child emitted a credential outside the exact Full child-launch boundary.'
                }
                $candidateCredentialId = [string]$Matches[1]
                Assert-CanonicalNonEmptyGuid -Value $candidateCredentialId -Label 'Issued credential ID'
                $script:canaryState = Set-BoundedUserCanaryStateStatus `
                    -State $script:canaryState `
                    -Bindings $script:canaryBindings `
                    -Status 'CredentialObserved' `
                    -RecoveryCredentialId $candidateCredentialId
                Save-BoundedUserCanaryState `
                    -State $script:canaryState `
                    -Path $script:canaryStatePath `
                    -Bindings $script:canaryBindings
                $script:issuedCredentialId = $candidateCredentialId
            }
            Write-Host $childLine
        }
        $childExitCode = $LASTEXITCODE
        if ($childExitCode -ne 0) {
            if ([string]$canaryState.status -ceq 'CredentialObserved') {
                throw "The bounded user canary failed after key ID $($canaryState.recoveryCredentialId) was durably observed. The temporary auth identity was preserved; rerun with that exact -RecoveryCredentialId value."
            }
            throw 'The bounded user canary failed after ChildLaunchStarted without a durably observed key ID. The temporary auth identity was preserved; do not issue another key. Inspect the registration credential lifecycle and perform exact manual recovery.'
        }

        if ([string]$canaryState.status -cne 'CredentialObserved') {
            throw 'The child returned success without the exact durable credential observation required for completion.'
        }
        $canaryState = Set-BoundedUserCanaryStateStatus `
            -State $canaryState `
            -Bindings $canaryBindings `
            -Status 'Completed'
        Save-BoundedUserCanaryState -State $canaryState -Path $canaryStatePath -Bindings $canaryBindings
        $preserveTemporaryIdentity = $false
        if ($recoveryMode) {
            Write-Host '[PASS] RevokeOnly recovery completed; temporary Entra cleanup is starting.'
        }
        else {
            Write-Host '[PASS] Bounded interactive-user canary completed; temporary Entra cleanup is starting.'
        }
    }
}
catch {
    $operationFailure = $_.Exception.Message
}
finally {
    try {
        if (-not $preserveTemporaryIdentity) {
            foreach ($cleanup in @(
                @{ label = 'delegated grant'; action = { Remove-ExactTemporaryGrant } },
                @{ label = 'service principal'; action = { Remove-ExactTemporaryServicePrincipal } },
                @{ label = 'active application'; action = { Remove-ExactTemporaryApplication } }
            )) {
                try {
                    & $cleanup.action
                }
                catch {
                    $cleanupFailures.Add("$($cleanup.label) cleanup failed safely; exact manual reconciliation is required.")
                }
            }
        }
        elseif ($recoveryBoundaryArmed) {
            Write-Warning '[RECOVERY REQUIRED] The registration-bound canary authority was preserved because exact Gateway-key revocation was not proven.'
        }
        else {
            Write-Warning '[RESUME REQUIRED] Exact PreChild canary authority was preserved at a durable GET-only stage; its external mutation will not be replayed.'
        }
        Clear-BootstrapAzureSubscriptionContext
    }
    finally {
        if ($null -ne $canaryLock) {
            $canaryLock.Dispose()
            $canaryLock = $null
        }
    }
}

if ($cleanupFailures.Count -ne 0) {
    throw ($cleanupFailures -join ' ')
}
if (-not [string]::IsNullOrWhiteSpace($operationFailure)) {
    throw $operationFailure
}

Write-Host '[PASS] Temporary canary grant, service principal, and active application are absent.'
