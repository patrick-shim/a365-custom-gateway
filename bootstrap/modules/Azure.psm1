Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Connect-BootstrapAzure {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [switch]$NonInteractive)
    $account = $null
    try { $account = Invoke-AzJson -Arguments @('account', 'show') } catch { }
    if (-not $account -or [string]$account.tenantId -ne [string]$Config.tenantId) {
        if ($NonInteractive) { throw 'Azure CLI is not signed in to the configured tenant.' }
        Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('login', '--tenant', [string]$Config.tenantId, '--allow-no-subscriptions') -NoCapture | Out-Null
    }
    Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('account', 'set', '--subscription', [string]$Config.subscriptionId) | Out-Null
    $account = Invoke-AzJson -Arguments @('account', 'show')
    if ([string]$account.tenantId -ne [string]$Config.tenantId -or [string]$account.id -ne [string]$Config.subscriptionId) {
        throw 'Azure CLI tenant/subscription selection does not match bootstrap configuration.'
    }
    $user = Invoke-AzJson -Arguments @('ad', 'signed-in-user', 'show', '--query', '{id:id,userPrincipalName:userPrincipalName,displayName:displayName}')
    Assert-GuidValue -Value ([string]$user.id) -Label 'Signed-in user object ID'
    return [ordered]@{
        subscriptionId = [string]$account.id
        tenantId = [string]$account.tenantId
        userObjectId = [string]$user.id
        userPrincipalName = [string]$user.userPrincipalName
        userDisplayName = [string]$user.displayName
    }
}

