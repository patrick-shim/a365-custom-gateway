Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:GraphAppId = '00000003-0000-0000-c000-000000000000'

function Get-ExactApplicationByDisplayName {
    param([Parameter(Mandatory)][string]$DisplayName)
    $escaped = $DisplayName.Replace("'", "''")
    $filter = [Uri]::EscapeDataString("displayName eq '$escaped'")
    $response = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId,displayName,identifierUris,api,appRoles,requiredResourceAccess,passwordCredentials")
    $applications = @($response.value)
    if ($applications.Count -gt 1) { throw "More than one application is named '$DisplayName'; refusing ambiguous adoption." }
    return if ($applications.Count -eq 1) { $applications[0] } else { $null }
}

function Get-ServicePrincipalByAppId {
    param([Parameter(Mandatory)][string]$AppId)
    $filter = [Uri]::EscapeDataString("appId eq '$AppId'")
    $response = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filter&`$select=id,appId,displayName,appRoles,oauth2PermissionScopes")
    $principals = @($response.value)
    if ($principals.Count -gt 1) { throw "Multiple service principals exist for application ID $AppId." }
    return if ($principals.Count -eq 1) { $principals[0] } else { $null }
}

function Invoke-GraphJsonBody {
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)]$Body)
    $json = $Body | ConvertTo-Json -Depth 30 -Compress
    return Invoke-AzJson -Arguments @('rest', '--method', $Method, '--url', $Url, '--headers', 'Content-Type=application/json', '--body', $json)
}

function Ensure-ServicePrincipal {
    param([Parameter(Mandatory)][string]$AppId)
    $principal = Get-ServicePrincipalByAppId -AppId $AppId
    if (-not $principal) {
        Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/servicePrincipals' -Body @{ appId = $AppId } | Out-Null
        for ($attempt = 1; $attempt -le 12 -and -not $principal; $attempt++) {
            Start-Sleep -Seconds 5
            $principal = Get-ServicePrincipalByAppId -AppId $AppId
        }
    }
    if (-not $principal) { throw "Service principal for application $AppId was not observable after creation." }
    return $principal
}

function Ensure-GatewayApiApplication {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$AzureIdentity)
    $displayName = "A365 Gateway API - $($Config.environment)"
    $audience = "api://a365-gateway-$($Config.environment)"
    $application = Get-ExactApplicationByDisplayName -DisplayName $displayName
    if (-not $application) {
        $audienceMatches = @(Invoke-AzJson -Arguments @('ad', 'app', 'list', '--identifier-uri', $audience))
        if ($audienceMatches.Count -gt 1) { throw "More than one Gateway API application exposes '$audience'." }
        if ($audienceMatches.Count -eq 1) {
            $application = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/applications/$($audienceMatches[0].id)?`$select=id,appId,displayName,identifierUris,api,appRoles,requiredResourceAccess,passwordCredentials")
        }
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
            api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @(@{
                id = $scopeId; value = 'access_as_user'; type = 'Admin'; isEnabled = $true
                adminConsentDisplayName = 'Access the A365 Gateway'
                adminConsentDescription = 'Allows the Admin UI to access the A365 Gateway on behalf of the signed-in user.'
                userConsentDisplayName = 'Access the A365 Gateway'
                userConsentDescription = 'Allows this application to access the A365 Gateway on your behalf.'
            }) }
            appRoles = $roles
        }
    }
    if (@($application.identifierUris) -notcontains $audience) { throw "Existing Gateway API app does not expose expected audience '$audience'." }
    $scope = @($application.api.oauth2PermissionScopes | Where-Object value -eq 'access_as_user')
    $adminRole = @($application.appRoles | Where-Object value -eq 'Gateway.Administrator')
    if ($scope.Count -ne 1 -or $adminRole.Count -ne 1) { throw 'Existing Gateway API app lacks the unique access_as_user scope or Gateway.Administrator role.' }
    if (@($adminRole[0].allowedMemberTypes) -contains 'Application') { throw 'Gateway.Administrator must not be assignable to applications.' }
    $principal = Ensure-ServicePrincipal -AppId ([string]$application.appId)

    $assignments = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$($principal.id)/appRoleAssignedTo?`$filter=principalId%20eq%20$($AzureIdentity.userObjectId)")
    $hasRole = @($assignments.value | Where-Object { [string]$_.appRoleId -eq [string]$adminRole[0].id }).Count -eq 1
    if (-not $hasRole) {
        Invoke-GraphJsonBody -Method 'POST' -Url "https://graph.microsoft.com/v1.0/servicePrincipals/$($principal.id)/appRoleAssignedTo" -Body @{
            principalId = [string]$AzureIdentity.userObjectId
            resourceId = [string]$principal.id
            appRoleId = [string]$adminRole[0].id
        } | Out-Null
    }
    return [ordered]@{
        gatewayApiApplicationObjectId = [string]$application.id
        gatewayApiClientId = [string]$application.appId
        gatewayApiServicePrincipalId = [string]$principal.id
        gatewayApiAudience = $audience
        gatewayApiAccessScopeId = [string]$scope[0].id
        gatewayAdministratorRoleId = [string]$adminRole[0].id
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
    $existing = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments")
    if (@($existing.value | Where-Object { [string]$_.resourceId -eq [string]$graph.id -and [string]$_.appRoleId -eq [string]$role[0].id }).Count -eq 0) {
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
    $root = Get-RepositoryRoot
    & (Join-Path $root 'tools/configure-workflow-v3-entra.ps1') `
        -ExpectedSubscriptionId ([guid]$Config.subscriptionId) `
        -ExpectedTenantId ([guid]$Config.tenantId) `
        -GatewayApiApplicationClientId ([guid]$Identity.gatewayApiClientId) `
        -GatewayApiManagedIdentityPrincipalId ([guid]$ApiPrincipalId) `
        -WorkerManagedIdentityPrincipalId ([guid]$WorkerPrincipalId) `
        -FederatedCredentialName "a365gw-api-obo-$($Config.environment)" `
        -Apply
    if ($LASTEXITCODE -ne 0) { throw 'Workflow-v3 Entra configuration failed.' }

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
    $workerRoleIds = [ordered]@{}
    foreach ($role in $workerRoles) { $workerRoleIds[$role] = Ensure-GraphApplicationRoleAssignment -PrincipalId $WorkerPrincipalId -RoleValue $role }
    $apiRoleIds = [ordered]@{}
    foreach ($role in $apiRoles) { $apiRoleIds[$role] = Ensure-GraphApplicationRoleAssignment -PrincipalId $ApiPrincipalId -RoleValue $role }
    return [ordered]@{
        federatedCredentialName = "a365gw-api-obo-$($Config.environment)"
        workerApplicationRoles = $workerRoleIds
        apiApplicationRoles = $apiRoleIds
        delegatedRegistryScopes = @('AgentRegistration.Read.All', 'AgentRegistration.ReadWrite.All')
    }
}

