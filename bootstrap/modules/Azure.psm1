Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Connect-BootstrapAzure {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [switch]$NonInteractive)
    Clear-BootstrapAzureSubscriptionContext
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
    Set-BootstrapAzureSubscriptionContext `
        -SubscriptionId ([string]$Config.subscriptionId) `
        -TenantId ([string]$Config.tenantId)
    $user = Invoke-AzJson -Arguments @(
        'rest', '--method', 'GET', '--url',
        'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName,displayName'
    )
    Assert-GuidValue -Value ([string]$user.id) -Label 'Signed-in user object ID'
    return [ordered]@{
        subscriptionId = [string]$account.id
        tenantId = [string]$account.tenantId
        userObjectId = [string]$user.id
        userPrincipalName = [string]$user.userPrincipalName
        userDisplayName = [string]$user.displayName
    }
}

function Assert-BootstrapAzureContext {
    param([Parameter(Mandatory)]$Config)

    $account = Invoke-AzJson -Arguments @('account', 'show')
    if (-not $account -or
        [string]$account.tenantId -ne [string]$Config.tenantId -or
        [string]$account.id -ne [string]$Config.subscriptionId) {
        throw 'The explicitly pinned Azure subscription no longer resolves to the configured tenant and subscription.'
    }
    return $true
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
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId
    )
    $root = Get-BootstrapExecutionSourceRoot
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Foundation deployment ownership ID must be a canonical lowercase GUID from the current bootstrap state.'
    }
    $groupExists = Invoke-AzTsv -Arguments @('group', 'exists', '--name', [string]$Config.resourceGroupName)
    if ($groupExists -notin @('true', 'false')) {
        throw 'Azure returned an invalid resource-group existence result; no foundation mutation was attempted.'
    }
    if ($groupExists -ne 'false') {
        throw 'Clean bootstrap refuses to deploy a fresh foundation into an existing resource group. Use only exact state-bound Resume recovery.'
    }
    # Subscription deployments share one name namespace across resource groups.
    # Include the project discriminator so two development Gateways in the same
    # subscription cannot overwrite each other's deployment record.
    $deploymentName = "a365gw-$($Config.projectName)-bootstrap-foundation-$($Config.environment)"
    $result = Invoke-AzJson -Arguments @(
        'deployment', 'sub', 'create',
        '--name', $deploymentName,
        '--location', [string]$Config.location,
        '--template-file', (Join-Path $root 'bootstrap/infra/subscription.bicep'),
        '--parameters',
        "resourceGroupName=$($Config.resourceGroupName)",
        "location=$($Config.location)",
        "environment=$($Config.environment)",
        "projectName=$($Config.projectName)",
        "deploymentOwnershipId=$canonicalOwnershipId"
    )
    $outputs = $result.properties.outputs
    if ([string]$outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId) {
        throw 'Foundation deployment did not echo the exact bootstrap ownership ID.'
    }
    return [ordered]@{
        deploymentName = $deploymentName
        deploymentOwnershipId = $canonicalOwnershipId
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

function Get-BootstrapFoundationEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId
    )
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Foundation recovery ownership ID is not canonical.'
    }
    $deploymentName = "a365gw-$($Config.projectName)-bootstrap-foundation-$($Config.environment)"
    $result = Invoke-AzJson -Arguments @(
        'deployment', 'sub', 'show', '--subscription', [string]$Config.subscriptionId,
        '--name', $deploymentName
    )
    if (-not $result -or [string]$result.properties.provisioningState -ne 'Succeeded' -or
        [string]$result.properties.parameters.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
        [string]$result.properties.outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId) {
        throw 'The prior foundation deployment was absent, incomplete, or not owned by this bootstrap state.'
    }
    $outputs = $result.properties.outputs
    return [ordered]@{
        deploymentName = $deploymentName
        deploymentOwnershipId = $canonicalOwnershipId
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
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter()]$Database,
        [Parameter()][string]$AdminUiImage = '',
        [Parameter()][string]$AdminUiClientId = '',
        [Parameter()][string]$AdminUiSecretUri = '',
        [Parameter()][switch]$Initial,
        [Parameter()][switch]$EnableWorkerProcessing,
        [Parameter()][switch]$EnableProvisioning,
        [Parameter()][switch]$EnablePurview
    )
    $root = Get-BootstrapExecutionSourceRoot
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Deployment ownership ID must be a canonical lowercase GUID from the current bootstrap state.'
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Deployment source fingerprint'
    if ((Get-BootstrapSourceFingerprint -Root $root) -cne $SourceFingerprint) {
        throw 'The workload deployment source no longer matches the accepted content-addressed snapshot.'
    }
    $canonicalManagerApplicationIds = @()
    if (-not $Initial) {
        $reviewedManagerIds = @($Config.agent365.reviewedManagerApplicationIds | ForEach-Object { ([guid][string]$_).ToString('D') } | Sort-Object -Unique)
        $requestedManagerIds = @($ManagerApplicationIds | ForEach-Object { ([guid][string]$_).ToString('D') } | Sort-Object -Unique)
        if ($reviewedManagerIds.Count -eq 0 -or
            $reviewedManagerIds.Count -ne @($Config.agent365.reviewedManagerApplicationIds).Count -or
            $requestedManagerIds.Count -ne $ManagerApplicationIds.Count -or
            ($reviewedManagerIds -join '|') -cne ($requestedManagerIds -join '|')) {
            throw 'Runtime managerApplications must exactly equal the independently reviewed configuration; provider-discovered authority is never accepted implicitly.'
        }
        $canonicalManagerApplicationIds = @($requestedManagerIds)
        if (-not $Database -or
            [string]$Database.deploymentOwnershipId -cne $canonicalOwnershipId -or
            [string]$Database.acceptedSourceFingerprint -cne $SourceFingerprint -or
            [string]$Database.server -cnotmatch '^[A-Za-z0-9-]+\.database\.windows\.net$' -or
            [string]$Database.database -cne 'GatewayDb' -or
            [string]$Database.schemaFingerprint -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            [string]$Database.apiPrincipalName -cne "ca-gateway-api-$($Config.environment)" -or
            [string]$Database.workerPrincipalName -cne "ca-gateway-worker-$($Config.environment)-v3") {
            throw 'Runtime deployment requires exact ownership/source-bound current database-attestation evidence.'
        }
        Assert-GuidValue -Value ([string]$Database.apiPrincipalClientId) -Label 'Gateway API database-principal client ID'
        Assert-GuidValue -Value ([string]$Database.workerPrincipalClientId) -Label 'Gateway worker database-principal client ID'
    }
    if ($EnablePurview -and $Config.purview.policyProvisioningEnabled -eq $true) {
        $configuredVaultHost = ([Uri][string]$Config.purview.policyProvisioningCertificateSecretUri).Host
        # The bootstrap foundation precedes the workload deployment that creates
        # Key Vault, so its evidence intentionally has no keyVaultUri output. The
        # shared vault name is nevertheless deterministic in the reviewed Bicep.
        $gatewayVaultHost = "kv-$($Config.projectName)-$($Config.environment).vault.azure.net"
        if (-not $configuredVaultHost.Equals($gatewayVaultHost, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Purview policy automation certificate must be stored in the Gateway shared Key Vault '$gatewayVaultHost' so the worker's read-only role remains narrowly scoped."
        }
    }
    $name = if ($Initial) { "a365gw-$($Config.projectName)-bootstrap-inert-$($Config.environment)" } else { "a365gw-$($Config.projectName)-bootstrap-runtime-$($Config.environment)" }
    if ($Initial) {
        $deploymentCountText = Invoke-AzTsv -Arguments @(
            'deployment', 'group', 'list', '--resource-group', [string]$Config.resourceGroupName,
            '--query', "length([?name=='$name'])"
        )
        $deploymentCount = 0
        if (-not [int]::TryParse($deploymentCountText, [ref]$deploymentCount) -or $deploymentCount -notin @(0, 1)) {
            throw 'Azure returned an invalid or duplicate inert deployment discovery result; no workload mutation was attempted.'
        }
        if ($deploymentCount -eq 1) {
            $existingDeployment = Invoke-AzJson -Arguments @(
                'deployment', 'group', 'show', '--resource-group', [string]$Config.resourceGroupName, '--name', $name
            )
            if (-not $existingDeployment -or [string]$existingDeployment.properties.provisioningState -ne 'Succeeded') {
                throw "The existing inert deployment '$name' is not a completed exact recovery candidate."
            }
            $existingOutputs = $existingDeployment.properties.outputs
            $recordedOwnershipId = [string]$existingDeployment.properties.parameters.deploymentOwnershipId.value
            $outputOwnershipId = [string]$existingOutputs.deploymentOwnershipId.value
            $recordedSourceFingerprint = [string]$existingDeployment.properties.parameters.bootstrapSourceFingerprint.value
            $outputSourceFingerprint = [string]$existingOutputs.bootstrapSourceFingerprint.value
            if ($recordedOwnershipId -cne $canonicalOwnershipId -or $outputOwnershipId -cne $canonicalOwnershipId -or
                $recordedSourceFingerprint -cne $SourceFingerprint -or $outputSourceFingerprint -cne $SourceFingerprint -or
                [string]$existingDeployment.properties.parameters.apiContainerImage.value -cne $ApiImage -or
                [string]$existingDeployment.properties.parameters.workerContainerImage.value -cne $WorkerImage -or
                [bool]$existingDeployment.properties.parameters.databaseAttestationEnabled.value -ne $false -or
                [string]$existingOutputs.apiContainerImage.value -cne $ApiImage -or
                [string]$existingOutputs.workerContainerImage.value -cne $WorkerImage) {
                throw "The existing inert deployment '$name' is not owned by this bootstrap state. Refusing to adopt its identities or outputs."
            }
            $existingApi = Invoke-AzJson -Arguments @(
                'containerapp', 'show', '--resource-group', [string]$Config.resourceGroupName,
                '--name', "ca-gateway-api-$($Config.environment)",
                '--query', '{principalId:identity.principalId,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint,image:properties.template.containers[0].image}'
            )
            $existingWorker = Invoke-AzJson -Arguments @(
                'containerapp', 'show', '--resource-group', [string]$Config.resourceGroupName,
                '--name', "ca-gateway-worker-$($Config.environment)-v3",
                '--query', '{principalId:identity.principalId,ownershipId:tags.bootstrapOwnershipId,sourceFingerprint:tags.bootstrapSourceFingerprint,image:properties.template.containers[0].image}'
            )
            if ([string]$existingApi.ownershipId -cne $canonicalOwnershipId -or
                [string]$existingWorker.ownershipId -cne $canonicalOwnershipId -or
                [string]$existingApi.sourceFingerprint -cne $SourceFingerprint -or
                [string]$existingWorker.sourceFingerprint -cne $SourceFingerprint -or
                [string]$existingApi.image -cne $ApiImage -or
                [string]$existingWorker.image -cne $WorkerImage -or
                [string]$existingApi.principalId -ne [string]$existingOutputs.apiPrincipalId.value -or
                [string]$existingWorker.principalId -ne [string]$existingOutputs.workerPrincipalId.value) {
                throw "The existing inert deployment '$name' resources do not match this bootstrap state's exact ownership and identity boundary."
            }
            $promptShieldEndpoint = if ($null -ne $existingOutputs.PSObject.Properties['promptShieldEndpoint']) { [string]$existingOutputs.promptShieldEndpoint.value } else { '' }
            $promptShieldAccountId = if ($null -ne $existingOutputs.PSObject.Properties['promptShieldAccountId']) { [string]$existingOutputs.promptShieldAccountId.value } else { '' }
            $promptShieldAccountName = if ($null -ne $existingOutputs.PSObject.Properties['promptShieldAccountName']) { [string]$existingOutputs.promptShieldAccountName.value } else { '' }
            return [ordered]@{
                deploymentName = $name
                deploymentOwnershipId = $canonicalOwnershipId
                sourceFingerprint = $SourceFingerprint
                apiImage = $ApiImage
                workerImage = $WorkerImage
                apiFqdn = [string]$existingOutputs.apiFqdn.value
                apiPrincipalId = [string]$existingOutputs.apiPrincipalId.value
                workerPrincipalId = [string]$existingOutputs.workerPrincipalId.value
                adminUiFqdn = [string]$existingOutputs.adminUiFqdn.value
                acrLoginServer = [string]$existingOutputs.acrLoginServer.value
                containerRegistryId = [string]$existingOutputs.containerRegistryId.value
                keyVaultUri = [string]$existingOutputs.keyVaultUri.value
                sharedKeyVaultId = [string]$existingOutputs.sharedKeyVaultId.value
                storageAccountId = [string]$existingOutputs.storageAccountId.value
                sqlServerFqdn = [string]$existingOutputs.sqlServerFqdn.value
                serviceBusQueueName = [string]$existingOutputs.serviceBusQueueName.value
                serviceBusQueueId = [string]$existingOutputs.serviceBusQueueId.value
                provisioningExecutionEnabled = [bool]$existingOutputs.provisioningExecutionEnabled.value
                workerProcessingEnabled = [bool]$existingOutputs.workerProcessingEnabled.value
                registryProvider = [string]$existingOutputs.agent365RegistryProvider.value
                promptShieldEndpoint = $promptShieldEndpoint
                promptShieldAccountId = $promptShieldAccountId
                promptShieldAccountName = $promptShieldAccountName
                databaseAttestationEnabled = [bool]$existingOutputs.databaseAttestationEnabled.value
                databaseAttestationExpectedSchemaFingerprint = [string]$existingOutputs.databaseAttestationExpectedSchemaFingerprint.value
                databaseAttestationApiPrincipalName = [string]$existingOutputs.databaseAttestationApiPrincipalName.value
                databaseAttestationApiPrincipalClientId = [string]$existingOutputs.databaseAttestationApiPrincipalClientId.value
                databaseAttestationWorkerPrincipalName = [string]$existingOutputs.databaseAttestationWorkerPrincipalName.value
                databaseAttestationWorkerPrincipalClientId = [string]$existingOutputs.databaseAttestationWorkerPrincipalClientId.value
                databaseAttestationDatabaseName = [string]$existingOutputs.databaseAttestationDatabaseName.value
            }
        }
        foreach ($containerAppName in @(
            "ca-gateway-api-$($Config.environment)",
            "ca-gateway-worker-$($Config.environment)-v3"
        )) {
            $resourceCountText = Invoke-AzTsv -Arguments @(
                'resource', 'list', '--resource-group', [string]$Config.resourceGroupName,
                '--name', $containerAppName, '--resource-type', 'Microsoft.App/containerApps',
                '--query', 'length(@)'
            )
            $resourceCount = 0
            if (-not [int]::TryParse($resourceCountText, [ref]$resourceCount) -or $resourceCount -ne 0) {
                throw "The fresh inert deployment target '$containerAppName' was not proven absent. Refusing to adopt or overwrite a pre-existing security principal."
            }
        }
    }
    $enablePreview = $EnableProvisioning -and [string]$Config.environment -eq 'dev' -and $Config.agent365.allowDevelopmentRegistryPreview -eq $true
    $parameters = [ordered]@{
        environment = [string]$Config.environment
        location = [string]$Config.location
        projectName = [string]$Config.projectName
        deploymentOwnershipId = $canonicalOwnershipId
        bootstrapSourceFingerprint = $SourceFingerprint
        databaseAttestationEnabled = [bool](-not $Initial)
        databaseAttestationExpectedSchemaFingerprint = if ($Initial) { '' } else { [string]$Database.schemaFingerprint }
        databaseAttestationApiPrincipalName = if ($Initial) { '' } else { [string]$Database.apiPrincipalName }
        databaseAttestationApiPrincipalClientId = if ($Initial) { '' } else { [string]$Database.apiPrincipalClientId }
        databaseAttestationWorkerPrincipalName = if ($Initial) { '' } else { [string]$Database.workerPrincipalName }
        databaseAttestationWorkerPrincipalClientId = if ($Initial) { '' } else { [string]$Database.workerPrincipalClientId }
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
        agent365ManagerApplicationsPreflightConfirmed = [bool](-not $Initial -and $ManagerApplicationIds.Count -gt 0)
        agent365ManagerApplicationIds = @($canonicalManagerApplicationIds)
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
    if ([string]$outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
        [string]$outputs.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
        [string]$outputs.apiContainerImage.value -cne $ApiImage -or
        [string]$outputs.workerContainerImage.value -cne $WorkerImage) {
        throw 'The workload deployment did not echo the exact ownership, source, and immutable-image boundary.'
    }
    return [ordered]@{
        deploymentName = $name
        deploymentOwnershipId = [string]$outputs.deploymentOwnershipId.value
        sourceFingerprint = [string]$outputs.bootstrapSourceFingerprint.value
        apiImage = [string]$outputs.apiContainerImage.value
        workerImage = [string]$outputs.workerContainerImage.value
        apiFqdn = [string]$outputs.apiFqdn.value
        apiPrincipalId = [string]$outputs.apiPrincipalId.value
        workerPrincipalId = [string]$outputs.workerPrincipalId.value
        adminUiFqdn = [string]$outputs.adminUiFqdn.value
        acrLoginServer = [string]$outputs.acrLoginServer.value
        containerRegistryId = [string]$outputs.containerRegistryId.value
        keyVaultUri = [string]$outputs.keyVaultUri.value
        sharedKeyVaultId = [string]$outputs.sharedKeyVaultId.value
        storageAccountId = [string]$outputs.storageAccountId.value
        sqlServerFqdn = [string]$outputs.sqlServerFqdn.value
        serviceBusQueueName = [string]$outputs.serviceBusQueueName.value
        serviceBusQueueId = [string]$outputs.serviceBusQueueId.value
        provisioningExecutionEnabled = [bool]$outputs.provisioningExecutionEnabled.value
        workerProcessingEnabled = [bool]$outputs.workerProcessingEnabled.value
        registryProvider = [string]$outputs.agent365RegistryProvider.value
        promptShieldEndpoint = [string]$outputs.promptShieldEndpoint.value
        promptShieldAccountId = [string]$outputs.promptShieldAccountId.value
        promptShieldAccountName = [string]$outputs.promptShieldAccountName.value
        databaseAttestationEnabled = [bool]$outputs.databaseAttestationEnabled.value
        databaseAttestationExpectedSchemaFingerprint = [string]$outputs.databaseAttestationExpectedSchemaFingerprint.value
        databaseAttestationApiPrincipalName = [string]$outputs.databaseAttestationApiPrincipalName.value
        databaseAttestationApiPrincipalClientId = [string]$outputs.databaseAttestationApiPrincipalClientId.value
        databaseAttestationWorkerPrincipalName = [string]$outputs.databaseAttestationWorkerPrincipalName.value
        databaseAttestationWorkerPrincipalClientId = [string]$outputs.databaseAttestationWorkerPrincipalClientId.value
        databaseAttestationDatabaseName = [string]$outputs.databaseAttestationDatabaseName.value
    }
}

function Get-GatewayAcrBuildSourceFiles {
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    $projectRoots = @(
        'Gateway.Api', 'Gateway.Application', 'Gateway.Domain', 'Gateway.Contracts',
        'Gateway.Infrastructure', 'Gateway.Agent365', 'Gateway.Purview',
        'Gateway.ContentSafety', 'Gateway.Observability', 'Gateway.Provisioning.Worker',
        'Gateway.AdminUi'
    )
    $rootFiles = @('global.json', 'nuget.config', 'Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props')
    $candidatePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git -and (Test-Path -LiteralPath (Join-Path $RepositoryRoot '.git'))) {
        $sourceArguments = @($projectRoots | ForEach-Object { "src/$_" }) + $rootFiles
        foreach ($mode in @('tracked', 'untracked')) {
            $arguments = if ($mode -eq 'tracked') {
                @('-C', $RepositoryRoot, 'ls-files', '--') + $sourceArguments
            }
            else {
                @('-C', $RepositoryRoot, 'ls-files', '--others', '--exclude-standard', '--') + $sourceArguments
            }
            foreach ($path in @(& $git.Source @arguments 2>$null)) {
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$path)) {
                    $null = $candidatePaths.Add(([string]$path).Replace('\', '/'))
                }
            }
        }
    }
    if ($candidatePaths.Count -eq 0) {
        foreach ($rootFile in $rootFiles) {
            if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $rootFile) -PathType Leaf) { $null = $candidatePaths.Add($rootFile) }
        }
        foreach ($projectRoot in $projectRoots) {
            $fullProjectRoot = Join-Path $RepositoryRoot "src/$projectRoot"
            foreach ($file in @(Get-ChildItem -LiteralPath $fullProjectRoot -File -Recurse -Force)) {
                $null = $candidatePaths.Add([IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName).Replace('\', '/'))
            }
        }
    }

    $allowedExtensions = @('.cs', '.csproj', '.razor', '.css', '.js', '.ps1', '.png', '.svg', '.ico', '.resx', '.woff', '.woff2', '.ttf', '.eot', '.map')
    $files = @($candidatePaths | Where-Object {
        if (Test-BootstrapSourcePathIsSensitive -RelativePath ([string]$_)) { return $false }
        if ($_ -in $rootFiles) { return $true }
        if ($_ -notmatch '^src/([^/]+)/(.+)$' -or $Matches[1] -notin $projectRoots) { return $false }
        $name = [IO.Path]::GetFileName($_)
        if ($name -eq 'Dockerfile') { return $true }
        if ($name -eq 'appsettings.json') { return $true }
        return [IO.Path]::GetExtension($name).ToLowerInvariant() -in $allowedExtensions
    } | Sort-Object -Unique)

    foreach ($required in @(
        'global.json', 'nuget.config',
        'src/Gateway.Api/Dockerfile', 'src/Gateway.Api/Gateway.Api.csproj',
        'src/Gateway.Provisioning.Worker/Dockerfile', 'src/Gateway.Provisioning.Worker/Gateway.Provisioning.Worker.csproj',
        'src/Gateway.AdminUi/Dockerfile', 'src/Gateway.AdminUi/Gateway.AdminUi.csproj'
    )) {
        if ($files -notcontains $required) { throw "Allowlisted ACR build input '$required' is absent from the repository source set." }
    }
    return @($files)
}

