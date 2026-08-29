Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Agent365BlueprintNextLink {
    param([Parameter(Mandatory)][string]$Value)

    $nextLink = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$nextLink) -or
        $nextLink.Scheme -cne 'https' -or
        $nextLink.Host -cne 'graph.microsoft.com' -or
        (-not $nextLink.IsDefaultPort -and $nextLink.Port -ne 443) -or
        -not [string]::IsNullOrEmpty($nextLink.UserInfo) -or
        -not [string]::IsNullOrEmpty($nextLink.Fragment) -or
        -not $nextLink.AbsolutePath.Equals('/v1.0/applications/microsoft.graph.agentIdentityBlueprint', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Agent ID blueprint paging returned an invalid or off-origin continuation URL.'
    }
    return $nextLink.AbsoluteUri
}

function Get-Agent365BlueprintByName {
    param([Parameter(Mandatory)][string]$DisplayName)

    $nextUrl = 'https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint?$select=id,appId,displayName,managerApplications,signInAudience,identifierUris,tags,api,appRoles,requiredResourceAccess,passwordCredentials,keyCredentials,web,spa,publicClient,isFallbackPublicClient&$top=100'
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $matches = [Collections.Generic.List[object]]::new()
    for ($page = 1; $page -le 100; $page++) {
        if (-not $visited.Add($nextUrl)) { throw 'Agent ID blueprint paging returned a repeated continuation URL.' }
        $response = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', $nextUrl)
        if ($null -eq $response) { throw 'Agent ID blueprint paging returned no response object.' }

        $value = $null
        if ($response -is [System.Collections.IDictionary]) {
            if (-not $response.Contains('value')) { throw 'Agent ID blueprint paging omitted the required value collection.' }
            $value = $response['value']
        }
        else {
            $valueProperty = @($response.PSObject.Properties | Where-Object { $_.Name -ceq 'value' })
            if ($valueProperty.Count -ne 1) { throw 'Agent ID blueprint paging omitted the required value collection.' }
            $value = $valueProperty[0].Value
        }
        if ($null -eq $value -or $value -is [string] -or
            $value -is [System.Collections.IDictionary] -or
            $value -isnot [System.Collections.IEnumerable]) {
            throw 'Agent ID blueprint paging returned a malformed value collection.'
        }
        $pageItems = @($value)
        if ($pageItems.Count -gt 100) {
            throw 'Agent ID blueprint paging exceeded the requested 100-item page boundary.'
        }
        foreach ($blueprint in $pageItems) {
            if ($null -eq $blueprint) { throw 'Agent ID blueprint paging returned a null collection member.' }
            if ([string]$blueprint.displayName -and
                ([string]$blueprint.displayName).Equals($DisplayName, [StringComparison]::OrdinalIgnoreCase)) {
                $matches.Add($blueprint)
            }
        }
        if ($matches.Count -gt 1) { throw "More than one typed Agent ID blueprint is named '$DisplayName'." }

        $continuation = if ($response -is [System.Collections.IDictionary]) {
            if ($response.Contains('@odata.nextLink')) { [string]$response['@odata.nextLink'] } else { '' }
        }
        else {
            $continuationProperty = @($response.PSObject.Properties | Where-Object { $_.Name -ceq '@odata.nextLink' })
            if ($continuationProperty.Count -gt 1) { throw 'Agent ID blueprint paging returned ambiguous continuation metadata.' }
            if ($continuationProperty.Count -eq 1) { [string]$continuationProperty[0].Value } else { '' }
        }
        if ([string]::IsNullOrWhiteSpace($continuation)) {
            if ($matches.Count -eq 1) { return $matches[0] }
            return $null
        }
        if ($page -eq 100) { throw 'Agent ID blueprint paging exceeded the bounded 100-page discovery limit.' }
        $nextUrl = Get-Agent365BlueprintNextLink -Value $continuation
    }
    throw 'Agent ID blueprint paging ended without a terminal response.'
}