function Ensure-AdminUiApplication {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Identity)
    $displayName = "A365 Gateway Admin UI - $($Config.environment)"
    $application = Get-ExactApplicationByDisplayName -DisplayName $displayName
    if (-not $application) {
        $application = Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/applications' -Body @{
            displayName = $displayName
            signInAudience = 'AzureADMyOrg'
            requiredResourceAccess = @(@{
                resourceAppId = [string]$Identity.gatewayApiClientId
                resourceAccess = @(@{ id = [string]$Identity.gatewayApiAccessScopeId; type = 'Scope' })
            })
        }
    }
    $apiRequirement = @($application.requiredResourceAccess | Where-Object { [string]$_.resourceAppId -eq [string]$Identity.gatewayApiClientId })
    $hasScope = $apiRequirement.Count -eq 1 -and @($apiRequirement[0].resourceAccess | Where-Object { [string]$_.id -eq [string]$Identity.gatewayApiAccessScopeId -and [string]$_.type -eq 'Scope' }).Count -eq 1
    if (-not $hasScope) {
        $requirements = @($application.requiredResourceAccess | Where-Object { [string]$_.resourceAppId -ne [string]$Identity.gatewayApiClientId })
        $requirements += @{
            resourceAppId = [string]$Identity.gatewayApiClientId
            resourceAccess = @(@{ id = [string]$Identity.gatewayApiAccessScopeId; type = 'Scope' })
        }
        Invoke-GraphJsonBody -Method 'PATCH' -Url "https://graph.microsoft.com/v1.0/applications/$($application.id)" -Body @{ requiredResourceAccess = $requirements } | Out-Null
    }
    $principal = Ensure-ServicePrincipal -AppId ([string]$application.appId)
    $grants = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId%20eq%20'$($principal.id)'%20and%20resourceId%20eq%20'$($Identity.gatewayApiServicePrincipalId)'")
    $grant = @($grants.value | Where-Object consentType -eq 'AllPrincipals')
    if ($grant.Count -eq 0) {
        Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' -Body @{
            clientId = [string]$principal.id; consentType = 'AllPrincipals'; resourceId = [string]$Identity.gatewayApiServicePrincipalId; scope = 'access_as_user'
        } | Out-Null
    }
    elseif (@($grant).Count -ne 1 -or ([string]$grant[0].scope -split ' ') -notcontains 'access_as_user') {
        throw 'Existing Admin UI delegated grant is ambiguous or lacks access_as_user.'
    }
    return [ordered]@{
        adminUiApplicationObjectId = [string]$application.id
        adminUiClientId = [string]$application.appId
        adminUiServicePrincipalId = [string]$principal.id
    }
}