function Register-BootstrapResourceProviders {
    foreach ($provider in @(
        'Microsoft.App',
        'Microsoft.ContainerRegistry',
        'Microsoft.Insights',
        'Microsoft.KeyVault',
        'Microsoft.ManagedIdentity',
        'Microsoft.Network',
        'Microsoft.OperationalInsights',
        'Microsoft.ServiceBus',
        'Microsoft.Sql',
        'Microsoft.Storage'
    )) {
        Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('provider', 'register', '--namespace', $provider, '--wait', '--only-show-errors') | Out-Null
        $state = Invoke-AzTsv -Arguments @('provider', 'show', '--namespace', $provider, '--query', 'registrationState')
        if ($state -ne 'Registered') { throw "Resource provider $provider did not reach Registered state." }
    }
    return [ordered]@{ registered = $true; verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O') }
}

function Deploy-BootstrapFoundation {
    param([Parameter(Mandatory)]$Config)
    $root = Get-RepositoryRoot
    $deploymentName = "a365gw-bootstrap-foundation-$($Config.environment)"
    $result = Invoke-AzJson -Arguments @(
        'deployment', 'sub', 'create',
        '--name', $deploymentName,
        '--location', [string]$Config.location,
        '--template-file', (Join-Path $root 'bootstrap/infra/subscription.bicep'),
        '--parameters',
        "resourceGroupName=$($Config.resourceGroupName)",
        "location=$($Config.location)",
        "environment=$($Config.environment)",
        "projectName=$($Config.projectName)"
    )
    $outputs = $result.properties.outputs
    return [ordered]@{
        deploymentName = $deploymentName
        resourceGroupName = [string]$outputs.resourceGroupName.value
        containerAppsEnvironmentName = [string]$outputs.containerAppsEnvironmentName.value
        containerAppsEnvironmentId = [string]$outputs.containerAppsEnvironmentId.value
        virtualNetworkName = [string]$outputs.virtualNetworkName.value
        virtualNetworkId = [string]$outputs.virtualNetworkId.value
        privateEndpointSubnetName = [string]$outputs.privateEndpointSubnetName.value
        privateEndpointSubnetId = [string]$outputs.privateEndpointSubnetId.value
        logAnalyticsWorkspaceName = [string]$outputs.logAnalyticsWorkspaceName.value
        acrLoginServer = [string]$outputs.acrLoginServer.value
        acrName = [string]$outputs.acrName.value
    }
}

function Invoke-ArmDeploymentWithSecureParameters {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TemplateFile,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters
    )
    $parameterObject = [ordered]@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = [ordered]@{} }
    foreach ($entry in $Parameters.GetEnumerator()) { $parameterObject.parameters[$entry.Key] = @{ value = $entry.Value } }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) "a365gw-bootstrap-$([guid]::NewGuid().ToString('N')).json"
    try {
        $parameterObject | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
        if ($IsWindows) {
            $acl = Get-Acl -LiteralPath $temporary
            $acl.SetAccessRuleProtection($true, $false)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().Name, 'FullControl', 'Allow')
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $temporary -AclObject $acl
        }
        elseif (Get-Command chmod -ErrorAction SilentlyContinue) {
            & chmod 600 $temporary
            if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the temporary ARM parameter file to the current user.' }
        }
        return Invoke-AzJson -Arguments @('deployment', 'group', 'create', '--resource-group', $ResourceGroup, '--name', $Name, '--template-file', $TemplateFile, '--parameters', "@$temporary")
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Deploy-GatewayCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$ApiImage,
        [Parameter(Mandatory)][string]$WorkerImage,
        [Parameter(Mandatory)][string]$WorkerPrincipalId,
        [Parameter(Mandatory)][string[]]$ManagerApplicationIds,
        [Parameter()][string]$AdminUiImage = '',
        [Parameter()][string]$AdminUiClientId = '',
        [Parameter()][string]$AdminUiSecretUri = '',
        [Parameter()][switch]$Initial,
        [Parameter()][switch]$EnableWorkerProcessing,
        [Parameter()][switch]$EnableProvisioning,
        [Parameter()][switch]$EnablePurview
    )
    $root = Get-RepositoryRoot
    if ($EnablePurview -and $Config.purview.policyProvisioningEnabled -eq $true) {
        $configuredVaultHost = ([Uri][string]$Config.purview.policyProvisioningCertificateSecretUri).Host
        $gatewayVaultHost = ([Uri][string]$Foundation.keyVaultUri).Host
        if (-not $configuredVaultHost.Equals($gatewayVaultHost, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Purview policy automation certificate must be stored in the Gateway shared Key Vault '$gatewayVaultHost' so the worker's read-only role remains narrowly scoped."
        }
    }
    $name = if ($Initial) { "a365gw-bootstrap-inert-$($Config.environment)" } else { "a365gw-bootstrap-runtime-$($Config.environment)" }
    if ($Initial) {
        $existingDeployment = $null
        try { $existingDeployment = Invoke-AzJson -Arguments @('deployment', 'group', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $name) } catch { }
        if ($existingDeployment -and [string]$existingDeployment.properties.provisioningState -eq 'Succeeded') {
            $existingOutputs = $existingDeployment.properties.outputs
            $promptShieldEndpoint = if ($null -ne $existingOutputs.PSObject.Properties['promptShieldEndpoint']) { [string]$existingOutputs.promptShieldEndpoint.value } else { '' }
            $promptShieldAccountId = if ($null -ne $existingOutputs.PSObject.Properties['promptShieldAccountId']) { [string]$existingOutputs.promptShieldAccountId.value } else { '' }
            $promptShieldAccountName = if ($null -ne $existingOutputs.PSObject.Properties['promptShieldAccountName']) { [string]$existingOutputs.promptShieldAccountName.value } else { '' }
            return [ordered]@{
                deploymentName = $name
                apiFqdn = [string]$existingOutputs.apiFqdn.value
                apiPrincipalId = [string]$existingOutputs.apiPrincipalId.value
                workerPrincipalId = [string]$existingOutputs.workerPrincipalId.value
                adminUiFqdn = [string]$existingOutputs.adminUiFqdn.value
                acrLoginServer = [string]$existingOutputs.acrLoginServer.value
                keyVaultUri = [string]$existingOutputs.keyVaultUri.value
                sqlServerFqdn = [string]$existingOutputs.sqlServerFqdn.value
                serviceBusQueueName = [string]$existingOutputs.serviceBusQueueName.value
                provisioningExecutionEnabled = [bool]$existingOutputs.provisioningExecutionEnabled.value
                workerProcessingEnabled = [bool]$existingOutputs.workerProcessingEnabled.value
                registryProvider = [string]$existingOutputs.agent365RegistryProvider.value
                promptShieldEndpoint = $promptShieldEndpoint
                promptShieldAccountId = $promptShieldAccountId
                promptShieldAccountName = $promptShieldAccountName
            }
        }
        $apiExists = $false
        try {
            $null = Invoke-AzJson -Arguments @('containerapp', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', "ca-gateway-api-$($Config.environment)")
            $apiExists = $true
        }
        catch { }
        if ($apiExists) {
            throw "The Gateway API already exists but the bootstrap inert deployment '$name' cannot be recovered. Refusing to overwrite it without state."
        }
    }
    $enablePreview = $EnableProvisioning -and [string]$Config.environment -eq 'dev' -and $Config.agent365.allowDevelopmentRegistryPreview -eq $true
    $parameters = [ordered]@{
        environment = [string]$Config.environment
        location = [string]$Config.location
        projectName = [string]$Config.projectName
        containerAppsEnvironmentName = [string]$Foundation.containerAppsEnvironmentName
        virtualNetworkName = [string]$Foundation.virtualNetworkName
        privateEndpointSubnetName = [string]$Foundation.privateEndpointSubnetName
        entraIdTenantId = [string]$Config.tenantId
        entraIdClientId = [string]$Identity.gatewayApiClientId
        entraIdAudience = [string]$Identity.gatewayApiAudience
        entraAdminObjectId = [string]$Identity.userObjectId
        entraAdminLogin = [string]$Identity.userPrincipalName
        apiContainerImage = $ApiImage
        workerContainerImage = $WorkerImage
        workerContainerAppName = "ca-gateway-worker-$($Config.environment)-v3"
        agent365ProvisioningManagedIdentityPrincipalId = $WorkerPrincipalId
        historicalWorkerContainerAppName = "ca-gateway-worker-$($Config.environment)"
        preserveExistingApiSecrets = -not $Initial
        workerProcessingEnabled = [bool]$EnableWorkerProcessing
        enableLegacyWorkerCredentialKeyVaultSecretsOfficer = $false
        provisioningExecutionEnabled = [bool]$EnableProvisioning
        continuousDevelopmentProvisioningEnabled = [bool]$enablePreview
        provisioningAdmissionExpiresAtUtc = ''
        provisioningAuthorizedExternalAgentId = ''
        provisioningAuthorizedRetryAgentId = ''
        agent365RegistryProvider = if ($enablePreview) { 'DirectRegistryPreview' } else { 'Disabled' }
        agent365DirectRegistryPreviewEnabled = [bool]$enablePreview
        agent365DelegatedRegistryEnabled = [bool]$enablePreview
        agent365DelegatedRegistryActionExpiresAtUtc = ''
        agent365DelegatedRegistryAuthorizedOperationId = ''
        agent365ManagerApplicationsPreflightConfirmed = [bool]($ManagerApplicationIds.Count -gt 0)
        agent365ManagerApplicationIds = @($ManagerApplicationIds)
        purviewEnabled = [bool]$EnablePurview
        promptShieldEnabled = [bool]$Config.promptShield.enabled
        promptShieldSkuName = [string]$Config.promptShield.skuName
        purviewPolicyProvisioningEnabled = [bool]($EnablePurview -and $Config.purview.policyProvisioningEnabled -eq $true)
        purviewPolicyProvisioningOrganization = [string]$Config.purview.policyProvisioningOrganization
        purviewPolicyProvisioningApplicationId = [string]$Config.purview.policyProvisioningApplicationId
        purviewPolicyProvisioningCertificateSecretUri = [string]$Config.purview.policyProvisioningCertificateSecretUri
        purviewDefaultSensitiveInformationType = [string]$Config.purview.sensitiveInformationType
        deployAdminUi = -not [string]::IsNullOrWhiteSpace($AdminUiImage)
        adminUiContainerImage = $AdminUiImage
        adminUiEntraClientId = $AdminUiClientId
        adminUiEntraClientSecretKeyVaultSecretUri = $AdminUiSecretUri
        adminUiGatewayApiScope = if ([string]::IsNullOrWhiteSpace($AdminUiClientId)) { '' } else { "$($Identity.gatewayApiAudience)/access_as_user" }
        alertEmail = [string]$Config.alertEmail
        sqlSkuName = [string]$Config.sql.skuName
        sqlSkuTier = [string]$Config.sql.skuTier
    }
    $deployment = Invoke-ArmDeploymentWithSecureParameters -ResourceGroup ([string]$Config.resourceGroupName) -Name $name -TemplateFile (Join-Path $root 'infrastructure/bicep/main.bicep') -Parameters $parameters
    $outputs = $deployment.properties.outputs
    return [ordered]@{
        deploymentName = $name
        apiFqdn = [string]$outputs.apiFqdn.value
        apiPrincipalId = [string]$outputs.apiPrincipalId.value
        workerPrincipalId = [string]$outputs.workerPrincipalId.value
        adminUiFqdn = [string]$outputs.adminUiFqdn.value
        acrLoginServer = [string]$outputs.acrLoginServer.value
        keyVaultUri = [string]$outputs.keyVaultUri.value
        sqlServerFqdn = [string]$outputs.sqlServerFqdn.value
        serviceBusQueueName = [string]$outputs.serviceBusQueueName.value
        provisioningExecutionEnabled = [bool]$outputs.provisioningExecutionEnabled.value
        workerProcessingEnabled = [bool]$outputs.workerProcessingEnabled.value
        registryProvider = [string]$outputs.agent365RegistryProvider.value
        promptShieldEndpoint = [string]$outputs.promptShieldEndpoint.value
        promptShieldAccountId = [string]$outputs.promptShieldAccountId.value
        promptShieldAccountName = [string]$outputs.promptShieldAccountName.value
    }
}

function Build-GatewayImages {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$AcrLoginServer)
    $root = Get-RepositoryRoot
    $registry = $AcrLoginServer.Split('.')[0]
    $revision = (& git -C $root rev-parse --short=12 HEAD 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($revision)) { $revision = [DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss') }
    $tag = "bootstrap-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))-$revision-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    $definitions = [ordered]@{
        api = @{ repository = 'gateway-api'; dockerfile = 'src/Gateway.Api/Dockerfile' }
        worker = @{ repository = 'gateway-worker'; dockerfile = 'src/Gateway.Provisioning.Worker/Dockerfile' }
        adminUi = @{ repository = 'gateway-admin'; dockerfile = 'src/Gateway.AdminUi/Dockerfile' }
    }
    $dirty = -not [string]::IsNullOrWhiteSpace((& git -C $root status --porcelain 2>$null | Out-String).Trim())
    $result = [ordered]@{ tag = $tag; registry = $registry; sourceCommit = $revision; sourceWorkingTreeDirty = $dirty }
    foreach ($entry in $definitions.GetEnumerator()) {
        $imageTag = "$($entry.Value.repository):$tag"
        Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('acr', 'build', '--registry', $registry, '--image', $imageTag, '--file', (Join-Path $root $entry.Value.dockerfile), $root, '--only-show-errors') -NoCapture | Out-Null
        $digest = Invoke-AzTsv -Arguments @('acr', 'manifest', 'show-metadata', '--registry', $registry, '--name', $imageTag, '--query', 'digest')
        if ($digest -notmatch '^sha256:[a-f0-9]{64}$') { throw "Could not resolve immutable digest for $imageTag." }
        $result[$entry.Key] = "$AcrLoginServer/$($entry.Value.repository)@$digest"
        $result["$($entry.Key)Digest"] = $digest
    }
    return $result
}

function Deploy-SqlPrivateEndpoint {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Foundation, [Parameter(Mandatory)][string]$SqlServerFqdn)
    $root = Get-RepositoryRoot
    $serverName = $SqlServerFqdn.Split('.')[0]
    $result = Invoke-AzJson -Arguments @(
        'deployment', 'group', 'create', '--resource-group', [string]$Config.resourceGroupName,
        '--name', "a365gw-bootstrap-sql-private-$($Config.environment)",
        '--template-file', (Join-Path $root 'bootstrap/infra/sql-private-endpoint.bicep'),
        '--parameters', "location=$($Config.location)", "sqlServerName=$serverName",
        "privateEndpointSubnetId=$($Foundation.privateEndpointSubnetId)", "virtualNetworkId=$($Foundation.virtualNetworkId)",
        "projectName=$($Config.projectName)", "environment=$($Config.environment)"
    )
    return [ordered]@{
        privateEndpointId = [string]$result.properties.outputs.privateEndpointId.value
        privateDnsZoneId = [string]$result.properties.outputs.privateDnsZoneId.value
    }
}