function Assert-GatewayCredentialFreeNuGetConfig {
    param([Parameter(Mandatory)][string]$Path)

    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $document = [Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    try {
        $reader = [Xml.XmlReader]::Create($Path, $settings)
        try { $document.Load($reader) } finally { $reader.Dispose() }
        $root = $document.DocumentElement
        if (-not $root -or $root.Name -cne 'configuration' -or $root.Attributes.Count -ne 0) { throw 'invalid-root' }
        $sections = @($root.ChildNodes | Where-Object { $_.NodeType -eq [Xml.XmlNodeType]::Element })
        if ($sections.Count -gt 1 -or ($sections.Count -eq 1 -and $sections[0].Name -cne 'packageSources')) {
            throw 'unreviewed-section'
        }
        if ($sections.Count -eq 0) { return $true }
        if ($sections[0].Attributes.Count -ne 0) { throw 'package-sources-attributes' }

        $sourceKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $clearCount = 0
        foreach ($node in @($sections[0].ChildNodes | Where-Object { $_.NodeType -eq [Xml.XmlNodeType]::Element })) {
            if ($node.Name -ceq 'clear') {
                $clearCount++
                if ($clearCount -ne 1 -or $node.Attributes.Count -ne 0 -or -not [string]::IsNullOrWhiteSpace($node.InnerText)) {
                    throw 'invalid-clear'
                }
                continue
            }
            if ($node.Name -cne 'add') { throw 'unreviewed-source-node' }
            $attributeNames = @($node.Attributes | ForEach-Object { [string]$_.Name })
            if (@($attributeNames | Where-Object { $_ -notin @('key', 'value', 'protocolVersion') }).Count -ne 0 -or
                @($attributeNames | Sort-Object -Unique).Count -ne $attributeNames.Count -or
                -not [string]::IsNullOrWhiteSpace($node.InnerText)) {
                throw 'unreviewed-source-attribute'
            }
            $key = [string]$node.GetAttribute('key')
            $value = [string]$node.GetAttribute('value')
            $protocolVersion = [string]$node.GetAttribute('protocolVersion')
            if ($key -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or
                -not $sourceKeys.Add($key) -or
                (-not [string]::IsNullOrWhiteSpace($protocolVersion) -and $protocolVersion -cne '3')) {
                throw 'invalid-source-metadata'
            }
            $uri = $null
            if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -cne 'https' -or
                (-not $uri.IsDefaultPort -and $uri.Port -ne 443) -or
                -not [string]::IsNullOrEmpty($uri.UserInfo) -or
                -not [string]::IsNullOrEmpty($uri.Query) -or
                -not [string]::IsNullOrEmpty($uri.Fragment)) {
                throw 'unsafe-source-uri'
            }
            $allowedSource =
                ($uri.Host.Equals('api.nuget.org', [StringComparison]::OrdinalIgnoreCase) -and $uri.AbsolutePath -ceq '/v3/index.json') -or
                ($uri.Host.Equals('packagefeedproxy.microsoft.io', [StringComparison]::OrdinalIgnoreCase) -and $uri.AbsolutePath -ceq '/nuget/v3/index.json')
            if (-not $allowedSource) { throw 'unreviewed-source-host' }
        }
        return $true
    }
    catch {
        throw 'The ACR build refuses NuGet configuration outside the exact credential-free HTTPS source allowlist. No configuration value was rendered.'
    }
}

