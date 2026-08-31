Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:GraphAppId = '00000003-0000-0000-c000-000000000000'
$script:KeyVaultSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

function Get-ExactApplicationByDisplayName {
    param([Parameter(Mandatory)][string]$DisplayName)
    $escaped = $DisplayName.Replace("'", "''")
    $filter = [Uri]::EscapeDataString("displayName eq '$escaped'")
    $applications = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId,displayName,signInAudience,identifierUris,tags,api,appRoles,requiredResourceAccess,passwordCredentials,keyCredentials,web,spa,publicClient,isFallbackPublicClient")
    if ($applications.Count -gt 1) { throw "More than one application is named '$DisplayName'; refusing ambiguous adoption." }
    if ($applications.Count -eq 1) { return $applications[0] }
    return $null
}

function Get-ServicePrincipalByAppId {
    param([Parameter(Mandatory)][string]$AppId)
    $filter = [Uri]::EscapeDataString("appId eq '$AppId'")
    $principals = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filter&`$select=id,appId,displayName,appRoles,oauth2PermissionScopes,passwordCredentials,keyCredentials,accountEnabled,appRoleAssignmentRequired,servicePrincipalType,servicePrincipalNames,tags,alternativeNames")
    if ($principals.Count -gt 1) { throw "Multiple service principals exist for application ID $AppId." }
    if ($principals.Count -eq 1) { return $principals[0] }
    return $null
}

function Get-ApplicationsByExactIdentifierUri {
    param([Parameter(Mandatory)][string]$IdentifierUri)

    if ([string]::IsNullOrWhiteSpace($IdentifierUri) -or $IdentifierUri.Length -gt 512) {
        throw 'Application identifier URI must be one bounded nonempty value.'
    }
    $escaped = $IdentifierUri.Replace("'", "''")
    $filter = [Uri]::EscapeDataString("identifierUris/any(uri:uri eq '$escaped')")
    $applications = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,identifierUris")
    foreach ($application in $applications) {
        $identifierUris = $null
        if ($application -is [System.Collections.IDictionary]) {
            if ($application.Contains('identifierUris')) { $identifierUris = $application['identifierUris'] }
        }
        else {
            $property = $application.PSObject.Properties['identifierUris']
            if ($null -ne $property) { $identifierUris = $property.Value }
        }
        if ($null -eq $identifierUris -or $identifierUris -is [string] -or
            $identifierUris -isnot [System.Collections.IEnumerable] -or
            -not (@($identifierUris) -ccontains $IdentifierUri)) {
            throw 'Microsoft Graph identifier-URI collision discovery returned an object outside the exact requested boundary.'
        }
    }
    return $applications
}

function Invoke-GraphJsonBody {
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)]$Body)
    $json = $Body | ConvertTo-Json -Depth 30 -Compress
    return Invoke-AzJson -Arguments @('rest', '--method', $Method, '--url', $Url, '--headers', 'Content-Type=application/json', '--body', $json)
}

function Invoke-AzJsonArray {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OperationLabel
    )
    $raw = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList ($Arguments + @('--output', 'json', '--only-show-errors'))
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "$OperationLabel returned no JSON array; absence was not proven."
    }
    try {
        $parsed = ConvertFrom-Json -InputObject $raw -Depth 100 -NoEnumerate -ErrorAction Stop
    }
    catch {
        throw "$OperationLabel returned malformed JSON; absence was not proven."
    }
    if ($parsed -isnot [System.Array]) {
        throw "$OperationLabel returned a non-array JSON contract; absence was not proven."
    }
    return $parsed
}

function Get-BoundedGraphCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InitialUrl,
        [ValidateRange(1, 100)][int]$MaximumPages = 20,
        [ValidateRange(1, 50000)][int]$MaximumItems = 10000
    )

    $initialUri = $null
    if (-not [Uri]::TryCreate($InitialUrl, [UriKind]::Absolute, [ref]$initialUri) -or
        $initialUri.Scheme -cne 'https' -or
        -not $initialUri.DnsSafeHost.Equals('graph.microsoft.com', [StringComparison]::OrdinalIgnoreCase) -or
        (-not $initialUri.IsDefaultPort -and $initialUri.Port -ne 443) -or
        -not [string]::IsNullOrEmpty($initialUri.UserInfo) -or
        -not [string]::IsNullOrEmpty($initialUri.Fragment) -or
        -not $initialUri.AbsolutePath.StartsWith('/v1.0/', [StringComparison]::Ordinal)) {
        throw 'Microsoft Graph collection URL must use the exact public-cloud HTTPS v1.0 origin.'
    }

    $collectionPath = $initialUri.AbsolutePath
    $nextUrl = $InitialUrl
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $items = [Collections.Generic.List[object]]::new()

    for ($page = 1; $page -le $MaximumPages; $page++) {
        $pageUri = $null
        if (-not [Uri]::TryCreate($nextUrl, [UriKind]::Absolute, [ref]$pageUri) -or
            $pageUri.Scheme -cne 'https' -or
            -not $pageUri.DnsSafeHost.Equals('graph.microsoft.com', [StringComparison]::OrdinalIgnoreCase) -or
            (-not $pageUri.IsDefaultPort -and $pageUri.Port -ne 443) -or
            -not [string]::IsNullOrEmpty($pageUri.UserInfo) -or
            -not [string]::IsNullOrEmpty($pageUri.Fragment) -or
            $pageUri.AbsolutePath -cne $collectionPath) {
            throw 'Microsoft Graph continuation left the exact HTTPS collection origin or path.'
        }
        if (-not $visited.Add($pageUri.AbsoluteUri)) {
            throw 'Microsoft Graph collection returned a repeated continuation URL.'
        }

        # Microsoft documents the continuation as opaque. Validate its trust
        # boundary above, then send the complete value without reconstructing it.
        $response = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', $nextUrl)
        if ($null -eq $response -or $null -eq $response.PSObject.Properties['value'] -or
            $response.value -isnot [System.Array]) {
            throw 'Microsoft Graph collection response did not contain the required value array.'
        }
        foreach ($item in @($response.value)) {
            if ($null -eq $item) { throw 'Microsoft Graph collection returned a null item.' }
            if ($items.Count -ge $MaximumItems) {
                throw "Microsoft Graph collection exceeded the bounded item limit of $MaximumItems."
            }
            $items.Add($item)
        }

        $nextProperty = $response.PSObject.Properties['@odata.nextLink']
        if ($null -eq $nextProperty -or $null -eq $nextProperty.Value -or
            [string]::IsNullOrWhiteSpace([string]$nextProperty.Value)) {
            return @($items)
        }
        $nextUrl = [string]$nextProperty.Value
    }

    throw "Microsoft Graph collection exceeded the bounded page limit of $MaximumPages."
}

function Get-OptionalObjectPropertyValue {
    param(
        [Parameter()][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$PropertyName
    )
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-OptionalFalseBooleanProperty {
    param(
        [Parameter()][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$PropertyName
    )
    $value = Get-OptionalObjectPropertyValue -InputObject $InputObject -PropertyName $PropertyName
    if ($null -eq $value) { return $true }
    return $value -is [bool] -and $value -eq $false
}

function Assert-ExactApplicationAuthenticationSurface {
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)][string]$ApplicationLabel
    )

    $api = Get-OptionalObjectPropertyValue -InputObject $Application -PropertyName 'api'
    $web = Get-OptionalObjectPropertyValue -InputObject $Application -PropertyName 'web'
    $implicit = Get-OptionalObjectPropertyValue -InputObject $web -PropertyName 'implicitGrantSettings'
    foreach ($boundary in @(
        [ordered]@{ object = $Application; property = 'isFallbackPublicClient' },
        [ordered]@{ object = $api; property = 'acceptMappedClaims' },
        [ordered]@{ object = $implicit; property = 'enableAccessTokenIssuance' },
        [ordered]@{ object = $implicit; property = 'enableIdTokenIssuance' }
    )) {
        if (-not (Test-OptionalFalseBooleanProperty -InputObject $boundary.object -PropertyName $boundary.property)) {
            throw "$ApplicationLabel exposes an unapproved public-client, mapped-claims, or implicit-grant authentication mode."
        }
    }
    foreach ($propertyName in @('preAuthorizedApplications', 'knownClientApplications')) {
        $value = Get-OptionalObjectPropertyValue -InputObject $api -PropertyName $propertyName
        if ($null -ne $value -and @($value).Count -ne 0) {
            throw "$ApplicationLabel exposes unapproved '$propertyName' client authority."
        }
    }
    return $true
}

function Assert-ExactBootstrapServicePrincipalBoundary {
    param(
        [Parameter(Mandatory)]$ServicePrincipal,
        [Parameter(Mandatory)][string]$ExpectedId,
        [Parameter(Mandatory)][string]$ExpectedAppId,
        [Parameter(Mandatory)][string]$ServicePrincipalLabel,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedServicePrincipalNames,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedTags,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ExpectedAppRoles,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ExpectedOauth2PermissionScopes,
        [Parameter()][string]$ExpectedAppRoleAssigneePrincipalId = '',
        [Parameter()][string]$ExpectedAppRoleId = '',
        [switch]$AllowMissingExpectedAppRoleAssignment
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedAppRoleAssigneePrincipalId) -ne
        [string]::IsNullOrWhiteSpace($ExpectedAppRoleId)) {
        throw "$ServicePrincipalLabel expected application-role assignment boundary is incomplete."
    }
    if (-not ([string]$ServicePrincipal.id).Equals($ExpectedId, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$ServicePrincipal.appId).Equals($ExpectedAppId, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$ServicePrincipalLabel identity does not match the exact expected service principal."
    }
    if ($ServicePrincipal.accountEnabled -isnot [bool] -or $ServicePrincipal.accountEnabled -ne $true -or
        $ServicePrincipal.appRoleAssignmentRequired -isnot [bool] -or $ServicePrincipal.appRoleAssignmentRequired -ne $false -or
        [string]$ServicePrincipal.servicePrincipalType -cne 'Application') {
        throw "$ServicePrincipalLabel is not the exact enabled application service-principal type and assignment mode."
    }
    foreach ($collectionBoundary in @(
        [ordered]@{ property = 'alternativeNames'; expected = @() },
        [ordered]@{ property = 'servicePrincipalNames'; expected = @($ExpectedServicePrincipalNames) },
        [ordered]@{ property = 'tags'; expected = @($ExpectedTags) }
    )) {
        $collectionProperty = $ServicePrincipal.PSObject.Properties[$collectionBoundary.property]
        if ($null -eq $collectionProperty -or $collectionProperty.Value -isnot [System.Array]) {
            throw "$ServicePrincipalLabel '$($collectionBoundary.property)' was not returned as an exact collection."
        }
        $actualValues = @($collectionProperty.Value | ForEach-Object { [string]$_ })
        if (-not (Test-ExactStringSet -Actual $actualValues -Expected @($collectionBoundary.expected))) {
            throw "$ServicePrincipalLabel '$($collectionBoundary.property)' is outside the exact reviewed boundary."
        }
    }
    foreach ($credentialPropertyName in @('passwordCredentials', 'keyCredentials')) {
        $credentialProperty = $ServicePrincipal.PSObject.Properties[$credentialPropertyName]
        if ($null -eq $credentialProperty -or $credentialProperty.Value -isnot [System.Array]) {
            throw "$ServicePrincipalLabel '$credentialPropertyName' was not returned as an exact collection; credential absence was not proven."
        }
        if (@($credentialProperty.Value).Count -ne 0) {
            throw "$ServicePrincipalLabel must not contain service-principal credentials."
        }
    }
    foreach ($permissionBoundary in @(
        [ordered]@{ property = 'appRoles'; expected = @($ExpectedAppRoles); allowedMemberTypes = $true },
        [ordered]@{ property = 'oauth2PermissionScopes'; expected = @($ExpectedOauth2PermissionScopes); allowedMemberTypes = $false }
    )) {
        $permissionProperty = $ServicePrincipal.PSObject.Properties[$permissionBoundary.property]
        if ($null -eq $permissionProperty -or $permissionProperty.Value -isnot [System.Array]) {
            throw "$ServicePrincipalLabel '$($permissionBoundary.property)' was not returned as an exact collection."
        }
        $actualPermissions = @($permissionProperty.Value)
        if ($actualPermissions.Count -ne @($permissionBoundary.expected).Count) {
            throw "$ServicePrincipalLabel exposes an unapproved service-principal-local permission."
        }
        foreach ($expectedPermission in @($permissionBoundary.expected)) {
            $matches = @($actualPermissions | Where-Object {
                ([string]$_.id).Equals([string]$expectedPermission.id, [StringComparison]::OrdinalIgnoreCase)
            })
            if ($matches.Count -ne 1 -or
                [string]$matches[0].value -cne [string]$expectedPermission.value -or
                $matches[0].isEnabled -isnot [bool] -or
                $matches[0].isEnabled -ne $expectedPermission.isEnabled) {
                throw "$ServicePrincipalLabel exposes an unapproved service-principal-local permission."
            }
            if ($permissionBoundary.allowedMemberTypes) {
                $actualMemberTypes = @($matches[0].allowedMemberTypes | ForEach-Object { [string]$_ })
                $expectedMemberTypes = @($expectedPermission.allowedMemberTypes | ForEach-Object { [string]$_ })
                if (-not (Test-ExactStringSet -Actual $actualMemberTypes -Expected $expectedMemberTypes)) {
                    throw "$ServicePrincipalLabel exposes an unapproved service-principal-local application role."
                }
            }
            elseif ([string]$matches[0].type -cne [string]$expectedPermission.type) {
                throw "$ServicePrincipalLabel exposes an unapproved service-principal-local delegated scope."
            }
        }
    }

    $owners = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals/$ExpectedId/owners?`$select=id")
    if ($owners.Count -ne 0) {
        throw "$ServicePrincipalLabel must not have service-principal owners."
    }
    $memberships = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals/$ExpectedId/transitiveMemberOf?`$select=id")
    if ($memberships.Count -ne 0) {
        throw "$ServicePrincipalLabel must not have group or directory-role memberships."
    }
    $clientAssignments = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals/$ExpectedId/appRoleAssignments?`$select=id,principalId,resourceId,appRoleId")
    if ($clientAssignments.Count -ne 0) {
        throw "$ServicePrincipalLabel must not have client application-role assignments."
    }

    # This collection is intentionally unfiltered. Filtering to the expected
    # operator would conceal another user, group, or service principal holding a
    # Gateway role on a later page.
    $resourceAssignments = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals/$ExpectedId/appRoleAssignedTo?`$select=id,principalId,resourceId,appRoleId")
    $expectsAssignment = -not [string]::IsNullOrWhiteSpace($ExpectedAppRoleAssigneePrincipalId)
    if (-not $expectsAssignment) {
        if ($resourceAssignments.Count -ne 0) {
            throw "$ServicePrincipalLabel has an unauthorized application-role assignee."
        }
    }
    else {
        $matchingAssignments = @($resourceAssignments | Where-Object {
            ([string]$_.principalId).Equals($ExpectedAppRoleAssigneePrincipalId, [StringComparison]::OrdinalIgnoreCase) -and
            ([string]$_.resourceId).Equals($ExpectedId, [StringComparison]::OrdinalIgnoreCase) -and
            ([string]$_.appRoleId).Equals($ExpectedAppRoleId, [StringComparison]::OrdinalIgnoreCase)
        })
        $minimumCount = if ($AllowMissingExpectedAppRoleAssignment) { 0 } else { 1 }
        if ($resourceAssignments.Count -gt 1 -or
            $resourceAssignments.Count -lt $minimumCount -or
            $matchingAssignments.Count -ne $resourceAssignments.Count) {
            throw "$ServicePrincipalLabel application-role assignees are outside the exact reviewed boundary."
        }
    }

    return [ordered]@{ appRoleAssignedTo = @($resourceAssignments) }
}

function Get-BootstrapApplicationTags {
    param([Parameter(Mandatory)][string]$DeploymentOwnershipId)
    Assert-GuidValue -Value $DeploymentOwnershipId -Label 'Deployment ownership identifier'
    return @(
        'A365GatewayBootstrap',
        "A365GatewayOwnership:$(([guid]$DeploymentOwnershipId).ToString('D'))"
    )
}

function Get-AdminUiGatewayApplicationRoles {
    param([Parameter(Mandatory)][string]$DeploymentOwnershipId)

    Assert-GuidValue -Value $DeploymentOwnershipId -Label 'Deployment ownership identifier'
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    $contracts = @(
        [ordered]@{
            displayName = 'Gateway Administrator'
            description = 'Full Gateway control-plane administration.'
            canonicalValue = 'Gateway.Administrator'
            value = 'Administrator'
        },
        [ordered]@{
            displayName = 'Gateway Operator'
            description = 'Operate registrations and provisioning.'
            canonicalValue = 'Gateway.Operator'
            value = 'Operator'
        },
        [ordered]@{
            displayName = 'Gateway Auditor'
            description = 'Read Gateway audit and configuration state.'
            canonicalValue = 'Gateway.Auditor'
            value = 'Auditor'
        },
        [ordered]@{
            displayName = 'Gateway Support Reader'
            description = 'Read redacted health and diagnostics.'
            canonicalValue = 'Gateway.SupportReader'
            value = 'Reader'
        }
    )
    return @($contracts | ForEach-Object {
        [ordered]@{
            id = Get-BootstrapDeterministicGuid -Material "a365gw-bootstrap-admin-ui-role-v1|$canonicalOwnershipId|$($_.canonicalValue)"
            displayName = [string]$_.displayName
            description = [string]$_.description
            value = [string]$_.value
            allowedMemberTypes = @('User')
            isEnabled = $true
        }
    })
}

function Assert-ExactAdminUiGatewayRoleContract {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AppRoles,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId
    )

    $expectedRoles = @(Get-AdminUiGatewayApplicationRoles -DeploymentOwnershipId $DeploymentOwnershipId)
    if ($AppRoles.Count -ne $expectedRoles.Count) {
        throw 'Admin UI application must publish exactly the four canonical user-only Gateway roles.'
    }
    foreach ($expectedRole in $expectedRoles) {
        $matches = @($AppRoles | Where-Object {
            ([string]$_.id).Equals([string]$expectedRole.id, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -ne 1 -or
            [string]$matches[0].displayName -cne [string]$expectedRole.displayName -or
            [string]$matches[0].description -cne [string]$expectedRole.description -or
            [string]$matches[0].value -cne [string]$expectedRole.value -or
            $matches[0].isEnabled -isnot [bool] -or $matches[0].isEnabled -ne $true -or
            @($matches[0].allowedMemberTypes).Count -ne 1 -or
            [string]$matches[0].allowedMemberTypes[0] -cne 'User') {
            throw 'Admin UI application must publish exactly the four canonical user-only Gateway roles.'
        }
    }
    return $expectedRoles
}

function Test-ExactStringSet {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Actual, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Expected)
    $actualSorted = @($Actual | Sort-Object -Unique)
    $expectedSorted = @($Expected | Sort-Object -Unique)
    return $Actual.Count -eq $Expected.Count -and ($actualSorted -join '|') -ceq ($expectedSorted -join '|')
}

function Assert-BootstrapApplicationOwnership {
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$OwnerObjectId,
        [switch]$AllowAddMissingOwner
    )

    Assert-GuidValue -Value $OwnerObjectId -Label 'Bootstrap application owner object ID'
    $expectedTags = Get-BootstrapApplicationTags -DeploymentOwnershipId $DeploymentOwnershipId
    if (-not (Test-ExactStringSet -Actual @($Application.tags | ForEach-Object { [string]$_ }) -Expected $expectedTags)) {
        throw 'An Entra application with the requested identity already exists without the exact unguessable bootstrap ownership marker; refusing adoption.'
    }

    $ownersUrl = "https://graph.microsoft.com/v1.0/applications/$($Application.id)/owners?`$select=id"
    $ownerIds = @(Get-BoundedGraphCollection -InitialUrl $ownersUrl | ForEach-Object { [string]$_.id })
    if ($ownerIds.Count -eq 0 -and $AllowAddMissingOwner) {
        Invoke-GraphJsonBody -Method 'POST' -Url "https://graph.microsoft.com/v1.0/applications/$($Application.id)/owners/`$ref" -Body @{
            '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$OwnerObjectId"
        } | Out-Null
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            $ownerIds = @(Get-BoundedGraphCollection -InitialUrl $ownersUrl | ForEach-Object { [string]$_.id })
            if ($ownerIds.Count -eq 1 -and $ownerIds[0].Equals($OwnerObjectId, [StringComparison]::OrdinalIgnoreCase)) { break }
            if ($attempt -lt 12) { Start-Sleep -Seconds 5 }
        }
    }
    if ($ownerIds.Count -ne 1 -or -not $ownerIds[0].Equals($OwnerObjectId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The bootstrap-managed Entra application must have exactly the pinned bootstrap operator as owner; refusing ambiguous or third-party ownership.'
    }
    return $true
}

