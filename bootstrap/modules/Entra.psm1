Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:GraphAppId = '00000003-0000-0000-c000-000000000000'
$script:KeyVaultSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
$script:PurviewExchangeOnlineProtectionAppId = '00000007-0000-0ff1-ce00-000000000000'
$script:PurviewExchangeManageAsAppRoleId = '455e5cd2-84e8-4751-8344-5672145dfa17'
$script:PurviewComplianceAdministratorRoleDefinitionId = '17315797-102d-40b4-93e0-432062caca18'

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
    if ($InputObject -is [Collections.IDictionary]) {
        if (-not $InputObject.Contains($PropertyName)) { return $null }
        return $InputObject[$PropertyName]
    }
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

function Get-BootstrapInitialTenantDomain {
    $domains = @(Get-BoundedGraphCollection -InitialUrl (
        'https://graph.microsoft.com/v1.0/domains?' +
        '$filter=isInitial%20eq%20true&$select=id,isInitial,isVerified'))
    if ($domains.Count -ne 1 -or
        $domains[0].isInitial -ne $true -or
        $domains[0].isVerified -ne $true -or
        [string]$domains[0].id -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?[.][A-Za-z]{2,}$') {
        throw 'The tenant initial verified domain required for Purview app-only authentication was not unique.'
    }
    return ([string]$domains[0].id).ToLowerInvariant()
}

function Get-BootstrapPurviewExchangeRole {
    $exchange = Get-ServicePrincipalByAppId -AppId $script:PurviewExchangeOnlineProtectionAppId
    if (-not $exchange) {
        throw 'Microsoft Exchange Online Protection service principal was not found in the tenant.'
    }
    $roles = @($exchange.appRoles | Where-Object {
        [string]$_.id -ceq $script:PurviewExchangeManageAsAppRoleId -and
        [string]$_.value -ceq 'Exchange.ManageAsApp' -and
        $_.isEnabled -eq $true -and
        @($_.allowedMemberTypes) -contains 'Application'
    })
    if ($roles.Count -ne 1) {
        throw 'Microsoft Exchange Online Protection Exchange.ManageAsApp was not uniquely available.'
    }
    return [ordered]@{
        servicePrincipalId = ([guid][string]$exchange.id).ToString('D')
        roleId = $script:PurviewExchangeManageAsAppRoleId
    }
}

function Get-BootstrapPurviewDirectoryRoleAssignments {
    param([Parameter(Mandatory)][string]$PrincipalId)

    return @(Get-BoundedGraphCollection -InitialUrl (
        "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?" +
        "`$filter=principalId%20eq%20'$PrincipalId'&" +
        '`$select=id,principalId,roleDefinitionId,directoryScopeId'))
}

function Assert-BootstrapPurviewAutomationApplication {
    param(
        [Parameter(Mandatory)]$Application,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$OwnerObjectId,
        [Parameter(Mandatory)]$ExchangeRole,
        [switch]$AllowMissingCertificate
    )

    Assert-ExactApplicationAuthenticationSurface `
        -Application $Application `
        -ApplicationLabel 'Purview automation application' | Out-Null
    if ([string]$Application.displayName -cne $DisplayName -or
        [string]$Application.signInAudience -cne 'AzureADMyOrg' -or
        @($Application.identifierUris).Count -ne 0 -or
        @($Application.passwordCredentials).Count -ne 0 -or
        @($Application.appRoles).Count -ne 0 -or
        @($Application.api.oauth2PermissionScopes).Count -ne 0 -or
        @($Application.web.redirectUris).Count -ne 0 -or
        @($Application.spa.redirectUris).Count -ne 0 -or
        @($Application.publicClient.redirectUris).Count -ne 0) {
        throw 'Purview automation application authentication and local permission surfaces are not exact.'
    }
    $requirements = @($Application.requiredResourceAccess)
    $access = if ($requirements.Count -eq 1) { @($requirements[0].resourceAccess) } else { @() }
    if ($requirements.Count -ne 1 -or
        [string]$requirements[0].resourceAppId -cne $script:PurviewExchangeOnlineProtectionAppId -or
        $access.Count -ne 1 -or
        [string]$access[0].id -cne [string]$ExchangeRole.roleId -or
        [string]$access[0].type -cne 'Role') {
        throw 'Purview automation application requiredResourceAccess is not the exact Security and Compliance app-only permission.'
    }
    if (-not $AllowMissingCertificate -and @($Application.keyCredentials).Count -ne 1) {
        throw 'Purview automation application must contain exactly one certificate credential.'
    }
    if ($AllowMissingCertificate -and @($Application.keyCredentials).Count -gt 1) {
        throw 'Purview automation application contains more than one certificate credential.'
    }
    Assert-BootstrapApplicationOwnership `
        -Application $Application `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -OwnerObjectId $OwnerObjectId | Out-Null
    return $true
}