function New-GatewayAcrBuildContext {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $context = [IO.Directory]::CreateTempSubdirectory('a365gw-acr-build-').FullName
    try {
        Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Image-build source fingerprint'
        $manifest = @(Get-BootstrapSourceManifest -Root $RepositoryRoot)
        if ((Get-BootstrapObjectFingerprint -InputObject $manifest) -cne $SourceFingerprint) {
            throw 'The image-build source does not match the accepted content-addressed snapshot.'
        }
        $expectedHashes = @{}
        foreach ($entry in $manifest) { $expectedHashes[[string]$entry.path] = [string]$entry.sha256 }
        foreach ($relativePath in @(Get-GatewayAcrBuildSourceFiles -RepositoryRoot $RepositoryRoot)) {
            if (-not $expectedHashes.ContainsKey($relativePath)) {
                throw "Allowlisted ACR build input '$relativePath' is outside the accepted source manifest."
            }
            Assert-BootstrapSourcePathIsRegular -Root $RepositoryRoot -RelativePath $relativePath | Out-Null
            $source = Join-Path $RepositoryRoot $relativePath
            $destination = Join-Path $context $relativePath
            [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Force
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedHashes[$relativePath]) {
                throw "Allowlisted ACR build input '$relativePath' changed after plan acceptance."
            }
        }
        $nugetConfig = Join-Path $context 'nuget.config'
        Assert-GatewayCredentialFreeNuGetConfig -Path $nugetConfig | Out-Null
        return $context
    }
    catch {
        if (Test-Path -LiteralPath $context) { Remove-Item -LiteralPath $context -Recurse -Force }
        throw
    }
}