function Get-GraphPermissionCatalog {
    $graph = Get-ServicePrincipalByAppId -AppId $script:GraphAppId
    if (-not $graph) { throw 'Microsoft Graph service principal was not found in the tenant.' }
    return [ordered]@{ servicePrincipal = $graph }
}

function Get-UniqueGraphPermissionId {
    param(
        [Parameter(Mandatory)]$Graph,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][ValidateSet('Scope', 'Role')][string]$Type
    )
    $published = if ($Type -eq 'Scope') {
        @($Graph.oauth2PermissionScopes | Where-Object { $_.isEnabled -eq $true -and [string]$_.value -eq $Value })
    }
    else {
        @($Graph.appRoles | Where-Object { $_.isEnabled -eq $true -and [string]$_.value -eq $Value -and @($_.allowedMemberTypes) -contains 'Application' })
    }
    if ($published.Count -ne 1) { throw "Microsoft Graph $Type '$Value' was not uniquely available." }
    return [string]$published[0].id
}

function Assert-GatewayApiDelegatedPermissionBoundary {
    param(
        [Parameter(Mandatory)]$Identity,
        [switch]$RequireComplete
    )

    $graph = (Get-GraphPermissionCatalog).servicePrincipal
    $requiredValues = @('AgentRegistration.Read.All', 'AgentRegistration.ReadWrite.All')
    $requiredIds = @($requiredValues | ForEach-Object { Get-UniqueGraphPermissionId -Graph $graph -Value $_ -Type Scope })
    $application = Invoke-AzJson -Arguments @(
        'rest', '--method', 'GET', '--url',
        "https://graph.microsoft.com/v1.0/applications/$($Identity.gatewayApiApplicationObjectId)?`$select=id,appId,api,requiredResourceAccess,passwordCredentials,keyCredentials,web,spa,publicClient,isFallbackPublicClient"
    )
    Assert-ExactApplicationAuthenticationSurface -Application $application -ApplicationLabel 'Gateway API application' | Out-Null
    if ([string]$application.appId -ne [string]$Identity.gatewayApiClientId -or
        @($application.passwordCredentials).Count -ne 0 -or
        @($application.keyCredentials).Count -ne 0 -or
        @($application.web.redirectUris).Count -ne 0 -or
        -not [string]::IsNullOrWhiteSpace([string]$application.web.logoutUrl) -or
        -not [string]::IsNullOrWhiteSpace([string]$application.web.homePageUrl) -or
        @($application.spa.redirectUris).Count -ne 0 -or
        @($application.publicClient.redirectUris).Count -ne 0) {
        throw 'Gateway API application identity or credential boundary is not exact.'
    }
    $requirements = @($application.requiredResourceAccess)
    if ($requirements.Count -gt 1 -or
        ($requirements.Count -eq 1 -and -not ([string]$requirements[0].resourceAppId).Equals($script:GraphAppId, [StringComparison]::OrdinalIgnoreCase))) {
        throw 'Gateway API requiredResourceAccess contains an unapproved resource or duplicate Graph entry.'
    }
    $actualIds = @()
    if ($requirements.Count -eq 1) {
        $access = @($requirements[0].resourceAccess)
        if (@($access | Where-Object { [string]$_.type -cne 'Scope' -or [string]$_.id -notin $requiredIds }).Count -gt 0) {
            throw 'Gateway API requiredResourceAccess contains an unapproved Microsoft Graph permission.'
        }
        $actualIds = @($access | ForEach-Object { [string]$_.id })
        if (@($actualIds | Sort-Object -Unique).Count -ne $actualIds.Count) { throw 'Gateway API requiredResourceAccess contains duplicate permissions.' }
    }
    if ($RequireComplete -and -not (Test-ExactStringSet -Actual $actualIds -Expected $requiredIds)) {
        throw 'Gateway API requiredResourceAccess is not the exact two-scope delegated Registry boundary.'
    }

    $grants = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId%20eq%20'$($Identity.gatewayApiServicePrincipalId)'&`$select=id,clientId,resourceId,consentType,scope")
    if ($grants.Count -gt 1) { throw 'Gateway API has more than one delegated permission grant; refusing an ambiguous consent boundary.' }
    $grantScopes = @()
    if ($grants.Count -eq 1) {
        if (-not ([string]$grants[0].resourceId).Equals([string]$graph.id, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$grants[0].consentType -cne 'AllPrincipals') {
            throw 'Gateway API has a delegated grant outside the exact tenant-wide Microsoft Graph boundary.'
        }
        $grantScopes = @(([string]$grants[0].scope).Split(' ', [StringSplitOptions]::RemoveEmptyEntries -bor [StringSplitOptions]::TrimEntries))
        if (@($grantScopes | Where-Object { $_ -notin $requiredValues }).Count -gt 0 -or
            @($grantScopes | Sort-Object -Unique).Count -ne $grantScopes.Count) {
            throw 'Gateway API delegated consent contains an unapproved or duplicate scope.'
        }
    }
    if ($RequireComplete -and -not (Test-ExactStringSet -Actual $grantScopes -Expected $requiredValues)) {
        throw 'Gateway API delegated consent is not the exact two-scope Registry boundary.'
    }
    return $true
}

function Assert-GraphApplicationRoleAssignmentBoundary {
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedRoleValues,
        [switch]$RequireComplete
    )
    $graph = (Get-GraphPermissionCatalog).servicePrincipal
    $expectedIds = @($ExpectedRoleValues | ForEach-Object { Get-UniqueGraphPermissionId -Graph $graph -Value $_ -Type Role })
    $assignments = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments?`$select=id,resourceId,appRoleId")
    if (@($assignments | Where-Object {
        -not ([string]$_.resourceId).Equals([string]$graph.id, [StringComparison]::OrdinalIgnoreCase) -or [string]$_.appRoleId -notin $expectedIds
    }).Count -gt 0) {
        throw 'Managed identity has an application-role assignment outside the exact reviewed Microsoft Graph boundary.'
    }
    $actualIds = @($assignments | ForEach-Object { [string]$_.appRoleId })
    if (@($actualIds | Sort-Object -Unique).Count -ne $actualIds.Count) {
        throw 'Managed identity has duplicate Microsoft Graph application-role assignments.'
    }
    if ($RequireComplete -and -not (Test-ExactStringSet -Actual $actualIds -Expected $expectedIds)) {
        throw 'Managed identity Microsoft Graph application roles do not exactly match the reviewed allowlist.'
    }
    return $true
}

