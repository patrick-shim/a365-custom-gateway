#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-RuntimeComposeProjectName {
    param([Parameter(Mandatory)]$Config)
    $name = [string](Get-OptionalObjectPropertyValue $Config.runtime 'composeProjectName')
    if ([string]::IsNullOrWhiteSpace($name)) { return 'a365-gateway' }
    return $name
}
function Get-RuntimeCredentialName {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Purpose)
    $prefix = [string](Get-OptionalObjectPropertyValue $Config.runtime 'credentialLabelPrefix')
    if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = 'a365gw-bootstrap-runtime' }
    return "$prefix-$Purpose"
}

function Get-GatewayDeployProfile {
    param([Parameter(Mandatory)]$Config)
    $hasProfile = if ($Config -is [Collections.IDictionary]) { $Config.Contains('deployProfile') } else { $Config.PSObject.Properties.Name -contains 'deployProfile' }
    if (-not $hasProfile -or [string]$Config.deployProfile -cne 'runtime') {
        throw 'This installer supports only the runtime deployment profile.'
    }
    return 'runtime'
}

function Test-GatewayRuntimeDeployProfile {
    param([Parameter(Mandatory)]$Config)
    return (Get-GatewayDeployProfile -Config $Config) -ceq 'runtime'
}

function Get-GatewayRuntimeBootstrapStepNames {
    return @(
        'Prerequisites'
        'Microsoft authentication'
        'Gateway API identity'
        'Console identity'
        'Runtime API OBO credential'
        'Runtime workload identity'
        'Agent 365 seed blueprint'
        'Runtime blueprint FMI credential'
        'Prompt Shields account'
        'Purview management access'
        'Local workload images'
        'Gateway runtime'
        'End-to-end deployment verification'
    )
}

function Get-GatewayRuntimeComposeDirectory {
    return [IO.Path]::GetFullPath((Join-Path (Get-RepositoryRoot) 'deploy/runtime'))
}

function Get-GatewayRuntimeDoctorReport {
    param([Parameter(Mandatory)]$Config)

    $checks = [Collections.Generic.List[object]]::new()
    $checks.Add((New-GatewayDoctorCheck -Name 'Configuration' -Status Pass -Value 'Validated runtime configuration'))
    $checks.Add((New-GatewayDoctorCheck -Name 'PowerShell' -Status $(if ($PSVersionTable.PSVersion.Major -ge 7) { 'Pass' } else { 'Fail' }) -Value $PSVersionTable.PSVersion.ToString()))
    foreach ($tool in @(
        @{ name = 'Git'; command = 'git'; arguments = @('--version') },
        @{ name = '.NET SDK'; command = 'dotnet'; arguments = @('--version') },
        @{ name = 'Docker Engine'; command = 'docker'; arguments = @('version', '--format', '{{.Server.Version}}') },
        @{ name = 'Docker Compose'; command = 'docker'; arguments = @('compose', 'version', '--short') }
    )) {
        $version = Get-GatewayCommandVersion -Name $tool.command -Arguments $tool.arguments
        $valid = -not [string]::IsNullOrWhiteSpace($version)
        if ($tool.name -eq '.NET SDK') { $valid = $version -match '^10\.' }
        $checks.Add((New-GatewayDoctorCheck -Name $tool.name -Status $(if ($valid) { 'Pass' } else { 'Fail' }) -Value $version -Remediation "Install or start $($tool.name) for the runtime deployment."))
    }
    $azVersion = Get-GatewayAzureCliVersion
    $checks.Add((New-GatewayDoctorCheck -Name 'Azure CLI' -Status $(if ($azVersion) { 'Pass' } else { 'Fail' }) -Value $azVersion -Remediation 'Install Azure CLI for Microsoft Entra product identity setup.'))
    if ($Config.purview.enabled) {
        $purviewModuleAvailable = $IsWindows -and [bool](Get-Module -ListAvailable ExchangeOnlineManagement | Where-Object Version -EQ ([version]'3.10.1'))
        $checks.Add((New-GatewayDoctorCheck -Name 'Purview PowerShell' -Status $(if ($purviewModuleAvailable) { 'Pass' } else { 'Fail' }) -Value $(if ($purviewModuleAvailable) { 'Windows / ExchangeOnlineManagement 3.10.1' } else { 'Required Windows module unavailable' }) -Remediation 'On Windows, run Install-Module ExchangeOnlineManagement -RequiredVersion 3.10.1 -Scope CurrentUser.'))
    }
    if ($Config.promptShield.enabled) {
        $bicepVersion = if ($azVersion) { Get-GatewayCommandVersion -Name az -Arguments @('bicep', 'version') } else { $null }
        $checks.Add((New-GatewayDoctorCheck -Name 'Content Safety Bicep' -Status $(if ($bicepVersion) { 'Pass' } else { 'Fail' }) -Value $bicepVersion -Remediation 'Run az bicep install to deploy the selected Content Safety product resource.'))
    }
    $sessionStatus = 'Fail'
    if ($azVersion) {
        try {
            $account = Invoke-GatewayAzJson -Arguments @('account', 'show', '--query', '{id:id,tenantId:tenantId}')
            $matches = $account -and [string]$account.tenantId -eq [string]$Config.tenantId -and
                ([string]::IsNullOrWhiteSpace([string]$Config.subscriptionId) -or [string]$account.id -eq [string]$Config.subscriptionId)
            if ($matches) { $sessionStatus = 'Pass' }
        } catch { }
    }
    $checks.Add((New-GatewayDoctorCheck -Name 'Microsoft session' -Status $sessionStatus -Value $(if ($sessionStatus -eq 'Pass') { 'Configured tenant and optional subscription match' } else { 'Missing or mismatched session' }) -Remediation 'Sign in to the configured Entra tenant and select the subscription when Content Safety deployment requires it.'))
    $failures = @($checks | Where-Object status -eq 'Fail').Count
    $checks.Add((New-GatewayDoctorCheck -Name 'Microsoft product authority and eligibility' -Status NotChecked -Value 'Verified during plan/apply and agent runtime tests' -Remediation 'Run the runtime plan and apply, then verify registration and each Microsoft destination.'))
    return [ordered]@{
        schemaVersion = 1
        checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        deployProfile = 'runtime'
        ready = $false
        readyForPlan = $failures -eq 0
        readyForApply = $false
        failures = $failures
        warnings = 0
        notChecked = 1
        checks = @($checks)
    }
}

