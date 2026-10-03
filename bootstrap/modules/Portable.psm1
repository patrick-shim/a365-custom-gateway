#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-GatewayDeployProfile {
    param([Parameter(Mandatory)]$Config)

    $value = [string]$Config.deployProfile
    if ([string]::IsNullOrWhiteSpace($value)) {
        return 'azureLegacy'
    }

    if ($value -cnotin @('portable', 'azureLegacy')) {
        throw "Unsupported deployProfile '$value'. Use portable or azureLegacy."
    }

    return $value
}

function Test-GatewayPortableDeployProfile {
    param([Parameter(Mandatory)]$Config)
    return (Get-GatewayDeployProfile -Config $Config) -ceq 'portable'
}

function Get-GatewayPortableBootstrapStepNames {
    return @(
        'Prerequisites'
        'Microsoft authentication'
        'Gateway API identity'
        'Console identity'
        'Portable workload identity'
        'Agent 365 seed blueprint'
        'Prompt Shields account'
        'Local workload images'
        'Portable runtime'
        'End-to-end deployment verification'
    )
}

function Get-GatewayPortableComposeDirectory {
    return [IO.Path]::GetFullPath((Join-Path (Get-RepositoryRoot) 'deploy/portable'))
}

function Assert-GatewayPortablePrerequisites {
    param([switch]$Install)

    Assert-GatewayPlanPrerequisites -Install:$Install | Out-Null

    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($null -eq $docker) {
        throw 'Portable bootstrap requires Docker Engine with the compose plugin.'
    }

    & docker version --format '{{.Server.Version}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker is installed but the daemon is not reachable. Start Docker Desktop or the engine, then retry.'
    }

    & docker compose version 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Compose plugin is required for the portable deploy profile.'
    }

    $composeDir = Get-GatewayPortableComposeDirectory
    if (-not (Test-Path -LiteralPath (Join-Path $composeDir 'docker-compose.yml'))) {
        throw "Portable compose file missing at $composeDir/docker-compose.yml."
    }

    return [ordered]@{
        docker = $true
        composeDirectory = $composeDir
    }
}

function Get-GatewayPortablePlanDescriptor {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $apiPort = [int]$Config.portable.apiHostPort
    $consolePort = [int]$Config.portable.consoleHostPort
    $promptShields = [bool]$Config.promptShield.enabled
    $purview = [bool]$Config.purview.enabled

    return [ordered]@{
        deploymentId = "portable-$($Config.projectName)-$($Config.environment)"
        deployProfile = 'portable'
        deploymentOwnershipId = $DeploymentOwnershipId
        sourceFingerprint = $SourceFingerprint
        features = [ordered]@{
            promptShields = $promptShields
            promptShieldSku = [string]$Config.promptShield.skuName
            purviewPrerequisites = $purview
            developmentRegistryPreview = [bool]$Config.agent365.allowDevelopmentRegistryPreview
            console = $true
        }
        azureResources = @(
            if ($promptShields) {
                "Microsoft.CognitiveServices/accounts (Content Safety $($Config.promptShield.skuName)) in $($Config.resourceGroupName)/$($Config.location)"
            }
            else {
                'No Azure infrastructure resources (Prompt Shields disabled)'
            }
        )
        imperativeOperations = @(
            [ordered]@{ system = 'Entra ID'; operation = 'Create/update Gateway API application, roles, and admin assignment'; mutation = $true }
            [ordered]@{ system = 'Entra ID'; operation = 'Create/update React Console SPA application, redirects, and API consent'; mutation = $true }
            [ordered]@{ system = 'Docker Compose'; operation = 'Build and start PostgreSQL, RabbitMQ, S3, Vault, API, Worker, Console'; mutation = $true }
            if ($promptShields) {
                [ordered]@{ system = 'Azure Resource Manager'; operation = 'Deploy Content Safety account for Prompt Shields'; mutation = $true }
            }
            if ($purview) {
                [ordered]@{ system = 'Microsoft 365'; operation = 'Purview executor packaging remains a separate Windows handoff after compose deploy'; mutation = $false }
            }
        )
        costClasses = @(
            'Local Docker compute/storage on the bootstrap host'
            if ($promptShields) { 'Azure AI Content Safety SKU charges in the selected subscription' }
            'Entra ID directory objects (no Azure compute required for the gateway host)'
        )
        previewWarning = 'Portable profile deploys the gateway host on Docker Compose. Azure is used only for essential product resources you enable (Content Safety, and later Purview packaging).'
        administratorBoundaries = @(
            'Entra Global Administrator or Application Administrator is required for app registration'
            if ($promptShields) { 'Azure subscription Contributor (or equivalent) is required for Content Safety in the selected resource group' }
            'Agent 365 / Purview tenant eligibility is separate from this compose deploy'
        )
        preflightLimitations = @(
            'Compose plan does not execute live Graph or ARM mutations'
            'Public TLS ingress and production secrets rotation are operator-owned after apply'
        )
        endpoints = [ordered]@{
            apiHealth = "http://127.0.0.1:${apiPort}/health"
            apiReady = "http://127.0.0.1:${apiPort}/health/ready"
            console = "http://127.0.0.1:${consolePort}/"
        }
    }
}