function Assert-ExactGraphApplicationRoleAssignments {
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedRoleValues
    )
    return Assert-GraphApplicationRoleAssignmentBoundary -PrincipalId $PrincipalId -ExpectedRoleValues $ExpectedRoleValues -RequireComplete
}

function Assert-GatewayFederatedCredentialBoundary {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$ApiPrincipalId,
        [switch]$AllowMissing
    )

    $ficName = "a365gw-$($Config.projectName)-api-obo-$($Config.environment)"
    $fics = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/applications/$($Identity.gatewayApiApplicationObjectId)/federatedIdentityCredentials?`$select=id,name,issuer,subject,audiences")
    if ($fics.Count -eq 0 -and $AllowMissing) { return $true }
    if ($fics.Count -ne 1 -or [string]$fics[0].name -cne $ficName -or
        [string]$fics[0].issuer -cne "https://login.microsoftonline.com/$($Config.tenantId)/v2.0" -or
        -not ([string]$fics[0].subject).Equals($ApiPrincipalId, [StringComparison]::OrdinalIgnoreCase) -or
        @($fics[0].audiences).Count -ne 1 -or [string]$fics[0].audiences[0] -cne 'api://AzureADTokenExchange') {
        throw 'Gateway API federated credentials are outside the reviewed empty-or-one exact managed-identity OBO boundary.'
    }
    return $true
}

function Ensure-ServicePrincipal {
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ServicePrincipalNames,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tags
    )
    $principal = Get-ServicePrincipalByAppId -AppId $AppId
    if (-not $principal) {
        Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/servicePrincipals' -Body @{
            appId = $AppId
            accountEnabled = $true
            appRoleAssignmentRequired = $false
            servicePrincipalNames = @($ServicePrincipalNames)
            tags = @($Tags)
        } | Out-Null
        for ($attempt = 1; $attempt -le 12 -and -not $principal; $attempt++) {
            Start-Sleep -Seconds 5
            $principal = Get-ServicePrincipalByAppId -AppId $AppId
        }
    }
    if (-not $principal) { throw "Service principal for application $AppId was not observable after creation." }
    return $principal
}

function Ensure-GatewayApiApplication {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AzureIdentity,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [switch]$ReconcileOnly
    )
    # Entra application display names and identifier URIs are tenant-scoped. The
    # environment alone is not a safe deployment identity when a tenant hosts more
    # than one Gateway, so bind both to the configured project discriminator.
    $displayName = "A365 Gateway API - $($Config.projectName)-$($Config.environment)"
    $audience = "api://a365-gateway-$($Config.projectName)-$($Config.environment)"
    $application = Get-ExactApplicationByDisplayName -DisplayName $displayName
    if (-not $application) {
        $audienceMatches = @(Get-ApplicationsByExactIdentifierUri -IdentifierUri $audience)
        if ($audienceMatches.Count -gt 0) { throw "The requested Gateway API audience '$audience' is already owned by an application that is not bound to this bootstrap state; refusing adoption." }
        if ($ReconcileOnly) { throw 'The state-owned Gateway API application was not observable during read-only reconciliation.' }
    }
    if (-not $application) {
        $roles = @(
            @{ id = [guid]::NewGuid(); displayName = 'Gateway Administrator'; description = 'Full Gateway control-plane administration.'; value = 'Gateway.Administrator'; allowedMemberTypes = @('User'); isEnabled = $true },
            @{ id = [guid]::NewGuid(); displayName = 'Gateway Operator'; description = 'Operate registrations and provisioning.'; value = 'Gateway.Operator'; allowedMemberTypes = @('User'); isEnabled = $true },
            @{ id = [guid]::NewGuid(); displayName = 'Gateway Auditor'; description = 'Read Gateway audit and configuration state.'; value = 'Gateway.Auditor'; allowedMemberTypes = @('User'); isEnabled = $true },
            @{ id = [guid]::NewGuid(); displayName = 'Gateway Support Reader'; description = 'Read redacted health and diagnostics.'; value = 'Gateway.SupportReader'; allowedMemberTypes = @('User'); isEnabled = $true }
        )
        $scopeId = [guid]::NewGuid()
        $application = Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/applications' -Body @{
            displayName = $displayName
            signInAudience = 'AzureADMyOrg'
            identifierUris = @($audience)
            tags = Get-BootstrapApplicationTags -DeploymentOwnershipId $DeploymentOwnershipId
            isFallbackPublicClient = $false
            web = @{ implicitGrantSettings = @{ enableAccessTokenIssuance = $false; enableIdTokenIssuance = $false } }
            api = @{ requestedAccessTokenVersion = 2; acceptMappedClaims = $false; preAuthorizedApplications = @(); knownClientApplications = @(); oauth2PermissionScopes = @(@{
                id = $scopeId; value = 'access_as_user'; type = 'Admin'; isEnabled = $true
                adminConsentDisplayName = 'Access the A365 Gateway'
                adminConsentDescription = 'Allows the Admin UI to access the A365 Gateway on behalf of the signed-in user.'
                userConsentDisplayName = 'Access the A365 Gateway'
                userConsentDescription = 'Allows this application to access the A365 Gateway on your behalf.'
            }) }
            appRoles = $roles
        }
    }
    $application = Invoke-AzJson -Arguments @(
        'rest', '--method', 'GET', '--url',
        "https://graph.microsoft.com/v1.0/applications/$($application.id)?`$select=id,appId,displayName,signInAudience,identifierUris,tags,api,appRoles,requiredResourceAccess,passwordCredentials,keyCredentials,web,spa,publicClient,isFallbackPublicClient"
    )
    Assert-ExactApplicationAuthenticationSurface -Application $application -ApplicationLabel 'Gateway API application' | Out-Null
    if ([string]$application.displayName -cne $displayName -or
        [string]$application.signInAudience -cne 'AzureADMyOrg' -or
        @($application.identifierUris).Count -ne 1 -or
        [string]$application.identifierUris[0] -cne $audience -or
        @($application.passwordCredentials).Count -ne 0 -or
        @($application.keyCredentials).Count -ne 0 -or
        @($application.web.redirectUris).Count -ne 0 -or
        -not [string]::IsNullOrWhiteSpace([string]$application.web.logoutUrl) -or
        -not [string]::IsNullOrWhiteSpace([string]$application.web.homePageUrl) -or
        @($application.spa.redirectUris).Count -ne 0 -or
        @($application.publicClient.redirectUris).Count -ne 0 -or
        [int]$application.api.requestedAccessTokenVersion -ne 2) {
        throw 'Gateway API application does not match the exact single-tenant, credential-free audience boundary.'
    }
    $scope = @($application.api.oauth2PermissionScopes | Where-Object value -eq 'access_as_user')
    if (@($application.api.oauth2PermissionScopes).Count -ne 1 -or $scope.Count -ne 1 -or
        $scope[0].isEnabled -ne $true -or [string]$scope[0].type -cne 'Admin') {
        throw 'Gateway API must publish exactly the enabled admin-consent access_as_user scope.'
    }
    $expectedRoleValues = @('Gateway.Administrator', 'Gateway.Operator', 'Gateway.Auditor', 'Gateway.SupportReader')
    $actualRoleValues = @($application.appRoles | ForEach-Object { [string]$_.value })
    if (-not (Test-ExactStringSet -Actual $actualRoleValues -Expected $expectedRoleValues) -or
        @($application.appRoles | Where-Object { $_.isEnabled -ne $true -or @($_.allowedMemberTypes).Count -ne 1 -or [string]$_.allowedMemberTypes[0] -cne 'User' }).Count -gt 0) {
        throw 'Gateway API must publish exactly the four user-only Gateway roles.'
    }
    # Ownership repair is permitted only after the immutable application shape
    # has passed exact readback.
    Assert-BootstrapApplicationOwnership -Application $application -DeploymentOwnershipId $DeploymentOwnershipId -OwnerObjectId ([string]$AzureIdentity.userObjectId) -AllowAddMissingOwner:(-not $ReconcileOnly) | Out-Null
    $adminRole = @($application.appRoles | Where-Object value -eq 'Gateway.Administrator')
    $expectedServicePrincipalTags = @(Get-BootstrapApplicationTags -DeploymentOwnershipId $DeploymentOwnershipId)
    $principal = if ($ReconcileOnly) {
        Get-ServicePrincipalByAppId -AppId ([string]$application.appId)
    }
    else {
        Ensure-ServicePrincipal `
            -AppId ([string]$application.appId) `
            -ServicePrincipalNames @([string]$application.appId, $audience) `
            -Tags $expectedServicePrincipalTags
    }
    if (-not $principal) { throw 'Gateway API service principal was not observable during read-only reconciliation.' }
    $gatewayApiServicePrincipalId = [string]$principal.id
    $principalBoundaryArguments = @{
        ServicePrincipal = $principal
        ExpectedId = $gatewayApiServicePrincipalId
        ExpectedAppId = [string]$application.appId
        ServicePrincipalLabel = 'Gateway API service principal'
        ExpectedServicePrincipalNames = @([string]$application.appId, $audience)
        ExpectedTags = $expectedServicePrincipalTags
        ExpectedAppRoles = @($application.appRoles)
        ExpectedOauth2PermissionScopes = @($application.api.oauth2PermissionScopes)
        ExpectedAppRoleAssigneePrincipalId = [string]$AzureIdentity.userObjectId
        ExpectedAppRoleId = [string]$adminRole[0].id
    }
    $principalBoundary = Assert-ExactBootstrapServicePrincipalBoundary @principalBoundaryArguments -AllowMissingExpectedAppRoleAssignment
    $gatewayApiIdentityBoundary = [ordered]@{
        gatewayApiApplicationObjectId = [string]$application.id
        gatewayApiClientId = [string]$application.appId
        gatewayApiServicePrincipalId = $gatewayApiServicePrincipalId
    }
    Assert-GatewayApiDelegatedPermissionBoundary -Identity $gatewayApiIdentityBoundary | Out-Null
    $userAssignments = @($principalBoundary.appRoleAssignedTo)
    if ($userAssignments.Count -eq 0) {
        if ($ReconcileOnly) { throw 'Gateway Administrator assignment was not observable during read-only reconciliation.' }
        Invoke-GraphJsonBody -Method 'POST' -Url "https://graph.microsoft.com/v1.0/servicePrincipals/$($principal.id)/appRoleAssignedTo" -Body @{
            principalId = [string]$AzureIdentity.userObjectId
            resourceId = [string]$principal.id
            appRoleId = [string]$adminRole[0].id
        } | Out-Null
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            $principal = Get-ServicePrincipalByAppId -AppId ([string]$application.appId)
            if (-not $principal) { throw 'Gateway API service principal disappeared during exact role-assignment readback.' }
            $principalBoundaryArguments.ServicePrincipal = $principal
            $principalBoundary = Assert-ExactBootstrapServicePrincipalBoundary @principalBoundaryArguments -AllowMissingExpectedAppRoleAssignment
            $userAssignments = @($principalBoundary.appRoleAssignedTo)
            if ($userAssignments.Count -eq 1) { break }
            if ($attempt -lt 12) { Start-Sleep -Seconds 5 }
        }
        if ($userAssignments.Count -ne 1) {
            throw 'The exact Gateway Administrator assignment was not observable after creation.'
        }
    }
    $principal = Get-ServicePrincipalByAppId -AppId ([string]$application.appId)
    if (-not $principal) { throw 'Gateway API service principal disappeared during final exact readback.' }
    $principalBoundaryArguments.ServicePrincipal = $principal
    Assert-ExactBootstrapServicePrincipalBoundary @principalBoundaryArguments | Out-Null
    Assert-GatewayApiDelegatedPermissionBoundary -Identity $gatewayApiIdentityBoundary | Out-Null
    return [ordered]@{
        gatewayApiApplicationObjectId = [string]$application.id
        gatewayApiClientId = [string]$application.appId
        gatewayApiServicePrincipalId = [string]$principal.id
        gatewayApiScopeBaseUri = $audience
        gatewayApiTokenAudience = [string]$application.appId
        gatewayApiAccessScopeId = [string]$scope[0].id
        gatewayAdministratorRoleId = [string]$adminRole[0].id
        deploymentOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
        ownerObjectId = [string]$AzureIdentity.userObjectId
        userObjectId = [string]$AzureIdentity.userObjectId
        userPrincipalName = [string]$AzureIdentity.userPrincipalName
    }
}

function Ensure-GraphApplicationRoleAssignment {
    param([Parameter(Mandatory)][string]$PrincipalId, [Parameter(Mandatory)][string]$RoleValue)
    $graph = Get-ServicePrincipalByAppId -AppId $script:GraphAppId
    if (-not $graph) { throw 'Microsoft Graph service principal was not found in the tenant.' }
    $role = @($graph.appRoles | Where-Object { $_.value -eq $RoleValue -and $_.isEnabled -eq $true -and @($_.allowedMemberTypes) -contains 'Application' })
    if ($role.Count -ne 1) { throw "Microsoft Graph application role '$RoleValue' was not uniquely available." }
    $existing = @(Get-BoundedGraphCollection -InitialUrl "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments?`$select=id,resourceId,appRoleId")
    if (@($existing | Where-Object { [string]$_.resourceId -eq [string]$graph.id -and [string]$_.appRoleId -eq [string]$role[0].id }).Count -eq 0) {
        Invoke-GraphJsonBody -Method 'POST' -Url "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" -Body @{
            principalId = $PrincipalId; resourceId = [string]$graph.id; appRoleId = [string]$role[0].id
        } | Out-Null
    }
    return [string]$role[0].id
}