function Invoke-GatewayAcrExactStringArray {
    param(
        [Parameter(Mandatory)][string]$OperationLabel,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$ExpectedValue
    )

    $raw = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList ($Arguments + @('--output', 'json', '--only-show-errors'))
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "$OperationLabel returned no JSON result."
    }

    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($raw)
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Array) {
            throw 'root-not-array'
        }
        $values = [Collections.Generic.List[string]]::new()
        foreach ($element in $document.RootElement.EnumerateArray()) {
            if ($element.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'item-not-string' }
            $value = $element.GetString()
            if ($value -cne $ExpectedValue) { throw 'unexpected-value' }
            $values.Add($value)
        }
        if ($values.Count -gt 1) { throw 'duplicate-value' }
        return @($values)
    }
    catch {
        throw "$OperationLabel returned a malformed or non-exact discovery result."
    }
    finally {
        if ($document) { $document.Dispose() }
    }
}

function Get-GatewayAcrExactTagDigest {
    param(
        [Parameter(Mandatory)][string]$Registry,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag
    )

    if ($Registry -cnotmatch '^[a-z0-9]{5,50}$' -or
        $Repository -cnotmatch '^[a-z0-9]+(?:[._/-][a-z0-9]+)*$' -or
        $Tag -cnotmatch '^bootstrap-[0-9a-f]{32}-[0-9a-f]{32}-[0-9a-f]{32}$') {
        throw 'The exact ACR discovery target is malformed.'
    }

    $repositories = @(Invoke-GatewayAcrExactStringArray `
        -OperationLabel 'ACR repository discovery' `
        -ExpectedValue $Repository `
        -Arguments @('acr', 'repository', 'list', '--name', $Registry, '--query', "[?@=='$Repository']"))
    if ($repositories.Count -eq 0) { return $null }

    $tags = @(Invoke-GatewayAcrExactStringArray `
        -OperationLabel 'ACR deterministic-tag discovery' `
        -ExpectedValue $Tag `
        -Arguments @('acr', 'repository', 'show-tags', '--name', $Registry, '--repository', $Repository, '--query', "[?@=='$Tag']"))
    if ($tags.Count -eq 0) { return $null }

    $digest = Invoke-AzTsv -Arguments @(
        'acr', 'manifest', 'show-metadata', '--registry', $Registry,
        '--name', "${Repository}:$Tag", '--query', 'digest')
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'ACR deterministic-tag discovery did not resolve one canonical immutable digest.'
    }
    return [pscustomobject]@{ tag = $Tag; digest = $digest }
}