function Get-Agent365RequiredProperty {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Label
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        if (-not $InputObject.Contains($Name)) { throw "$Label omitted required property '$Name'." }
        return $InputObject[$Name]
    }
    $properties = @($InputObject.PSObject.Properties | Where-Object { $_.Name -ceq $Name })
    if ($properties.Count -ne 1) { throw "$Label omitted or duplicated required property '$Name'." }
    return $properties[0].Value
}

function Get-Agent365RequiredCollectionItems {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Label,
        [int]$MaximumCount = 1000
    )

    # Invoke the existing accessor first so an omitted selected property is
    # distinguishable from a present, empty array. Then retrieve the raw value
    # without allowing PowerShell's pipeline to unwrap an empty collection.
    $null = Get-Agent365RequiredProperty -InputObject $InputObject -Name $Name -Label $Label
    $value = $null
    if ($InputObject -is [System.Collections.IDictionary]) {
        $value = $InputObject[$Name]
    }
    else {
        $value = @($InputObject.PSObject.Properties | Where-Object { $_.Name -ceq $Name })[0].Value
    }
    if ($null -eq $value -or $value -is [string] -or
        $value -is [System.Collections.IDictionary] -or
        $value -isnot [System.Collections.IEnumerable]) {
        throw "$Label property '$Name' is not a collection."
    }
    $items = @($value)
    if ($items.Count -gt $MaximumCount -or @($items | Where-Object { $null -eq $_ }).Count -ne 0) {
        throw "$Label property '$Name' exceeded its bounded shape or contains a null member."
    }
    return @($items)
}

function Get-Agent365BoundedGraphCollection {
    param(
        [Parameter(Mandatory)][string]$InitialUrl,
        [Parameter(Mandatory)][string]$ExpectedPath,
        [Parameter(Mandatory)][string]$OperationLabel
    )

    $nextUrl = $InitialUrl
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $items = [Collections.Generic.List[object]]::new()
    for ($page = 1; $page -le 100; $page++) {
        $uri = $null
        if (-not [Uri]::TryCreate($nextUrl, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -cne 'https' -or $uri.Host -cne 'graph.microsoft.com' -or
            (-not $uri.IsDefaultPort -and $uri.Port -ne 443) -or
            -not [string]::IsNullOrEmpty($uri.UserInfo) -or
            -not [string]::IsNullOrEmpty($uri.Fragment) -or
            -not $uri.AbsolutePath.Equals($ExpectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$OperationLabel returned an invalid or off-origin Graph collection URL."
        }
        if (-not $visited.Add($uri.AbsoluteUri)) { throw "$OperationLabel returned a repeated continuation URL." }

        $response = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', $uri.AbsoluteUri)
        if ($null -eq $response) { throw "$OperationLabel returned no response object." }
        $value = $null
        if ($response -is [System.Collections.IDictionary]) {
            if (-not $response.Contains('value')) { throw "$OperationLabel omitted required property 'value'." }
            $value = $response['value']
        }
        else {
            $valueProperties = @($response.PSObject.Properties | Where-Object { $_.Name -ceq 'value' })
            if ($valueProperties.Count -ne 1) { throw "$OperationLabel omitted or duplicated required property 'value'." }
            $value = $valueProperties[0].Value
        }
        if ($null -eq $value -or $value -is [string] -or
            $value -is [System.Collections.IDictionary] -or
            $value -isnot [System.Collections.IEnumerable]) {
            throw "$OperationLabel returned a malformed value collection."
        }
        $pageItems = @($value)
        if ($pageItems.Count -gt 1000 -or ($items.Count + $pageItems.Count) -gt 10000) {
            throw "$OperationLabel exceeded its bounded collection size."
        }
        foreach ($item in $pageItems) {
            if ($null -eq $item) { throw "$OperationLabel returned a null collection member." }
            $items.Add($item)
        }

        $continuation = ''
        if ($response -is [System.Collections.IDictionary]) {
            if ($response.Contains('@odata.nextLink')) { $continuation = [string]$response['@odata.nextLink'] }
        }
        else {
            $continuationProperties = @($response.PSObject.Properties | Where-Object { $_.Name -ceq '@odata.nextLink' })
            if ($continuationProperties.Count -gt 1) { throw "$OperationLabel returned ambiguous continuation metadata." }
            if ($continuationProperties.Count -eq 1) { $continuation = [string]$continuationProperties[0].Value }
        }
        if ([string]::IsNullOrWhiteSpace($continuation)) { return @($items) }
        if ($page -eq 100) { throw "$OperationLabel exceeded the bounded 100-page discovery limit." }
        $nextUrl = $continuation
    }
    throw "$OperationLabel ended without a terminal response."
}

function Get-Agent365SeedBlueprintDisplayName {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $baseName = [string]$Config.agent365.seedBlueprintName
    if ([string]::IsNullOrWhiteSpace($baseName)) { throw 'agent365.seedBlueprintName is required.' }
    $ownershipId = [guid]::Empty
    if (-not [guid]::TryParse($DeploymentOwnershipId, [ref]$ownershipId) -or $ownershipId -eq [guid]::Empty) {
        throw 'Deployment ownership ID is not a non-empty GUID.'
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Agent ID blueprint source fingerprint'
    $sourceHash = $SourceFingerprint.Substring('sha256:'.Length)
    $displayName = "$baseName Blueprint [a365gw:$($ownershipId.ToString('D')):$sourceHash]"
    if ($displayName.Length -gt 256) { throw 'The source- and ownership-bound Agent ID blueprint display name exceeds 256 characters.' }
    return $displayName
}

function Invoke-Agent365GraphJsonBody {
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)]$Body)

    $json = $Body | ConvertTo-Json -Depth 30 -Compress
    return Invoke-AzJson -Arguments @(
        'rest', '--method', $Method, '--url', $Url,
        '--headers', 'Content-Type=application/json', 'OData-Version=4.0',
        '--body', $json
    )
}