function Configure-GatewayWorkloadIdentity {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$ApiPrincipalId,
        [Parameter(Mandatory)][string]$WorkerPrincipalId,
        [switch]$EnablePurview
    )
    $root = Get-BootstrapExecutionSourceRoot
    $federatedCredentialName = "a365gw-$($Config.projectName)-api-obo-$($Config.environment)"
    $workerRoles = @(
        'Application.Read.All',
        'AppRoleAssignment.ReadWrite.All',
        'AgentIdentityBlueprint.Create',
        'AgentIdentityBlueprint.AddRemoveCreds.All',
        'AgentIdentityBlueprintPrincipal.Create',
        'AgentIdentityBlueprint.Read.All',
        'AgentIdentity.Create.All',
        'AgentIdentity.Read.All'
    )
    $apiRoles = [Collections.Generic.List[string]]::new()
    $apiRoles.Add('AgentIdentityBlueprint.Read.All')
    if ($EnablePurview) {
        foreach ($role in @('ProtectionScopes.Compute.User', 'Content.Process.User', 'ContentActivity.Write')) { $apiRoles.Add($role) }
    }
    # Reject unknown requested permissions or grants before making any Entra
    # mutation. Missing members of the reviewed sets may be added below, but an
    # extra FIC or application-role assignment requires explicit runbook recovery.
    Assert-GatewayApiDelegatedPermissionBoundary -Identity $Identity | Out-Null
    Assert-GatewayFederatedCredentialBoundary -Config $Config -Identity $Identity -ApiPrincipalId $ApiPrincipalId -AllowMissing | Out-Null
    Assert-GraphApplicationRoleAssignmentBoundary -PrincipalId $WorkerPrincipalId -ExpectedRoleValues $workerRoles | Out-Null
    Assert-GraphApplicationRoleAssignmentBoundary -PrincipalId $ApiPrincipalId -ExpectedRoleValues @($apiRoles) | Out-Null
    & (Join-Path $root 'tools/configure-workflow-v3-entra.ps1') `
        -ExpectedSubscriptionId ([guid]$Config.subscriptionId) `
        -ExpectedTenantId ([guid]$Config.tenantId) `
        -GatewayApiApplicationClientId ([guid]$Identity.gatewayApiClientId) `
        -GatewayApiManagedIdentityPrincipalId ([guid]$ApiPrincipalId) `
        -WorkerManagedIdentityPrincipalId ([guid]$WorkerPrincipalId) `
        -FederatedCredentialName $federatedCredentialName `
        -RequireNoDestructiveChanges `
        -Apply | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Workflow-v3 Entra configuration failed.' }
    $workerRoleIds = [ordered]@{}
    foreach ($role in $workerRoles) { $workerRoleIds[$role] = Ensure-GraphApplicationRoleAssignment -PrincipalId $WorkerPrincipalId -RoleValue $role }
    $apiRoleIds = [ordered]@{}
    foreach ($role in $apiRoles) { $apiRoleIds[$role] = Ensure-GraphApplicationRoleAssignment -PrincipalId $ApiPrincipalId -RoleValue $role }
    Assert-GatewayApiDelegatedPermissionBoundary -Identity $Identity -RequireComplete | Out-Null
    Assert-ExactGraphApplicationRoleAssignments -PrincipalId $WorkerPrincipalId -ExpectedRoleValues $workerRoles | Out-Null
    Assert-ExactGraphApplicationRoleAssignments -PrincipalId $ApiPrincipalId -ExpectedRoleValues @($apiRoles) | Out-Null
    Assert-GatewayFederatedCredentialBoundary -Config $Config -Identity $Identity -ApiPrincipalId $ApiPrincipalId | Out-Null
    return Get-GatewayWorkloadIdentityEvidence -Config $Config -Identity $Identity -ApiPrincipalId $ApiPrincipalId -WorkerPrincipalId $WorkerPrincipalId -EnablePurview:$EnablePurview
}

function Get-GatewayWorkloadIdentityEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$ApiPrincipalId,
        [Parameter(Mandatory)][string]$WorkerPrincipalId,
        [switch]$EnablePurview
    )
    $workerRoles = @(
        'Application.Read.All', 'AppRoleAssignment.ReadWrite.All',
        'AgentIdentityBlueprint.Create', 'AgentIdentityBlueprint.AddRemoveCreds.All',
        'AgentIdentityBlueprintPrincipal.Create', 'AgentIdentityBlueprint.Read.All',
        'AgentIdentity.Create.All', 'AgentIdentity.Read.All'
    )
    $apiRoles = [Collections.Generic.List[string]]::new()
    $apiRoles.Add('AgentIdentityBlueprint.Read.All')
    if ($EnablePurview) {
        foreach ($role in @('ProtectionScopes.Compute.User', 'Content.Process.User', 'ContentActivity.Write')) { $apiRoles.Add($role) }
    }
    Assert-GatewayApiDelegatedPermissionBoundary -Identity $Identity -RequireComplete | Out-Null
    Assert-ExactGraphApplicationRoleAssignments -PrincipalId $WorkerPrincipalId -ExpectedRoleValues $workerRoles | Out-Null
    Assert-ExactGraphApplicationRoleAssignments -PrincipalId $ApiPrincipalId -ExpectedRoleValues @($apiRoles) | Out-Null

    $ficName = "a365gw-$($Config.projectName)-api-obo-$($Config.environment)"
    Assert-GatewayFederatedCredentialBoundary -Config $Config -Identity $Identity -ApiPrincipalId $ApiPrincipalId | Out-Null
    $graph = (Get-GraphPermissionCatalog).servicePrincipal
    $workerRoleIds = [ordered]@{}
    foreach ($role in $workerRoles) { $workerRoleIds[$role] = Get-UniqueGraphPermissionId -Graph $graph -Value $role -Type Role }
    $apiRoleIds = [ordered]@{}
    foreach ($role in $apiRoles) { $apiRoleIds[$role] = Get-UniqueGraphPermissionId -Graph $graph -Value $role -Type Role }
    return [ordered]@{
        federatedCredentialName = $ficName
        workerApplicationRoles = $workerRoleIds
        apiApplicationRoles = $apiRoleIds
        delegatedRegistryScopes = @('AgentRegistration.Read.All', 'AgentRegistration.ReadWrite.All')
    }
}