function Get-GatewayAcrExactImageRuns {
    param(
        [Parameter(Mandatory)][string]$Registry,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag
    )

    if ($Registry -cnotmatch '^[a-z0-9]{5,50}$' -or
        $Repository -cnotmatch '^[a-z0-9]+(?:[._/-][a-z0-9]+)*$' -or
        $Tag -cnotmatch '^bootstrap-[0-9a-f]{32}-[0-9a-f]{32}-[0-9a-f]{32}$') {
        throw 'The exact ACR run-discovery target is malformed.'
    }
    $tagDigest = Get-GatewayAcrExactTagDigest -Registry $Registry -Repository $Repository -Tag $Tag
    if (-not $tagDigest) {
        # `az acr task list-runs --image` resolves the tag to a manifest first and
        # exits nonzero for a never-built tag. Exact tag absence is sufficient to
        # prove that there is no discoverable completed output for this image.
        return @()
    }
    $raw = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @(
        'acr', 'task', 'list-runs', '--registry', $Registry,
        '--image', "${Repository}:$Tag", '--top', '2',
        '--query', '[].{runId:runId,status:status,runType:runType,outputImages:outputImages}',
        '--output', 'json', '--only-show-errors'
    )
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'ACR exact image-run discovery returned no JSON array.'
    }
    try {
        $runs = ConvertFrom-Json -InputObject $raw -Depth 30 -NoEnumerate -ErrorAction Stop
    }
    catch {
        throw 'ACR exact image-run discovery returned malformed JSON.'
    }
    if ($runs -isnot [System.Array] -or $runs.Count -gt 1) {
        throw 'ACR exact image-run discovery was non-array or ambiguous.'
    }
    foreach ($run in @($runs)) {
        if ([string]$run.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$' -or
            [string]$run.runType -cne 'QuickRun' -or
            @('Queued', 'Started', 'Running', 'Succeeded', 'Failed', 'Canceled', 'Error', 'Timeout') -cnotcontains [string]$run.status) {
            throw 'ACR exact image-run discovery returned a malformed run contract.'
        }
        $outputImages = @($run.outputImages)
        if ([string]$run.status -ceq 'Succeeded') {
            if ($outputImages.Count -ne 1 -or
                [string]$outputImages[0].repository -cne $Repository -or
                [string]$outputImages[0].tag -cne $Tag -or
                [string]$outputImages[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
                throw 'A succeeded ACR run did not report the one exact intended output image.'
            }
        }
        elseif ($outputImages.Count -gt 1 -or ($outputImages.Count -eq 1 -and (
            [string]$outputImages[0].repository -cne $Repository -or
            [string]$outputImages[0].tag -cne $Tag -or
            (-not [string]::IsNullOrWhiteSpace([string]$outputImages[0].digest) -and
                [string]$outputImages[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$')))) {
            throw 'A non-succeeded ACR run reported a mismatched output image contract.'
        }
    }
    return @($runs)
}

function Get-GatewayAcrExactRunById {
    param(
        [Parameter(Mandatory)][string]$Registry,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$RunId
    )

    if ($Registry -cnotmatch '^[a-z0-9]{5,50}$' -or
        $Repository -cnotmatch '^[a-z0-9]+(?:[._/-][a-z0-9]+)*$' -or
        $Tag -cnotmatch '^bootstrap-[0-9a-f]{32}-[0-9a-f]{32}-[0-9a-f]{32}$' -or
        $RunId -cnotmatch '^[A-Za-z0-9-]{1,64}$') {
        throw 'The exact ACR run readback target is malformed.'
    }
    $raw = Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @(
        'acr', 'task', 'show-run', '--registry', $Registry, '--run-id', $RunId,
        '--query', '{runId:runId,status:status,runType:runType,outputImages:outputImages}',
        '--output', 'json', '--only-show-errors'
    )
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'ACR exact run readback returned no JSON object.'
    }
    try {
        $run = ConvertFrom-Json -InputObject $raw -Depth 30 -NoEnumerate -ErrorAction Stop
    }
    catch {
        throw 'ACR exact run readback returned malformed JSON.'
    }
    if ($run -isnot [pscustomobject]) {
        throw 'ACR exact run readback returned a different or malformed run.'
    }
    $propertyNames = @($run.PSObject.Properties.Name)
    if ($propertyNames.Count -ne 4 -or
        @(@('runId', 'status', 'runType', 'outputImages') |
                Where-Object { $propertyNames -cnotcontains $_ }).Count -ne 0 -or
        [string]$run.runId -cne $RunId) {
        throw 'ACR exact run readback returned a different or malformed run.'
    }
    if ([string]$run.runType -cne 'QuickRun' -or
        @('Queued', 'Started', 'Running', 'Succeeded', 'Failed', 'Canceled', 'Error', 'Timeout') -cnotcontains [string]$run.status) {
        throw 'ACR exact run readback returned a malformed run contract.'
    }
    $outputImages = @($run.outputImages)
    if ([string]$run.status -ceq 'Succeeded') {
        if ($outputImages.Count -ne 1 -or
            [string]$outputImages[0].repository -cne $Repository -or
            [string]$outputImages[0].tag -cne $Tag -or
            [string]$outputImages[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
            throw 'A succeeded ACR run did not report the one exact intended output image.'
        }
    }
    elseif ($outputImages.Count -gt 1 -or ($outputImages.Count -eq 1 -and (
        [string]$outputImages[0].repository -cne $Repository -or
        [string]$outputImages[0].tag -cne $Tag -or
        (-not [string]::IsNullOrWhiteSpace([string]$outputImages[0].digest) -and
            [string]$outputImages[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$')))) {
        throw 'A non-succeeded ACR run reported a mismatched output image contract.'
    }
    return $run
}

function Assert-GatewayAcrBuildSubmissionReceiptContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$Receipt
    )
    if ($Receipt -isnot [pscustomobject]) {
        throw 'The submitted ACR build did not return one canonical run-ID receipt.'
    }
    $propertyNames = @($Receipt.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($propertyNames.Count -ne 1 -or
        [string]$propertyNames[0] -cne 'runId' -or
        [string]$Receipt.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$') {
        throw 'The submitted ACR build did not return one canonical run-ID receipt.'
    }
    return [string]$Receipt.runId
}

function Build-GatewayImages {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AcrLoginServer,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter()][AllowNull()]$RecoveredEvidence,
        [Parameter(Mandatory)][scriptblock]$Checkpoint
    )
    $root = Get-BootstrapExecutionSourceRoot
    $registry = $AcrLoginServer.Split('.')[0]
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Image-build source fingerprint'
    if ((Get-BootstrapSourceFingerprint -Root $root) -cne $SourceFingerprint) {
        throw 'The image-build source no longer matches the accepted content-addressed snapshot.'
    }
    $definitions = [ordered]@{
        api = @{ repository = 'gateway-api'; dockerfile = 'src/Gateway.Api/Dockerfile' }
        worker = @{ repository = 'gateway-worker'; dockerfile = 'src/Gateway.Provisioning.Worker/Dockerfile' }
        adminUi = @{ repository = 'gateway-admin'; dockerfile = 'src/Gateway.AdminUi/Dockerfile' }
    }
    $result = [ordered]@{
        schemaVersion = 2
        registry = $registry
        sourceFingerprint = $SourceFingerprint
        deploymentOwnershipId = $DeploymentOwnershipId
        provenance = 'BootstrapPreMutationIntentV2'
        buildIntents = [ordered]@{}
        checkpointedComponents = @()
    }
    if ($RecoveredEvidence) {
        if ([int]$RecoveredEvidence.schemaVersion -ne 2 -or
            [string]$RecoveredEvidence.registry -cne $registry -or
            [string]$RecoveredEvidence.sourceFingerprint -cne $SourceFingerprint -or
            [string]$RecoveredEvidence.deploymentOwnershipId -cne $DeploymentOwnershipId -or
            [string]$RecoveredEvidence.provenance -cne 'BootstrapPreMutationIntentV2' -or
            $RecoveredEvidence.buildIntents -isnot [System.Collections.IDictionary]) {
            throw 'Partial image-build evidence belongs to a different registry, state, or accepted source.'
        }
        $recoveredComponents = @($RecoveredEvidence.checkpointedComponents | ForEach-Object { [string]$_ })
        $uniqueRecoveredComponents = @($recoveredComponents | Sort-Object -Unique)
        if ($recoveredComponents.Count -ne $uniqueRecoveredComponents.Count -or
            @($uniqueRecoveredComponents | Where-Object { $_ -notin @('api', 'worker', 'adminUi') }).Count -ne 0) {
            throw 'Partial image-build evidence contains an invalid component checkpoint set.'
        }
        $result.checkpointedComponents = @($uniqueRecoveredComponents)
        $recoveredIntentComponents = @($RecoveredEvidence.buildIntents.Keys | ForEach-Object { [string]$_ })
        $uniqueIntentComponents = @($recoveredIntentComponents | Sort-Object -Unique)
        if ($recoveredIntentComponents.Count -ne $uniqueIntentComponents.Count -or
            @($uniqueIntentComponents | Where-Object { $_ -notin @('api', 'worker', 'adminUi') }).Count -ne 0) {
            throw 'Partial image-build evidence contains an invalid pre-mutation intent set.'
        }
        foreach ($component in $uniqueIntentComponents) {
            $definition = $definitions[$component]
            $intent = $RecoveredEvidence.buildIntents[$component]
            $canonicalIntentId = ([guid][string]$intent.intentId).ToString('D')
            $expectedTag = Get-BootstrapImageBuildIntentTag `
                -DeploymentOwnershipId $DeploymentOwnershipId `
                -SourceFingerprint $SourceFingerprint `
                -IntentId $canonicalIntentId
            if ([string]$intent.component -cne $component -or
                [string]$intent.repository -cne [string]$definition.repository -or
                [string]$intent.intentId -cne $canonicalIntentId -or
                [string]$intent.tag -cne $expectedTag -or
                [string]$intent.state -notin @('IntentRecorded', 'RunQueued', 'DigestCheckpointed')) {
                throw 'Partial image-build evidence contains a malformed or mismatched pre-mutation intent.'
            }
            $copiedIntent = [ordered]@{
                component = $component
                repository = [string]$definition.repository
                intentId = $canonicalIntentId
                tag = $expectedTag
                state = [string]$intent.state
            }
            if ([string]$intent.state -in @('RunQueued', 'DigestCheckpointed')) {
                if ([string]$intent.runId -cnotmatch '^[A-Za-z0-9-]{1,64}$') {
                    throw 'A submitted image-build intent has no canonical ACR run identifier.'
                }
                $copiedIntent.runId = [string]$intent.runId
            }
            if ([string]$intent.state -ceq 'DigestCheckpointed') {
                $digest = [string]$intent.digest
                $image = "$AcrLoginServer/$($definition.repository)@$digest"
                if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
                    [string]$intent.image -cne $image -or
                    [string]$RecoveredEvidence["${component}Digest"] -cne $digest -or
                    [string]$RecoveredEvidence[$component] -cne $image -or
                    $component -notin $uniqueRecoveredComponents) {
                    throw 'A completed image-build intent has incomplete or mismatched digest evidence.'
                }
                $copiedIntent.digest = $digest
                $copiedIntent.image = $image
                $result[$component] = $image
                $result["${component}Digest"] = $digest
            }
            elseif ($component -in $uniqueRecoveredComponents -or
                $RecoveredEvidence.Contains($component) -or $RecoveredEvidence.Contains("${component}Digest")) {
                throw 'An uncompleted image-build intent cannot carry completed image evidence.'
            }
            $result.buildIntents[$component] = $copiedIntent
        }
        if (@($uniqueRecoveredComponents | Where-Object { $_ -notin $uniqueIntentComponents }).Count -ne 0) {
            throw 'A completed image checkpoint has no matching durable pre-mutation intent.'
        }
    }
    $buildContext = $null
    try {
        foreach ($entry in $definitions.GetEnumerator()) {
            $component = [string]$entry.Key
            $repository = [string]$entry.Value.repository
            $intent = if ($result.buildIntents.Contains($component)) { $result.buildIntents[$component] } else { $null }
            $intentCreatedThisInvocation = $false
            if (-not $intent) {
                $intentId = [guid]::NewGuid().ToString('D')
                $intentTag = Get-BootstrapImageBuildIntentTag `
                    -DeploymentOwnershipId $DeploymentOwnershipId `
                    -SourceFingerprint $SourceFingerprint `
                    -IntentId $intentId
                $preexisting = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $intentTag
                $preexistingRuns = @(Get-GatewayAcrExactImageRuns -Registry $registry -Repository $repository -Tag $intentTag)
                if ($preexisting -or $preexistingRuns.Count -ne 0) {
                    throw 'A freshly generated image-build intent tag already exists; refusing to claim or overwrite it.'
                }
                $intent = [ordered]@{
                    component = $component
                    repository = $repository
                    intentId = $intentId
                    tag = $intentTag
                    state = 'IntentRecorded'
                }
                $result.buildIntents[$component] = $intent
                # This checkpoint is deliberately before the first external build mutation.
                & $Checkpoint $result
                $intentCreatedThisInvocation = $true
            }

            $tag = [string]$intent.tag
            $imageTag = "${repository}:$tag"
            if ([string]$intent.state -ceq 'DigestCheckpointed') {
                $discovered = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $tag
                $expectedDigest = [string]$intent.digest
                $expectedImage = "$AcrLoginServer/$repository@$expectedDigest"
                if (-not $discovered -or [string]$discovered.digest -cne $expectedDigest -or
                    [string]$intent.image -cne $expectedImage -or
                    [string]$result[$component] -cne $expectedImage) {
                    throw 'A checkpointed image no longer matches its exact intent tag and immutable digest.'
                }
                continue
            }

            if ([string]$intent.state -ceq 'IntentRecorded') {
                $runs = @()
                for ($discoveryAttempt = 1; $discoveryAttempt -le 6 -and $runs.Count -eq 0; $discoveryAttempt++) {
                    $runs = @(Get-GatewayAcrExactImageRuns -Registry $registry -Repository $repository -Tag $tag)
                    if ($runs.Count -eq 0 -and -not $intentCreatedThisInvocation -and $discoveryAttempt -lt 6) {
                        Start-Sleep -Seconds 2
                    }
                    elseif ($intentCreatedThisInvocation) { break }
                }

                if ($runs.Count -eq 0) {
                    if (-not $intentCreatedThisInvocation) {
                        throw 'A recovered image-build intent has neither an exact ACR run nor a digest. Submission outcome is ambiguous, so automatic resubmission is forbidden.'
                    }
                    if (-not $buildContext) {
                        $buildContext = New-GatewayAcrBuildContext -RepositoryRoot $root -SourceFingerprint $SourceFingerprint
                    }
                    # `az acr build --no-wait` returns the sparse schedule-run
                    # receipt. Persist its canonical ID before requiring the
                    # full QuickRun contract through exact show-run readback.
                    $submissionReceipt = Invoke-AzJson -CaptureStdoutOnly -Arguments @(
                        'acr', 'build', '--registry', $registry, '--image', $imageTag,
                        '--file', [string]$entry.Value.dockerfile,
                        $buildContext, '--no-wait',
                        '--query', '{runId:runId}')
                    $intent.runId = Assert-GatewayAcrBuildSubmissionReceiptContract -Receipt $submissionReceipt
                    $intent.state = 'RunQueued'
                    & $Checkpoint $result
                }
                else {
                    $intent.runId = [string]$runs[0].runId
                    $intent.state = 'RunQueued'
                    & $Checkpoint $result
                }
            }

            $terminalRun = $null
            for ($attempt = 1; $attempt -le 30; $attempt++) {
                $currentRun = Get-GatewayAcrExactRunById `
                    -Registry $registry `
                    -Repository $repository `
                    -Tag $tag `
                    -RunId ([string]$intent.runId)
                if ([string]$currentRun.status -ceq 'Succeeded') { $terminalRun = $currentRun; break }
                if ([string]$currentRun.status -in @('Failed', 'Canceled', 'Error', 'Timeout')) {
                    throw 'The exact ACR build reached a terminal failure. Automatic resubmission is forbidden; review the run and start a newly accepted plan.'
                }
                if ($attempt -lt 30) { Start-Sleep -Seconds 2 }
            }
            if (-not $terminalRun) {
                throw 'The exact ACR build is still pending or temporarily unavailable. Resume later; no second build was submitted.'
            }
            $runOutputImages = @($terminalRun.outputImages)
            $digest = [string]$runOutputImages[0].digest
            $discovered = Get-GatewayAcrExactTagDigest -Registry $registry -Repository $repository -Tag $tag
            if (-not $discovered -or [string]$discovered.digest -cne $digest) {
                throw 'The succeeded ACR run did not reconcile to the exact intent tag and output digest.'
            }
            $image = "$AcrLoginServer/$repository@$digest"
            $intent.state = 'DigestCheckpointed'
            $intent.digest = $digest
            $intent.image = $image
            $result[$component] = $image
            $result["${component}Digest"] = $digest
            $result.checkpointedComponents = @(@($result.checkpointedComponents) + $component | Sort-Object -Unique)
            & $Checkpoint $result
        }
    }
    finally {
        if ($buildContext -and (Test-Path -LiteralPath $buildContext)) {
            Remove-Item -LiteralPath $buildContext -Recurse -Force
        }
    }
    return $result
}

function Deploy-SqlPrivateEndpoint {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)][string]$SqlServerFqdn,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )
    $root = Get-BootstrapExecutionSourceRoot
    $serverName = $SqlServerFqdn.Split('.')[0]
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) { throw 'SQL private-endpoint ownership ID is not canonical.' }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'SQL private-endpoint source fingerprint'
    $deploymentName = "a365gw-$($Config.projectName)-bootstrap-sql-private-$($Config.environment)"
    $result = Invoke-AzJson -Arguments @(
        'deployment', 'group', 'create', '--resource-group', [string]$Config.resourceGroupName,
        '--name', $deploymentName,
        '--template-file', (Join-Path $root 'bootstrap/infra/sql-private-endpoint.bicep'),
        '--parameters', "location=$($Config.location)", "sqlServerName=$serverName",
        "privateEndpointSubnetId=$($Foundation.privateEndpointSubnetId)", "virtualNetworkId=$($Foundation.virtualNetworkId)",
        "projectName=$($Config.projectName)", "environment=$($Config.environment)",
        "deploymentOwnershipId=$canonicalOwnershipId", "bootstrapSourceFingerprint=$SourceFingerprint"
    )
    $outputs = $result.properties.outputs
    if ([string]$outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
        [string]$outputs.bootstrapSourceFingerprint.value -cne $SourceFingerprint) {
        throw 'SQL private-endpoint deployment did not echo the exact ownership/source boundary.'
    }
    return [ordered]@{
        deploymentName = $deploymentName
        deploymentOwnershipId = $canonicalOwnershipId
        sourceFingerprint = $SourceFingerprint
        privateEndpointId = [string]$outputs.privateEndpointId.value
        privateDnsZoneId = [string]$outputs.privateDnsZoneId.value
        virtualNetworkLinkId = [string]$outputs.virtualNetworkLinkId.value
        privateDnsZoneGroupId = [string]$outputs.privateDnsZoneGroupId.value
        sqlServerId = [string]$outputs.sqlServerId.value
        privateEndpointSubnetId = [string]$outputs.privateEndpointSubnetId.value
        virtualNetworkId = [string]$outputs.virtualNetworkId.value
    }
}