function Invoke-GatewayPortablePlanWorkflow {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][ValidateSet('Text', 'Json')][string]$Format,
        [Parameter(Mandatory)][bool]$InstallLocalPrerequisites,
        [switch]$StreamOnly
    )

    $script:GatewayFailureStage = 'Plan review'
    $script:GatewayFailureCode = 'plan_state'
    if ($State.Contains('steps') -and
        $State.steps -is [System.Collections.IDictionary] -and
        $State.steps.Count -gt 0) {
        throw 'This portable deployment already has persisted checkpoints. Run gateway resume so completed steps are revalidated before further mutation.'
    }

    Clear-BootstrapAcceptedPlan -State $State -StatePath $StatePath | Out-Null
    $planEventBase = [ordered]@{
        step = 'Plan review'
        index = 1
        total = (Get-GatewayPortableBootstrapStepNames).Count
    }

    Write-GatewayExperienceEvent -Type Info -Message 'Checking Docker, .NET, Git, and Azure CLI prerequisites for the portable profile.' -Data ([ordered]@{
        step = $planEventBase.step; category = 'localPrerequisites'
    }) -OutputFormat $Format

    $script:GatewayFailureCode = 'plan_prerequisites'
    Assert-GatewayPortablePrerequisites -Install:$InstallLocalPrerequisites | Out-Null

    $sourceFingerprint = Get-BootstrapSourceFingerprint
    $configurationFingerprint = Get-BootstrapConfigurationFingerprint -Config $Configuration
    $descriptor = Get-GatewayPortablePlanDescriptor `
        -Config $Configuration `
        -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) `
        -SourceFingerprint $sourceFingerprint

    $needsAzure = [bool]$Configuration.promptShield.enabled
    if ($needsAzure -or $true) {
        # Entra app registration always needs an authenticated Graph session via Azure CLI.
        $script:GatewayFailureCode = 'plan_account'
        Clear-BootstrapAzureSubscriptionContext
        if ([string]::IsNullOrWhiteSpace([string]$Configuration.subscriptionId)) {
            Set-BootstrapAzureTenantContext -TenantId ([string]$Configuration.tenantId)
        }
        else {
            Set-BootstrapAzureSubscriptionContext `
                -SubscriptionId ([string]$Configuration.subscriptionId) `
                -TenantId ([string]$Configuration.tenantId)
        }

        $script:GatewayFailureCode = 'plan_entra_namespace'
        Assert-GatewayApplicationNamespacePlanBoundary `
            -Config $Configuration `
            -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) | Out-Null
    }

    if ([bool]$Configuration.promptShield.enabled) {
        $script:GatewayFailureCode = 'plan_prompt_shield_capacity'
        Assert-GatewayPromptShieldFreeTierCapacity `
            -Config $Configuration `
            -ResourceGroupName ([string]$Configuration.resourceGroupName) | Out-Null
    }

    $whatIf = [ordered]@{
        executed = $true
        applyReady = $true
        changeCounts = [ordered]@{ Create = 1; Modify = 0; Delete = 0; NoChange = 0; Ignore = 0; Deploy = 0 }
        changes = @(
            [ordered]@{
                resourceId = "compose://$(Get-GatewayPortableComposeDirectory)"
                changeType = 'Create'
            }
        )
    }

    $planFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
        contractVersion = 1
        profile = 'portable'
        configurationFingerprint = $configurationFingerprint
        sourceFingerprint = $sourceFingerprint
        descriptor = $descriptor
        composeWhatIf = $whatIf
    })

    Write-GatewayExperienceEvent -Type Info -Message "Portable plan $($descriptor.deploymentId); fingerprint $planFingerprint." -Data ([ordered]@{
        step = $planEventBase.step
        category = 'planResult'
        deploymentId = [string]$descriptor.deploymentId
        planFingerprint = $planFingerprint
        applyReady = $true
        features = $descriptor.features
        endpoints = $descriptor.endpoints
    }) -OutputFormat $Format

    if (-not $StreamOnly -and $Format -eq 'Text') {
        Write-Host ''
        Write-Host 'Portable deploy plan' -ForegroundColor Cyan
        Write-Host "  Deployment : $($descriptor.deploymentId)"
        Write-Host "  Console    : $($descriptor.endpoints.console)"
        Write-Host "  API health : $($descriptor.endpoints.apiHealth)"
        Write-Host "  Prompt Shields : $(if ($descriptor.features.promptShields) { 'enabled' } else { 'disabled' })"
        Write-Host "  Purview prep   : $(if ($descriptor.features.purviewPrerequisites) { 'requested (post-compose handoff)' } else { 'not requested' })"
        Write-Host "  Fingerprint    : $planFingerprint"
        Write-Host ''
    }

    $bootstrapClientIpv4 = '127.0.0.1'
    try { $bootstrapClientIpv4 = Get-GatewayBootstrapClientIpv4 } catch { }

    return [ordered]@{
        descriptor = $descriptor
        whatIf = $whatIf
        planFingerprint = $planFingerprint
        configurationFingerprint = $configurationFingerprint
        sourceFingerprint = $sourceFingerprint
        deploymentSourceFingerprint = $sourceFingerprint
        bootstrapClientIpv4 = $bootstrapClientIpv4
    }
}

function Set-BootstrapAzureTenantContext {
    param([Parameter(Mandatory)][string]$TenantId)

    $current = & az account show --query tenantId -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($current)) {
        throw 'Azure CLI has no signed-in account. Run az login against the intended Entra tenant, then retry.'
    }

    if (-not $current.Equals($TenantId, [StringComparison]::OrdinalIgnoreCase)) {
        & az login --tenant $TenantId --allow-no-subscriptions --output none --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to establish Azure CLI context for tenant $TenantId."
        }
    }
}

function Build-GatewayPortableImages {
    param([Parameter(Mandatory)]$Config)

    $root = Get-RepositoryRoot
    $apiTag = "a365-gateway-api:$($Config.environment)"
    $workerTag = "a365-gateway-worker:$($Config.environment)"
    $consoleTag = "a365-gateway-console:$($Config.environment)"

    Push-Location -LiteralPath $root
    try {
        Write-GatewayExperienceEvent -Type Info -Message "Building local API image $apiTag." -OutputFormat Text
        Invoke-BootstrapCommand -FilePath 'docker' -ArgumentList @(
            'build', '-f', 'src/Gateway.Api/Dockerfile', '-t', $apiTag, '.'
        ) | Out-Null

        Write-GatewayExperienceEvent -Type Info -Message "Building local Worker image $workerTag." -OutputFormat Text
        Invoke-BootstrapCommand -FilePath 'docker' -ArgumentList @(
            'build', '-f', 'src/Gateway.Provisioning.Worker/Dockerfile', '-t', $workerTag, '.'
        ) | Out-Null

        Write-GatewayExperienceEvent -Type Info -Message "Building local React Console image $consoleTag." -OutputFormat Text
        Invoke-BootstrapCommand -FilePath 'docker' -ArgumentList @(
            'build', '-f', 'web/console/Dockerfile', '-t', $consoleTag, 'web/console'
        ) | Out-Null
    }
    finally {
        Pop-Location
    }

    return [ordered]@{
        api = $apiTag
        worker = $workerTag
        console = $consoleTag
    }
}

function Deploy-GatewayPortableContentSafety {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    if (-not [bool]$Config.promptShield.enabled) {
        return [ordered]@{
            enabled = $false
            endpoint = ''
            accountId = ''
        }
    }

    $root = Get-RepositoryRoot
    $template = Join-Path $root 'infrastructure/bicep/portable-content-safety.bicep'
    if (-not (Test-Path -LiteralPath $template)) {
        throw "Missing portable Content Safety template at $template."
    }

    $accountName = ("cs$($Config.projectName)$($Config.environment)").ToLowerInvariant()
    if ($accountName.Length -gt 24) {
        $accountName = $accountName.Substring(0, 24)
    }

    $rg = [string]$Config.resourceGroupName
    $exists = [string](Invoke-AzTsv -Arguments @('group', 'exists', '--name', $rg))
    if ($exists -eq 'false') {
        Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @(
            'group', 'create',
            '--name', $rg,
            '--location', [string]$Config.location,
            '--tags', "bootstrapOwnershipId=$DeploymentOwnershipId", "bootstrapSourceFingerprint=$SourceFingerprint", 'workload=prompt-protection'
        ) | Out-Null
    }

    $deploymentName = "portable-cs-$($Config.environment)"
    $outputs = Invoke-AzJson -Arguments @(
        'deployment', 'group', 'create',
        '--resource-group', $rg,
        '--name', $deploymentName,
        '--template-file', $template,
        '--parameters',
        "location=$([string]$Config.location)",
        "accountName=$accountName",
        "skuName=$([string]$Config.promptShield.skuName)",
        "deploymentOwnershipId=$DeploymentOwnershipId",
        "sourceFingerprint=$SourceFingerprint",
        '--query', 'properties.outputs'
    )

    if ($null -eq $outputs -or [string]::IsNullOrWhiteSpace([string]$outputs.endpoint.value)) {
        throw "Content Safety deployment '$deploymentName' did not return an endpoint output."
    }

    $endpoint = [string]$outputs.endpoint.value
    $resolvedAccountName = if ([string]::IsNullOrWhiteSpace([string]$outputs.accountName.value)) {
        $accountName
    }
    else {
        [string]$outputs.accountName.value
    }

    return [ordered]@{
        enabled = $true
        endpoint = $endpoint
        accountId = [string]$outputs.accountId.value
        accountName = $resolvedAccountName
        authMode = 'ClientSecret'
    }
}

function Set-PortableContentSafetyWorkloadRole {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AccountId,
        [Parameter(Mandatory)][string]$WorkloadServicePrincipalId
    )

    if ([string]::IsNullOrWhiteSpace($AccountId)) {
        throw 'Content Safety account resource id is required for portable role assignment.'
    }

    $existing = @(Invoke-AzJson -Arguments @(
        'role', 'assignment', 'list',
        '--assignee-object-id', $WorkloadServicePrincipalId,
        '--scope', $AccountId,
        '--role', 'Cognitive Services User',
        '--query', '[].id'
    ))
    if ($existing.Count -gt 0) {
        return [ordered]@{ assigned = $false; scope = $AccountId }
    }

    Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $WorkloadServicePrincipalId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', 'Cognitive Services User',
        '--scope', $AccountId,
        '--only-show-errors'
    ) | Out-Null

    return [ordered]@{ assigned = $true; scope = $AccountId }
}

function Get-GatewayPortableAdminUiSecretPath {
    param([Parameter(Mandatory)]$Config)
    $root = Get-RepositoryRoot
    return Join-Path $root ".bootstrap/secrets/portable-$($Config.tenantId)-$($Config.projectName)-$($Config.environment)-admin-ui.secret"
}

function Get-GatewayPortableWorkloadSecretPath {
    param([Parameter(Mandatory)]$Config)
    $root = Get-RepositoryRoot
    return Join-Path $root ".bootstrap/secrets/portable-$($Config.tenantId)-$($Config.projectName)-$($Config.environment)-workload.secret"
}

function Get-GatewayPortableApiOboSecretPath {
    param([Parameter(Mandatory)]$Config)
    $root = Get-RepositoryRoot
    return Join-Path $root ".bootstrap/secrets/portable-$($Config.tenantId)-$($Config.projectName)-$($Config.environment)-api-obo.secret"
}

function Get-GatewayPortableBlueprintSecretPath {
    param([Parameter(Mandatory)]$Config)
    $root = Get-RepositoryRoot
    return Join-Path $root ".bootstrap/secrets/portable-$($Config.tenantId)-$($Config.projectName)-$($Config.environment)-blueprint.secret"
}

function Ensure-PortableGatewayApiOboSecret {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Identity
    )

    $applicationObjectId = [string]$Identity.gatewayApiApplicationObjectId
    if ([string]::IsNullOrWhiteSpace($applicationObjectId)) {
        throw 'Gateway API application object ID is required for portable OBO client secret creation.'
    }

    $secretPath = Get-GatewayPortableApiOboSecretPath -Config $Config
    $secretDirectory = Split-Path -Parent $secretPath
    if (-not (Test-Path -LiteralPath $secretDirectory)) {
        New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
    }

    $application = Invoke-AzJson -Arguments @(
        'rest', '--method', 'GET', '--url',
        "https://graph.microsoft.com/v1.0/applications/${applicationObjectId}?`$select=id,appId,passwordCredentials"
    )
    $credentials = @($application.passwordCredentials)
    $bootstrapCreds = @($credentials | Where-Object { [string]$_.displayName -ceq 'a365gw-bootstrap-portable-api-obo' })
    $secretText = ''
    if ($bootstrapCreds.Count -eq 1 -and (Test-Path -LiteralPath $secretPath)) {
        $secretText = [IO.File]::ReadAllText($secretPath).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($secretText)) {
        foreach ($cred in $bootstrapCreds) {
            Invoke-GraphJsonBody `
                -Method 'POST' `
                -Url "https://graph.microsoft.com/v1.0/applications/${applicationObjectId}/removePassword" `
                -Body @{ keyId = [string]$cred.keyId } | Out-Null
        }
        $created = Invoke-GraphJsonBody `
            -Method 'POST' `
            -Url "https://graph.microsoft.com/v1.0/applications/${applicationObjectId}/addPassword" `
            -Body @{
                passwordCredential = @{
                    displayName = 'a365gw-bootstrap-portable-api-obo'
                    endDateTime = [DateTimeOffset]::UtcNow.AddYears(1).ToString('O')
                }
            }
        $secretText = [string]$created.secretText
        if ([string]::IsNullOrWhiteSpace($secretText)) {
            throw 'Microsoft Graph did not return the portable Gateway API OBO client secret.'
        }
        Set-Content -LiteralPath $secretPath -Value $secretText -Encoding utf8 -NoNewline
    }

    return [ordered]@{
        gatewayApiApplicationObjectId = $applicationObjectId
        gatewayApiClientId = [string]$Identity.gatewayApiClientId
        gatewayApiOboClientSecret = $secretText
    }
}