function Ensure-AdminUiApplication {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [switch]$ReconcileOnly
    )
    $displayName = "A365 Gateway Admin UI - $($Config.projectName)-$($Config.environment)"
    $expectedRoles = @(Get-AdminUiGatewayApplicationRoles -DeploymentOwnershipId $DeploymentOwnershipId)
    $application = Get-ExactApplicationByDisplayName -DisplayName $displayName
    if (-not $application) {
        if ($ReconcileOnly) { throw 'The state-owned Admin UI application was not observable during read-only reconciliation.' }
        $application = Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/applications' -Body @{
            displayName = $displayName
            signInAudience = 'AzureADMyOrg'
            tags = Get-BootstrapApplicationTags -DeploymentOwnershipId $DeploymentOwnershipId
            isFallbackPublicClient = $false
            web = @{ implicitGrantSettings = @{ enableAccessTokenIssuance = $false; enableIdTokenIssuance = $false } }
            api = @{ acceptMappedClaims = $false; preAuthorizedApplications = @(); knownClientApplications = @() }
            requiredResourceAccess = @(@{
                resourceAppId = [string]$Identity.gatewayApiClientId
                resourceAccess = @(@{ id = [string]$Identity.gatewayApiAccessScopeId; type = 'Scope' })
            })
            appRoles = $expectedRoles
        }
    }
    $application = Invoke-AzJson -Arguments @(
        'rest', '--method', 'GET', '--url',
        "https://graph.microsoft.com/v1.0/applications/$($application.id)?`$select=id,appId,displayName,signInAudience,identifierUris,tags,api,appRoles,requiredResourceAccess,passwordCredentials,keyCredentials,web,spa,publicClient,isFallbackPublicClient"
    )
    Assert-ExactApplicationAuthenticationSurface -Application $application -ApplicationLabel 'Admin UI application' | Out-Null
    $apiRequirements = @($application.requiredResourceAccess)
    $exactRequiredScope = $apiRequirements.Count -eq 1 -and
        ([string]$apiRequirements[0].resourceAppId).Equals([string]$Identity.gatewayApiClientId, [StringComparison]::OrdinalIgnoreCase) -and
        @($apiRequirements[0].resourceAccess).Count -eq 1 -and
        ([string]$apiRequirements[0].resourceAccess[0].id).Equals([string]$Identity.gatewayApiAccessScopeId, [StringComparison]::OrdinalIgnoreCase) -and
        [string]$apiRequirements[0].resourceAccess[0].type -ceq 'Scope'
    $credentials = @($application.passwordCredentials)
    $credentialsAreBootstrapOwned = $credentials.Count -le 1 -and
        @($credentials | Where-Object { [string]$_.displayName -cne 'a365gw-bootstrap-admin-ui' }).Count -eq 0
    Assert-ExactAdminUiGatewayRoleContract `
        -AppRoles @($application.appRoles) `
        -DeploymentOwnershipId $DeploymentOwnershipId | Out-Null
    if ([string]$application.displayName -cne $displayName -or
        [string]$application.signInAudience -cne 'AzureADMyOrg' -or
        @($application.identifierUris).Count -ne 0 -or
        @($application.api.oauth2PermissionScopes).Count -ne 0 -or
        @($application.keyCredentials).Count -ne 0 -or
        @($application.web.redirectUris).Count -ne 0 -or
        -not [string]::IsNullOrWhiteSpace([string]$application.web.logoutUrl) -or
        -not [string]::IsNullOrWhiteSpace([string]$application.web.homePageUrl) -or
        @($application.spa.redirectUris).Count -ne 0 -or
        @($application.publicClient.redirectUris).Count -ne 0 -or
        -not $exactRequiredScope -or -not $credentialsAreBootstrapOwned) {
        throw 'Admin UI application does not match the exact single-tenant client, permission, role, and credential boundary.'
    }
    # Never change application ownership before the exact client boundary above
    # has been proven.
    Assert-BootstrapApplicationOwnership -Application $application -DeploymentOwnershipId $DeploymentOwnershipId -OwnerObjectId ([string]$Identity.userObjectId) -AllowAddMissingOwner:(-not $ReconcileOnly) | Out-Null
    $expectedServicePrincipalTags = @(Get-BootstrapApplicationTags -DeploymentOwnershipId $DeploymentOwnershipId)
    $principal = if ($ReconcileOnly) {
        Get-ServicePrincipalByAppId -AppId ([string]$application.appId)
    }
    else {
        Ensure-ServicePrincipal `
            -AppId ([string]$application.appId) `
            -ServicePrincipalNames @([string]$application.appId) `
            -Tags $expectedServicePrincipalTags
    }
    if (-not $principal) { throw 'Admin UI service principal was not observable during read-only reconciliation.' }
    $adminUiServicePrincipalId = [string]$principal.id
    $adminRole = @($application.appRoles | Where-Object { [string]$_.value -ceq 'Administrator' })
    $principalBoundaryArguments = @{
        ServicePrincipal = $principal
        ExpectedId = $adminUiServicePrincipalId
        ExpectedAppId = [string]$application.appId
        ServicePrincipalLabel = 'Admin UI service principal'
        ExpectedServicePrincipalNames = @([string]$application.appId)
        ExpectedTags = $expectedServicePrincipalTags
        ExpectedAppRoles = @($application.appRoles)
        ExpectedOauth2PermissionScopes = @()
        ExpectedAppRoleAssigneePrincipalId = [string]$Identity.userObjectId
        ExpectedAppRoleId = [string]$adminRole[0].id
    }
    $principalBoundary = Assert-ExactBootstrapServicePrincipalBoundary @principalBoundaryArguments -AllowMissingExpectedAppRoleAssignment
    $userAssignments = @($principalBoundary.appRoleAssignedTo)
    if ($userAssignments.Count -eq 0) {
        if ($ReconcileOnly) { throw 'Admin UI Gateway Administrator assignment was not observable during read-only reconciliation.' }
        Invoke-GraphJsonBody -Method 'POST' -Url "https://graph.microsoft.com/v1.0/servicePrincipals/$($principal.id)/appRoleAssignedTo" -Body @{
            principalId = [string]$Identity.userObjectId
            resourceId = [string]$principal.id
            appRoleId = [string]$adminRole[0].id
        } | Out-Null
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            $principal = Get-ServicePrincipalByAppId -AppId ([string]$application.appId)
            if (-not $principal) { throw 'Admin UI service principal disappeared during exact role-assignment readback.' }
            $principalBoundaryArguments.ServicePrincipal = $principal
            $principalBoundary = Assert-ExactBootstrapServicePrincipalBoundary @principalBoundaryArguments -AllowMissingExpectedAppRoleAssignment
            $userAssignments = @($principalBoundary.appRoleAssignedTo)
            if ($userAssignments.Count -eq 1) { break }
            if ($attempt -lt 12) { Start-Sleep -Seconds 5 }
        }
        if ($userAssignments.Count -ne 1) {
            throw 'The exact Admin UI Gateway Administrator assignment was not observable after creation.'
        }
    }
    $grantUrl = "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId%20eq%20'$($principal.id)'&`$select=id,clientId,resourceId,consentType,scope"
    $grant = @(Get-BoundedGraphCollection -InitialUrl $grantUrl)
    if ($grant.Count -eq 0) {
        if ($ReconcileOnly) { throw 'Admin UI delegated grant was not observable during read-only reconciliation.' }
        Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' -Body @{
            clientId = [string]$principal.id; consentType = 'AllPrincipals'; resourceId = [string]$Identity.gatewayApiServicePrincipalId; scope = 'access_as_user'
        } | Out-Null
        $grant = @(Get-BoundedGraphCollection -InitialUrl $grantUrl)
    }
    $grantScopes = if ($grant.Count -eq 1) {
        @(([string]$grant[0].scope).Split(' ', [StringSplitOptions]::RemoveEmptyEntries -bor [StringSplitOptions]::TrimEntries))
    }
    else { @() }
    if ($grant.Count -ne 1 -or
        -not ([string]$grant[0].resourceId).Equals([string]$Identity.gatewayApiServicePrincipalId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$grant[0].consentType -cne 'AllPrincipals' -or
        -not (Test-ExactStringSet -Actual $grantScopes -Expected @('access_as_user'))) {
        throw 'Admin UI delegated consent must be exactly one tenant-wide access_as_user grant to this Gateway API.'
    }
    $principal = Get-ServicePrincipalByAppId -AppId ([string]$application.appId)
    if (-not $principal) { throw 'Admin UI service principal disappeared during final exact readback.' }
    $principalBoundaryArguments.ServicePrincipal = $principal
    Assert-ExactBootstrapServicePrincipalBoundary @principalBoundaryArguments | Out-Null
    return [ordered]@{
        adminUiApplicationObjectId = [string]$application.id
        adminUiClientId = [string]$application.appId
        adminUiServicePrincipalId = $adminUiServicePrincipalId
        gatewayApiClientId = [string]$Identity.gatewayApiClientId
        gatewayApiAccessScopeId = [string]$Identity.gatewayApiAccessScopeId
        deploymentOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
        ownerObjectId = [string]$Identity.userObjectId
    }
}

function Set-AdminUiRedirectUris {
    param([Parameter(Mandatory)]$AdminIdentity, [Parameter(Mandatory)][string]$AdminUiFqdn)
    if ([string]::IsNullOrWhiteSpace($AdminUiFqdn)) { throw 'Admin UI FQDN is required.' }
    $base = "https://$AdminUiFqdn"
    Invoke-GraphJsonBody -Method 'PATCH' -Url "https://graph.microsoft.com/v1.0/applications/$($AdminIdentity.adminUiApplicationObjectId)" -Body @{
        isFallbackPublicClient = $false
        web = @{
            redirectUris = @("$base/signin-oidc")
            logoutUrl = "$base/signout-callback-oidc"
            implicitGrantSettings = @{
                enableAccessTokenIssuance = $false
                enableIdTokenIssuance = $false
            }
        }
    } | Out-Null
    return [ordered]@{ signInRedirectUri = "$base/signin-oidc"; signedOutCallbackUri = "$base/signout-callback-oidc" }
}

function Get-BootstrapDeterministicRoleAssignmentName {
    param([Parameter(Mandatory)][string]$Scope, [Parameter(Mandatory)][string]$PrincipalId)

    $fingerprint = Get-BootstrapSha256 -Text "a365gw-bootstrap-admin-ui-kv-officer-v1|$($Scope.ToLowerInvariant())|$($PrincipalId.ToLowerInvariant())"
    $hex = $fingerprint.Substring('sha256:'.Length, 32)
    return "$($hex.Substring(0, 8))-$($hex.Substring(8, 4))-$($hex.Substring(12, 4))-$($hex.Substring(16, 4))-$($hex.Substring(20, 12))"
}

function Get-ExactBootstrapRoleAssignment {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$AssignmentId
    )

    $assignments = @(Invoke-AzJsonArray -OperationLabel 'Temporary Key Vault role-assignment discovery' -Arguments @(
        'role', 'assignment', 'list', '--scope', $Scope, '--include-inherited',
        '--query', '[].{id:id,principalId:principalId,scope:scope,roleDefinitionId:roleDefinitionId}'
    ))
    return @($assignments | Where-Object {
        ([string]$_.id).Equals($AssignmentId, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Wait-ExactBootstrapRoleAssignmentAbsent {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$AssignmentId,
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$RoleDefinitionId,
        [ValidateRange(2, 10)][int]$RequiredConsecutiveAbsenceReads = 3,
        [ValidateRange(3, 30)][int]$MaximumAttempts = 18
    )

    $consecutiveAbsenceReads = 0
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $assignments = @(Get-ExactBootstrapRoleAssignment -Scope $Scope -AssignmentId $AssignmentId)
        if ($assignments.Count -gt 1) {
            throw 'The deterministic temporary Key Vault role assignment is ambiguous during absence verification.'
        }
        if ($assignments.Count -eq 1) {
            $assignment = $assignments[0]
            if (-not ([string]$assignment.principalId).Equals($PrincipalId, [StringComparison]::OrdinalIgnoreCase) -or
                -not ([string]$assignment.scope).Equals($Scope, [StringComparison]::OrdinalIgnoreCase) -or
                -not ([string]$assignment.roleDefinitionId).Equals($RoleDefinitionId, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The deterministic temporary Key Vault role-assignment ID changed authority during absence verification.'
            }
            $consecutiveAbsenceReads = 0
        }
        else {
            $consecutiveAbsenceReads++
            if ($consecutiveAbsenceReads -ge $RequiredConsecutiveAbsenceReads) { return $true }
        }
        if ($attempt -lt $MaximumAttempts) { Start-Sleep -Seconds 5 }
    }
    return $false
}

function Get-AdminUiCredentialEvidenceFromMetadata {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AdminIdentity,
        [Parameter(Mandatory)][string]$KeyVaultUri,
        [ValidateRange(1, 30)][int]$MaximumAttempts = 18
    )
    $vaultName = ([uri]$KeyVaultUri).Host.Split('.')[0]
    $secretResourceId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.KeyVault/vaults/$vaultName/secrets/admin-ui-entra-client-secret"
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $application = Invoke-AzJson -Arguments @(
                'rest', '--method', 'GET', '--url',
                "https://graph.microsoft.com/v1.0/applications/$($AdminIdentity.adminUiApplicationObjectId)?`$select=id,appId,passwordCredentials"
            )
            if (-not ([string]$application.appId).Equals([string]$AdminIdentity.adminUiClientId, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'mismatch'
            }
            $credentials = @($application.passwordCredentials)
            if ($credentials.Count -ne 1 -or [string]$credentials[0].displayName -cne 'a365gw-bootstrap-admin-ui') {
                throw 'mismatch'
            }
            $expires = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse(
                [string]$credentials[0].endDateTime,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$expires) -or $expires.ToUniversalTime() -le [DateTimeOffset]::UtcNow) {
                throw 'mismatch'
            }
            $secret = Invoke-AzJson -Arguments @(
                'resource', 'show', '--ids', $secretResourceId, '--api-version', '2023-07-01',
                '--query', '{id:id,name:name,enabled:properties.attributes.enabled,tags:tags}'
            )
            if (-not ([string]$secret.id).Equals($secretResourceId, [StringComparison]::OrdinalIgnoreCase) -or
                [string]$secret.name -cne 'admin-ui-entra-client-secret' -or $secret.enabled -ne $true -or
                -not $secret.tags -or [string]$secret.tags.managedBy -cne 'a365gw-bootstrap' -or
                -not ([string]$secret.tags.credentialKeyId).Equals([string]$credentials[0].keyId, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'mismatch'
            }
            return [ordered]@{
                secretUri = "$($KeyVaultUri.TrimEnd('/'))/secrets/admin-ui-entra-client-secret"
                credentialKeyId = [string]$credentials[0].keyId
                credentialExpiresAtUtc = $expires.ToUniversalTime().ToString('O')
            }
        }
        catch {
            if ($attempt -lt $MaximumAttempts) { Start-Sleep -Seconds 5 }
        }
    }
    throw 'Admin UI credential metadata was not observed with the exact bootstrap-owned application and Key Vault boundary during the bounded readback window.'
}