function Set-AdminUiRedirectUris {
    param([Parameter(Mandatory)]$AdminIdentity, [Parameter(Mandatory)][string]$AdminUiFqdn)
    if ([string]::IsNullOrWhiteSpace($AdminUiFqdn)) { throw 'Admin UI FQDN is required.' }
    $base = "https://$AdminUiFqdn"
    Invoke-GraphJsonBody -Method 'PATCH' -Url "https://graph.microsoft.com/v1.0/applications/$($AdminIdentity.adminUiApplicationObjectId)" -Body @{
        web = @{ redirectUris = @("$base/signin-oidc"); logoutUrl = "$base/signout-callback-oidc" }
    } | Out-Null
    return [ordered]@{ signInRedirectUri = "$base/signin-oidc"; signedOutCallbackUri = "$base/signout-callback-oidc" }
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
    $roleName = 'Key Vault Secrets Officer'
    $existingAssignments = Invoke-AzJson -Arguments @('role', 'assignment', 'list', '--assignee-object-id', $UserObjectId, '--scope', $scope, '--query', "[?roleDefinitionName=='$roleName']")
    $createdTemporaryRole = @($existingAssignments).Count -eq 0
    if ($createdTemporaryRole) {
        Invoke-AzJson -Arguments @('role', 'assignment', 'create', '--assignee-object-id', $UserObjectId, '--assignee-principal-type', 'User', '--role', $roleName, '--scope', $scope) | Out-Null
    }
    $secretText = $null
    try {
        $tokenResult = Invoke-AzJson -Arguments @('account', 'get-access-token', '--resource', 'https://vault.azure.net')
        $headers = @{ Authorization = "Bearer $($tokenResult.accessToken)"; 'Content-Type' = 'application/json' }
        $application = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/applications/$($AdminIdentity.adminUiApplicationObjectId)?`$select=passwordCredentials")
        $bootstrapCredentials = @($application.passwordCredentials | Where-Object { [string]$_.displayName -eq 'a365gw-bootstrap-admin-ui' })
        $secretListUrl = "$($KeyVaultUri.TrimEnd('/'))/secrets?api-version=7.4"
        $secretList = $null
        for ($attempt = 1; $attempt -le 18 -and -not $secretList; $attempt++) {
            try { $secretList = Invoke-RestMethod -Method Get -Uri $secretListUrl -Headers $headers }
            catch {
                if ($attempt -eq 18) { throw }
                Start-Sleep -Seconds 5
            }
        }
        $vaultMetadata = @($secretList.value | Where-Object { ([uri]$_.id).Segments[-2].TrimEnd('/') -eq 'admin-ui-entra-client-secret' })
        if ($vaultMetadata.Count -gt 1) { throw 'Key Vault returned ambiguous current Admin UI secret metadata.' }
        if ($vaultMetadata.Count -eq 1) {
            $recordedKeyId = [string]$vaultMetadata[0].tags.credentialKeyId
            $matchingCredential = @($bootstrapCredentials | Where-Object { [string]$_.keyId -eq $recordedKeyId })
            if ([string]::IsNullOrWhiteSpace($recordedKeyId) -or $matchingCredential.Count -ne 1) {
                throw 'An Admin UI Key Vault secret already exists but cannot be safely matched to the bootstrap app credential. Rotate it through the credential runbook.'
            }
            return [ordered]@{
                secretUri = "$($KeyVaultUri.TrimEnd('/'))/secrets/admin-ui-entra-client-secret"
                credentialKeyId = $recordedKeyId
                credentialExpiresAtUtc = [string]$matchingCredential[0].endDateTime
            }
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
            try { $stored = Invoke-RestMethod -Method Put -Uri $secretUrl -Headers $headers -Body $body }
            catch {
                if ($attempt -eq 18) { throw }
                Start-Sleep -Seconds 5
            }
        }
        return [ordered]@{
            secretUri = "$($KeyVaultUri.TrimEnd('/'))/secrets/admin-ui-entra-client-secret"
            credentialKeyId = [string]$credential.keyId
            credentialExpiresAtUtc = [string]$credential.endDateTime
        }
    }
    finally {
        $secretText = $null
        $body = $null
        $stored = $null
        $secretList = $null
        $headers = $null
        $tokenResult = $null
        if ($createdTemporaryRole) {
            Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('role', 'assignment', 'delete', '--assignee-object-id', $UserObjectId, '--role', $roleName, '--scope', $scope, '--only-show-errors') -AllowFailure | Out-Null
        }
    }
}

Export-ModuleMember -Function *