function Ensure-PortableWorkloadApplication {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$AzureIdentity,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId
    )

    $displayName = "A365 Gateway Workload - $($Config.projectName)-$($Config.environment)"
    $expectedTags = @(Get-BootstrapApplicationTags -DeploymentOwnershipId $DeploymentOwnershipId)
    $application = Get-ExactApplicationByDisplayName -DisplayName $displayName
    if (-not $application) {
        $application = Invoke-GraphJsonBody -Method 'POST' -Url 'https://graph.microsoft.com/v1.0/applications' -Body @{
            displayName = $displayName
            signInAudience = 'AzureADMyOrg'
            tags = $expectedTags
            isFallbackPublicClient = $false
            web = @{ implicitGrantSettings = @{ enableAccessTokenIssuance = $false; enableIdTokenIssuance = $false } }
            api = @{ acceptMappedClaims = $false; preAuthorizedApplications = @(); knownClientApplications = @() }
        }
    }

    $application = Invoke-AzJson -Arguments @(
        'rest', '--method', 'GET', '--url',
        "https://graph.microsoft.com/v1.0/applications/$($application.id)?`$select=id,appId,displayName,signInAudience,identifierUris,tags,api,appRoles,requiredResourceAccess,passwordCredentials,keyCredentials,web,spa,publicClient,isFallbackPublicClient"
    )
    Assert-ExactApplicationAuthenticationSurface -Application $application -ApplicationLabel 'Portable workload application' | Out-Null
    if ([string]$application.displayName -cne $displayName -or
        [string]$application.signInAudience -cne 'AzureADMyOrg' -or
        @($application.identifierUris).Count -ne 0 -or
        @($application.spa.redirectUris).Count -ne 0 -or
        @($application.publicClient.redirectUris).Count -ne 0) {
        throw 'Portable workload application does not match the exact confidential-client boundary.'
    }
    Assert-BootstrapApplicationOwnership -Application $application -DeploymentOwnershipId $DeploymentOwnershipId -OwnerObjectId ([string]$AzureIdentity.userObjectId) -AllowAddMissingOwner | Out-Null

    $principal = Ensure-ServicePrincipal `
        -AppId ([string]$application.appId) `
        -ServicePrincipalNames @([string]$application.appId) `
        -Tags $expectedTags

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
    foreach ($role in $workerRoles) {
        Ensure-GraphApplicationRoleAssignment -PrincipalId ([string]$principal.id) -RoleValue $role | Out-Null
    }

    $secretPath = Get-GatewayPortableWorkloadSecretPath -Config $Config
    $secretDirectory = Split-Path -Parent $secretPath
    if (-not (Test-Path -LiteralPath $secretDirectory)) {
        New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
    }

    $credentials = @($application.passwordCredentials)
    $bootstrapCreds = @($credentials | Where-Object { [string]$_.displayName -ceq 'a365gw-bootstrap-portable-workload' })
    $secretText = ''
    if ($bootstrapCreds.Count -eq 1 -and (Test-Path -LiteralPath $secretPath)) {
        $secretText = [IO.File]::ReadAllText($secretPath).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($secretText)) {
        foreach ($cred in $bootstrapCreds) {
            Invoke-GraphJsonBody `
                -Method 'POST' `
                -Url "https://graph.microsoft.com/v1.0/applications/$($application.id)/removePassword" `
                -Body @{ keyId = [string]$cred.keyId } | Out-Null
        }
        $created = Invoke-GraphJsonBody `
            -Method 'POST' `
            -Url "https://graph.microsoft.com/v1.0/applications/$($application.id)/addPassword" `
            -Body @{
                passwordCredential = @{
                    displayName = 'a365gw-bootstrap-portable-workload'
                    endDateTime = [DateTimeOffset]::UtcNow.AddYears(1).ToString('O')
                }
            }
        $secretText = [string]$created.secretText
        if ([string]::IsNullOrWhiteSpace($secretText)) {
            throw 'Microsoft Graph did not return the portable workload client secret.'
        }
        Set-Content -LiteralPath $secretPath -Value $secretText -Encoding utf8 -NoNewline
    }

    return [ordered]@{
        workloadApplicationObjectId = [string]$application.id
        workloadClientId = [string]$application.appId
        workloadServicePrincipalId = [string]$principal.id
        workloadClientSecret = $secretText
        deploymentOwnershipId = ([guid]$DeploymentOwnershipId).ToString('D')
    }
}

function Ensure-PortableAgent365SeedBlueprint {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$SponsorObjectId,
        [Parameter(Mandatory)][string]$WorkloadServicePrincipalId
    )

    $displayName = Get-Agent365SeedBlueprintDisplayName `
        -Config $Config `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $SourceFingerprint
    $existing = Get-Agent365BlueprintByName -DisplayName $displayName
    if ($existing) {
        try {
            return Assert-Agent365SeedBlueprintSurface `
                -Blueprint $existing `
                -Config $Config `
                -ExpectedDisplayName $displayName `
                -DeploymentOwnershipId $DeploymentOwnershipId `
                -SourceFingerprint $SourceFingerprint `
                -SponsorObjectId $SponsorObjectId `
                -RequirePristineAuthoritySurface
        }
        catch {
            return Assert-Agent365SeedBlueprintSurface `
                -Blueprint $existing `
                -Config $Config `
                -ExpectedDisplayName $displayName `
                -DeploymentOwnershipId $DeploymentOwnershipId `
                -SourceFingerprint $SourceFingerprint `
                -SponsorObjectId $SponsorObjectId `
                -GatewayManagedIdentityPrincipalId $WorkloadServicePrincipalId
        }
    }

    return Ensure-Agent365SeedBlueprint `
        -Config $Config `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $SourceFingerprint `
        -SponsorObjectId $SponsorObjectId
}