function Assert-BootstrapPurviewAutomationServicePrincipal {
    param(
        [Parameter(Mandatory)]$Principal,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)]$ExchangeRole,
        [switch]$AllowMissingAssignments
    )

    $expectedTags = @(Get-BootstrapApplicationTags -DeploymentOwnershipId $DeploymentOwnershipId)
    if ([string]$Principal.appId -cne $ApplicationId -or
        $Principal.accountEnabled -ne $true -or
        [string]$Principal.servicePrincipalType -cne 'Application' -or
        $Principal.appRoleAssignmentRequired -ne $false -or
        @($Principal.passwordCredentials).Count -ne 0 -or
        @($Principal.keyCredentials).Count -ne 0 -or
        @($Principal.appRoles).Count -ne 0 -or
        @($Principal.oauth2PermissionScopes).Count -ne 0 -or
        -not (Test-ExactStringSet -Actual @($Principal.servicePrincipalNames) -Expected @($ApplicationId)) -or
        -not (Test-ExactStringSet -Actual @($Principal.tags) -Expected $expectedTags)) {
        throw 'Purview automation service principal is outside the exact credential-free ownership boundary.'
    }
    $principalId = ([guid][string]$Principal.id).ToString('D')
    $owners = @(Get-BoundedGraphCollection -InitialUrl (
        "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/owners?`$select=id"))
    $groups = @(Get-BoundedGraphCollection -InitialUrl (
        "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/" +
        'transitiveMemberOf/microsoft.graph.group?$select=id'))
    $resourceAssignments = @(Get-BoundedGraphCollection -InitialUrl (
        "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/" +
        'appRoleAssignedTo?$select=id,principalId,resourceId,appRoleId'))
    if ($owners.Count -ne 0 -or $groups.Count -ne 0 -or $resourceAssignments.Count -ne 0) {
        throw 'Purview automation service principal has an unreviewed owner, group membership, or local role assignee.'
    }
    $assignments = @(Get-BoundedGraphCollection -InitialUrl (
        "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/" +
        'appRoleAssignments?$select=id,resourceId,appRoleId'))
    $matchingExchange = @($assignments | Where-Object {
        [string]$_.resourceId -ceq [string]$ExchangeRole.servicePrincipalId -and
        [string]$_.appRoleId -ceq [string]$ExchangeRole.roleId
    })
    $directoryAssignments = @(Get-BootstrapPurviewDirectoryRoleAssignments -PrincipalId $principalId)
    $matchingCompliance = @($directoryAssignments | Where-Object {
        [string]$_.principalId -ceq $principalId -and
        [string]$_.roleDefinitionId -ceq $script:PurviewComplianceAdministratorRoleDefinitionId -and
        [string]$_.directoryScopeId -ceq '/'
    })
    $minimum = if ($AllowMissingAssignments) { 0 } else { 1 }
    if ($assignments.Count -gt 1 -or $assignments.Count -lt $minimum -or
        $matchingExchange.Count -ne $assignments.Count -or
        $directoryAssignments.Count -gt 1 -or
        $directoryAssignments.Count -lt $minimum -or
        $matchingCompliance.Count -ne $directoryAssignments.Count) {
        throw 'Purview automation principal app-only or Compliance Administrator assignments are outside the exact reviewed boundary.'
    }
    return [ordered]@{
        exchangeAssignments = @($assignments)
        complianceAssignments = @($directoryAssignments)
    }
}

function Get-BootstrapPurviewAutomationApplication {
    param([Parameter(Mandatory)][string]$ApplicationObjectId)

    return Invoke-AzJson -Arguments @(
        'rest', '--method', 'GET', '--url',
        "https://graph.microsoft.com/v1.0/applications/${ApplicationObjectId}?`$select=id,appId,displayName,signInAudience,identifierUris,tags,api,appRoles,requiredResourceAccess,passwordCredentials,keyCredentials,web,spa,publicClient,isFallbackPublicClient"
    )
}

function New-BootstrapPurviewCertificateRsa {
    if ($IsWindows) {
        $csp = [Security.Cryptography.CspParameters]::new(24)
        $csp.KeyContainerName = "a365gw-purview-$([guid]::NewGuid().ToString('N'))"
        $csp.KeyNumber = [Security.Cryptography.KeyNumber]::Exchange
        $csp.Flags = [Security.Cryptography.CspProviderFlags]::NoPrompt
        $rsa = [Security.Cryptography.RSACryptoServiceProvider]::new(2048, $csp)
        $rsa.PersistKeyInCsp = $false
        return $rsa
    }
    return [Security.Cryptography.RSA]::Create(2048)
}