function Deploy-GatewayAdminUi {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Foundation,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$AdminIdentity,
        [Parameter(Mandatory)][string]$AdminUiImage,
        [Parameter(Mandatory)][string]$AdminUiSecretUri,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )
    $root = Get-BootstrapExecutionSourceRoot
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Admin UI deployment ownership ID must be a canonical lowercase GUID from the current bootstrap state.'
    }
    Assert-BootstrapFingerprintValue -Value $SourceFingerprint -Label 'Admin UI source fingerprint'
    if ((Get-BootstrapSourceFingerprint -Root $root) -cne $SourceFingerprint) {
        throw 'The Admin UI deployment source no longer matches the accepted content-addressed snapshot.'
    }
    $deploymentName = "a365gw-$($Config.projectName)-bootstrap-admin-$($Config.environment)"
    $deploymentCountText = Invoke-AzTsv -Arguments @(
        'deployment', 'group', 'list', '--resource-group', [string]$Config.resourceGroupName,
        '--query', "length([?name=='$deploymentName'])"
    )
    $deploymentCount = 0
    if (-not [int]::TryParse($deploymentCountText, [ref]$deploymentCount) -or $deploymentCount -ne 0) {
        throw 'The fresh Admin UI deployment record was not proven absent. Use only exact state-bound Resume recovery.'
    }
    foreach ($target in @(
        [ordered]@{ name = "id-gateway-admin-$($Config.environment)"; type = 'Microsoft.ManagedIdentity/userAssignedIdentities' },
        [ordered]@{ name = "ca-gateway-admin-$($Config.environment)"; type = 'Microsoft.App/containerApps' }
    )) {
        $resourceCountText = Invoke-AzTsv -Arguments @(
            'resource', 'list', '--resource-group', [string]$Config.resourceGroupName,
            '--name', [string]$target.name, '--resource-type', [string]$target.type,
            '--query', 'length(@)'
        )
        $resourceCount = 0
        if (-not [int]::TryParse($resourceCountText, [ref]$resourceCount) -or $resourceCount -ne 0) {
            throw "The fresh Admin UI target '$($target.name)' was not proven absent. Refusing to adopt a pre-existing credential-bearing identity or app."
        }
    }
    $parameters = [ordered]@{
        environment = [string]$Config.environment
        projectName = [string]$Config.projectName
        deploymentOwnershipId = $canonicalOwnershipId
        bootstrapSourceFingerprint = $SourceFingerprint
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
    $deployment = Invoke-ArmDeploymentWithSecureParameters -ResourceGroup ([string]$Config.resourceGroupName) -Name $deploymentName -TemplateFile (Join-Path $root 'infrastructure/bicep/admin-ui.bicep') -Parameters $parameters
    $outputs = $deployment.properties.outputs
    if ([string]$outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
        [string]$outputs.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
        [string]$outputs.adminUiContainerImage.value -cne $AdminUiImage) {
        throw 'Admin UI deployment did not echo the exact bootstrap ownership, source, and immutable-image boundary.'
    }
    return [ordered]@{
        deploymentOwnershipId = $canonicalOwnershipId
        sourceFingerprint = $SourceFingerprint
        adminUiImage = $AdminUiImage
        adminUiFqdn = [string]$outputs.adminUiFqdn.value
        adminUiUrl = [string]$outputs.adminUiUrl.value
        adminUiPrincipalId = [string]$outputs.adminUiPrincipalId.value
        signInRedirectUri = [string]$outputs.adminUiSignInRedirectUri.value
        signedOutCallbackUri = [string]$outputs.adminUiSignedOutCallbackUri.value
    }
}