function Ensure-PortableBlueprintClientSecret {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Blueprint
    )

    $applicationObjectId = [string]$Blueprint.objectId
    if ([string]::IsNullOrWhiteSpace($applicationObjectId)) {
        throw 'Seed blueprint object ID is required for portable FMI client secret creation.'
    }

    $secretPath = Get-GatewayPortableBlueprintSecretPath -Config $Config
    $secretDirectory = Split-Path -Parent $secretPath
    if (-not (Test-Path -LiteralPath $secretDirectory)) {
        New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
    }

    $application = Invoke-AzJson -Arguments @(
        'rest', '--method', 'GET', '--url',
        "https://graph.microsoft.com/v1.0/applications/${applicationObjectId}?`$select=id,appId,passwordCredentials"
    )
    $credentials = @($application.passwordCredentials)
    $bootstrapCreds = @($credentials | Where-Object { [string]$_.displayName -ceq 'a365gw-bootstrap-portable-blueprint' })
    $secretText = ''
    if ($bootstrapCreds.Count -eq 1 -and (Test-Path -LiteralPath $secretPath)) {
        $secretText = [IO.File]::ReadAllText($secretPath).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($secretText)) {
        foreach ($cred in $bootstrapCreds) {
            Invoke-GraphJsonBody `
                -Method 'POST' `
                -Url "https://graph.microsoft.com/v1.0/applications/${applicationObjectId}/removePassword" `
                -Body @{ keyId = [string]$cred.keyId } | Out-Null
        }
        $created = Invoke-GraphJsonBody `
            -Method 'POST' `
            -Url "https://graph.microsoft.com/v1.0/applications/${applicationObjectId}/addPassword" `
            -Body @{
                passwordCredential = @{
                    displayName = 'a365gw-bootstrap-portable-blueprint'
                    endDateTime = [DateTimeOffset]::UtcNow.AddYears(1).ToString('O')
                }
            }
        $secretText = [string]$created.secretText
        if ([string]::IsNullOrWhiteSpace($secretText)) {
            throw 'Microsoft Graph did not return the portable blueprint FMI client secret.'
        }
        Set-Content -LiteralPath $secretPath -Value $secretText -Encoding utf8 -NoNewline
    }

    return [ordered]@{
        blueprintObjectId = $applicationObjectId
        blueprintApplicationId = [string]$Blueprint.applicationId
        blueprintClientSecret = $secretText
    }
}