function Get-BootstrapPurviewAutomationIdentityEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AzureIdentity,
        [Parameter(Mandatory)][string]$KeyVaultUri,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $displayName = "A365 Gateway Purview Automation - $($Config.projectName)-$($Config.environment)"
    $application = Get-ExactApplicationByDisplayName -DisplayName $displayName
    if (-not $application) { throw 'The bootstrap-owned Purview automation application was not found.' }
    $application = Get-BootstrapPurviewAutomationApplication -ApplicationObjectId ([string]$application.id)
    $exchangeRole = Get-BootstrapPurviewExchangeRole
    Assert-BootstrapPurviewAutomationApplication `
        -Application $application `
        -DisplayName $displayName `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -OwnerObjectId ([string]$AzureIdentity.userObjectId) `
        -ExchangeRole $exchangeRole | Out-Null
    $principal = Get-ServicePrincipalByAppId -AppId ([string]$application.appId)
    if (-not $principal) { throw 'The bootstrap-owned Purview automation service principal was not found.' }
    $null = Assert-BootstrapPurviewAutomationServicePrincipal `
        -Principal $principal `
        -ApplicationId ([string]$application.appId) `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -ExchangeRole $exchangeRole
    $certificate = Get-GatewayPurviewAutomationCertificateSecretArmMetadata `
        -Config $Config `
        -KeyVaultUri $KeyVaultUri `
        -AutomationApplicationId ([string]$application.appId) `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $SourceFingerprint
    $keys = @($application.keyCredentials)
    $customIdentifierBytes = $null
    $customIdentifierThumbprint = ''
    $keyExpiresAt = [DateTimeOffset]::MinValue
    if ($keys.Count -eq 1) {
        try {
            $customIdentifierBytes = [Convert]::FromBase64String([string]$keys[0].customKeyIdentifier)
            $customIdentifierThumbprint = [Convert]::ToHexString($customIdentifierBytes).ToLowerInvariant()
        }
        catch {
            $customIdentifierThumbprint = ''
        }
        finally {
            if ($customIdentifierBytes) {
                [Security.Cryptography.CryptographicOperations]::ZeroMemory($customIdentifierBytes)
            }
        }
    }
    if ([string]$certificate.status -cne 'Present' -or $keys.Count -ne 1 -or
        [string]$keys[0].keyId -cne [string]$certificate.keyCredentialId -or
        [string]$keys[0].displayName -cne 'a365gw-purview-automation-certificate' -or
        [string]$keys[0].type -cne 'AsymmetricX509Cert' -or
        [string]$keys[0].usage -cne 'Verify' -or
        $customIdentifierThumbprint -cne [string]$certificate.certificateThumbprint -or
        -not [DateTimeOffset]::TryParse(
            [string]$keys[0].endDateTime,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$keyExpiresAt) -or
        $keyExpiresAt.ToUniversalTime() -le [DateTimeOffset]::UtcNow) {
        throw 'Purview automation certificate and Key Vault metadata do not match exactly.'
    }
    return [ordered]@{
        enabled = $true
        status = 'Installed'
        organization = Get-BootstrapInitialTenantDomain
        automationApplicationObjectId = ([guid][string]$application.id).ToString('D')
        automationApplicationId = ([guid][string]$application.appId).ToString('D')
        automationServicePrincipalId = ([guid][string]$principal.id).ToString('D')
        exchangeOnlineProtectionApplicationId = $script:PurviewExchangeOnlineProtectionAppId
        exchangeManageAsAppRoleId = $script:PurviewExchangeManageAsAppRoleId
        complianceAdministratorRoleDefinitionId = $script:PurviewComplianceAdministratorRoleDefinitionId
        keyCredentialId = [string]$certificate.keyCredentialId
        certificateThumbprint = [string]$certificate.certificateThumbprint
        certificateSecretResourceId = [string]$certificate.secretResourceId
        certificateSecretUri = [string]$certificate.secretUri
        deploymentOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
        sourceFingerprint = $SourceFingerprint
        policyConfiguration = 'NotPerformed'
        policyReadiness = 'NotClaimed'
    }
}

function Test-BootstrapPurviewAutomationIdentityEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AzureIdentity,
        [Parameter(Mandatory)][string]$KeyVaultUri,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)]$Evidence
    )

    $readback = Get-BootstrapPurviewAutomationIdentityEvidence `
        -Config $Config `
        -AzureIdentity $AzureIdentity `
        -KeyVaultUri $KeyVaultUri `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $SourceFingerprint
    $projection = [ordered]@{}
    foreach ($name in @($readback.Keys | ForEach-Object { [string]$_ })) {
        $value = Get-OptionalObjectPropertyValue -InputObject $Evidence -PropertyName $name
        $projection[$name] = $value
    }
    if ((Get-BootstrapObjectFingerprint -InputObject $projection) -cne
        (Get-BootstrapObjectFingerprint -InputObject $readback)) {
        throw 'Purview automation identity evidence no longer matches exact provider readback.'
    }
    return $true
}

function Ensure-BootstrapPurviewAutomationIdentity {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AzureIdentity,
        [Parameter(Mandatory)][string]$KeyVaultUri,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [switch]$ReconcileOnly
    )

    $displayName = "A365 Gateway Purview Automation - $($Config.projectName)-$($Config.environment)"
    $exchangeRole = Get-BootstrapPurviewExchangeRole
    $application = Get-ExactApplicationByDisplayName -DisplayName $displayName
    if (-not $application) {
        if ($ReconcileOnly) { throw 'The bootstrap-owned Purview automation application was not observable during read-only reconciliation.' }
        $application = Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/applications' -Body @{
            displayName = $displayName
            signInAudience = 'AzureADMyOrg'
            tags = Get-BootstrapApplicationTags -DeploymentOwnershipId $DeploymentOwnershipId
            isFallbackPublicClient = $false
            web = @{ implicitGrantSettings = @{ enableAccessTokenIssuance = $false; enableIdTokenIssuance = $false } }
            api = @{ acceptMappedClaims = $false; preAuthorizedApplications = @(); knownClientApplications = @(); oauth2PermissionScopes = @() }
            appRoles = @()
            requiredResourceAccess = @(@{
                resourceAppId = $script:PurviewExchangeOnlineProtectionAppId
                resourceAccess = @(@{
                    id = $script:PurviewExchangeManageAsAppRoleId
                    type = 'Role'
                })
            })
            keyCredentials = @()
        }
    }
    $application = Get-BootstrapPurviewAutomationApplication -ApplicationObjectId ([string]$application.id)
    Assert-BootstrapApplicationOwnership `
        -Application $application `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -OwnerObjectId ([string]$AzureIdentity.userObjectId) `
        -AllowAddMissingOwner:(!$ReconcileOnly) | Out-Null
    $application = Get-BootstrapPurviewAutomationApplication -ApplicationObjectId ([string]$application.id)
    Assert-BootstrapPurviewAutomationApplication `
        -Application $application `
        -DisplayName $displayName `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -OwnerObjectId ([string]$AzureIdentity.userObjectId) `
        -ExchangeRole $exchangeRole `
        -AllowMissingCertificate | Out-Null

    $principal = Get-ServicePrincipalByAppId -AppId ([string]$application.appId)
    if (-not $principal) {
        if ($ReconcileOnly) { throw 'The Purview automation service principal was not observable during read-only reconciliation.' }
        $principal = Ensure-ServicePrincipal `
            -AppId ([string]$application.appId) `
            -ServicePrincipalNames @([string]$application.appId) `
            -Tags @(Get-BootstrapApplicationTags -DeploymentOwnershipId $DeploymentOwnershipId)
    }
    $assignmentBoundary = Assert-BootstrapPurviewAutomationServicePrincipal `
        -Principal $principal `
        -ApplicationId ([string]$application.appId) `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -ExchangeRole $exchangeRole `
        -AllowMissingAssignments
    if ($assignmentBoundary.exchangeAssignments.Count -eq 0) {
        if ($ReconcileOnly) { throw 'Purview Exchange.ManageAsApp consent is missing during read-only reconciliation.' }
        Invoke-GraphJsonBody -Method 'POST' -Url (
            "https://graph.microsoft.com/v1.0/servicePrincipals/$($principal.id)/appRoleAssignments") -Body @{
            principalId = [string]$principal.id
            resourceId = [string]$exchangeRole.servicePrincipalId
            appRoleId = [string]$exchangeRole.roleId
        } | Out-Null
    }
    if ($assignmentBoundary.complianceAssignments.Count -eq 0) {
        if ($ReconcileOnly) { throw 'Purview Compliance Administrator assignment is missing during read-only reconciliation.' }
        $definition = Invoke-AzJson -Arguments @(
            'rest', '--method', 'GET', '--url',
            "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/$($script:PurviewComplianceAdministratorRoleDefinitionId)?`$select=id,templateId,isBuiltIn,isEnabled"
        )
        if ([string]$definition.id -cne $script:PurviewComplianceAdministratorRoleDefinitionId -or
            [string]$definition.templateId -cne $script:PurviewComplianceAdministratorRoleDefinitionId -or
            $definition.isBuiltIn -ne $true -or $definition.isEnabled -ne $true) {
            throw 'The supported Compliance Administrator role definition was not available exactly.'
        }
        Invoke-GraphJsonBody -Method 'POST' -Url (
            'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments') -Body @{
            principalId = [string]$principal.id
            roleDefinitionId = $script:PurviewComplianceAdministratorRoleDefinitionId
            directoryScopeId = '/'
        } | Out-Null
    }
    $assignmentVerified = $false
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            $principal = Get-ServicePrincipalByAppId -AppId ([string]$application.appId)
            $null = Assert-BootstrapPurviewAutomationServicePrincipal `
                -Principal $principal `
                -ApplicationId ([string]$application.appId) `
                -DeploymentOwnershipId $DeploymentOwnershipId `
                -ExchangeRole $exchangeRole
            $assignmentVerified = $true
            break
        }
        catch {
            if ($attempt -lt 12) { Start-Sleep -Seconds 5 }
        }
    }
    if (-not $assignmentVerified) {
        throw 'Purview automation app-only and Compliance Administrator assignments were not observed exactly.'
    }

    $certificate = Get-GatewayPurviewAutomationCertificateSecretArmMetadata `
        -Config $Config `
        -KeyVaultUri $KeyVaultUri `
        -AutomationApplicationId ([string]$application.appId) `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $SourceFingerprint
    $keys = @($application.keyCredentials)
    if (($keys.Count -eq 0) -ne ([string]$certificate.status -ceq 'Absent')) {
        throw 'Purview automation certificate state is partial across Entra and Key Vault; no automatic replacement was attempted.'
    }
    if ($keys.Count -eq 0) {
        if ($ReconcileOnly) { throw 'Purview automation certificate is missing during read-only reconciliation.' }
        $rsa = $null
        $certificateObject = $null
        $pfxBytes = $null
        $publicBytes = $null
        $certificateSecretText = $null
        try {
            $rsa = New-BootstrapPurviewCertificateRsa
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                "CN=a365gw-$($Config.projectName)-$($Config.environment)-purview",
                $rsa,
                [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $request.CertificateExtensions.Add(
                [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
            $request.CertificateExtensions.Add(
                [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                    [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,
                    $true))
            $notBefore = [DateTimeOffset]::UtcNow.AddMinutes(-5)
            $notAfter = [DateTimeOffset]::UtcNow.AddYears(1)
            $certificateObject = $request.CreateSelfSigned($notBefore, $notAfter)
            $pfxBytes = $certificateObject.Export(
                [Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12)
            $publicBytes = $certificateObject.Export(
                [Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            $certificateSecretText = [Convert]::ToBase64String($pfxBytes)
            $thumbprint = ([string]$certificateObject.Thumbprint).ToLowerInvariant()
            $keyCredentialId = [guid]::NewGuid().ToString('D')
            $null = Deploy-GatewayPurviewAutomationCertificateSecret `
                -Config $Config `
                -KeyVaultUri $KeyVaultUri `
                -AutomationApplicationId ([string]$application.appId) `
                -KeyCredentialId $keyCredentialId `
                -CertificateThumbprint $thumbprint `
                -CertificateSecretText $certificateSecretText `
                -DeploymentOwnershipId $DeploymentOwnershipId `
                -SourceFingerprint $SourceFingerprint
            try {
                Invoke-GraphJsonBody -Method 'PATCH' -Url (
                    "https://graph.microsoft.com/v1.0/applications/$($application.id)") -Body @{
                    keyCredentials = @(@{
                        keyId = $keyCredentialId
                        displayName = 'a365gw-purview-automation-certificate'
                        type = 'AsymmetricX509Cert'
                        usage = 'Verify'
                        key = [Convert]::ToBase64String($publicBytes)
                        customKeyIdentifier = [Convert]::ToBase64String(
                            [Convert]::FromHexString($thumbprint))
                        startDateTime = $notBefore.ToString('O')
                        endDateTime = $notAfter.ToString('O')
                    })
                } | Out-Null
            }
            catch {
                $application = Get-BootstrapPurviewAutomationApplication `
                    -ApplicationObjectId ([string]$application.id)
                if (@($application.keyCredentials | Where-Object {
                    [string]$_.keyId -ceq $keyCredentialId
                }).Count -ne 1) {
                    throw 'Microsoft Graph returned an unknown Purview certificate outcome and exact readback did not prove success.'
                }
            }
        }
        finally {
            if ($pfxBytes) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($pfxBytes) }
            if ($publicBytes) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($publicBytes) }
            if ($certificateObject) { $certificateObject.Dispose() }
            if ($rsa) { $rsa.Dispose() }
            $certificateSecretText = $null
            $request = $null
        }
    }

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            return Get-BootstrapPurviewAutomationIdentityEvidence `
                -Config $Config `
                -AzureIdentity $AzureIdentity `
                -KeyVaultUri $KeyVaultUri `
                -DeploymentOwnershipId $DeploymentOwnershipId `
                -SourceFingerprint $SourceFingerprint
        }
        catch {
            if ($attempt -eq 12) { throw }
            Start-Sleep -Seconds 5
        }
    }
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

function Get-GatewayPurviewRuntimeManagedIdentity {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Identity
    )

    if ($Config.purview.enabled -ne $true) {
        throw 'Purview runtime managed-identity readback requires the Purview capability.'
    }

    $name = "id-gateway-runtime-pull-$($Config.environment)"
    $resource = Invoke-AzJson -Arguments @(
        'identity', 'show',
        '--subscription', [string]$Config.subscriptionId,
        '--resource-group', [string]$Config.resourceGroupName,
        '--name', $name
    )
    $expectedId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$name"
    $clientId = [guid]::Empty
    $principalId = [guid]::Empty
    if ([string]$resource.id -ine $expectedId -or
        [string]$resource.name -cne $name -or
        [string]$resource.type -ine 'Microsoft.ManagedIdentity/userAssignedIdentities' -or
        [string]$resource.location -ine [string]$Config.location -or
        [string]$resource.tenantId -ine [string]$Config.tenantId -or
        -not [guid]::TryParse([string]$resource.clientId, [ref]$clientId) -or
        $clientId -eq [guid]::Empty -or
        [string]$resource.clientId -cne $clientId.ToString('D') -or
        -not [guid]::TryParse([string]$resource.principalId, [ref]$principalId) -or
        $principalId -eq [guid]::Empty -or
        [string]$resource.principalId -cne $principalId.ToString('D') -or
        [string]$resource.tags.application -cne 'a365-custom-gateway' -or
        [string]$resource.tags.environment -cne [string]$Config.environment -or
        [string]$resource.tags.managedBy -cne 'bootstrap' -or
        [string]$resource.tags.projectName -cne [string]$Config.projectName -or
        [string]$resource.tags.deploymentId -cne "$($Config.projectName)-$($Config.environment)" -or
        [string]$resource.tags.bootstrapOwnershipId -cne [string]$Identity.deploymentOwnershipId -or
        [string]$resource.tags.workload -cne 'runtime-image-pull') {
        throw 'The API Purview runtime managed identity does not match the exact bootstrap-owned deployment boundary.'
    }

    return [ordered]@{
        resourceId = $expectedId
        clientId = $clientId.ToString('D')
        principalId = $principalId.ToString('D')
    }
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
    $purviewRuntimeRoles = @(
        'ProtectionScopes.Compute.User',
        'Content.Process.User',
        'ContentActivity.Write'
    )
    $purviewRuntimeIdentity = $null
    if ($EnablePurview) {
        $purviewRuntimeIdentity = Get-GatewayPurviewRuntimeManagedIdentity `
            -Config $Config `
            -Identity $Identity
    }
    # Reject unknown requested permissions or grants before making any Entra
    # mutation. Missing members of the reviewed sets may be added below, but an
    # extra FIC or application-role assignment requires explicit runbook recovery.
    Assert-GatewayApiDelegatedPermissionBoundary -Identity $Identity | Out-Null
    Assert-GatewayFederatedCredentialBoundary -Config $Config -Identity $Identity -ApiPrincipalId $ApiPrincipalId -AllowMissing | Out-Null
    Assert-GraphApplicationRoleAssignmentBoundary -PrincipalId $WorkerPrincipalId -ExpectedRoleValues $workerRoles | Out-Null
    Assert-GraphApplicationRoleAssignmentBoundary -PrincipalId $ApiPrincipalId -ExpectedRoleValues @($apiRoles) | Out-Null
    if ($EnablePurview) {
        Assert-GraphApplicationRoleAssignmentBoundary `
            -PrincipalId $purviewRuntimeIdentity.principalId `
            -ExpectedRoleValues $purviewRuntimeRoles | Out-Null
    }
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
    if ($EnablePurview) {
        foreach ($role in $purviewRuntimeRoles) {
            $null = Ensure-GraphApplicationRoleAssignment `
                -PrincipalId $purviewRuntimeIdentity.principalId `
                -RoleValue $role
        }
    }
    Assert-GatewayApiDelegatedPermissionBoundary -Identity $Identity -RequireComplete | Out-Null
    Assert-ExactGraphApplicationRoleAssignments -PrincipalId $WorkerPrincipalId -ExpectedRoleValues $workerRoles | Out-Null
    Assert-ExactGraphApplicationRoleAssignments -PrincipalId $ApiPrincipalId -ExpectedRoleValues @($apiRoles) | Out-Null
    if ($EnablePurview) {
        Assert-ExactGraphApplicationRoleAssignments -PrincipalId $purviewRuntimeIdentity.principalId -ExpectedRoleValues $purviewRuntimeRoles | Out-Null
    }
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
    $purviewRuntimeRoles = @(
        'ProtectionScopes.Compute.User',
        'Content.Process.User',
        'ContentActivity.Write'
    )
    $purviewRuntimeIdentity = $null
    if ($EnablePurview) {
        $purviewRuntimeIdentity = Get-GatewayPurviewRuntimeManagedIdentity `
            -Config $Config `
            -Identity $Identity
    }
    Assert-GatewayApiDelegatedPermissionBoundary -Identity $Identity -RequireComplete | Out-Null
    Assert-ExactGraphApplicationRoleAssignments -PrincipalId $WorkerPrincipalId -ExpectedRoleValues $workerRoles | Out-Null
    Assert-ExactGraphApplicationRoleAssignments -PrincipalId $ApiPrincipalId -ExpectedRoleValues @($apiRoles) | Out-Null
    if ($EnablePurview) {
        Assert-ExactGraphApplicationRoleAssignments -PrincipalId $purviewRuntimeIdentity.principalId -ExpectedRoleValues $purviewRuntimeRoles | Out-Null
    }

    $ficName = "a365gw-$($Config.projectName)-api-obo-$($Config.environment)"
    Assert-GatewayFederatedCredentialBoundary -Config $Config -Identity $Identity -ApiPrincipalId $ApiPrincipalId | Out-Null
    $graph = (Get-GraphPermissionCatalog).servicePrincipal
    $workerRoleIds = [ordered]@{}
    foreach ($role in $workerRoles) { $workerRoleIds[$role] = Get-UniqueGraphPermissionId -Graph $graph -Value $role -Type Role }
    $apiHostRoleIds = [ordered]@{}
    foreach ($role in $apiRoles) { $apiHostRoleIds[$role] = Get-UniqueGraphPermissionId -Graph $graph -Value $role -Type Role }
    $purviewRuntimeRoleIds = [ordered]@{}
    if ($EnablePurview) {
        foreach ($role in $purviewRuntimeRoles) {
            $purviewRuntimeRoleIds[$role] =
                Get-UniqueGraphPermissionId -Graph $graph -Value $role -Type Role
        }
    }
    $apiCapabilityRoleIds = [ordered]@{}
    foreach ($entry in $apiHostRoleIds.GetEnumerator()) {
        $apiCapabilityRoleIds[[string]$entry.Key] = [string]$entry.Value
    }
    foreach ($entry in $purviewRuntimeRoleIds.GetEnumerator()) {
        $apiCapabilityRoleIds[[string]$entry.Key] = [string]$entry.Value
    }
    return [ordered]@{
        federatedCredentialName = $ficName
        workerApplicationRoles = $workerRoleIds
        # Retain the established capability-level role map while binding its
        # Purview members to the dedicated runtime identity below.
        apiApplicationRoles = $apiCapabilityRoleIds
        apiHostApplicationRoles = $apiHostRoleIds
        purviewRuntimeIdentityResourceId = if ($EnablePurview) { [string]$purviewRuntimeIdentity.resourceId } else { '' }
        purviewRuntimeManagedIdentityClientId = if ($EnablePurview) { [string]$purviewRuntimeIdentity.clientId } else { '' }
        purviewRuntimeManagedIdentityPrincipalId = if ($EnablePurview) { [string]$purviewRuntimeIdentity.principalId } else { '' }
        purviewRuntimeApplicationRoles = $purviewRuntimeRoleIds
        delegatedRegistryScopes = @('AgentRegistration.Read.All', 'AgentRegistration.ReadWrite.All')
    }
}

function Test-GatewayWorkflowIdentityEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$Inert,
        [Parameter(Mandatory)]$Evidence
    )

    if ($Config.purview.enabled -ne $true) {
        return Experience\Test-GatewayWorkflowIdentityEvidence `
            -Config $Config `
            -Identity $Identity `
            -Inert $Inert `
            -Evidence $Evidence
    }

    if ($Evidence.apiHostApplicationRoles -isnot [System.Collections.IDictionary] -or
        $Evidence.purviewRuntimeApplicationRoles -isnot [System.Collections.IDictionary]) {
        throw 'Workflow identity evidence has no exact API Purview runtime identity binding.'
    }

    $baseConfig = $Config | Select-Object *
    $baseConfig.purview = $Config.purview | Select-Object *
    $baseConfig.purview.enabled = $false
    $baseEvidence = [ordered]@{}
    foreach ($entry in $Evidence.GetEnumerator()) {
        $baseEvidence[[string]$entry.Key] = $entry.Value
    }
    $baseEvidence.apiApplicationRoles = $Evidence.apiHostApplicationRoles
    $null = Experience\Test-GatewayWorkflowIdentityEvidence `
        -Config $baseConfig `
        -Identity $Identity `
        -Inert $Inert `
        -Evidence $baseEvidence

    $runtimeIdentity = Get-GatewayPurviewRuntimeManagedIdentity `
        -Config $Config `
        -Identity $Identity
    $requiredRoles = @(
        'ProtectionScopes.Compute.User',
        'Content.Process.User',
        'ContentActivity.Write'
    )
    Assert-ExactGraphApplicationRoleAssignments `
        -PrincipalId $runtimeIdentity.principalId `
        -ExpectedRoleValues $requiredRoles | Out-Null
    $evidenceRoles = @(
        $Evidence.purviewRuntimeApplicationRoles.Keys |
            ForEach-Object { [string]$_ } |
            Sort-Object
    )
    if ([string]$Evidence.purviewRuntimeIdentityResourceId -ine [string]$runtimeIdentity.resourceId -or
        [string]$Evidence.purviewRuntimeManagedIdentityClientId -cne [string]$runtimeIdentity.clientId -or
        [string]$Evidence.purviewRuntimeManagedIdentityPrincipalId -cne [string]$runtimeIdentity.principalId -or
        ($evidenceRoles -join '|') -cne (($requiredRoles | Sort-Object) -join '|')) {
        throw 'Workflow identity evidence no longer matches the exact API Purview runtime identity.'
    }

    return $true
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
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [ValidateRange(1, 30)][int]$MaximumAttempts = 18
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $state = Get-AdminUiCredentialReconciliationState `
                -Config $Config `
                -AdminIdentity $AdminIdentity `
                -KeyVaultUri $KeyVaultUri `
                -DeploymentOwnershipId $DeploymentOwnershipId `
                -SourceFingerprint $SourceFingerprint
            if ([string]$state.status -ceq 'ExactPair') { return $state.evidence }
        }
        catch { }
        if ($attempt -lt $MaximumAttempts) { Start-Sleep -Seconds 5 }
    }
    throw 'Admin UI credential metadata was not observed with the exact bootstrap-owned Graph and ARM boundary during the bounded readback window.'
}

function Get-AdminUiCredentialReconciliationState {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AdminIdentity,
        [Parameter(Mandatory)][string]$KeyVaultUri,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $applicationObjectId = [guid]::Empty
    $clientId = [guid]::Empty
    $ownershipId = [guid]::Empty
    $subscriptionId = [guid]::Empty
    if (-not [guid]::TryParse([string]$AdminIdentity.adminUiApplicationObjectId, [ref]$applicationObjectId) -or
        $applicationObjectId -eq [guid]::Empty -or
        -not [guid]::TryParse([string]$AdminIdentity.adminUiClientId, [ref]$clientId) -or
        $clientId -eq [guid]::Empty -or
        -not [guid]::TryParse([string]$Config.subscriptionId, [ref]$subscriptionId) -or
        $subscriptionId -eq [guid]::Empty -or
        [string]$Config.subscriptionId -cne $subscriptionId.ToString('D') -or
        [string]$Config.resourceGroupName -cnotmatch '^[A-Za-z0-9._()\-]{1,90}$' -or
        [string]$Config.resourceGroupName -match '[.]$' -or
        -not [guid]::TryParse($DeploymentOwnershipId, [ref]$ownershipId) -or
        $ownershipId -eq [guid]::Empty -or
        $DeploymentOwnershipId -cne $ownershipId.ToString('D') -or
        [string]$AdminIdentity.deploymentOwnershipId -cne $ownershipId.ToString('D')) {
        throw 'Admin UI credential reconciliation identity or ownership evidence is invalid.'
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Admin UI credential reconciliation source fingerprint'

    $vault = $null
    if (-not [Uri]::TryCreate($KeyVaultUri, [UriKind]::Absolute, [ref]$vault) -or
        $vault.Scheme -cne 'https' -or -not $vault.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($vault.UserInfo) -or
        -not [string]::IsNullOrEmpty($vault.Query) -or
        -not [string]::IsNullOrEmpty($vault.Fragment) -or
        $vault.AbsolutePath -cne '/' -or
        $vault.DnsSafeHost -cnotmatch '^[a-z][a-z0-9-]{2,23}[.]vault[.]azure[.]net$') {
        throw 'Admin UI credential reconciliation requires one exact HTTPS Key Vault origin.'
    }

    $application = $null
    $metadata = $null
    try {
        $application = Invoke-AzJson -Arguments @(
            'rest', '--method', 'GET', '--url',
            "https://graph.microsoft.com/v1.0/applications/$($applicationObjectId.ToString('D'))?`$select=appId,passwordCredentials"
        )
        if ($null -eq $application -or
            -not ([string](Get-OptionalObjectPropertyValue -InputObject $application -PropertyName 'appId')).Equals($clientId.ToString('D'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'graph-mismatch'
        }
        if ($application -is [Collections.IDictionary]) {
            if (-not $application.Contains('passwordCredentials')) { throw 'graph-shape' }
            $credentials = @($application['passwordCredentials'])
        }
        else {
            $credentialProperty = $application.PSObject.Properties['passwordCredentials']
            if ($null -eq $credentialProperty) { throw 'graph-shape' }
            $credentials = @($credentialProperty.Value)
        }
        $metadata = Get-GatewayAdminUiCredentialSecretArmMetadata `
            -Config $Config `
            -KeyVaultUri $KeyVaultUri `
            -DeploymentOwnershipId $ownershipId.ToString('D') `
            -SourceFingerprint $SourceFingerprint
    }
    catch {
        throw 'Admin UI credential reconciliation could not read the exact Graph and ARM metadata boundary.'
    }

    $graphStatus = 'Mismatch'
    $credential = $null
    $expires = [DateTimeOffset]::MinValue
    $credentialKeyId = [guid]::Empty
    if ($credentials.Count -eq 0) {
        $graphStatus = 'Absent'
    }
    elseif ($credentials.Count -eq 1 -and
        [string](Get-OptionalObjectPropertyValue -InputObject $credentials[0] -PropertyName 'displayName') -ceq 'a365gw-bootstrap-admin-ui' -and
        [guid]::TryParse([string](Get-OptionalObjectPropertyValue -InputObject $credentials[0] -PropertyName 'keyId'), [ref]$credentialKeyId) -and
        $credentialKeyId -ne [guid]::Empty -and
        [DateTimeOffset]::TryParse(
            [string](Get-OptionalObjectPropertyValue -InputObject $credentials[0] -PropertyName 'endDateTime'),
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$expires) -and
        $expires.ToUniversalTime() -gt [DateTimeOffset]::UtcNow) {
        $graphStatus = 'Present'
        $credential = $credentials[0]
    }

    $armStatus = [string](Get-OptionalObjectPropertyValue -InputObject $metadata -PropertyName 'status')
    if ($armStatus -cnotin @('Present', 'Absent')) {
        throw 'Admin UI credential reconciliation received an unsupported ARM metadata state.'
    }
    if ($graphStatus -ceq 'Absent' -and $armStatus -ceq 'Absent') {
        return [pscustomobject][ordered]@{ status = 'DoubleAbsent' }
    }

    if ($graphStatus -ceq 'Present' -and $armStatus -ceq 'Present') {
        $vaultName = $vault.DnsSafeHost.Substring(0, $vault.DnsSafeHost.IndexOf('.'))
        $expectedSecretResourceId = "/subscriptions/$($subscriptionId.ToString('D'))/resourceGroups/$($Config.resourceGroupName)/providers/Microsoft.KeyVault/vaults/$vaultName/secrets/admin-ui-entra-client-secret"
        $tags = Get-OptionalObjectPropertyValue -InputObject $metadata -PropertyName 'tags'
        $tagNames = if ($tags -is [Collections.IDictionary]) {
            @($tags.Keys | ForEach-Object { [string]$_ })
        }
        elseif ($null -ne $tags) {
            @($tags.PSObject.Properties.Name | ForEach-Object { [string]$_ })
        }
        else { @() }
        $metadataKeyId = [guid]::Empty
        $exactPair =
            $tagNames.Count -eq 4 -and
            @(@('managedBy', 'credentialKeyId', 'bootstrapOwnershipId', 'bootstrapSourceFingerprint') |
                Where-Object { $tagNames -cnotcontains $_ }).Count -eq 0 -and
            ([string](Get-OptionalObjectPropertyValue -InputObject $metadata -PropertyName 'id')).Equals($expectedSecretResourceId, [StringComparison]::OrdinalIgnoreCase) -and
            [string](Get-OptionalObjectPropertyValue -InputObject $metadata -PropertyName 'name') -ceq 'admin-ui-entra-client-secret' -and
            (Get-OptionalObjectPropertyValue -InputObject $metadata -PropertyName 'enabled') -eq $true -and
            [string](Get-OptionalObjectPropertyValue -InputObject $metadata -PropertyName 'contentType') -ceq 'application/vnd.a365-gateway.admin-ui-entra-client-secret' -and
            [string](Get-OptionalObjectPropertyValue -InputObject $tags -PropertyName 'managedBy') -ceq 'a365gw-bootstrap' -and
            [string](Get-OptionalObjectPropertyValue -InputObject $tags -PropertyName 'bootstrapOwnershipId') -ceq $ownershipId.ToString('D') -and
            [string](Get-OptionalObjectPropertyValue -InputObject $tags -PropertyName 'bootstrapSourceFingerprint') -ceq $SourceFingerprint -and
            [guid]::TryParse([string](Get-OptionalObjectPropertyValue -InputObject $tags -PropertyName 'credentialKeyId'), [ref]$metadataKeyId) -and
            $metadataKeyId -ne [guid]::Empty -and
            $metadataKeyId -eq $credentialKeyId
        if ($exactPair) {
            return [pscustomobject][ordered]@{
                status = 'ExactPair'
                evidence = [ordered]@{
                    secretUri = "$($KeyVaultUri.TrimEnd('/'))/secrets/admin-ui-entra-client-secret"
                    credentialKeyId = $credentialKeyId.ToString('D')
                    credentialExpiresAtUtc = $expires.ToUniversalTime().ToString('O')
                    deploymentOwnershipId = $ownershipId.ToString('D')
                    sourceFingerprint = $SourceFingerprint
                    contentType = 'application/vnd.a365-gateway.admin-ui-entra-client-secret'
                }
            }
        }
    }

    return [pscustomobject][ordered]@{ status = 'PartialOrMismatch' }
}

function Resolve-AdminUiCredentialAfterStartedOutcome {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AdminIdentity,
        [Parameter(Mandatory)][string]$KeyVaultUri,
        [Parameter(Mandatory)][string]$UserObjectId,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    Assert-GuidValue -Value $UserObjectId -Label 'Admin UI credential operator object ID'
    $ownershipId = [guid]::Empty
    if (-not [guid]::TryParse($DeploymentOwnershipId, [ref]$ownershipId) -or
        $ownershipId -eq [guid]::Empty -or
        $DeploymentOwnershipId -cne $ownershipId.ToString('D') -or
        [string]$AdminIdentity.deploymentOwnershipId -cne $ownershipId.ToString('D')) {
        throw 'Admin UI credential recovery ownership evidence is invalid.'
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Admin UI credential recovery source fingerprint'
    $vault = $null
    if (-not [Uri]::TryCreate($KeyVaultUri, [UriKind]::Absolute, [ref]$vault) -or
        $vault.Scheme -cne 'https' -or -not $vault.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($vault.UserInfo) -or
        -not [string]::IsNullOrEmpty($vault.Query) -or
        -not [string]::IsNullOrEmpty($vault.Fragment) -or
        $vault.AbsolutePath -cne '/' -or
        $vault.DnsSafeHost -cnotmatch '^[a-z][a-z0-9-]{2,23}[.]vault[.]azure[.]net$') {
        throw 'Admin UI credential recovery requires one exact HTTPS Key Vault origin.'
    }
    $vaultName = $vault.DnsSafeHost.Substring(0, $vault.DnsSafeHost.IndexOf('.'))
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

    $consecutiveDoubleAbsenceReads = 0
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $state = Get-AdminUiCredentialReconciliationState `
            -Config $Config `
            -AdminIdentity $AdminIdentity `
            -KeyVaultUri $KeyVaultUri `
            -DeploymentOwnershipId $ownershipId.ToString('D') `
            -SourceFingerprint $SourceFingerprint
        if ([string]$state.status -ceq 'ExactPair') { return $state.evidence }
        if ([string]$state.status -ceq 'PartialOrMismatch') {
            throw 'Admin UI credential recovery found partial or mismatched provider state. Use the reviewed credential-rotation procedure; no mutation was attempted.'
        }
        if ([string]$state.status -cne 'DoubleAbsent') {
            throw 'Admin UI credential recovery received an unsupported reconciliation state.'
        }
        $consecutiveDoubleAbsenceReads++
        if ($consecutiveDoubleAbsenceReads -ge 3) { break }
        if ($attempt -lt 18) { Start-Sleep -Seconds 5 }
    }
    if ($consecutiveDoubleAbsenceReads -lt 3) {
        throw 'Admin UI credential recovery could not prove consecutive exact absence in both providers.'
    }
    return New-AdminUiCredentialInKeyVault `
        -Config $Config `
        -AdminIdentity $AdminIdentity `
        -KeyVaultUri $KeyVaultUri `
        -DeploymentOwnershipId $ownershipId.ToString('D') `
        -SourceFingerprint $SourceFingerprint
}

function New-AdminUiCredentialInKeyVault {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AdminIdentity,
        [Parameter(Mandatory)][string]$KeyVaultUri,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $ownershipId = [guid]::Empty
    if (-not [guid]::TryParse($DeploymentOwnershipId, [ref]$ownershipId) -or
        $ownershipId -eq [guid]::Empty -or
        $DeploymentOwnershipId -cne $ownershipId.ToString('D') -or
        [string]$AdminIdentity.deploymentOwnershipId -cne $ownershipId.ToString('D')) {
        throw 'Admin UI credential creation ownership evidence is invalid.'
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Admin UI credential creation source fingerprint'

    $credential = $null
    $secretText = $null
    $passwordRequest = $null
    $secretMetadata = $null
    try {
        $state = Get-AdminUiCredentialReconciliationState `
            -Config $Config `
            -AdminIdentity $AdminIdentity `
            -KeyVaultUri $KeyVaultUri `
            -DeploymentOwnershipId $ownershipId.ToString('D') `
            -SourceFingerprint $SourceFingerprint
        if ([string]$state.status -ceq 'ExactPair') { return $state.evidence }
        if ([string]$state.status -cne 'DoubleAbsent') {
            throw 'Admin UI credential creation found partial or mismatched provider state. Use the reviewed credential-rotation procedure; no mutation was attempted.'
        }

        $passwordRequest = [ordered]@{
            passwordCredential = [ordered]@{
                displayName = 'a365gw-bootstrap-admin-ui'
                endDateTime = [DateTimeOffset]::UtcNow.AddYears(1).ToString('O')
            }
        }
        try {
            $credential = Invoke-GraphJsonBody `
                -Method 'POST' `
                -Url "https://graph.microsoft.com/v1.0/applications/$($AdminIdentity.adminUiApplicationObjectId)/addPassword" `
                -Body $passwordRequest
        }
        catch {
            throw 'Microsoft Graph returned an unknown Admin UI credential-creation outcome. Resume must reconcile exact provider metadata before any further mutation.'
        }

        $credentialKeyId = [guid]::Empty
        if (-not [guid]::TryParse([string](Get-OptionalObjectPropertyValue -InputObject $credential -PropertyName 'keyId'), [ref]$credentialKeyId) -or
            $credentialKeyId -eq [guid]::Empty) {
            throw 'Microsoft Graph did not return one valid Admin UI credential key ID.'
        }
        $secretText = [string]$credential.secretText
        if ([string]::IsNullOrEmpty($secretText)) { throw 'Microsoft Graph did not return the one-time Admin UI credential.' }

        try {
            $secretMetadata = Deploy-GatewayAdminUiCredentialSecret `
                -Config $Config `
                -KeyVaultUri $KeyVaultUri `
                -CredentialKeyId $credentialKeyId.ToString('D') `
                -SecretText $secretText `
                -DeploymentOwnershipId $ownershipId.ToString('D') `
                -SourceFingerprint $SourceFingerprint
        }
        catch {
            try {
                $secretMetadata = Get-GatewayAdminUiCredentialSecretArmMetadata `
                    -Config $Config `
                    -KeyVaultUri $KeyVaultUri `
                    -DeploymentOwnershipId $ownershipId.ToString('D') `
                    -SourceFingerprint $SourceFingerprint
            }
            catch {
                throw 'The one ARM secret deployment returned an unknown outcome and exact metadata reconciliation did not prove success. No deployment was repeated.'
            }
        }
        # The full Graph-plus-ARM classifier below is the single authoritative
        # proof. It independently re-reads the child resource and rejects an
        # absent, mismatched, disabled, wrong-owner, or wrong-source result.
        return Get-AdminUiCredentialEvidenceFromMetadata `
            -Config $Config `
            -AdminIdentity $AdminIdentity `
            -KeyVaultUri $KeyVaultUri `
            -DeploymentOwnershipId $ownershipId.ToString('D') `
            -SourceFingerprint $SourceFingerprint
    }
    finally {
        if ($credential) {
            if ($credential -is [Collections.IDictionary]) {
                if ($credential.Contains('secretText')) { $credential['secretText'] = $null }
            }
            else {
                $secretProperty = $credential.PSObject.Properties['secretText']
                if ($null -ne $secretProperty) { $secretProperty.Value = $null }
            }
        }
        $secretText = $null
        $secretMetadata = $null
        if ($passwordRequest) {
            if ($passwordRequest.passwordCredential) { $passwordRequest.passwordCredential.Clear() }
            $passwordRequest.Clear()
        }
        $passwordRequest = $null
        $credential = $null
    }
}

Export-ModuleMember -Function *