function Get-GatewayAdminUiDeploymentEvidence {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$AdminUiImage
    )
    $canonicalOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    if ($DeploymentOwnershipId -cne $canonicalOwnershipId) {
        throw 'Admin UI recovery ownership ID is not canonical.'
    }
    $deploymentName = "a365gw-$($Config.projectName)-bootstrap-admin-$($Config.environment)"
    $deployment = Invoke-AzJson -Arguments @(
        'deployment', 'group', 'show', '--resource-group', [string]$Config.resourceGroupName,
        '--name', $deploymentName
    )
    if (-not $deployment -or [string]$deployment.properties.provisioningState -ne 'Succeeded' -or
        [string]$deployment.properties.parameters.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
        [string]$deployment.properties.outputs.deploymentOwnershipId.value -cne $canonicalOwnershipId -or
        [string]$deployment.properties.parameters.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
        [string]$deployment.properties.outputs.bootstrapSourceFingerprint.value -cne $SourceFingerprint -or
        [string]$deployment.properties.parameters.adminUiContainerImage.value -cne $AdminUiImage -or
        [string]$deployment.properties.outputs.adminUiContainerImage.value -cne $AdminUiImage) {
        throw 'The prior Admin UI deployment was absent, incomplete, or not owned by this bootstrap state.'
    }
    $outputs = $deployment.properties.outputs
    return [ordered]@{
        deploymentOwnershipId = $canonicalOwnershipId
        sourceFingerprint = $SourceFingerprint
        adminUiImage = $AdminUiImage
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
    foreach ($vault in @($sharedVault, $provisioningVault)) {
        $actual = Invoke-AzTsv -Arguments @(
            'keyvault', 'show', '--resource-group', [string]$Config.resourceGroupName,
            '--name', $vault, '--query', 'properties.publicNetworkAccess'
        )
        if ($actual -cne 'Disabled') {
            throw "Key Vault network hardening was not independently read back as Disabled for the expected project vault category."
        }
    }
    return [ordered]@{
        sharedKeyVault = $sharedVault
        provisioningKeyVault = $provisioningVault
        publicNetworkAccess = 'Disabled'
        exactPostMutationReadback = $true
    }
}

Export-ModuleMember -Function *