function Get-Agent365CanonicalIdentifierCollection {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Values,
        [Parameter(Mandatory)][string]$Label,
        [switch]$RequireNonEmpty
    )

    $canonical = @($Values | ForEach-Object {
        $identifier = [guid]::Empty
        if (-not [guid]::TryParse([string]$_, [ref]$identifier) -or $identifier -eq [guid]::Empty) {
            throw "$Label contains an invalid identifier."
        }
        $identifier.ToString('D')
    } | Sort-Object -Unique)
    if (($RequireNonEmpty -and $canonical.Count -eq 0) -or $canonical.Count -ne $Values.Count) {
        throw "$Label is empty or contains duplicate identifiers."
    }
    return $canonical
}

function Get-Agent365BlueprintRelationshipIds {
    param(
        [Parameter(Mandatory)][string]$BlueprintObjectId,
        [Parameter(Mandatory)][ValidateSet('owners', 'sponsors')][string]$Relationship
    )

    Assert-GuidValue -Value $BlueprintObjectId -Label 'Blueprint object ID'
    $path = "/v1.0/applications/$BlueprintObjectId/microsoft.graph.agentIdentityBlueprint/$Relationship"
    $items = @(Get-Agent365BoundedGraphCollection `
        -InitialUrl "https://graph.microsoft.com${path}?`$select=id" `
        -ExpectedPath $path `
        -OperationLabel "Agent ID blueprint $Relationship")
    return @(Get-Agent365CanonicalIdentifierCollection -Values @($items | ForEach-Object {
        Get-Agent365RequiredProperty -InputObject $_ -Name 'id' -Label "Agent ID blueprint $Relationship member"
    }) -Label "Agent ID blueprint $Relationship" -RequireNonEmpty)
}

function Assert-Agent365SeedBlueprintSurface {
    param(
        [Parameter(Mandatory)]$Blueprint,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ExpectedDisplayName,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$SponsorObjectId,
        [string]$GatewayManagedIdentityPrincipalId = '',
        [switch]$RequirePristineAuthoritySurface
    )

    $objectId = [string](Get-Agent365RequiredProperty -InputObject $Blueprint -Name 'id' -Label 'Agent ID blueprint')
    $applicationId = [string](Get-Agent365RequiredProperty -InputObject $Blueprint -Name 'appId' -Label 'Agent ID blueprint')
    Assert-GuidValue -Value $objectId -Label 'Blueprint object ID'
    Assert-GuidValue -Value $applicationId -Label 'Blueprint application ID'
    Assert-GuidValue -Value $SponsorObjectId -Label 'Blueprint owner/sponsor object ID'
    $canonicalSponsorId = ([guid]$SponsorObjectId).ToString('D')
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Agent ID blueprint source fingerprint'

    $displayName = [string](Get-Agent365RequiredProperty -InputObject $Blueprint -Name 'displayName' -Label 'Agent ID blueprint')
    if ($displayName -cne $ExpectedDisplayName) { throw 'The Agent ID blueprint display name is not the exact source- and ownership-bound name.' }
    if ([string](Get-Agent365RequiredProperty -InputObject $Blueprint -Name 'signInAudience' -Label 'Agent ID blueprint') -cne 'AzureADMyOrg') {
        throw 'The Agent ID blueprint sign-in audience is not the required single-tenant value.'
    }

    $managerValues = @(Get-Agent365RequiredProperty -InputObject $Blueprint -Name 'managerApplications' -Label 'Agent ID blueprint')
    $managers = @(Get-Agent365CanonicalIdentifierCollection -Values $managerValues -Label 'Agent ID blueprint managerApplications' -RequireNonEmpty)
    $reviewedManagerValues = @($Config.agent365.reviewedManagerApplicationIds)
    $reviewedManagers = @(Get-Agent365CanonicalIdentifierCollection -Values $reviewedManagerValues -Label 'Reviewed Agent ID manager applications' -RequireNonEmpty)
    if (($managers -join '|') -cne ($reviewedManagers -join '|')) {
        throw 'The seed blueprint managerApplications do not exactly match the independently reviewed configuration. No provider-discovered authority was accepted.'
    }

    foreach ($property in @('identifierUris', 'tags', 'appRoles', 'requiredResourceAccess', 'passwordCredentials', 'keyCredentials')) {
        if (@(Get-Agent365RequiredProperty -InputObject $Blueprint -Name $property -Label 'Agent ID blueprint').Count -ne 0) {
            throw "The Agent ID blueprint has an unexpected $property authority surface."
        }
    }
    $api = Get-Agent365RequiredProperty -InputObject $Blueprint -Name 'api' -Label 'Agent ID blueprint'
    if ($null -ne $api) {
        foreach ($property in @('oauth2PermissionScopes', 'knownClientApplications', 'preAuthorizedApplications')) {
            $values = Get-Agent365RequiredProperty -InputObject $api -Name $property -Label 'Agent ID blueprint API surface'
            if (@($values).Count -ne 0) { throw "The Agent ID blueprint API surface has unexpected $property entries." }
        }
    }
    foreach ($surfaceName in @('web', 'spa', 'publicClient')) {
        $surface = Get-Agent365RequiredProperty -InputObject $Blueprint -Name $surfaceName -Label 'Agent ID blueprint'
        if ($null -ne $surface) {
            $redirectUris = Get-Agent365RequiredProperty -InputObject $surface -Name 'redirectUris' -Label "Agent ID blueprint $surfaceName surface"
            if (@($redirectUris).Count -ne 0) { throw "The Agent ID blueprint has unexpected $surfaceName redirect URIs." }
            if ($surfaceName -eq 'web') {
                foreach ($property in @('homePageUrl', 'logoutUrl')) {
                    $value = Get-Agent365RequiredProperty -InputObject $surface -Name $property -Label 'Agent ID blueprint web surface'
                    if (-not [string]::IsNullOrWhiteSpace([string]$value)) { throw "The Agent ID blueprint has an unexpected web $property value." }
                }
            }
        }
    }
    $fallback = Get-Agent365RequiredProperty -InputObject $Blueprint -Name 'isFallbackPublicClient' -Label 'Agent ID blueprint'
    if ($fallback -eq $true) { throw 'The Agent ID blueprint unexpectedly enables fallback public-client behavior.' }

    $owners = @(Get-Agent365BlueprintRelationshipIds -BlueprintObjectId $objectId -Relationship owners)
    $sponsors = @(Get-Agent365BlueprintRelationshipIds -BlueprintObjectId $objectId -Relationship sponsors)
    if ($owners.Count -ne 1 -or $owners[0] -cne $canonicalSponsorId -or
        $sponsors.Count -ne 1 -or $sponsors[0] -cne $canonicalSponsorId) {
        throw 'The Agent ID blueprint owner and sponsor sets must each contain exactly the authenticated bootstrap administrator.'
    }

    $ficPath = "/v1.0/applications/$objectId/federatedIdentityCredentials"
    $fics = @(Get-Agent365BoundedGraphCollection `
        -InitialUrl "https://graph.microsoft.com${ficPath}?`$select=id,name,issuer,subject,audiences" `
        -ExpectedPath $ficPath `
        -OperationLabel 'Agent ID blueprint federated credentials')
    $filter = [Uri]::EscapeDataString("appId eq '$applicationId'")
    $principalPath = '/v1.0/servicePrincipals'
    $principals = @(Get-Agent365BoundedGraphCollection `
        -InitialUrl "https://graph.microsoft.com${principalPath}?`$filter=$filter&`$select=id,appId,displayName" `
        -ExpectedPath $principalPath `
        -OperationLabel 'Agent ID blueprint principals')

    $runtimeAuthorityMode = 'Pristine'
    if ($RequirePristineAuthoritySurface) {
        if ($fics.Count -ne 0 -or $principals.Count -ne 0) {
            throw 'The newly created Agent ID blueprint already has a federated credential or principal; the clean authority surface was not proven.'
        }
    }
    elseif ($fics.Count -eq 0 -and $principals.Count -eq 0) {
        $runtimeAuthorityMode = 'Pristine'
    }
    else {
        Assert-GuidValue -Value $GatewayManagedIdentityPrincipalId -Label 'Gateway managed-identity principal ID for blueprint authority verification'
        $gatewayPrincipalId = ([guid]$GatewayManagedIdentityPrincipalId).ToString('D')
        $expectedFicName = "a365-gateway-$(([guid]$gatewayPrincipalId).ToString('N'))"
        $expectedIssuer = "https://login.microsoftonline.com/$(([guid][string]$Config.tenantId).ToString('D'))/v2.0"
        if ($fics.Count -ne 1 -or
            [string]$fics[0].name -cne $expectedFicName -or
            -not ([string]$fics[0].issuer).Equals($expectedIssuer, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$fics[0].subject).Equals($gatewayPrincipalId, [StringComparison]::OrdinalIgnoreCase) -or
            @($fics[0].audiences).Count -ne 1 -or [string]$fics[0].audiences[0] -cne 'api://AzureADTokenExchange') {
            throw 'The Agent ID blueprint federated credentials are outside the exact pristine-or-Gateway-activated authority boundary.'
        }
        if ($principals.Count -ne 1 -or
            [string]$principals[0].appId -cne $applicationId -or
            [string]$principals[0].displayName -cne $displayName) {
            throw 'The Agent ID blueprint principals are outside the exact pristine-or-single-typed-principal authority boundary.'
        }
        $principalObjectId = [string]$principals[0].id
        Assert-GuidValue -Value $principalObjectId -Label 'Agent ID blueprint principal object ID'
        $gatewayWorkerPrincipal = Invoke-AzJson -Arguments @(
            'rest', '--method', 'GET', '--url',
            "https://graph.microsoft.com/v1.0/servicePrincipals/${gatewayPrincipalId}?`$select=id,appId"
        )
        if (-not $gatewayWorkerPrincipal -or
            -not ([string]$gatewayWorkerPrincipal.id).Equals($gatewayPrincipalId, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The Gateway worker service principal was unavailable during blueprint-principal authority verification.'
        }
        $gatewayWorkerApplicationId = [string]$gatewayWorkerPrincipal.appId
        Assert-GuidValue -Value $gatewayWorkerApplicationId -Label 'Gateway worker service-principal application ID'
        $typedPrincipal = Invoke-AzJson -Arguments @(
            'rest', '--method', 'GET', '--url',
            "https://graph.microsoft.com/v1.0/servicePrincipals/$principalObjectId/microsoft.graph.agentIdentityBlueprintPrincipal?`$select=id,appId,appDisplayName,appOwnerOrganizationId,accountEnabled,appRoleAssignmentRequired,appRoles,createdByAppId,disabledByMicrosoftStatus,displayName,keyCredentials,passwordCredentials,publishedPermissionScopes,servicePrincipalNames,servicePrincipalType,signInAudience,tags"
        )
        foreach ($property in @(
            'id', 'appId', 'appDisplayName', 'appOwnerOrganizationId', 'accountEnabled',
            'appRoleAssignmentRequired', 'appRoles', 'createdByAppId',
            'disabledByMicrosoftStatus', 'displayName', 'keyCredentials',
            'passwordCredentials', 'publishedPermissionScopes',
            'servicePrincipalNames', 'servicePrincipalType', 'signInAudience', 'tags'
        )) {
            $null = Get-Agent365RequiredProperty -InputObject $typedPrincipal -Name $property -Label 'Agent ID blueprint principal'
        }
        foreach ($property in @('appRoles', 'keyCredentials', 'passwordCredentials', 'publishedPermissionScopes', 'tags')) {
            $values = @(Get-Agent365RequiredCollectionItems `
                -InputObject $typedPrincipal `
                -Name $property `
                -Label 'Agent ID blueprint principal')
            if ($values.Count -ne 0) {
                throw 'The sole blueprint principal did not pass exact typed Microsoft Graph readback.'
            }
        }
        $servicePrincipalNames = @(Get-Agent365RequiredCollectionItems `
            -InputObject $typedPrincipal `
            -Name 'servicePrincipalNames' `
            -Label 'Agent ID blueprint principal')
        if (-not $typedPrincipal -or [string]$typedPrincipal.id -cne $principalObjectId -or
            [string]$typedPrincipal.appId -cne $applicationId -or
            [string]$typedPrincipal.appDisplayName -cne $displayName -or
            -not ([string]$typedPrincipal.appOwnerOrganizationId).Equals(([guid][string]$Config.tenantId).ToString('D'), [StringComparison]::OrdinalIgnoreCase) -or
            $typedPrincipal.accountEnabled -ne $true -or
            $typedPrincipal.appRoleAssignmentRequired -ne $false -or
            -not ([string]$typedPrincipal.createdByAppId).Equals($gatewayWorkerApplicationId, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::IsNullOrWhiteSpace([string]$typedPrincipal.disabledByMicrosoftStatus) -or
            [string]$typedPrincipal.displayName -cne $displayName -or
            [string]$typedPrincipal.servicePrincipalType -cne 'Application' -or
            [string]$typedPrincipal.signInAudience -cne 'AzureADMyOrg' -or
            $servicePrincipalNames.Count -ne 1 -or
            [string]$servicePrincipalNames[0] -cne $applicationId) {
            throw 'The sole blueprint principal did not pass exact typed Microsoft Graph readback.'
        }

        foreach ($relationship in @(
            [ordered]@{ name = 'appRoleAssignments'; path = "/v1.0/servicePrincipals/$principalObjectId/appRoleAssignments"; expected = @() },
            [ordered]@{ name = 'appRoleAssignedTo'; path = "/v1.0/servicePrincipals/$principalObjectId/appRoleAssignedTo"; expected = @() },
            [ordered]@{ name = 'oauth2PermissionGrants'; path = "/v1.0/servicePrincipals/$principalObjectId/oauth2PermissionGrants"; expected = @() },
            [ordered]@{ name = 'memberOf'; path = "/v1.0/servicePrincipals/$principalObjectId/memberOf"; expected = @() },
            [ordered]@{ name = 'owners'; path = "/v1.0/servicePrincipals/$principalObjectId/microsoft.graph.agentIdentityBlueprintPrincipal/owners"; expected = @($gatewayPrincipalId) },
            [ordered]@{ name = 'sponsors'; path = "/v1.0/servicePrincipals/$principalObjectId/microsoft.graph.agentIdentityBlueprintPrincipal/sponsors"; expected = @() }
        )) {
            $members = @(Get-Agent365BoundedGraphCollection `
                -InitialUrl "https://graph.microsoft.com$($relationship.path)?`$select=id" `
                -ExpectedPath ([string]$relationship.path) `
                -OperationLabel "Agent ID blueprint principal $($relationship.name)")
            $actualIds = @(Get-Agent365CanonicalIdentifierCollection `
                -Values @($members | ForEach-Object {
                    Get-Agent365RequiredProperty -InputObject $_ -Name 'id' -Label "Agent ID blueprint principal $($relationship.name) member"
                }) `
                -Label "Agent ID blueprint principal $($relationship.name)")
            $expectedIds = @($relationship.expected | ForEach-Object { ([guid][string]$_).ToString('D') } | Sort-Object -Unique)
            if (($actualIds -join '|') -cne ($expectedIds -join '|')) {
                throw "The Agent ID blueprint principal $($relationship.name) relationship is outside the exact reviewed authority boundary."
            }
        }
        $runtimeAuthorityMode = 'GatewayActivated'
    }

    return [ordered]@{
        schemaVersion = 2
        provenance = 'BootstrapOwnedDirectGraphV1'
        objectId = $objectId
        applicationId = $applicationId
        displayName = $displayName
        deploymentOwnershipId = $canonicalOwnershipId
        sourceFingerprint = $SourceFingerprint
        ownerObjectId = $canonicalSponsorId
        sponsorObjectId = $canonicalSponsorId
        ownerObjectIds = @($owners)
        sponsorObjectIds = @($sponsors)
        managerApplicationIds = @($reviewedManagers)
        managerApplicationsPreflightConfirmed = $true
        credentialCreationPerformed = $false
        pristineAuthoritySurfaceConfirmed = [bool]$RequirePristineAuthoritySurface
        runtimeAuthorityMode = $runtimeAuthorityMode
    }
}

function Ensure-Agent365SeedBlueprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$SponsorObjectId,
        [switch]$NonInteractive,
        [switch]$ReconcileOnly
    )

    $displayName = Get-Agent365SeedBlueprintDisplayName `
        -Config $Config `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $SourceFingerprint
    $blueprint = Get-Agent365BlueprintByName -DisplayName $displayName
    if ($ReconcileOnly) {
        if (-not $blueprint) { throw "Typed Agent ID blueprint '$displayName' was not observable during read-only reconciliation; its prior create outcome must not be repeated automatically." }
    }
    else {
        if ($blueprint) {
            throw "Typed Agent ID blueprint '$displayName' already exists before this bootstrap create intent. Refusing to adopt or mutate a preexisting tenant object."
        }
        $reviewedManagers = @(Get-Agent365CanonicalIdentifierCollection `
            -Values @($Config.agent365.reviewedManagerApplicationIds) `
            -Label 'Reviewed Agent ID manager applications' `
            -RequireNonEmpty)
        $canonicalSponsorId = ([guid]$SponsorObjectId).ToString('D')
        $userBinding = "https://graph.microsoft.com/v1.0/users/$canonicalSponsorId"
        $null = Invoke-Agent365GraphJsonBody `
            -Method POST `
            -Url 'https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint' `
            -Body ([ordered]@{
                '@odata.type' = '#microsoft.graph.agentIdentityBlueprint'
                displayName = $displayName
                managerApplications = @($reviewedManagers)
                'sponsors@odata.bind' = @($userBinding)
                'owners@odata.bind' = @($userBinding)
            })
        for ($attempt = 1; $attempt -le 18 -and -not $blueprint; $attempt++) {
            Start-Sleep -Seconds 5
            $blueprint = Get-Agent365BlueprintByName -DisplayName $displayName
        }
    }
    if (-not $blueprint) { throw "Microsoft Graph accepted the create call but typed blueprint '$displayName' was not observable within the bounded readback window. Resume may reconcile the exact name; it must not repeat POST." }
    return Assert-Agent365SeedBlueprintSurface `
        -Blueprint $blueprint `
        -Config $Config `
        -ExpectedDisplayName $displayName `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $SourceFingerprint `
        -SponsorObjectId $SponsorObjectId `
        -RequirePristineAuthoritySurface
}

Export-ModuleMember -Function *