function Deploy-GatewayAdminUi {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$AdminIdentity,
        [Parameter(Mandatory)][string]$AdminUiImage,
        [Parameter(Mandatory)][string]$AdminUiSecretUri
    )
    $root = Get-RepositoryRoot
    $parameters = [ordered]@{
        environment = [string]$Config.environment
        projectName = [string]$Config.projectName
        containerAppsEnvironmentName = [string]$Foundation.containerAppsEnvironmentName
        adminUiContainerImage = $AdminUiImage
        entraIdTenantId = [string]$Config.tenantId
        adminUiEntraClientId = [string]$AdminIdentity.adminUiClientId
        adminUiEntraClientSecretKeyVaultSecretUri = $AdminUiSecretUri
        adminUiGatewayApiScope = "$($Identity.gatewayApiAudience)/access_as_user"
        deployKeyVaultPrivateEndpoint = $true
        keyVaultPrivateEndpointSubnetId = [string]$Foundation.privateEndpointSubnetId
        keyVaultPrivateDnsVirtualNetworkId = [string]$Foundation.virtualNetworkId
    }
    $deployment = Invoke-ArmDeploymentWithSecureParameters -ResourceGroup ([string]$Config.resourceGroupName) -Name "a365gw-bootstrap-admin-$($Config.environment)" -TemplateFile (Join-Path $root 'infrastructure/bicep/admin-ui.bicep') -Parameters $parameters
    $outputs = $deployment.properties.outputs
    return [ordered]@{
        adminUiFqdn = [string]$outputs.adminUiFqdn.value
        adminUiUrl = [string]$outputs.adminUiUrl.value
        adminUiPrincipalId = [string]$outputs.adminUiPrincipalId.value
        signInRedirectUri = [string]$outputs.adminUiSignInRedirectUri.value
        signedOutCallbackUri = [string]$outputs.adminUiSignedOutCallbackUri.value
    }
}

function Set-GatewayNetworkHardening {
    param([Parameter(Mandatory)]$Config)
    $sharedVault = "kv-$($Config.projectName)-$($Config.environment)"
    $provisioningVault = "kv-$($Config.projectName)-$($Config.environment)-prov"
    Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('keyvault', 'update', '--resource-group', [string]$Config.resourceGroupName, '--name', $sharedVault, '--public-network-access', 'Disabled', '--only-show-errors') | Out-Null
    # Workflow v3 does not use the provisioning vault. Closing its public endpoint is
    # safe even though it intentionally has no private endpoint.
    Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @('keyvault', 'update', '--resource-group', [string]$Config.resourceGroupName, '--name', $provisioningVault, '--public-network-access', 'Disabled', '--only-show-errors') | Out-Null
    return [ordered]@{ sharedKeyVault = $sharedVault; provisioningKeyVault = $provisioningVault; publicNetworkAccess = 'Disabled' }
}

Export-ModuleMember -Function *
