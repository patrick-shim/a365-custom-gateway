BeforeAll {
    $deploymentModule = $null
    $finalImageModule = $null
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $definitions = foreach ($source in @(
        @{ Path = 'bootstrap\modules\Experience.psm1'; Names = @(
            'Test-GatewayNamedGroupDeployment', 'Test-GatewayHttpsUrl', 'Get-GatewayOptionalObjectProperty',
            'Test-GatewayContainerAppLocationEquivalent', 'Assert-GatewayExactContainerEnvironment',
            'Assert-GatewayExactContainerRegistry'
        ) }
        @{ Path = 'bootstrap\modules\Common.psm1'; Names = @(
            'Assert-BootstrapFingerprintValue', 'New-BootstrapValidationMismatchException',
            'Get-BootstrapExceptionValidationMismatchPropertyName'
        ) }
    )) {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $root $source.Path), [ref]$tokens, [ref]$errors)
        if ($errors.Count -ne 0) { throw 'The actual named-deployment verifier must parse.' }
        foreach ($name in $source.Names) {
            $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $false)
            if ($null -eq $definition) { throw "Missing real named-deployment helper: $name" }
            $definition.Extent.Text
        }
    }
    $deploymentModule = New-Module -Name "AdminDeploymentFixture_$([guid]::NewGuid().ToString('N'))" `
        -ArgumentList ($definitions -join "`n") -ScriptBlock {
        param($definitions)
        Set-StrictMode -Version Latest
        function Invoke-AzJson { param([string[]]$Arguments) throw 'Live Azure access is forbidden.' }
        . ([scriptblock]::Create($definitions))
        Export-ModuleMember -Function Test-GatewayNamedGroupDeployment
    }
    $deploymentModule | Import-Module -NoClobber -DisableNameChecking
    $verifyDeployment = $deploymentModule.ExportedCommands['Test-GatewayNamedGroupDeployment']

    $verification = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'bootstrap\modules\Verification.psm1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'The actual complete verifier must parse.' }
    $completeVerifier = $verification.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Test-GatewayBootstrapDeployment'
    }, $false)
    $imageMap = $completeVerifier.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -ceq '$deployedImages'
    }, $true)
    $imageReadback = $completeVerifier.Find({
        param($node)
        $node -is [Management.Automation.Language.ForEachStatementAst] -and
            $node.Condition.Extent.Text -ceq '$deployedImages.GetEnumerator()'
    }, $true)
    $report = $completeVerifier.Find({
        param($node)
        $node -is [Management.Automation.Language.HashtableAst] -and
            @($node.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -ceq 'immutableImages' }).Count -eq 1
    }, $true)
    if ($null -eq $imageMap -or $null -eq $imageReadback -or $null -eq $report) {
        throw 'The complete verifier must retain separate original and live image readback.'
    }
    $originalImageMap = @($report.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -ceq 'immutableImages' })[0].Item2.Extent.Text
    $finalImageModule = New-Module -Name "FinalImageFixture_$([guid]::NewGuid().ToString('N'))" `
        -ArgumentList $imageMap.Extent.Text, $imageReadback.Extent.Text, $originalImageMap -ScriptBlock {
        param($imageMap, $imageReadback, $originalImageMap)
        Set-StrictMode -Version Latest
        $script:imageMap = [scriptblock]::Create($imageMap)
        $script:imageReadback = [scriptblock]::Create($imageReadback)
        $script:originalImageMap = [scriptblock]::Create($originalImageMap)
        function Invoke-AzTsv { param($Arguments) throw 'Unscripted Azure access is forbidden.' }
        function Invoke-FinalWorkloadImageFixture {
            param($Config, $Images, $AdminUiPredecessor)
            . $script:imageMap
            . $script:imageReadback
            @{ immutableImages = (. $script:originalImageMap); deployedImages = $deployedImages }
        }
        Export-ModuleMember -Function Invoke-FinalWorkloadImageFixture
    }
    $finalImageModule | Import-Module -NoClobber -DisableNameChecking
    $verifyFinalImages = $finalImageModule.ExportedCommands['Invoke-FinalWorkloadImageFixture']
}

AfterAll {
    if ($deploymentModule) { Remove-Module -ModuleInfo $deploymentModule -Force }
    if ($finalImageModule) { Remove-Module -ModuleInfo $finalImageModule -Force }
}

Describe 'Complete verifier original and current immutable image readback' {
    BeforeEach {
        $config = @{ environment = 'dev'; resourceGroupName = 'synthetic-fixture-group' }
        $images = @{
            api = 'synthetic.invalid/api@sha256:' + ('1' * 64)
            worker = 'synthetic.invalid/worker@sha256:' + ('2' * 64)
            adminUi = 'synthetic.invalid/admin@sha256:' + ('3' * 64)
        }
        $proof = @{ build = @{ image = 'synthetic.invalid/admin@sha256:' + ('4' * 64) } }
        $actual = @{
            'ca-gateway-api-dev' = $images.api
            'ca-gateway-worker-dev-v3' = $images.worker
            'ca-gateway-admin-dev' = $proof.build.image
        }
        Mock Invoke-AzTsv -ModuleName $finalImageModule.Name {
            $Arguments[0] | Should -BeExactly 'containerapp'
            $Arguments[1] | Should -BeExactly 'show'
            $Arguments[[Array]::IndexOf($Arguments, '--resource-group') + 1] | Should -BeExactly $config.resourceGroupName
            $Arguments[[Array]::IndexOf($Arguments, '--query') + 1] | Should -BeExactly 'properties.template.containers[0].image'
            $name = $Arguments[[Array]::IndexOf($Arguments, '--name') + 1]
            $actual.Contains($name) | Should -BeTrue
            $actual[$name]
        }
    }

    It 'retains original image evidence while checking the separately verified live promotion' {
        $before = ConvertTo-Json $images -Compress
        $result = & $verifyFinalImages $config $images $proof
        $result.immutableImages['ca-gateway-admin-dev'] | Should -BeExactly $images.adminUi
        $result.deployedImages['ca-gateway-admin-dev'] | Should -BeExactly $proof.build.image
        $result.deployedImages['ca-gateway-api-dev'] | Should -BeExactly $images.api
        $result.deployedImages['ca-gateway-worker-dev-v3'] | Should -BeExactly $images.worker
        (ConvertTo-Json $images -Compress) | Should -BeExactly $before
        Should -Invoke Invoke-AzTsv -ModuleName $finalImageModule.Name -Exactly -Times 3
    }

    It 'keeps original-only verification unchanged when no promotion exists' {
        $actual['ca-gateway-admin-dev'] = $images.adminUi
        $result = & $verifyFinalImages $config $images $null
        $result.deployedImages['ca-gateway-admin-dev'] | Should -BeExactly $images.adminUi
        $result.immutableImages['ca-gateway-admin-dev'] | Should -BeExactly $images.adminUi
    }

    It 'does not adopt an unproven promotion' {
        { & $verifyFinalImages $config $images $null } | Should -Throw '*not running the recorded immutable image digest*'
    }

    It 'rejects current image drift in <_> despite a verified UI predecessor' -ForEach @(
        'ca-gateway-api-dev', 'ca-gateway-worker-dev-v3', 'ca-gateway-admin-dev'
    ) {
        $actual[$_] = 'synthetic.invalid/unapproved@sha256:' + ('5' * 64)
        { & $verifyFinalImages $config $images $proof } | Should -Throw '*not running the recorded immutable image digest*'
    }

    It 'does not silently accept the original UI image after a verified promotion' {
        $actual['ca-gateway-admin-dev'] = $images.adminUi
        { & $verifyFinalImages $config $images $proof } | Should -Throw '*not running the recorded immutable image digest*'
    }
}

Describe 'Original bootstrap deployment and separately verified live Admin UI' {
    BeforeEach {
        $config = @{
            subscriptionId = '22222222-2222-4222-8222-222222222222'
            tenantId = '11111111-1111-4111-8111-111111111111'
            resourceGroupName = 'rg-fixture-dev-20260924'; projectName = 'fixture'
            environment = 'dev'; location = 'koreacentral'
        }
        $ownership = '33333333-3333-4333-8333-333333333333'
        $source = 'sha256:' + ('1' * 64)
        $upgradeSource = 'sha256:' + ('2' * 64)
        $originalImage = 'synthetic.invalid/admin@sha256:' + ('3' * 64)
        $promotedImage = 'synthetic.invalid/admin@sha256:' + ('4' * 64)
        $principal = '44444444-4444-4444-8444-444444444444'
        $clientId = '55555555-5555-4555-8555-555555555555'
        $identityId = '/synthetic/admin-identity'
        $secretUri = 'https://synthetic.invalid/secrets/admin-ui-entra-client-secret'
        $fqdn = 'synthetic.invalid'
        $url = "https://$fqdn"
        $scopeBase = 'api://synthetic'
        $secretScope = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroupName)/providers/Microsoft.KeyVault/vaults/kv-fixture-dev/secrets/admin-ui-entra-client-secret"
        $evidence = @{
            deploymentOwnershipId = $ownership; sourceFingerprint = $source; adminUiImage = $originalImage
            adminUiUrl = $url; adminUiFqdn = $fqdn; adminUiPrincipalId = $principal
            signInRedirectUri = "$url/signin-oidc"; signedOutCallbackUri = "$url/signout-callback-oidc"
        }
        $deployment = @{
            state = 'Succeeded'
            parameters = @{
                deploymentOwnershipId = @{ value = $ownership }; bootstrapSourceFingerprint = @{ value = $source }
                adminUiContainerImage = @{ value = $originalImage }; containerAppsEnvironmentName = @{ value = 'fixture-environment' }
                entraIdTenantId = @{ value = $config.tenantId }; adminUiEntraClientId = @{ value = $clientId }
                adminUiGatewayApiScope = @{ value = "$scopeBase/access_as_user" }
            }
            outputs = @{
                deploymentOwnershipId = @{ value = $ownership }; bootstrapSourceFingerprint = @{ value = $source }
                adminUiContainerImage = @{ value = $originalImage }; adminUiFqdn = @{ value = $fqdn }
                adminUiUrl = @{ value = $url }; adminUiPrincipalId = @{ value = $principal }
                adminUiSignInRedirectUri = @{ value = $evidence.signInRedirectUri }
                adminUiSignedOutCallbackUri = @{ value = $evidence.signedOutCallbackUri }
            }
        }

        $values = @{
            ASPNETCORE_ENVIRONMENT = 'Production'; ASPNETCORE_HTTP_PORTS = '8080'; ASPNETCORE_FORWARDEDHEADERS_ENABLED = 'true'
            EntraId__Instance = 'https://login.microsoftonline.com/'; EntraId__TenantId = $config.tenantId
            EntraId__ClientId = $clientId; EntraId__CallbackPath = '/signin-oidc'; EntraId__SignedOutCallbackPath = '/signout-callback-oidc'
            GatewayApi__BaseUrl = 'https://api.synthetic.invalid/'; GatewayApi__Scopes__0 = "$scopeBase/access_as_user"
            GatewayApi__TimeoutSeconds = '120'
        }
        $environment = @($values.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value } })
        $environment += @{ name = 'EntraId__ClientSecret'; secretRef = 'admin-ui-entra-client-secret' }
        $app = @{
            name = 'ca-gateway-admin-dev'; location = 'Korea Central'
            tags = @{ bootstrapOwnershipId = $ownership; bootstrapSourceFingerprint = $source; adminUiUpgradeSourceFingerprint = $upgradeSource }
            identity = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $identityId = @{} } }
            properties = @{
                provisioningState = 'Succeeded'; managedEnvironmentId = '/synthetic/environment'
                configuration = @{
                    activeRevisionsMode = 'Single'
                    ingress = @{ fqdn = $fqdn; external = $true; allowInsecure = $false; targetPort = 8080; transport = 'auto'; stickySessions = @{ affinity = 'sticky' } }
                    registries = @(@{ server = 'synthetic.invalid'; identity = $identityId })
                    secrets = @(@{ name = 'admin-ui-entra-client-secret'; keyVaultUrl = $secretUri; identity = $identityId })
                }
                template = @{
                    containers = @(@{ image = $promotedImage; env = $environment })
                    scale = @{ minReplicas = 1; maxReplicas = 1 }
                }
            }
        } | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $identity = @{ id = $identityId; name = 'id-gateway-admin-dev'; principalId = $principal; ownershipId = $ownership }
        $roles = @(@{ principalId = $principal; scope = $secretScope; roleDefinitionId = '/roles/4633458b-17de-408a-b874-0445c86b69e6' })
        $proof = @{
            context = @{
                subscriptionId = $config.subscriptionId; tenantId = $config.tenantId; resourceGroupName = $config.resourceGroupName
                deploymentOwnershipId = $ownership; bootstrapSourceFingerprint = $source
            }
            receiptByteFingerprint = 'sha256:' + ('5' * 64); receiptSetFingerprint = 'sha256:' + ('6' * 64)
            upgradeSourceFingerprint = $upgradeSource
            build = @{ state = 'DigestCheckpointed'; image = $promotedImage }
            deployment = @{ state = 'Succeeded' }
            verification = @{
                kind = 'ReadOnlyPredecessorReverification'
                adminUi = @{ image = $promotedImage; principalId = $principal; fqdn = $fqdn }
            }
        }
        $arguments = @{
            Config = $config; Foundation = @{ containerAppsEnvironmentId = '/synthetic/environment'; containerAppsEnvironmentName = 'fixture-environment' }
            Runtime = @{ acrLoginServer = 'synthetic.invalid'; apiFqdn = 'api.synthetic.invalid' }
            Identity = @{ gatewayApiScopeBaseUri = $scopeBase }; AdminIdentity = @{ adminUiClientId = $clientId }
            AdminCredential = @{ secretUri = $secretUri }; DeploymentName = 'a365gw-fixture-bootstrap-admin-dev'
            Evidence = $evidence; DeploymentOwnershipId = $ownership; SourceFingerprint = $source
            AdminUiImage = $originalImage; AdminUiPredecessor = $proof
        }
        $readResponses = @{}
        $readResponses[(@('deployment', 'group', 'show', '--subscription', $config.subscriptionId, '--resource-group',
            $config.resourceGroupName, '--name', $arguments.DeploymentName,
            '--query', '{state:properties.provisioningState,outputs:properties.outputs,parameters:properties.parameters}') -join '|')] = $deployment
        $readResponses["containerapp|show|--resource-group|$($config.resourceGroupName)|--name|ca-gateway-admin-dev"] = $app
        $readResponses["identity|show|--resource-group|$($config.resourceGroupName)|--name|id-gateway-admin-dev|--query|{id:id,name:name,principalId:principalId,ownershipId:tags.bootstrapOwnershipId}"] = $identity
        $readResponses["role|assignment|list|--assignee-object-id|$principal|--scope|$secretScope|--include-inherited|--query|[].{principalId:principalId,scope:scope,roleDefinitionId:roleDefinitionId}"] = $roles
        Mock Invoke-AzJson -ModuleName $deploymentModule.Name {
            $key = $Arguments -join '|'
            if (-not $readResponses.ContainsKey($key)) { throw 'An unscripted provider request is forbidden.' }
            return $readResponses[$key]
        }
    }

    It 'verifies original deployment bytes against the original image and live bytes against the independently proved successor' {
        & $verifyDeployment @arguments | Should -BeTrue
        $deployment.parameters.adminUiContainerImage.value | Should -BeExactly $originalImage
        $deployment.outputs.adminUiContainerImage.value | Should -BeExactly $originalImage
        $evidence.adminUiImage | Should -BeExactly $originalImage
        Should -Invoke Invoke-AzJson -ModuleName $deploymentModule.Name -Times 4 -Exactly
    }

    It 'keeps the ordinary bootstrap image check when no predecessor is provided' {
        $arguments.Remove('AdminUiPredecessor')
        { & $verifyDeployment @arguments } | Should -Throw '*Named ARM deployment revalidation*'
        $app.properties.template.containers[0].image = $originalImage
        & $verifyDeployment @arguments | Should -BeTrue
    }

    It 'rejects <Label> instead of relabeling original evidence or relaxing the live boundary' -ForEach @(
        @{ Label = 'original evidence image'; Change = { $evidence.adminUiImage = $promotedImage } }
        @{ Label = 'original deployment parameter'; Change = { $deployment.parameters.adminUiContainerImage.value = $promotedImage } }
        @{ Label = 'original deployment output'; Change = { $deployment.outputs.adminUiContainerImage.value = $promotedImage } }
        @{ Label = 'original source'; Change = { $deployment.outputs.bootstrapSourceFingerprint.value = $upgradeSource } }
        @{ Label = 'live image'; Change = { $app.properties.template.containers[0].image = $originalImage } }
        @{ Label = 'live source tag'; Change = { $app.tags.adminUiUpgradeSourceFingerprint = $source } }
        @{ Label = 'tenant'; Change = { $proof.context.tenantId = 'foreign-tenant' } }
        @{ Label = 'target'; Change = { $proof.context.resourceGroupName = 'foreign-group' } }
        @{ Label = 'owner'; Change = { $proof.context.deploymentOwnershipId = 'foreign-owner' } }
        @{ Label = 'provider identity'; Change = { $proof.verification.adminUi.principalId = 'foreign-principal' } }
        @{ Label = 'unfinished build'; Change = { $proof.build.state = 'RunQueued' } }
        @{ Label = 'unfinished deployment'; Change = { $proof.deployment.state = 'IntentRecorded' } }
        @{ Label = 'non-read-only proof'; Change = { $proof.verification.kind = 'HistoricalReceipt' } }
        @{ Label = 'registry credentials'; Change = { $app.properties.configuration.registries[0] | Add-Member username 'forbidden' } }
        @{ Label = 'changed secret'; Change = { $app.properties.configuration.secrets[0].keyVaultUrl = 'https://foreign.invalid/secret' } }
        @{ Label = 'changed environment'; Change = { $app.properties.template.containers[0].env[0].value = 'changed' } }
        @{ Label = 'insecure ingress'; Change = { $app.properties.configuration.ingress.allowInsecure = $true } }
    ) {
        . $Change
        { & $verifyDeployment @arguments } | Should -Throw '*Named ARM deployment revalidation*'
    }
}