function Write-GatewayPortableRuntimeEnv {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$ConsoleIdentity,
        [Parameter(Mandatory)]$WorkloadIdentity,
        [Parameter(Mandatory)]$Images,
        [Parameter(Mandatory)]$PromptShield,
        [Parameter(Mandatory)][string]$GatewayApiOboClientSecret,
        [Parameter(Mandatory)][string]$BlueprintClientSecret
    )

    $composeDir = Get-GatewayPortableComposeDirectory
    $envPath = Join-Path $composeDir '.env.runtime'
    $apiPort = [int]$Config.portable.apiHostPort
    $consolePort = [int]$Config.portable.consoleHostPort
    $apiScope = [string]$ConsoleIdentity.apiScope
    $managerIds = @($Config.agent365.reviewedManagerApplicationIds | ForEach-Object { [string]$_ })
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]@(
        "GATEWAY_API_IMAGE=$($Images.api)"
        "GATEWAY_WORKER_IMAGE=$($Images.worker)"
        "GATEWAY_CONSOLE_IMAGE=$($Images.console)"
        "GATEWAY_API_HOST_PORT=$apiPort"
        "GATEWAY_CONSOLE_HOST_PORT=$consolePort"
        "CONSOLE_CLIENT_ID=$([string]$ConsoleIdentity.consoleClientId)"
        "CONSOLE_TENANT_ID=$([string]$Config.tenantId)"
        "CONSOLE_API_SCOPE=$apiScope"
        'ASPNETCORE_ENVIRONMENT=Portable'
        'DOTNET_ENVIRONMENT=Portable'
        "EntraId__TenantId=$([string]$Config.tenantId)"
        "EntraId__ClientId=$([string]$Identity.gatewayApiClientId)"
        "EntraId__Audience=$([string]$Identity.gatewayApiTokenAudience)"
        'EntraId__ClientCredentials__0__SourceType=ClientSecret'
        "EntraId__ClientCredentials__0__ClientSecret=$GatewayApiOboClientSecret"
        "Agent365__TenantId=$([string]$Config.tenantId)"
        "Agent365__ProvisioningManagedIdentityClientId=$([string]$WorkloadIdentity.workloadClientId)"
        "Agent365__ProvisioningManagedIdentityPrincipalId=$([string]$WorkloadIdentity.workloadServicePrincipalId)"
        "Agent365__ProvisioningClientSecret=$([string]$WorkloadIdentity.workloadClientSecret)"
        "Agent365__BlueprintClientSecret=$BlueprintClientSecret"
        'Provisioning__ExecutionEnabled=true'
        'Provisioning__AllowContinuousDevelopmentAccess=true'
        'Agent365__DelegatedRegistry__Enabled=true'
        'Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess=true'
        'Agent365__DelegatedRegistry__Scopes__0=https://graph.microsoft.com/AgentRegistration.ReadWrite.All'
        'Agent365__DelegatedRegistry__Scopes__1=https://graph.microsoft.com/AgentRegistration.Read.All'
        'ProvisioningWorker__ProvisioningExecutionEnabled=true'
        'ConnectionStrings__GatewayDb=Host=postgres;Port=5432;Database=gateway;Username=gateway;Password=gateway'
        'RabbitMq__ConnectionUri=amqp://gateway:gateway@rabbitmq:5672/'
        'ObjectStorage__ServiceUrl=http://s3:8000'
        'ObjectStorage__AccessKey=gateway'
        'ObjectStorage__SecretKey=gatewaysecret'
        'ObjectStorage__BucketName=a365-gateway-interactions'
        'ObjectStorage__ForcePathStyle=true'
        'ObjectStorage__CreateBucketIfMissing=true'
        'Infrastructure__Provider=Portable'
        'DatabaseAttestation__Enabled=false'
        'BootstrapCapabilities__Enabled=false'
        'OutboxRelay__Enabled=true'
        'ProvisioningWorker__ProcessingEnabled=true'
        'ProtectionAdminWorker__ProcessingEnabled=false'
    ))

    for ($i = 0; $i -lt $managerIds.Count; $i++) {
        $lines.Add("Agent365__ManagerApplicationIds__$i=$($managerIds[$i])")
    }

    if ([bool]$PromptShield.enabled -and -not [string]::IsNullOrWhiteSpace([string]$PromptShield.endpoint)) {
        $lines.Add('PromptShield__Enabled=true')
        $lines.Add('PromptShield__AuthMode=ClientSecret')
        $lines.Add("PromptShield__Endpoint=$([string]$PromptShield.endpoint)")
        $lines.Add("PromptShield__TenantId=$([string]$Config.tenantId)")
        $lines.Add("PromptShield__ClientId=$([string]$WorkloadIdentity.workloadClientId)")
        $lines.Add("PromptShield__ClientSecret=$([string]$WorkloadIdentity.workloadClientSecret)")
        $lines.Add("PromptShield__ClientPrincipalId=$([string]$WorkloadIdentity.workloadServicePrincipalId)")
    }
    else {
        $lines.Add('PromptShield__Enabled=false')
        $lines.Add('PromptShield__AuthMode=ManagedIdentity')
        $lines.Add('PromptShield__Endpoint=')
    }

    Set-Content -LiteralPath $envPath -Value ($lines -join [Environment]::NewLine) -Encoding utf8
    return $envPath
}

