Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Wait-HttpsHealth {
    param([Parameter(Mandatory)][string]$Url)
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 15 -SkipHttpErrorCheck
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                return [ordered]@{ url = $Url; statusCode = [int]$response.StatusCode }
            }
        }
        catch { }
        if ($attempt -lt 30) { Start-Sleep -Seconds 10 }
    }
    throw "Health endpoint '$Url' did not return a 2xx response within five minutes."
}

function Test-GatewayBootstrapDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$Blueprint,
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)]$AdminUi,
        [Parameter(Mandatory)]$Images,
        [Parameter(Mandatory)]$AdminIdentity
    )
    $root = Get-RepositoryRoot
    $serverName = ([string]$Runtime.sqlServerFqdn).Split('.')[0]
    $sqlPublic = Invoke-AzTsv -Arguments @('sql', 'server', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $serverName, '--query', 'publicNetworkAccess')
    if ($sqlPublic -ne 'Disabled') { throw 'Azure SQL public network access is not Disabled.' }
    foreach ($vault in @("kv-$($Config.projectName)-$($Config.environment)", "kv-$($Config.projectName)-$($Config.environment)-prov")) {
        $public = Invoke-AzTsv -Arguments @('keyvault', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $vault, '--query', 'properties.publicNetworkAccess')
        if ($public -ne 'Disabled') { throw "Key Vault '$vault' public network access is not Disabled." }
    }
    $privateEndpointCount = [int](Invoke-AzTsv -Arguments @('network', 'private-endpoint', 'list', '--resource-group', [string]$Config.resourceGroupName, '--query', 'length(@)'))
    if ($privateEndpointCount -lt 3) { throw 'Expected at least Storage, SQL, and Key Vault private endpoints.' }

    $expectedImages = [ordered]@{
        "ca-gateway-api-$($Config.environment)" = [string]$Images.api
        "ca-gateway-worker-$($Config.environment)-v3" = [string]$Images.worker
        "ca-gateway-admin-$($Config.environment)" = [string]$Images.adminUi
    }
    foreach ($entry in $expectedImages.GetEnumerator()) {
        $actualImage = Invoke-AzTsv -Arguments @('containerapp', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $entry.Key, '--query', 'properties.template.containers[0].image')
        if ($actualImage -ne $entry.Value) { throw "Container App '$($entry.Key)' is not running the recorded immutable image digest." }
    }

    $purviewRoleIds = @(
        'fe696d63-5e1f-4515-8232-cccc316903c6',
        '24ceb246-ad29-4680-90b4-3e91ffad15eb',
        '2932e07a-3c29-44e4-bb36-6d0fc176387f'
    )
    if ($Config.purview.enabled -eq $true) {
        $assignments = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$($Runtime.apiPrincipalId)/appRoleAssignments?`$select=appRoleId,resourceId")
        $assignedIds = @($assignments.value | ForEach-Object { [string]$_.appRoleId })
        foreach ($roleId in $purviewRoleIds) {
            if ($assignedIds -notcontains $roleId) { throw "Gateway API managed identity is missing required Purview Graph role $roleId." }
        }
    }

    $expectedSignIn = "$($AdminUi.adminUiUrl.TrimEnd('/'))/signin-oidc"
    $expectedSignOut = "$($AdminUi.adminUiUrl.TrimEnd('/'))/signout-callback-oidc"
    $redirectsVerified = $false
    for ($attempt = 1; $attempt -le 12 -and -not $redirectsVerified; $attempt++) {
        $adminApplication = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/applications/$($AdminIdentity.adminUiApplicationObjectId)?`$select=web")
        $redirectsVerified = @($adminApplication.web.redirectUris) -contains $expectedSignIn -and [string]$adminApplication.web.logoutUrl -eq $expectedSignOut
        if (-not $redirectsVerified -and $attempt -lt 12) { Start-Sleep -Seconds 5 }
    }
    if (-not $redirectsVerified) {
        throw 'Admin UI Entra redirect/logout URIs do not match the deployed HTTPS endpoint.'
    }
    $adminGrants = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId%20eq%20'$($AdminIdentity.adminUiServicePrincipalId)'%20and%20resourceId%20eq%20'$($Identity.gatewayApiServicePrincipalId)'")
    $validAdminGrant = @($adminGrants.value | Where-Object { $_.consentType -eq 'AllPrincipals' -and (([string]$_.scope -split ' ') -contains 'access_as_user') })
    if ($validAdminGrant.Count -ne 1) { throw 'Admin UI does not have one tenant-wide access_as_user grant to the Gateway API.' }

    $enablePreview = [string]$Config.environment -eq 'dev' -and $Config.agent365.allowDevelopmentRegistryPreview -eq $true
    $preflightArguments = @(
        '-Environment', [string]$Config.environment,
        '-ResourceGroup', [string]$Config.resourceGroupName,
        '-ProjectName', [string]$Config.projectName,
        '-ContainerAppsEnvironmentName', [string]$Foundation.containerAppsEnvironmentName,
        '-WorkerContainerAppName', "ca-gateway-worker-$($Config.environment)-v3",
        '-ExpectedServiceBusQueueName', [string]$Runtime.serviceBusQueueName,
        '-WorkerProcessingEnabled', [bool]$Runtime.workerProcessingEnabled,
        '-ExpectedGatewayApiApplicationClientId', [string]$Identity.gatewayApiClientId,
        '-ExpectedCredentialKeyVaultUri', "https://kv-$($Config.projectName)-$($Config.environment)-prov.vault.azure.net/",
        '-ExpectedManagerApplicationIds', @($Blueprint.managerApplicationIds),
        '-RegistryProvider', $(if ($enablePreview) { 'DirectRegistryPreview' } else { 'Disabled' }),
        '-ExpectedGatewayApiFederatedCredentialName', "a365gw-api-obo-$($Config.environment)",
        '-ManagerApplicationsPreflightConfirmed',
        '-RequireDeployedConfigurationMatch'
    )
    if ($enablePreview) { $preflightArguments += @('-DirectRegistryPreviewEnabled', '-DelegatedRegistryEnabled', '-RequireExecutionReady') }
    & (Join-Path $root 'operations/test-provisioning-prerequisites.ps1') @preflightArguments
    if ($LASTEXITCODE -ne 0) { throw 'Read-only provisioning preflight failed.' }

    $apiHealth = Wait-HttpsHealth -Url "https://$($Runtime.apiFqdn)/health/checks"
    $adminHealth = Wait-HttpsHealth -Url "$($AdminUi.adminUiUrl.TrimEnd('/'))/health"
    return [ordered]@{
        verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        api = $apiHealth
        adminUi = $adminHealth
        sqlPublicNetworkAccess = $sqlPublic
        keyVaultPublicNetworkAccess = 'Disabled'
        privateEndpointCount = $privateEndpointCount
        immutableImages = $expectedImages
        purviewGraphRoles = if ($Config.purview.enabled -eq $true) { 'Passed' } else { 'NotConfigured' }
        adminUiIdentity = 'Passed'
        provisioningPreflight = 'Passed'
        registrationMode = if ($enablePreview) { 'ContinuousDevelopmentPreview' } else { 'ClosedUnsupportedForProduction' }
    }
}

Export-ModuleMember -Function *