function Test-BootstrapKeyVaultSecretIdentifier {
    param(
        [Parameter(Mandatory)][string]$Identifier,
        [Parameter(Mandatory)][string]$KeyVaultUri,
        [Parameter(Mandatory)][string]$SecretName
    )
    $candidate = $null
    $vault = $null
    if (-not [Uri]::TryCreate($Identifier, [UriKind]::Absolute, [ref]$candidate) -or
        -not [Uri]::TryCreate($KeyVaultUri, [UriKind]::Absolute, [ref]$vault) -or
        $candidate.Scheme -cne 'https' -or
        -not $candidate.Host.Equals($vault.Host, [StringComparison]::OrdinalIgnoreCase) -or
        $candidate.Port -ne $vault.Port -or
        -not [string]::IsNullOrEmpty($candidate.UserInfo) -or
        -not [string]::IsNullOrEmpty($candidate.Fragment) -or
        -not [string]::IsNullOrEmpty($candidate.Query)) {
        return $false
    }
    $segments = @($candidate.AbsolutePath.Trim('/').Split('/', [StringSplitOptions]::RemoveEmptyEntries))
    return $segments.Count -in @(2, 3) -and
        [string]$segments[0] -ceq 'secrets' -and
        [Uri]::UnescapeDataString([string]$segments[1]) -ceq $SecretName
}

function Get-BoundedKeyVaultSecretMetadata {
    param(
        [Parameter(Mandatory)][string]$KeyVaultUri,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Headers,
        [ValidateRange(1, 100)][int]$MaximumPages = 20,
        [ValidateRange(1, 50000)][int]$MaximumItems = 10000,
        [ValidateRange(1, 30)][int]$MaximumAttemptsPerPage = 18
    )

    $vault = $null
    if (-not [Uri]::TryCreate($KeyVaultUri, [UriKind]::Absolute, [ref]$vault) -or
        $vault.Scheme -cne 'https' -or -not $vault.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($vault.UserInfo) -or
        -not [string]::IsNullOrEmpty($vault.Query) -or
        -not [string]::IsNullOrEmpty($vault.Fragment)) {
        throw 'Key Vault URI is not an exact HTTPS vault origin.'
    }
    $collectionPath = '/secrets'
    $nextUrl = "$($KeyVaultUri.TrimEnd('/'))${collectionPath}?api-version=7.4"
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $items = [Collections.Generic.List[object]]::new()

    for ($page = 1; $page -le $MaximumPages; $page++) {
        $pageUri = $null
        if (-not [Uri]::TryCreate($nextUrl, [UriKind]::Absolute, [ref]$pageUri) -or
            $pageUri.Scheme -cne 'https' -or
            -not $pageUri.Host.Equals($vault.Host, [StringComparison]::OrdinalIgnoreCase) -or
            $pageUri.Port -ne $vault.Port -or
            -not [string]::IsNullOrEmpty($pageUri.UserInfo) -or
            -not [string]::IsNullOrEmpty($pageUri.Fragment) -or
            $pageUri.AbsolutePath -cne $collectionPath) {
            throw 'Key Vault continuation left the exact HTTPS vault secret-list origin or path.'
        }
        if (-not $visited.Add($pageUri.AbsoluteUri)) {
            throw 'Key Vault secret list returned a repeated continuation URL.'
        }

        $response = $null
        for ($attempt = 1; $attempt -le $MaximumAttemptsPerPage -and $null -eq $response; $attempt++) {
            try { $response = Invoke-RestMethod -Method Get -Uri $nextUrl -Headers $Headers }
            catch {
                if ($attempt -eq $MaximumAttemptsPerPage) {
                    throw 'Key Vault secret metadata was unavailable during the bounded readback window.'
                }
                Start-Sleep -Seconds 5
            }
        }
        if ($null -eq $response -or $null -eq $response.PSObject.Properties['value'] -or
            $response.value -isnot [System.Array]) {
            throw 'Key Vault secret-list response did not contain the required value array.'
        }
        foreach ($item in @($response.value)) {
            if ($null -eq $item) { throw 'Key Vault secret list returned a null metadata item.' }
            if ($items.Count -ge $MaximumItems) {
                throw "Key Vault secret list exceeded the bounded item limit of $MaximumItems."
            }
            $items.Add($item)
        }

        $nextProperty = $response.PSObject.Properties['nextLink']
        if ($null -eq $nextProperty -or $null -eq $nextProperty.Value -or
            [string]::IsNullOrWhiteSpace([string]$nextProperty.Value)) {
            return @($items)
        }
        $nextUrl = [string]$nextProperty.Value
    }
    throw "Key Vault secret list exceeded the bounded page limit of $MaximumPages."
}

function Resolve-AdminUiCredentialAfterStartedOutcome {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AdminIdentity,
        [Parameter(Mandatory)][string]$KeyVaultUri,
        [Parameter(Mandatory)][string]$UserObjectId
    )

    Assert-GuidValue -Value $UserObjectId -Label 'Admin UI credential operator object ID'
    $vaultName = ([uri]$KeyVaultUri).Host.Split('.')[0]
    $scope = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.KeyVault/vaults/$vaultName"
    $assignmentName = Get-BootstrapDeterministicRoleAssignmentName -Scope $scope -PrincipalId $UserObjectId
    $assignmentId = "$scope/providers/Microsoft.Authorization/roleAssignments/$assignmentName"
    $roleDefinitionId = "/subscriptions/$(([guid]$Config.subscriptionId).ToString('D'))/providers/Microsoft.Authorization/roleDefinitions/$script:KeyVaultSecretsOfficerRoleId"

    $assignments = @(Get-ExactBootstrapRoleAssignment -Scope $scope -AssignmentId $assignmentId)
    if ($assignments.Count -gt 1) {
        throw 'The bootstrap-owned temporary Key Vault role assignment is ambiguous during recovery.'
    }
    if ($assignments.Count -eq 1) {
        $assignment = $assignments[0]
        if (-not ([string]$assignment.principalId).Equals($UserObjectId, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$assignment.scope).Equals($scope, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$assignment.roleDefinitionId).Equals($roleDefinitionId, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The deterministic temporary Key Vault role assignment belongs to different authority; refusing recovery deletion.'
        }
        Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @(
            'role', 'assignment', 'delete', '--ids', $assignmentId, '--only-show-errors'
        ) | Out-Null
    }

    $removed = Wait-ExactBootstrapRoleAssignmentAbsent `
        -Scope $scope `
        -AssignmentId $assignmentId `
        -PrincipalId $UserObjectId `
        -RoleDefinitionId $roleDefinitionId
    if (-not $removed) {
        throw 'The bootstrap-owned temporary Key Vault role assignment could not be proven removed during recovery.'
    }

    return Get-AdminUiCredentialEvidenceFromMetadata -Config $Config -AdminIdentity $AdminIdentity -KeyVaultUri $KeyVaultUri
}