function Assert-GatewayRuntimePrerequisites {
    param([switch]$Install, [bool]$RequireBicep = $false)

    Assert-GatewayPlanPrerequisites -Install:$Install -RequireBicep:$RequireBicep | Out-Null

    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($null -eq $docker) {
        throw 'Runtime bootstrap requires Docker Engine with the compose plugin.'
    }

    & docker version --format '{{.Server.Version}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker is installed but the daemon is not reachable. Start Docker Desktop or the engine, then retry.'
    }

    & docker compose version 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Compose plugin is required for the runtime deploy profile.'
    }

    $composeDir = Get-GatewayRuntimeComposeDirectory
    if (-not (Test-Path -LiteralPath (Join-Path $composeDir 'docker-compose.yml'))) {
        throw "Runtime compose file missing at $composeDir/docker-compose.yml."
    }

    return [ordered]@{
        docker = $true
        composeDirectory = $composeDir
    }
}

function Get-GatewayRuntimePlanDescriptor {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint
    )

    $apiPort = [int]$Config.runtime.apiHostPort
    $consolePort = [int]$Config.runtime.consoleHostPort
    $promptShields = [bool]$Config.promptShield.enabled
    $purview = [bool]$Config.purview.enabled

    return [ordered]@{
        deploymentId = "runtime-$($Config.projectName)-$($Config.environment)"
        deployProfile = 'runtime'
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
                [ordered]@{ system = 'Microsoft 365'; operation = 'Provision dedicated certificate identity, Exchange.ManageAsApp consent and a dedicated DLP Compliance Management role group; verify existing policy catalog from Windows catalog-host account'; mutation = $true }
            }
        )
        costClasses = @(
            'Local Docker compute/storage on the bootstrap host'
            if ($promptShields) { 'Azure AI Content Safety SKU charges in the selected subscription' }
            'Entra ID directory objects (no Azure compute required for the gateway host)'
        )
        previewWarning = 'Runtime profile deploys the gateway host on Docker Compose. Content Safety is an optional Azure product resource. Purview management requires a Windows catalog-host account and Microsoft 365 permissions, not Azure hosting.'
        administratorBoundaries = @(
            'Entra Global Administrator or Application Administrator is required for app registration'
            if ($Config.environment -eq 'dev' -and $Config.agent365.allowDevelopmentRegistryPreview -and $Config.agent365.registryBetaAcknowledged) {
                'Registry preview grants the Gateway API exactly AgentRegistration.Read.All and AgentRegistration.ReadWrite.All delegated Graph consent for this tenant; an administrator authorized to grant that consent must run setup'
            }
            if ($promptShields) { 'Azure subscription Contributor (or equivalent) is required for Content Safety in the selected resource group' }
            if ($purview) { 'Purview setup requires Windows, Entra application consent authority and Purview role-group management authority; private certificate stays in this Windows account' }
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

function Invoke-GatewayRuntimePlanWorkflow {
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
    try {
    $existingDeployment = $State.Contains('steps') -and
        $State.steps -is [System.Collections.IDictionary] -and
        $State.steps.Count -gt 0
    if ($existingDeployment) {
        foreach ($name in $State.steps.Keys) {
            if ($name -notin @(Get-GatewayRuntimeBootstrapStepNames) -or
                $State.steps[$name].status -notin @('Completed','Running','Failed')) {
                throw 'Unrecognized checkpoint; current bootstrap cannot reinterpret that state.'
            }
        }
        Write-GatewayExperienceEvent -Type Info -Message 'Existing resources will be read back and reconciled against their recorded ownership. Missing credentials require explicit repair; no implicit rotation.' -OutputFormat $Format
    }

    Clear-BootstrapAcceptedPlan -State $State -StatePath $StatePath | Out-Null
    $planEventBase = [ordered]@{
        step = 'Plan review'
        index = 1
        total = (Get-GatewayRuntimeBootstrapStepNames).Count
    }

    Write-GatewayExperienceEvent -Type Info -Message 'Checking Docker, .NET, Git, and Azure CLI prerequisites for the runtime profile.' -Data ([ordered]@{
        step = $planEventBase.step; category = 'localPrerequisites'
    }) -OutputFormat $Format

    $script:GatewayFailureCode = 'plan_prerequisites'
    Assert-GatewayRuntimePrerequisites -Install:$InstallLocalPrerequisites -RequireBicep:([bool]$Configuration.promptShield.enabled) | Out-Null
    Assert-RuntimePurviewPrerequisites -Enabled:([bool]$Configuration.purview.enabled)

    $sourceFingerprint = Get-BootstrapSourceFingerprint
    $configurationFingerprint = Get-BootstrapConfigurationFingerprint -Config $Configuration
    $descriptor = Get-GatewayRuntimePlanDescriptor `
        -Config $Configuration `
        -DeploymentOwnershipId ([string]$State.deploymentOwnershipId) `
        -SourceFingerprint $sourceFingerprint

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

    if ([bool]$Configuration.promptShield.enabled) {
        $script:GatewayFailureCode = 'plan_content_safety_ownership'
        Assert-RuntimeContentSafetyOwnership -Config $Configuration -DeploymentOwnershipId $State.deploymentOwnershipId
        $script:GatewayFailureCode = 'plan_prompt_shield_capacity'
        Assert-GatewayPromptShieldFreeTierCapacity `
            -Config $Configuration `
            -ResourceGroupName ([string]$Configuration.resourceGroupName) | Out-Null
    }

    $whatIf = [ordered]@{
        executed = $true
        applyReady = $true
        changeCounts = [ordered]@{ Create = $(if ($existingDeployment) { 0 } else { 1 }); Modify = $(if ($existingDeployment) { 1 } else { 0 }); Delete = 0; NoChange = 0; Ignore = 0; Deploy = 0 }
        changes = @(
            [ordered]@{
                resourceId = "compose://$(Get-GatewayRuntimeComposeDirectory)"
                changeType = if ($existingDeployment) { 'Modify' } else { 'Create' }
            }
        )
    }

    $planFingerprint = Get-BootstrapObjectFingerprint -InputObject ([ordered]@{
        contractVersion = 1
        profile = 'runtime'
        configurationFingerprint = $configurationFingerprint
        sourceFingerprint = $sourceFingerprint
        descriptor = $descriptor
        composeWhatIf = $whatIf
    })

    Write-GatewayExperienceEvent -Type Info -Message "Runtime plan $($descriptor.deploymentId); fingerprint $planFingerprint." -Data ([ordered]@{
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
        Write-Host 'Runtime deploy plan' -ForegroundColor Cyan
        Write-Host "  Deployment : $($descriptor.deploymentId)"
        Write-Host "  Console    : $($descriptor.endpoints.console)"
        Write-Host "  API health : $($descriptor.endpoints.apiHealth)"
        Write-Host "  Prompt Shields : $(if ($descriptor.features.promptShields) { 'enabled' } else { 'disabled' })"
        Write-Host "  Purview access : $(if ($descriptor.features.purviewPrerequisites) { 'dedicated certificate identity and DLP role group' } else { 'not requested' })"
        Write-Host "  Fingerprint    : $planFingerprint"
        Write-Host ''
    }


    return [ordered]@{
        descriptor = $descriptor
        whatIf = $whatIf
        planFingerprint = $planFingerprint
        configurationFingerprint = $configurationFingerprint
        sourceFingerprint = $sourceFingerprint
        deploymentSourceFingerprint = $sourceFingerprint
    }
    } catch {
        $_.Exception.Data['BootstrapStep'] = 'Plan review'
        $_.Exception.Data['BootstrapFailureCode'] = $script:GatewayFailureCode
        throw
    }
}

function Set-BootstrapAzureTenantContext {
    param([Parameter(Mandatory)][string]$TenantId,[bool]$NonInteractive=$true)

    $current = & az account show --query tenantId -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($current)) {
        throw 'Azure CLI has no signed-in account. Run az login against the intended Entra tenant, then retry.'
    }

    if (-not $current.Equals($TenantId, [StringComparison]::OrdinalIgnoreCase)) {
        if ($NonInteractive) { throw 'Sign in to the configured Microsoft tenant before running setup.' }
        & az login --tenant $TenantId --allow-no-subscriptions --output none --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to establish Azure CLI context for tenant $TenantId."
        }
    }
    $confirmed = & az account show --query tenantId -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or $confirmed -ine $TenantId) { throw 'The signed-in tenant could not be confirmed.' }
    Set-BootstrapTenantOnlyContext -TenantId $TenantId
}

function Build-GatewayRuntimeImages {
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

function Assert-RuntimeContentSafetyOwnership {
    param([Parameter(Mandatory)]$Config,[Parameter(Mandatory)][string]$DeploymentOwnershipId)
    $exists = Invoke-AzTsv -Arguments @('group','exists','--name',$Config.resourceGroupName)
    if ($exists -eq 'false') { return }
    if ($exists -ne 'true') { throw 'Content Safety resource group existence could not be confirmed.' }
    $group = Invoke-AzJson -Arguments @('group','show','--name',$Config.resourceGroupName)
    if ((Get-OptionalObjectPropertyValue (Get-OptionalObjectPropertyValue $group 'tags') 'bootstrapOwnershipId') -cne $DeploymentOwnershipId) {
        throw 'The Content Safety resource group is not owned by this installation. Choose a new resource group; setup will not adopt it.'
    }
    $accounts = @(Invoke-AzJson -Arguments @('resource','list','--resource-group',$Config.resourceGroupName,'--resource-type','Microsoft.CognitiveServices/accounts'))
    $expected = "cs$($Config.projectName)$($Config.environment)"
    foreach ($account in $accounts) {
        if ($account.name -eq $expected -and
            (Get-OptionalObjectPropertyValue (Get-OptionalObjectPropertyValue $account 'tags') 'bootstrapOwnershipId') -cne $DeploymentOwnershipId) {
            throw 'The Content Safety account is not owned by this installation; refusing replacement.'
        }
    }
}

function Deploy-GatewayRuntimeContentSafety {
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
            accountName = ''
            authMode = ''
        }
    }

    $root = Get-RepositoryRoot
    $template = Join-Path $root 'infrastructure/bicep/runtime-content-safety.bicep'
    if (-not (Test-Path -LiteralPath $template)) {
        throw "Missing runtime Content Safety template at $template."
    }

    $accountName = ("cs$($Config.projectName)$($Config.environment)").ToLowerInvariant()
    if ($accountName.Length -gt 24) {
        $accountName = $accountName.Substring(0, 24)
    }

    $rg = [string]$Config.resourceGroupName
    Assert-RuntimeContentSafetyOwnership -Config $Config -DeploymentOwnershipId $DeploymentOwnershipId
    $exists = [string](Invoke-AzTsv -Arguments @('group', 'exists', '--name', $rg))
    if ($exists -eq 'false') {
        Invoke-BootstrapCommand -FilePath 'az' -ArgumentList @(
            'group', 'create',
            '--name', $rg,
            '--location', [string]$Config.location,
            '--tags', "bootstrapOwnershipId=$DeploymentOwnershipId", "bootstrapSourceFingerprint=$SourceFingerprint", 'workload=prompt-protection'
        ) | Out-Null
    }
    elseif ($exists -ne 'true') { throw 'Content Safety resource group existence could not be confirmed.' }

    $deploymentName = "runtime-cs-$($Config.environment)"
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

function Set-RuntimeContentSafetyWorkloadRole {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AccountId,
        [Parameter(Mandatory)][string]$WorkloadServicePrincipalId
    )

    if ([string]::IsNullOrWhiteSpace($AccountId)) {
        throw 'Content Safety account resource id is required for runtime role assignment.'
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

function Get-GatewayRuntimeWorkloadSecretPath {
    param([Parameter(Mandatory)]$Config)
    $root = Get-RepositoryRoot
    return Join-Path $root ".bootstrap/secrets/runtime-$($Config.tenantId)-$($Config.projectName)-$($Config.environment)-workload.secret"
}

function Get-GatewayRuntimeApiOboSecretPath {
    param([Parameter(Mandatory)]$Config)
    $root = Get-RepositoryRoot
    return Join-Path $root ".bootstrap/secrets/runtime-$($Config.tenantId)-$($Config.projectName)-$($Config.environment)-api-obo.secret"
}

function Get-GatewayRuntimeBlueprintSecretPath {
    param([Parameter(Mandatory)]$Config)
    $root = Get-RepositoryRoot
    return Join-Path $root ".bootstrap/secrets/runtime-$($Config.tenantId)-$($Config.projectName)-$($Config.environment)-blueprint.secret"
}

function Ensure-RuntimeGatewayApiOboSecret {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Identity
    )

    $applicationObjectId = [string]$Identity.gatewayApiApplicationObjectId
    if ([string]::IsNullOrWhiteSpace($applicationObjectId)) {
        throw 'Gateway API application object ID is required for runtime OBO client secret creation.'
    }

    $secretPath = Get-GatewayRuntimeApiOboSecretPath -Config $Config
    $secretDirectory = Split-Path -Parent $secretPath
    if (-not (Test-Path -LiteralPath $secretDirectory)) {
        New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
    }

    $application = Invoke-AzJson -Arguments @(
        'rest', '--method', 'GET', '--url',
        "https://graph.microsoft.com/v1.0/applications/${applicationObjectId}?`$select=id,appId,passwordCredentials"
    )
    $credentials = @($application.passwordCredentials)
    Assert-RuntimePasswordCredentials -Credentials $credentials -ExpectedName (Get-RuntimeCredentialName -Config $Config -Purpose 'api-obo')
    $bootstrapCreds = @($credentials | Where-Object { [string]$_.displayName -ceq (Get-RuntimeCredentialName -Config $Config -Purpose 'api-obo') })
    $secretText = ''
    if ($bootstrapCreds.Count -eq 1 -and (Test-Path -LiteralPath $secretPath)) {
        $secretText = [IO.File]::ReadAllText($secretPath).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($secretText)) {
        if ($bootstrapCreds.Count -gt 0) {
            throw 'The tenant credential exists but its local secret is missing. Restore the matching secret or perform an explicitly reviewed rotation; setup will not replace it.'
        }
        $created = Invoke-GraphJsonBody `
            -Method 'POST' `
            -Url "https://graph.microsoft.com/v1.0/applications/${applicationObjectId}/addPassword" `
            -Body @{
                passwordCredential = @{
                    displayName = (Get-RuntimeCredentialName -Config $Config -Purpose 'api-obo')
                    endDateTime = [DateTimeOffset]::UtcNow.AddYears(1).ToString('O')
                }
            }
        $secretText = [string]$created.secretText
        if ([string]::IsNullOrWhiteSpace($secretText)) {
            throw 'Microsoft Graph did not return the runtime Gateway API OBO client secret.'
        }
        Set-Content -LiteralPath $secretPath -Value $secretText -Encoding utf8 -NoNewline
    }

    return [ordered]@{
        gatewayApiApplicationObjectId = $applicationObjectId
        gatewayApiClientId = [string]$Identity.gatewayApiClientId
        gatewayApiOboClientSecret = $secretText
    }
}

function Ensure-RuntimeWorkloadApplication {
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
    Assert-ExactApplicationAuthenticationSurface -Application $application -ApplicationLabel 'Runtime workload application' | Out-Null
    if ([string]$application.displayName -cne $displayName -or
        [string]$application.signInAudience -cne 'AzureADMyOrg' -or
        @($application.identifierUris).Count -ne 0 -or
        @($application.spa.redirectUris).Count -ne 0 -or
        @($application.publicClient.redirectUris).Count -ne 0) {
        throw 'Runtime workload application does not match the exact confidential-client boundary.'
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

    $secretPath = Get-GatewayRuntimeWorkloadSecretPath -Config $Config
    $secretDirectory = Split-Path -Parent $secretPath
    if (-not (Test-Path -LiteralPath $secretDirectory)) {
        New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
    }

    $credentials = @($application.passwordCredentials)
    Assert-RuntimePasswordCredentials -Credentials $credentials -ExpectedName (Get-RuntimeCredentialName -Config $Config -Purpose 'workload')
    $bootstrapCreds = @($credentials | Where-Object { [string]$_.displayName -ceq (Get-RuntimeCredentialName -Config $Config -Purpose 'workload') })
    $secretText = ''
    if ($bootstrapCreds.Count -eq 1 -and (Test-Path -LiteralPath $secretPath)) {
        $secretText = [IO.File]::ReadAllText($secretPath).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($secretText)) {
        if ($bootstrapCreds.Count -gt 0) {
            throw 'The tenant credential exists but its local secret is missing. Restore the matching secret or perform an explicitly reviewed rotation; setup will not replace it.'
        }
        $created = Invoke-GraphJsonBody `
            -Method 'POST' `
            -Url "https://graph.microsoft.com/v1.0/applications/$($application.id)/addPassword" `
            -Body @{
                passwordCredential = @{
                    displayName = (Get-RuntimeCredentialName -Config $Config -Purpose 'workload')
                    endDateTime = [DateTimeOffset]::UtcNow.AddYears(1).ToString('O')
                }
            }
        $secretText = [string]$created.secretText
        if ([string]::IsNullOrWhiteSpace($secretText)) {
            throw 'Microsoft Graph did not return the runtime workload client secret.'
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

function Ensure-RuntimeAgent365SeedBlueprint {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DeploymentOwnershipId,
        [Parameter(Mandatory)][string]$SourceFingerprint,
        [Parameter(Mandatory)][string]$SponsorObjectId,
        [Parameter(Mandatory)][string]$WorkloadServicePrincipalId,
        [AllowNull()][System.Collections.IDictionary]$ExistingEvidence
    )

    if ($null -ne $ExistingEvidence) {
        if ([string]$ExistingEvidence.deploymentOwnershipId -cne $DeploymentOwnershipId) {
            throw 'Seed blueprint checkpoint belongs to another deployment.'
        }
        # A code update must not create another seed or change its creation provenance.
        $SourceFingerprint = [string]$ExistingEvidence.sourceFingerprint
        $objectId = ([guid][string]$ExistingEvidence.objectId).ToString('D')
        $existing = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url',
            "https://graph.microsoft.com/v1.0/applications/$objectId/microsoft.graph.agentIdentityBlueprint?`$select=id,appId,displayName,managerApplications,signInAudience,identifierUris,tags,api,appRoles,requiredResourceAccess,passwordCredentials,keyCredentials,web,spa,publicClient,isFallbackPublicClient")
        if ([string]$existing.appId -cne [string]$ExistingEvidence.applicationId) {
            throw 'Seed blueprint exact-ID readback does not match its checkpoint.'
        }
    }
    $displayName = Get-Agent365SeedBlueprintDisplayName `
        -Config $Config `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $SourceFingerprint
    if ($null -eq $ExistingEvidence) { $existing = Get-Agent365BlueprintByName -DisplayName $displayName }
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
                -GatewayWorkloadPrincipalId $WorkloadServicePrincipalId
        }
    }

    return Ensure-Agent365SeedBlueprint `
        -Config $Config `
        -DeploymentOwnershipId $DeploymentOwnershipId `
        -SourceFingerprint $SourceFingerprint `
        -SponsorObjectId $SponsorObjectId
}