function Deploy-GatewayPortableRuntime {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$EnvFile
    )

    $composeDir = Get-GatewayPortableComposeDirectory
    Push-Location -LiteralPath $composeDir
    try {
        Invoke-BootstrapCommand -FilePath 'docker' -ArgumentList @(
            'compose',
            '--env-file', $EnvFile,
            '-f', 'docker-compose.yml',
            '-f', 'docker-compose.apps.yml',
            'up', '-d', '--remove-orphans'
        ) | Out-Null
    }
    finally {
        Pop-Location
    }

    return [ordered]@{
        composeDirectory = $composeDir
        envFile = $EnvFile
        apiHealthUrl = "http://127.0.0.1:$([int]$Config.portable.apiHostPort)/health"
        apiReadyUrl = "http://127.0.0.1:$([int]$Config.portable.apiHostPort)/health/ready"
        consoleUrl = "http://127.0.0.1:$([int]$Config.portable.consoleHostPort)/"
        consoleConfigUrl = "http://127.0.0.1:$([int]$Config.portable.consoleHostPort)/config.js"
        consoleProxyHealthUrl = "http://127.0.0.1:$([int]$Config.portable.consoleHostPort)/health"
    }
}

function Test-GatewayPortableRuntimeHealth {
    param(
        [Parameter(Mandatory)][string]$HealthUrl,
        [Parameter(Mandatory)][string]$ReadyUrl,
        [Parameter(Mandatory)][string]$ConsoleConfigUrl,
        [Parameter(Mandatory)][string]$ConsoleProxyHealthUrl,
        [int]$TimeoutSeconds = 180
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = ''
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $health = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 5
            $ready = Invoke-WebRequest -Uri $ReadyUrl -UseBasicParsing -TimeoutSec 5
            $consoleConfig = Invoke-WebRequest -Uri $ConsoleConfigUrl -UseBasicParsing -TimeoutSec 5
            $consoleProxy = Invoke-WebRequest -Uri $ConsoleProxyHealthUrl -UseBasicParsing -TimeoutSec 5
            if ($health.StatusCode -eq 200 -and $ready.StatusCode -eq 200 -and
                $consoleConfig.StatusCode -eq 200 -and $consoleProxy.StatusCode -eq 200 -and
                [string]$consoleConfig.Content -match '__A365_CONFIG__') {
                return [ordered]@{
                    healthy = $true
                    healthStatusCode = [int]$health.StatusCode
                    readyStatusCode = [int]$ready.StatusCode
                    consoleConfigStatusCode = [int]$consoleConfig.StatusCode
                    consoleProxyHealthStatusCode = [int]$consoleProxy.StatusCode
                }
            }
            $lastError = "health=$($health.StatusCode) ready=$($ready.StatusCode) consoleConfig=$($consoleConfig.StatusCode) consoleProxy=$($consoleProxy.StatusCode)"
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Seconds 3
    }

    throw "Portable runtime did not become healthy within ${TimeoutSeconds}s. Last error: $lastError"
}