function New-AdminUiCredentialInKeyVault {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AdminIdentity,
        [Parameter(Mandatory)][string]$KeyVaultUri,
        [Parameter(Mandatory)][string]$UserObjectId
    )
    $vaultName = ([uri]$KeyVaultUri).Host.Split('.')[0]
    $scope = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.KeyVault/vaults/$vaultName"
    $roleDefinitionId = "/subscriptions/$(([guid]$Config.subscriptionId).ToString('D'))/providers/Microsoft.Authorization/roleDefinitions/$script:KeyVaultSecretsOfficerRoleId"
    Assert-GuidValue -Value $UserObjectId -Label 'Admin UI credential operator object ID'
    $temporaryRoleAssignmentName = Get-BootstrapDeterministicRoleAssignmentName -Scope $scope -PrincipalId $UserObjectId
    $temporaryRoleAssignmentId = "$scope/providers/Microsoft.Authorization/roleAssignments/$temporaryRoleAssignmentName"
    $removeTemporaryRole = $false
    $secretText = $null
    try {
        $exactTemporaryAssignments = @(Get-ExactBootstrapRoleAssignment -Scope $scope -AssignmentId $temporaryRoleAssignmentId)
        if ($exactTemporaryAssignments.Count -gt 1) {
            throw 'The bootstrap-owned temporary Key Vault role assignment is ambiguous; refusing credential handling.'
        }
        if ($exactTemporaryAssignments.Count -eq 1) {
            $temporaryAssignment = $exactTemporaryAssignments[0]
            if (-not ([string]$temporaryAssignment.principalId).Equals($UserObjectId, [StringComparison]::OrdinalIgnoreCase) -or
                -not ([string]$temporaryAssignment.scope).Equals($scope, [StringComparison]::OrdinalIgnoreCase) -or
                -not ([string]$temporaryAssignment.roleDefinitionId).Equals($roleDefinitionId, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The deterministic bootstrap role-assignment ID is already bound to different authority; refusing credential handling.'
            }
            $removeTemporaryRole = $true
        }

        $existingAssignments = @(Invoke-AzJsonArray -OperationLabel 'Existing Key Vault role-assignment discovery' -Arguments @(
            'role', 'assignment', 'list', '--assignee-object-id', $UserObjectId,
            '--scope', $scope, '--include-inherited',
            '--query', '[].{id:id,roleDefinitionId:roleDefinitionId}'
        ))
        $hasIndependentAssignment = @($existingAssignments | Where-Object {
            ([string]$_.roleDefinitionId).Equals($roleDefinitionId, [StringComparison]::OrdinalIgnoreCase) -and
            -not ([string]$_.id).Equals($temporaryRoleAssignmentId, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if (-not $removeTemporaryRole -and -not $hasIndependentAssignment) {
            # Set ownership before the create call. If Azure reports an unknown
            # outcome, finally performs exact-ID discovery/cleanup and Resume can
            # repeat that cleanup without creating a second assignment.
            $removeTemporaryRole = $true
            $createdAssignment = Invoke-AzJson -Arguments @(
                'role', 'assignment', 'create', '--name', $temporaryRoleAssignmentName,
                '--assignee-object-id', $UserObjectId, '--assignee-principal-type', 'User',
                '--role', $roleDefinitionId, '--scope', $scope
            )
            if (-not ([string]$createdAssignment.id).Equals($temporaryRoleAssignmentId, [StringComparison]::OrdinalIgnoreCase) -or
                -not ([string]$createdAssignment.principalId).Equals($UserObjectId, [StringComparison]::OrdinalIgnoreCase) -or
                -not ([string]$createdAssignment.scope).Equals($scope, [StringComparison]::OrdinalIgnoreCase) -or
                -not ([string]$createdAssignment.roleDefinitionId).Equals($roleDefinitionId, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Azure did not return the exact bootstrap-owned temporary Key Vault role assignment.'
            }
        }

        $tokenResult = Invoke-AzJson -Arguments @('account', 'get-access-token', '--resource', 'https://vault.azure.net')
        $headers = @{ Authorization = "Bearer $($tokenResult.accessToken)"; 'Content-Type' = 'application/json' }
        $application = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/applications/$($AdminIdentity.adminUiApplicationObjectId)?`$select=passwordCredentials")
        $bootstrapCredentials = @($application.passwordCredentials | Where-Object { [string]$_.displayName -eq 'a365gw-bootstrap-admin-ui' })
        $secretList = @(Get-BoundedKeyVaultSecretMetadata -KeyVaultUri $KeyVaultUri -Headers $headers)
        $vaultMetadata = @($secretList | Where-Object {
            Test-BootstrapKeyVaultSecretIdentifier -Identifier ([string]$_.id) -KeyVaultUri $KeyVaultUri -SecretName 'admin-ui-entra-client-secret'
        })
        if ($vaultMetadata.Count -gt 1) { throw 'Key Vault returned ambiguous current Admin UI secret metadata.' }
        if ($vaultMetadata.Count -eq 1) {
            $recordedKeyId = [string]$vaultMetadata[0].tags.credentialKeyId
            $matchingCredential = @($bootstrapCredentials | Where-Object { [string]$_.keyId -eq $recordedKeyId })
            if ([string]::IsNullOrWhiteSpace($recordedKeyId) -or $matchingCredential.Count -ne 1) {
                throw 'An Admin UI Key Vault secret already exists but cannot be safely matched to the bootstrap app credential. Rotate it through the credential runbook.'
            }
            return Get-AdminUiCredentialEvidenceFromMetadata -Config $Config -AdminIdentity $AdminIdentity -KeyVaultUri $KeyVaultUri
        }
        if ($bootstrapCredentials.Count -gt 0) {
            throw 'A bootstrap-labeled Admin UI app credential exists without matching Key Vault metadata. Refusing an unreviewed replacement.'
        }

        $credential = Invoke-GraphJsonBody -Method 'POST' -Url "https://graph.microsoft.com/v1.0/applications/$($AdminIdentity.adminUiApplicationObjectId)/addPassword" -Body @{
            passwordCredential = @{ displayName = 'a365gw-bootstrap-admin-ui'; endDateTime = [DateTimeOffset]::UtcNow.AddYears(1).ToString('O') }
        }
        $secretText = [string]$credential.secretText
        if ([string]::IsNullOrWhiteSpace($secretText)) { throw 'Microsoft Graph did not return the one-time Admin UI credential.' }
        $body = @{ value = $secretText; attributes = @{ enabled = $true }; tags = @{ credentialKeyId = [string]$credential.keyId; managedBy = 'a365gw-bootstrap' } } | ConvertTo-Json -Compress
        $secretUrl = "$($KeyVaultUri.TrimEnd('/'))/secrets/admin-ui-entra-client-secret?api-version=7.4"
        $stored = $null
        for ($attempt = 1; $attempt -le 18 -and -not $stored; $attempt++) {
            try {
                $stored = Invoke-RestMethod -Method Put -Uri $secretUrl -Headers $headers -Body $body
                if ($null -eq $stored -or
                    -not (Test-BootstrapKeyVaultSecretIdentifier -Identifier ([string]$stored.id) -KeyVaultUri $KeyVaultUri -SecretName 'admin-ui-entra-client-secret') -or
                    $stored.attributes.enabled -ne $true -or
                    [string]$stored.tags.managedBy -cne 'a365gw-bootstrap' -or
                    -not ([string]$stored.tags.credentialKeyId).Equals([string]$credential.keyId, [StringComparison]::OrdinalIgnoreCase)) {
                    $stored = $null
                    throw 'Key Vault returned a mismatched secret-set response.'
                }
            }
            catch {
                # A versionless secret PUT creates a new version. After any
                # ambiguous response, reconcile the paged metadata collection
                # before deciding whether another mutation is safe.
                $reconciliationList = @(Get-BoundedKeyVaultSecretMetadata -KeyVaultUri $KeyVaultUri -Headers $headers)
                $reconciliationMatches = @($reconciliationList | Where-Object {
                    Test-BootstrapKeyVaultSecretIdentifier -Identifier ([string]$_.id) -KeyVaultUri $KeyVaultUri -SecretName 'admin-ui-entra-client-secret'
                })
                if ($reconciliationMatches.Count -gt 1) {
                    throw 'Key Vault returned ambiguous Admin UI secret metadata after an unknown secret-set outcome; refusing another version.'
                }
                if ($reconciliationMatches.Count -eq 1) {
                    $reconciled = $reconciliationMatches[0]
                    if ($reconciled.attributes.enabled -ne $true -or
                        [string]$reconciled.tags.managedBy -cne 'a365gw-bootstrap' -or
                        -not ([string]$reconciled.tags.credentialKeyId).Equals([string]$credential.keyId, [StringComparison]::OrdinalIgnoreCase)) {
                        throw 'Key Vault secret metadata mismatched after an unknown secret-set outcome; refusing another version.'
                    }
                    $stored = $reconciled
                    break
                }
                # A complete, bounded metadata traversal proved the exact secret
                # absent. Only that outcome permits another set attempt.
                if ($attempt -eq 18) {
                    throw 'Key Vault did not accept the Admin UI secret within the bounded exact-absence retry window.'
                }
                Start-Sleep -Seconds 5
            }
        }
        return Get-AdminUiCredentialEvidenceFromMetadata -Config $Config -AdminIdentity $AdminIdentity -KeyVaultUri $KeyVaultUri
    }
    finally {
        $secretText = $null
        $body = $null
        $stored = $null
        $secretList = $null
        $headers = $null
        $tokenResult = $null
        if ($removeTemporaryRole) {
            $cleanupAssignments = @(Get-ExactBootstrapRoleAssignment -Scope $scope -AssignmentId $temporaryRoleAssignmentId)
            if ($cleanupAssignments.Count -gt 1) {
                throw 'The bootstrap-owned temporary Key Vault role assignment is ambiguous during cleanup. Stop and review the exact assignment ID.'
            }
            if ($cleanupAssignments.Count -eq 1) {
                $cleanupAssignment = $cleanupAssignments[0]
                if (-not ([string]$cleanupAssignment.principalId).Equals($UserObjectId, [StringComparison]::OrdinalIgnoreCase) -or
                    -not ([string]$cleanupAssignment.scope).Equals($scope, [StringComparison]::OrdinalIgnoreCase) -or
                    -not ([string]$cleanupAssignment.roleDefinitionId).Equals($roleDefinitionId, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'The deterministic bootstrap role-assignment ID changed authority before cleanup; refusing deletion.'
                }
                Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @(
                    'role', 'assignment', 'delete', '--ids', $temporaryRoleAssignmentId, '--only-show-errors'
                ) | Out-Null
            }
            $removed = Wait-ExactBootstrapRoleAssignmentAbsent `
                -Scope $scope `
                -AssignmentId $temporaryRoleAssignmentId `
                -PrincipalId $UserObjectId `
                -RoleDefinitionId $roleDefinitionId
            if (-not $removed) {
                throw 'The bootstrap-owned temporary Key Vault role assignment could not be proven removed. Credential handling is incomplete; Resume must retry exact cleanup.'
            }
        }
    }
}

Export-ModuleMember -Function *