function Ensure-RuntimeBlueprintClientSecret {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Blueprint
    )

    $applicationObjectId = [string]$Blueprint.objectId
    if ([string]::IsNullOrWhiteSpace($applicationObjectId)) {
        throw 'Seed blueprint object ID is required for runtime FMI client secret creation.'
    }

    $secretPath = Get-GatewayRuntimeBlueprintSecretPath -Config $Config
    $secretDirectory = Split-Path -Parent $secretPath
    if (-not (Test-Path -LiteralPath $secretDirectory)) {
        New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
    }

    $application = Invoke-AzJson -Arguments @(
        'rest', '--method', 'GET', '--url',
        "https://graph.microsoft.com/v1.0/applications/${applicationObjectId}?`$select=id,appId,passwordCredentials"
    )
    $credentials = @($application.passwordCredentials)
    Assert-RuntimePasswordCredentials -Credentials $credentials -ExpectedName (Get-RuntimeCredentialName -Config $Config -Purpose 'blueprint')
    $bootstrapCreds = @($credentials | Where-Object { [string]$_.displayName -ceq (Get-RuntimeCredentialName -Config $Config -Purpose 'blueprint') })
    $secretText = ''
    if ($bootstrapCreds.Count -eq 1 -and (Test-Path -LiteralPath $secretPath)) {
        $secretText = [IO.File]::ReadAllText($secretPath).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($secretText)) {
        if ($bootstrapCreds.Count -gt 0) {
            throw 'The tenant credential exists but its local secret is missing. Restore the matching secret or perform an explicitly reviewed rotation; setup will not replace it.'
        }
        $created = Invoke-GraphJsonBody `
            -Method 'POST' `
            -Url "https://graph.microsoft.com/v1.0/applications/${applicationObjectId}/addPassword" `
            -Body @{
                passwordCredential = @{
                    displayName = (Get-RuntimeCredentialName -Config $Config -Purpose 'blueprint')
                    endDateTime = [DateTimeOffset]::UtcNow.AddYears(1).ToString('O')
                }
            }
        $secretText = [string]$created.secretText
        if ([string]::IsNullOrWhiteSpace($secretText)) {
            throw 'Microsoft Graph did not return the runtime blueprint FMI client secret.'
        }
        Set-Content -LiteralPath $secretPath -Value $secretText -Encoding utf8 -NoNewline
    }

    return [ordered]@{
        blueprintObjectId = $applicationObjectId
        blueprintApplicationId = [string]$Blueprint.applicationId
        blueprintClientSecret = $secretText
    }
}

function Assert-RuntimePasswordCredentials {
    param([AllowEmptyCollection()][object[]]$Credentials, [Parameter(Mandatory)][string]$ExpectedName)
    if ($Credentials.Count -eq 0) { return }
    $expiry = [DateTimeOffset]::MinValue
    $keyId = [guid]::Empty
    if ($Credentials.Count -ne 1 -or [string]$Credentials[0].displayName -cne $ExpectedName -or
        -not [guid]::TryParse([string]$Credentials[0].keyId, [ref]$keyId) -or $keyId -eq [guid]::Empty -or
        -not [DateTimeOffset]::TryParse([string]$Credentials[0].endDateTime, [ref]$expiry) -or $expiry -le [DateTimeOffset]::UtcNow) {
        throw 'Bootstrap credential is expired, duplicated or unexpected. Restore the reviewed credential or arrange an explicit rotation; setup will not replace credentials.'
    }
}

function Write-GatewayRuntimeEnv {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$ConsoleIdentity,
        [Parameter(Mandatory)]$WorkloadIdentity,
        [Parameter(Mandatory)]$Images,
        [Parameter(Mandatory)]$PromptShield,
        [Parameter(Mandatory)][string]$GatewayApiOboClientSecret,
        [Parameter(Mandatory)][string]$BlueprintClientSecret,
        [Parameter(Mandatory)][ValidateScript({ [guid]::Parse($_) -ne [guid]::Empty })][string]$BlueprintApplicationId,
        $PurviewIdentity = $null
    )

    $composeDir = Get-GatewayRuntimeComposeDirectory
    $envPath = Join-Path $composeDir '.env.runtime'
    $blueprintSecrets = [ordered]@{}
    if (Test-Path -LiteralPath $envPath) {
        foreach ($line in Get-Content -LiteralPath $envPath) {
            if ($line -match '^Agent365__BlueprintClientSecrets__([0-9a-fA-F-]{36})=(.+)$') {
                $blueprintSecrets[([guid]$Matches[1]).ToString('D')] = $Matches[2]
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($BlueprintApplicationId)) {
        $blueprintSecrets[([guid]$BlueprintApplicationId).ToString('D')] = $BlueprintClientSecret
    }
    $apiPort = [int]$Config.runtime.apiHostPort
    $consolePort = [int]$Config.runtime.consoleHostPort
    $apiScope = [string]$ConsoleIdentity.apiScope
    $managerIds = @($Config.agent365.reviewedManagerApplicationIds | ForEach-Object { [string]$_ })
    $registryEnabled = ([bool]($Config.environment -eq 'dev' -and $Config.agent365.allowDevelopmentRegistryPreview -and $Config.agent365.registryBetaAcknowledged)).ToString().ToLowerInvariant()
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]@(
        "COMPOSE_PROJECT_NAME=$(Get-RuntimeComposeProjectName -Config $Config)"
        "GATEWAY_API_IMAGE=$($Images.api)"
        "GATEWAY_WORKER_IMAGE=$($Images.worker)"
        "GATEWAY_CONSOLE_IMAGE=$($Images.console)"
        "GATEWAY_API_HOST_PORT=$apiPort"
        "GATEWAY_CONSOLE_HOST_PORT=$consolePort"
        "CONSOLE_CLIENT_ID=$([string]$ConsoleIdentity.consoleClientId)"
        "CONSOLE_TENANT_ID=$([string]$Config.tenantId)"
        "CONSOLE_API_SCOPE=$apiScope"
        'ASPNETCORE_ENVIRONMENT=Runtime'
        'DOTNET_ENVIRONMENT=Runtime'
        "EntraId__TenantId=$([string]$Config.tenantId)"
        "EntraId__ClientId=$([string]$Identity.gatewayApiClientId)"
        "EntraId__Audience=$([string]$Identity.gatewayApiTokenAudience)"
        'EntraId__ClientCredentials__0__SourceType=ClientSecret'
        "EntraId__ClientCredentials__0__ClientSecret=$GatewayApiOboClientSecret"
        "Agent365__TenantId=$([string]$Config.tenantId)"
        'Agent365__ObservabilityServerAddress=127.0.0.1'
        "Agent365__ObservabilityServerPort=$apiPort"
        "Agent365__ProvisioningClientId=$([string]$WorkloadIdentity.workloadClientId)"
        "Agent365__ProvisioningPrincipalId=$([string]$WorkloadIdentity.workloadServicePrincipalId)"
        "Agent365__ProvisioningClientSecret=$([string]$WorkloadIdentity.workloadClientSecret)"
        "Provisioning__ExecutionEnabled=$registryEnabled"
        "Provisioning__AllowContinuousDevelopmentAccess=$registryEnabled"
        "Agent365__DelegatedRegistry__Enabled=$registryEnabled"
        "Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess=$registryEnabled"
        'Agent365__DelegatedRegistry__Scopes__0=https://graph.microsoft.com/AgentRegistration.ReadWrite.All'
        'Agent365__DelegatedRegistry__Scopes__1=https://graph.microsoft.com/AgentRegistration.Read.All'
        "ProvisioningWorker__ProvisioningExecutionEnabled=$registryEnabled"
        'ConnectionStrings__GatewayDb=Host=postgres;Port=5432;Database=gateway;Username=gateway;Password=gateway'
        'RabbitMq__ConnectionUri=amqp://gateway:gateway@rabbitmq:5672/'
        'ObjectStorage__ServiceUrl=http://s3:8000'
        'ObjectStorage__AccessKey=gateway'
        'ObjectStorage__SecretKey=gatewaysecret'
        'ObjectStorage__BucketName=a365-gateway-interactions'
        'ObjectStorage__ForcePathStyle=true'
        'ObjectStorage__CreateBucketIfMissing=true'
        'Infrastructure__Provider=Runtime'
        'OutboxRelay__Enabled=true'
        'ProvisioningWorker__ProcessingEnabled=true'
    ))

    for ($i = 0; $i -lt $managerIds.Count; $i++) {
        $lines.Add("Agent365__ManagerApplicationIds__$i=$($managerIds[$i])")
    }
    foreach ($blueprintId in $blueprintSecrets.Keys) {
        $lines.Add("Agent365__BlueprintClientSecrets__${blueprintId}=$($blueprintSecrets[$blueprintId])")
    }
    if ($null -ne $PurviewIdentity -and $PurviewIdentity.accessVerified) {
        $certificate = Get-Item "Cert:\CurrentUser\My\$($PurviewIdentity.certificateThumbprint)"
        $assignmentKeyPath = Join-Path (Get-RepositoryRoot) '.bootstrap/secrets/purview-assignment.key'
        $lines.Add("RuntimePolicyAssignments__AuthenticationKey=$([IO.File]::ReadAllText($assignmentKeyPath).Trim())")
        $lines.Add('RuntimePolicyAssignments__QueueDirectory=/app/purview-assignments')
        $lines.Add('Purview__Enabled=true')
        $lines.Add('RuntimePurviewCatalog__Enabled=true')
        $lines.Add("RuntimePurviewCatalog__TenantId=$($PurviewIdentity.tenantId)")
        $lines.Add('RuntimePurviewCatalog__SnapshotPath=/app/purview-catalog/catalog.json')
        $lines.Add("RuntimePurviewCatalog__CertificateBase64=$([Convert]::ToBase64String($certificate.RawData))")
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
        $lines.Add('PromptShield__AuthMode=ClientSecret')
        $lines.Add('PromptShield__Endpoint=')
    }

    Set-Content -LiteralPath $envPath -Value ($lines -join [Environment]::NewLine) -Encoding utf8
    return $envPath
}

function Deploy-GatewayRuntime {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$EnvFile
    )

    $composeDir = Get-GatewayRuntimeComposeDirectory
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
        apiHealthUrl = "http://127.0.0.1:$([int]$Config.runtime.apiHostPort)/health"
        apiReadyUrl = "http://127.0.0.1:$([int]$Config.runtime.apiHostPort)/health/ready"
        consoleUrl = "http://127.0.0.1:$([int]$Config.runtime.consoleHostPort)/"
        consoleConfigUrl = "http://127.0.0.1:$([int]$Config.runtime.consoleHostPort)/config.js"
        consoleProxyHealthUrl = "http://127.0.0.1:$([int]$Config.runtime.consoleHostPort)/health"
    }
}

function Test-GatewayRuntimeWorkerHealth {
    $composeDir = Get-GatewayRuntimeComposeDirectory
    $composeArguments = @('compose', '--project-directory', $composeDir,
        '--env-file', (Join-Path $composeDir '.env.runtime'),
        '-f', (Join-Path $composeDir 'docker-compose.yml'),
        '-f', (Join-Path $composeDir 'docker-compose.apps.yml'))
    $worker = Invoke-BootstrapCommand -FilePath docker -ArgumentList ($composeArguments + @('ps', '--status', 'running', '-q', 'worker')) -CaptureStdoutOnly
    if ([string]::IsNullOrWhiteSpace($worker)) { throw 'The gateway worker is not running.' }
    $queuesJson = Invoke-BootstrapCommand -FilePath docker -ArgumentList ($composeArguments + @('exec', '-T', 'rabbitmq', 'rabbitmqctl', 'list_queues', 'name', 'consumers', '--formatter', 'json', '--quiet')) -CaptureStdoutOnly
    $queues = @($queuesJson | ConvertFrom-Json)
    $queue = @($queues | Where-Object name -EQ 'gateway-provisioning-v3')
    if ($queue.Count -ne 1 -or [int]$queue[0].consumers -lt 1) {
        throw 'The gateway worker has not subscribed to the provisioning queue.'
    }
    return [ordered]@{ workerRunning = $true; provisioningConsumers = [int]$queue[0].consumers }
}

function Test-GatewayRuntimeHealth {
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
                $worker = Test-GatewayRuntimeWorkerHealth
                return [ordered]@{
                    healthy = $true
                    workerRunning = $worker.workerRunning
                    provisioningConsumers = $worker.provisioningConsumers
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

    throw "Gateway runtime did not become healthy within ${TimeoutSeconds}s. Last error: $lastError"
}

function Invoke-GatewayRuntimeApplyWorkflow {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][ValidateSet('Text','Json')][string]$Format,
        [Parameter(Mandatory)][bool]$InstallLocalPrerequisites,
        [Parameter(Mandatory)][bool]$NonInteractive,
        [Parameter(Mandatory)][string]$AcceptedPlanFingerprint
    )
    if (-not $State.Contains('acceptedPlan') -or
        $State.acceptedPlan -isnot [Collections.IDictionary] -or
        $State.acceptedPlan.planFingerprint -cne $AcceptedPlanFingerprint -or
        $State.acceptedPlan.configurationFingerprint -cne (Get-BootstrapConfigurationFingerprint -Config $Configuration) -or
        $State.acceptedPlan.sourceFingerprint -cne (Get-BootstrapSourceFingerprint)) {
        throw 'Apply requires a reviewed plan for the current source and configuration. Run gateway plan again.'
    }
    $context = @{ state=$State; path=$StatePath; format=$Format; index=0; total=@(Get-GatewayRuntimeBootstrapStepNames).Count }
    $null = Invoke-GatewaySetupStep -Name 'Prerequisites' -Context $context -Action {
        Assert-GatewayRuntimePrerequisites -Install:$InstallLocalPrerequisites -RequireBicep:([bool]$Configuration.promptShield.enabled)
        Assert-RuntimePurviewPrerequisites -Enabled:([bool]$Configuration.purview.enabled)
    } -Evidence { param($r) @{ docker=$true; compose=$true; purviewSelected=[bool]$Configuration.purview.enabled } }
    $azureIdentity = Invoke-GatewaySetupStep -Name 'Microsoft authentication' -Context $context -Action {
        if ([string]::IsNullOrWhiteSpace($Configuration.subscriptionId)) {
            Set-BootstrapAzureTenantContext -TenantId $Configuration.tenantId -NonInteractive:$NonInteractive
            @{ userObjectId=Invoke-AzTsv -Arguments @('ad','signed-in-user','show','--query','id')
               userPrincipalName=Invoke-AzTsv -Arguments @('ad','signed-in-user','show','--query','userPrincipalName')
               tenantId=$Configuration.tenantId; subscriptionId='' }
        } else { Connect-BootstrapAzure -Config $Configuration -NonInteractive:$NonInteractive }
    } -Evidence { param($r) @{tenantId=$r.tenantId} }
    $identity = Invoke-GatewaySetupStep -Name 'Gateway API identity' -Context $context -Action {
        Ensure-GatewayApiApplication -Config $Configuration -AzureIdentity $azureIdentity -DeploymentOwnershipId $State.deploymentOwnershipId
    } -Evidence { param($r) $r }
    $consoleIdentity = Invoke-GatewaySetupStep -Name 'Console identity' -Context $context -Action {
        Ensure-RuntimeConsoleApplication -Config $Configuration -Identity $identity -DeploymentOwnershipId $State.deploymentOwnershipId -ConsoleHostPort $Configuration.runtime.consoleHostPort
    } -Evidence { param($r) @{consoleClientId=$r.consoleClientId; consoleUrl=$r.consoleUrl; apiScope=$r.apiScope} }
    $apiObo = Invoke-GatewaySetupStep -Name 'Runtime API OBO credential' -Context $context -Action {
        Ensure-RuntimeGatewayApiOboSecret -Config $Configuration -Identity $identity
    } -Evidence { param($r) @{gatewayApiApplicationObjectId=$r.gatewayApiApplicationObjectId;gatewayApiClientId=$r.gatewayApiClientId} }
    $workloadIdentity = Invoke-GatewaySetupStep -Name 'Runtime workload identity' -Context $context -Action {
        Ensure-RuntimeWorkloadApplication -Config $Configuration -AzureIdentity $azureIdentity -DeploymentOwnershipId $State.deploymentOwnershipId
    } -Evidence { param($r) @{workloadClientId=$r.workloadClientId;workloadServicePrincipalId=$r.workloadServicePrincipalId} }
    $sourceFingerprint = Get-BootstrapSourceFingerprint
    $blueprint = Invoke-GatewaySetupStep -Name 'Agent 365 seed blueprint' -Context $context -Action {
        $prior = $State.steps['Agent 365 seed blueprint'].evidence
        Ensure-RuntimeAgent365SeedBlueprint -Config $Configuration -DeploymentOwnershipId $State.deploymentOwnershipId -SourceFingerprint $sourceFingerprint -SponsorObjectId $azureIdentity.userObjectId -WorkloadServicePrincipalId $workloadIdentity.workloadServicePrincipalId -ExistingEvidence $(if ($prior.Count) {$prior} else {$null})
    } -Evidence { param($r) $r }
    $blueprintSecret = Invoke-GatewaySetupStep -Name 'Runtime blueprint FMI credential' -Context $context -Action {
        Ensure-RuntimeBlueprintClientSecret -Config $Configuration -Blueprint $blueprint
    } -Evidence { param($r) @{blueprintObjectId=$r.blueprintObjectId;blueprintApplicationId=$r.blueprintApplicationId} }
    $promptShield = Invoke-GatewaySetupStep -Name 'Prompt Shields account' -Context $context -Action {
        $resource = Deploy-GatewayRuntimeContentSafety -Config $Configuration -DeploymentOwnershipId $State.deploymentOwnershipId -SourceFingerprint $sourceFingerprint
        if ($resource.enabled) {
            Set-RuntimeContentSafetyWorkloadRole -Config $Configuration -AccountId $resource.accountId -WorkloadServicePrincipalId $workloadIdentity.workloadServicePrincipalId | Out-Null
        }
        $resource
    } -Evidence { param($r) $r }
    $purviewIdentity = Invoke-GatewaySetupStep -Name 'Purview management access' -Context $context -Action {
        if (-not $Configuration.purview.enabled) { return $null }
        $management = Ensure-RuntimePurviewManagementIdentity -TenantId $Configuration.tenantId -DeploymentOwnershipId $State.deploymentOwnershipId -DeploymentName "$($Configuration.projectName)-$($Configuration.environment)" -OwnerObjectId $azureIdentity.userObjectId
        # Persist safe identity evidence before administrator consent or readback.
        $State.steps['Purview management access'].evidence = $management
        Save-BootstrapState -State $State -Path $StatePath
        Set-RuntimePurviewManagementRoleGroup -Identity $management -AdministratorUpn $azureIdentity.userPrincipalName
        $verified = Test-RuntimePurviewManagementAccess -Identity $management
        $management.accessVerified=$true
        $management['verifiedAtUtc']=$verified.verifiedAtUtc
        $management['policyCount']=$verified.policyCount
        Start-RuntimePurviewCatalogHost -Identity $management | Out-Null
        $management
    } -Evidence { param($r) if ($null -eq $r) { @{enabled=$false;disposition='NotRequested'} } else {$r} }
    $images = Invoke-GatewaySetupStep -Name 'Local workload images' -Context $context -Action {
        Build-GatewayRuntimeImages -Config $Configuration
    } -Evidence { param($r) $r }
    $runtime = Invoke-GatewaySetupStep -Name 'Gateway runtime' -Context $context -Action {
        $envFile = Write-GatewayRuntimeEnv -Config $Configuration -Identity $identity -ConsoleIdentity $consoleIdentity -WorkloadIdentity $workloadIdentity -Images $images -PromptShield $promptShield -GatewayApiOboClientSecret $apiObo.gatewayApiOboClientSecret -BlueprintClientSecret $blueprintSecret.blueprintClientSecret -BlueprintApplicationId $blueprint.applicationId -PurviewIdentity $purviewIdentity
        Deploy-GatewayRuntime -Config $Configuration -EnvFile $envFile
    } -Evidence { param($r) $r }
    $health = Invoke-GatewaySetupStep -Name 'End-to-end deployment verification' -Context $context -Action {
        Test-GatewayRuntimeHealth -HealthUrl $runtime.apiHealthUrl -ReadyUrl $runtime.apiReadyUrl -ConsoleConfigUrl $runtime.consoleConfigUrl -ConsoleProxyHealthUrl $runtime.consoleProxyHealthUrl
    } -Evidence { param($r) $r }
    Write-GatewayExperienceEvent -Type Result -Message "Gateway is running. Open Console: $($runtime.consoleUrl)" -Data @{
        step='End-to-end deployment verification'; index=$context.total; total=$context.total
        consoleUrl=$runtime.consoleUrl; apiHealthUrl=$runtime.apiHealthUrl
    } -OutputFormat $Format
    return @{identity=$identity;consoleIdentity=$consoleIdentity;workloadIdentity=$workloadIdentity;blueprint=$blueprint;promptShield=$promptShield;images=$images;runtime=$runtime;health=$health}
}

Export-ModuleMember -Function *