function Invoke-GatewayPortableApplyWorkflow {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][ValidateSet('Text', 'Json')][string]$Format,
        [Parameter(Mandatory)][bool]$InstallLocalPrerequisites,
        [Parameter(Mandatory)][bool]$NonInteractive,
        [Parameter(Mandatory)][string]$AcceptedPlanFingerprint
    )

    $stepNames = @(Get-GatewayPortableBootstrapStepNames)
    $total = $stepNames.Count

    Write-GatewayExperienceEvent -Type PhaseStarted -Message 'Applying portable bootstrap profile (Compose host + Entra product identity).' -Data ([ordered]@{
        step = 'Portable apply'; total = $total; planFingerprint = $AcceptedPlanFingerprint
    }) -OutputFormat $Format

    Assert-GatewayPortablePrerequisites -Install:$InstallLocalPrerequisites | Out-Null

    if ([string]::IsNullOrWhiteSpace([string]$Configuration.subscriptionId)) {
        Set-BootstrapAzureTenantContext -TenantId ([string]$Configuration.tenantId)
        $azureIdentity = [ordered]@{
            userObjectId = [string](Invoke-AzTsv -Arguments @('ad', 'signed-in-user', 'show', '--query', 'id'))
            userPrincipalName = [string](Invoke-AzTsv -Arguments @('ad', 'signed-in-user', 'show', '--query', 'userPrincipalName'))
            tenantId = [string]$Configuration.tenantId
            subscriptionId = ''
        }
    }
    else {
        $azureIdentity = Connect-BootstrapAzure -Config $Configuration -NonInteractive:$NonInteractive
    }

    $identity = Ensure-GatewayApiApplication `
        -Config $Configuration `
        -AzureIdentity $azureIdentity `
        -DeploymentOwnershipId ([string]$State.deploymentOwnershipId)
    $State.steps['Gateway API identity'] = [ordered]@{
        status = 'Completed'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        evidence = $identity
    }
    Save-BootstrapState -State $State -Path $StatePath

    $consoleIdentity = Ensure-PortableConsoleApplication `
        -Config $Configuration `
        -Identity $identity `
        -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) `
        -ConsoleHostPort ([int]$Configuration.portable.consoleHostPort)
    $State.steps['Console identity'] = [ordered]@{
        status = 'Completed'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        evidence = [ordered]@{
            consoleClientId = [string]$consoleIdentity.consoleClientId
            consoleUrl = [string]$consoleIdentity.consoleUrl
            apiScope = [string]$consoleIdentity.apiScope
        }
    }
    Save-BootstrapState -State $State -Path $StatePath

    $apiObo = Ensure-PortableGatewayApiOboSecret -Config $Configuration -Identity $identity
    $State.steps['Portable API OBO credential'] = [ordered]@{
        status = 'Completed'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        evidence = [ordered]@{
            gatewayApiApplicationObjectId = [string]$apiObo.gatewayApiApplicationObjectId
            gatewayApiClientId = [string]$apiObo.gatewayApiClientId
        }
    }
    Save-BootstrapState -State $State -Path $StatePath

    $workloadIdentity = Ensure-PortableWorkloadApplication `
        -Config $Configuration `
        -AzureIdentity $azureIdentity `
        -DeploymentOwnershipId ([string]$State.deploymentOwnershipId)
    $State.steps['Portable workload identity'] = [ordered]@{
        status = 'Completed'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        evidence = [ordered]@{
            workloadClientId = [string]$workloadIdentity.workloadClientId
            workloadServicePrincipalId = [string]$workloadIdentity.workloadServicePrincipalId
        }
    }
    Save-BootstrapState -State $State -Path $StatePath

    $sourceFingerprint = Get-BootstrapSourceFingerprint
    $blueprint = Ensure-PortableAgent365SeedBlueprint `
        -Config $Configuration `
        -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) `
        -SourceFingerprint $sourceFingerprint `
        -SponsorObjectId ([string]$azureIdentity.userObjectId) `
        -WorkloadServicePrincipalId ([string]$workloadIdentity.workloadServicePrincipalId)
    $State.steps['Agent 365 seed blueprint'] = [ordered]@{
        status = 'Completed'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        evidence = $blueprint
    }
    Save-BootstrapState -State $State -Path $StatePath

    $blueprintSecret = Ensure-PortableBlueprintClientSecret -Config $Configuration -Blueprint $blueprint
    $State.steps['Portable blueprint FMI credential'] = [ordered]@{
        status = 'Completed'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        evidence = [ordered]@{
            blueprintObjectId = [string]$blueprintSecret.blueprintObjectId
            blueprintApplicationId = [string]$blueprintSecret.blueprintApplicationId
        }
    }
    Save-BootstrapState -State $State -Path $StatePath

    $promptShield = Deploy-GatewayPortableContentSafety `
        -Config $Configuration `
        -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) `
        -SourceFingerprint $sourceFingerprint
    if ([bool]$promptShield.enabled) {
        Set-PortableContentSafetyWorkloadRole `
            -Config $Configuration `
            -AccountId ([string]$promptShield.accountId) `
            -WorkloadServicePrincipalId ([string]$workloadIdentity.workloadServicePrincipalId) | Out-Null
    }
    $State.steps['Prompt Shields account'] = [ordered]@{
        status = 'Completed'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        evidence = [ordered]@{
            enabled = [bool]$promptShield.enabled
            endpoint = [string]$promptShield.endpoint
            accountId = [string]$promptShield.accountId
            accountName = [string]$promptShield.accountName
            authMode = [string]$promptShield.authMode
            workloadServicePrincipalId = [string]$workloadIdentity.workloadServicePrincipalId
        }
    }
    Save-BootstrapState -State $State -Path $StatePath

    $images = Build-GatewayPortableImages -Config $Configuration
    $State.steps['Local workload images'] = [ordered]@{
        status = 'Completed'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        evidence = $images
    }
    Save-BootstrapState -State $State -Path $StatePath

    $envFile = Write-GatewayPortableRuntimeEnv `
        -Config $Configuration `
        -Identity $identity `
        -ConsoleIdentity $consoleIdentity `
        -WorkloadIdentity $workloadIdentity `
        -Images $images `
        -PromptShield $promptShield `
        -GatewayApiOboClientSecret ([string]$apiObo.gatewayApiOboClientSecret) `
        -BlueprintClientSecret ([string]$blueprintSecret.blueprintClientSecret)
    $runtime = Deploy-GatewayPortableRuntime -Config $Configuration -EnvFile $envFile
    $health = Test-GatewayPortableRuntimeHealth `
        -HealthUrl ([string]$runtime.apiHealthUrl) `
        -ReadyUrl ([string]$runtime.apiReadyUrl) `
        -ConsoleConfigUrl ([string]$runtime.consoleConfigUrl) `
        -ConsoleProxyHealthUrl ([string]$runtime.consoleProxyHealthUrl)

    $State.steps['Portable runtime'] = [ordered]@{
        status = 'Completed'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        evidence = $runtime
    }
    $State.steps['End-to-end deployment verification'] = [ordered]@{
        status = 'Completed'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        evidence = $health
    }
    Save-BootstrapState -State $State -Path $StatePath

    Write-GatewayExperienceEvent -Type Result -Message "Portable gateway is up. Open React Console: $($runtime.consoleUrl) (API health: $($runtime.apiHealthUrl))" -Data ([ordered]@{
        step = 'End-to-end deployment verification'
        index = $total
        total = $total
        apiHealthUrl = [string]$runtime.apiHealthUrl
        apiReadyUrl = [string]$runtime.apiReadyUrl
        consoleUrl = [string]$runtime.consoleUrl
        gatewayApiClientId = [string]$identity.gatewayApiClientId
        consoleClientId = [string]$consoleIdentity.consoleClientId
        workloadClientId = [string]$workloadIdentity.workloadClientId
        promptShieldEnabled = [bool]$promptShield.enabled
        promptShieldAuthMode = [string]$promptShield.authMode
        seedBlueprintApplicationId = [string]$blueprint.applicationId
    }) -OutputFormat $Format

    return [ordered]@{
        identity = $identity
        consoleIdentity = $consoleIdentity
        workloadIdentity = $workloadIdentity
        blueprint = $blueprint
        promptShield = $promptShield
        images = $images
        runtime = $runtime
        health = $health
    }
}

Export-ModuleMember -Function *
