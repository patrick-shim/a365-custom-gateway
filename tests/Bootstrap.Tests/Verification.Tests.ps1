$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Entra.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Verification.psm1') -Force

Describe 'Final Entra and runtime admission boundaries' {
    InModuleScope Verification {
        BeforeEach {
            $script:safeAdminApplication = [pscustomobject]@{
                isFallbackPublicClient = $false
                api = [pscustomobject]@{
                    acceptMappedClaims = $false
                    preAuthorizedApplications = @()
                    knownClientApplications = @()
                }
                web = [pscustomobject]@{
                    redirectUris = @('https://admin.example.test/signin-oidc')
                    logoutUrl = 'https://admin.example.test/signout-callback-oidc'
                    homePageUrl = $null
                    implicitGrantSettings = [pscustomobject]@{
                        enableAccessTokenIssuance = $false
                        enableIdTokenIssuance = $false
                    }
                }
                spa = [pscustomobject]@{ redirectUris = @() }
                publicClient = [pscustomobject]@{ redirectUris = @() }
                keyCredentials = @()
            }
        }

        It 'accepts exact HTTPS redirects only when every optional auth mode is disabled' {
            Test-ExactAdminUiRuntimeApplicationSurface `
                -Application $script:safeAdminApplication `
                -ExpectedSignInRedirectUri 'https://admin.example.test/signin-oidc' `
                -ExpectedSignedOutCallbackUri 'https://admin.example.test/signout-callback-oidc' |
                Should -BeTrue
        }

        It 'rejects implicit token issuance during final verification' {
            $script:safeAdminApplication.web.implicitGrantSettings.enableIdTokenIssuance = $true

            { Test-ExactAdminUiRuntimeApplicationSurface `
                -Application $script:safeAdminApplication `
                -ExpectedSignInRedirectUri 'https://admin.example.test/signin-oidc' `
                -ExpectedSignedOutCallbackUri 'https://admin.example.test/signout-callback-oidc' } |
                Should -Throw '*unapproved*'
        }

        It 'binds runtime evidence to the exact canonical bootstrap ownership identifier' {
            $runtime = [pscustomobject]@{ deploymentOwnershipId = '11111111-1111-4111-8111-111111111111' }

            Assert-GatewayRuntimeDeploymentOwnership `
                -Runtime $runtime `
                -DeploymentOwnershipId '11111111-1111-4111-8111-111111111111' |
                Should -BeTrue

            $runtime.deploymentOwnershipId = '22222222-2222-4222-8222-222222222222'
            { Assert-GatewayRuntimeDeploymentOwnership `
                -Runtime $runtime `
                -DeploymentOwnershipId '11111111-1111-4111-8111-111111111111' } |
                Should -Throw '*canonical ownership*'
        }

        It 'keeps runtime preview closed while Purview policy authority remains outside bootstrap' {
            $config = [pscustomobject]@{
                environment = 'dev'
                agent365 = [pscustomobject]@{ allowDevelopmentRegistryPreview = $true }
                purview = [pscustomobject]@{ policyProvisioningEnabled = $true }
            }
            $runtime = [pscustomobject]@{
                provisioningExecutionEnabled = $false
                registryProvider = 'Disabled'
            }

            $mode = Get-GatewayRuntimeProvisioningMode -Config $config -Runtime $runtime

            $mode.previewRequested | Should -BeTrue
            $mode.runtimePreviewEnabled | Should -BeFalse
            $mode.expectedRegistryProvider | Should -Be 'Disabled'
        }

        It 'rejects runtime execution that contradicts the Purview-closed effective mode' {
            $config = [pscustomobject]@{
                environment = 'dev'
                agent365 = [pscustomobject]@{ allowDevelopmentRegistryPreview = $true }
                purview = [pscustomobject]@{ policyProvisioningEnabled = $true }
            }
            $runtime = [pscustomobject]@{
                provisioningExecutionEnabled = $true
                registryProvider = 'DirectRegistryPreview'
            }

            { Get-GatewayRuntimeProvisioningMode -Config $config -Runtime $runtime } |
                Should -Throw '*do not match the reviewed effective*'
        }
    }
}

Describe 'Current private-runtime database attestation boundary' {
    InModuleScope Verification {
        BeforeEach {
            $script:ownershipId = '11111111-1111-4111-8111-111111111111'
            $script:sourceFingerprint = "sha256:$('a' * 64)"
            $script:apiObjectId = '22222222-2222-4222-8222-222222222222'
            $script:workerObjectId = '33333333-3333-4333-8333-333333333333'
            $script:apiClientId = '44444444-4444-4444-8444-444444444444'
            $script:workerClientId = '55555555-5555-4555-8555-555555555555'
            $script:schemaFingerprint = "sha256:$('b' * 64)"
            $script:config = [pscustomobject]@{ environment = 'dev' }
            $script:runtime = [pscustomobject]@{
                sqlServerFqdn = 'sql-safe-dev.database.windows.net'
                apiPrincipalId = $script:apiObjectId
                workerPrincipalId = $script:workerObjectId
                databaseAttestationEnabled = $true
                databaseAttestationExpectedSchemaFingerprint = $script:schemaFingerprint
                databaseAttestationApiPrincipalName = 'ca-gateway-api-dev'
                databaseAttestationApiPrincipalClientId = $script:apiClientId
                databaseAttestationWorkerPrincipalName = 'ca-gateway-worker-dev-v3'
                databaseAttestationWorkerPrincipalClientId = $script:workerClientId
                databaseAttestationDatabaseName = 'GatewayDb'
            }
            $script:database = [pscustomobject]@{
                deploymentOwnershipId = $script:ownershipId
                acceptedSourceFingerprint = $script:sourceFingerprint
                server = $script:runtime.sqlServerFqdn
                database = 'GatewayDb'
                schemaFingerprint = $script:schemaFingerprint
                apiPrincipalName = 'ca-gateway-api-dev'
                workerPrincipalName = 'ca-gateway-worker-dev-v3'
                apiPrincipalObjectId = $script:apiObjectId
                workerPrincipalObjectId = $script:workerObjectId
                apiPrincipalClientId = $script:apiClientId
                workerPrincipalClientId = $script:workerClientId
                apiDirectPermissions = @('VIEW DEFINITION')
                workerDirectPermissions = @()
                initializationIntent = [pscustomobject]@{
                    markerName = 'A365GatewayBootstrapInitializationIntent'
                    schemaVersion = 1
                    deploymentOwnershipId = $script:ownershipId
                    acceptedSourceFingerprint = $script:sourceFingerprint
                    server = $script:runtime.sqlServerFqdn
                    database = 'GatewayDb'
                    databaseCollation = 'SQL_Latin1_General_CP1_CI_AS'
                    catalogCollation = 'SQL_Latin1_General_CP1_CI_AS'
                    databaseOwnerSidSha256 = "sha256:$('c' * 64)"
                    exactReadbackVerified = $true
                }
            }
            Mock Start-Sleep { }
        }

        It 'accepts only an exact recorded ownership, schema, marker, and principal boundary' {
            Test-GatewayRecordedDatabaseAttestationBoundary `
                -Config $script:config `
                -Runtime $script:runtime `
                -Database $script:database `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint |
                Should -BeTrue
        }

        It 'rejects a different database owner identity hash' {
            $script:database.initializationIntent.databaseOwnerSidSha256 = 'not-the-reviewed-hash'

            { Test-GatewayRecordedDatabaseAttestationBoundary `
                -Config $script:config `
                -Runtime $script:runtime `
                -Database $script:database `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint } |
                Should -Throw '*initialization-intent*'
        }

        It 'accepts only the two-field v1 live attestation response' {
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '{"status":"Attested","contractVersion":1}'
                }
            }

            $result = Get-GatewayCurrentDatabaseAttestationEvidence -ApiFqdn 'api.example.test'

            $result.status | Should -Be 'Passed'
            $result.contractVersion | Should -Be 1
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://api.example.test/health/bootstrap-attestation' -and
                $Method -eq 'Get' -and $TimeoutSec -eq 30
            }
        }

        It 'fails closed without reflecting provider content or accepting extra fields' {
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    StatusCode = 503
                    Content = '{"status":"Unavailable","contractVersion":1,"schema":"sensitive-provider-detail"}'
                }
            }

            { Get-GatewayCurrentDatabaseAttestationEvidence -ApiFqdn 'api.example.test' } |
                Should -Throw '*exact bounded v1 success contract*'
            Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        }
    }
}

Describe 'Exact Azure runtime identity RBAC boundary' {
    InModuleScope Verification {
        BeforeEach {
            $script:subscriptionId = '11111111-1111-4111-8111-111111111111'
            $script:principalId = '22222222-2222-4222-8222-222222222222'
            $script:scope = "/subscriptions/$script:subscriptionId/resourceGroups/rg-safe-dev/providers/Microsoft.Storage/storageAccounts/stsafe"
            $script:roleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
            $script:assignments = @([pscustomobject]@{
                id = "$script:scope/providers/Microsoft.Authorization/roleAssignments/33333333-3333-4333-8333-333333333333"
                principalId = $script:principalId
                principalType = 'ServicePrincipal'
                scope = $script:scope
                roleDefinitionId = "/subscriptions/$script:subscriptionId/providers/Microsoft.Authorization/roleDefinitions/$script:roleId"
                condition = $null
                conditionVersion = $null
                delegatedManagedIdentityResourceId = $null
            })
            Mock Invoke-AzJsonArray { return @($script:assignments) }
        }

        It 'accepts one exact assignment and requests all descendant and inherited assignments' {
            Assert-GatewayPrincipalExactAzureRoleAssignments `
                -PrincipalId $script:principalId `
                -SubscriptionId $script:subscriptionId `
                -ExpectedAssignments @([ordered]@{ scope = $script:scope; roleDefinitionId = $script:roleId }) `
                -PrincipalLabel 'Test identity' |
                Should -BeTrue

            Should -Invoke Invoke-AzJsonArray -Times 1 -Exactly -ParameterFilter {
                $Arguments -contains '--all' -and
                $Arguments -contains '--include-inherited' -and
                $Arguments -contains '--assignee-object-id'
            }
        }

        It 'rejects an extra inherited or broader assignment even when the required leaf role exists' {
            $script:assignments += [pscustomobject]@{
                id = "/subscriptions/$script:subscriptionId/providers/Microsoft.Authorization/roleAssignments/44444444-4444-4444-8444-444444444444"
                principalId = $script:principalId
                principalType = 'ServicePrincipal'
                scope = "/subscriptions/$script:subscriptionId"
                roleDefinitionId = "/subscriptions/$script:subscriptionId/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
                condition = $null
                conditionVersion = $null
                delegatedManagedIdentityResourceId = $null
            }

            { Assert-GatewayPrincipalExactAzureRoleAssignments `
                -PrincipalId $script:principalId `
                -SubscriptionId $script:subscriptionId `
                -ExpectedAssignments @([ordered]@{ scope = $script:scope; roleDefinitionId = $script:roleId }) `
                -PrincipalLabel 'Test identity' } |
                Should -Throw '*unreviewed Azure role assignments*'
        }

        It 'rejects conditional, delegated, duplicate, or wrong-scope substitutions' {
            $script:assignments[0].condition = "@Resource[Microsoft.Storage/storageAccounts:name] StringEquals 'other'"

            { Assert-GatewayPrincipalExactAzureRoleAssignments `
                -PrincipalId $script:principalId `
                -SubscriptionId $script:subscriptionId `
                -ExpectedAssignments @([ordered]@{ scope = $script:scope; roleDefinitionId = $script:roleId }) `
                -PrincipalLabel 'Test identity' } |
                Should -Throw '*unreviewed condition*'
        }

        It 'requires a dedicated managed identity to have no transitive group or directory-role membership' {
            Mock Get-BoundedGraphCollection { return @() }

            Assert-GatewayServicePrincipalHasNoDirectoryMemberships `
                -PrincipalId $script:principalId `
                -PrincipalLabel 'Test identity' |
                Should -BeTrue

            Should -Invoke Get-BoundedGraphCollection -Times 1 -Exactly -ParameterFilter {
                $InitialUrl -match '/servicePrincipals/.+/transitiveMemberOf\?'
            }
        }

        It 'rejects any transitive group membership before accepting direct Azure roles' {
            Mock Get-BoundedGraphCollection {
                return @([pscustomobject]@{ id = '55555555-5555-4555-8555-555555555555' })
            }

            { Assert-GatewayServicePrincipalHasNoDirectoryMemberships `
                -PrincipalId $script:principalId `
                -PrincipalLabel 'Test identity' } |
                Should -Throw '*group/directory-role membership*'
        }
    }
}

Describe 'Exact Azure local-credential and transport controls' {
    InModuleScope Verification {
        BeforeEach {
            $script:controlConfig = [pscustomobject]@{
                tenantId = '11111111-1111-4111-8111-111111111111'
                resourceGroupName = 'rg-safe-dev'
                projectName = 'safe'
                environment = 'dev'
                promptShield = [pscustomobject]@{ enabled = $true }
            }
            $script:controlRuntime = [pscustomobject]@{
                acrLoginServer = 'acrsafe.azurecr.io'
                storageAccountId = '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-safe-dev/providers/Microsoft.Storage/storageAccounts/stsafe'
                sqlServerFqdn = 'sql-safe-dev.database.windows.net'
                promptShieldAccountId = '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-safe-dev/providers/Microsoft.CognitiveServices/accounts/cs-safe'
                deploymentOwnershipId = '33333333-3333-4333-8333-333333333333'
                sourceFingerprint = "sha256:$('a' * 64)"
            }
            $script:acrAdminEnabled = $false
            $script:storageSharedKeys = $false
            Mock Invoke-AzTsv { return 'true' }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                switch ([string]$Arguments[0]) {
                    'acr' {
                        return [pscustomobject]@{
                            adminUserEnabled = $script:acrAdminEnabled
                            ownershipId = $script:controlRuntime.deploymentOwnershipId
                            sourceFingerprint = $script:controlRuntime.sourceFingerprint
                        }
                    }
                    'storage' {
                        return [pscustomobject]@{
                            httpsOnly = $true; minimumTlsVersion = 'TLS1_2'; allowBlobPublicAccess = $false
                            allowSharedKeyAccess = $script:storageSharedKeys; publicNetworkAccess = 'Disabled'
                            defaultAction = 'Deny'; bypass = 'None'
                            ownershipId = $script:controlRuntime.deploymentOwnershipId
                            sourceFingerprint = $script:controlRuntime.sourceFingerprint
                        }
                    }
                    'servicebus' {
                        return [pscustomobject]@{
                            disableLocalAuth = $true; minimumTlsVersion = '1.2'
                            ownershipId = $script:controlRuntime.deploymentOwnershipId
                            sourceFingerprint = $script:controlRuntime.sourceFingerprint
                        }
                    }
                    'sql' {
                        return [pscustomobject]@{
                            minimalTlsVersion = '1.2'; publicNetworkAccess = 'Disabled'
                            ownershipId = $script:controlRuntime.deploymentOwnershipId
                            sourceFingerprint = $script:controlRuntime.sourceFingerprint
                        }
                    }
                    'keyvault' {
                        return [pscustomobject]@{
                            tenantId = $script:controlConfig.tenantId; enableRbacAuthorization = $true
                            enableSoftDelete = $true; softDeleteRetentionInDays = 90; enablePurgeProtection = $true
                            enabledForDeployment = $false; enabledForDiskEncryption = $false; enabledForTemplateDeployment = $false
                            publicNetworkAccess = 'Disabled'; defaultAction = 'Allow'; bypass = 'AzureServices'
                            ownershipId = $script:controlRuntime.deploymentOwnershipId
                            sourceFingerprint = $script:controlRuntime.sourceFingerprint
                        }
                    }
                    'resource' {
                        return [pscustomobject]@{
                            kind = 'ContentSafety'; disableLocalAuth = $true; publicNetworkAccess = 'Enabled'; defaultAction = 'Allow'
                            ownershipId = $script:controlRuntime.deploymentOwnershipId
                            sourceFingerprint = $script:controlRuntime.sourceFingerprint
                        }
                    }
                    default { throw 'Unexpected mocked Azure control readback.' }
                }
            }
        }

        It 'accepts only the exact no-local-secret and TLS/network matrix' {
            Assert-GatewayExactAzureLocalCredentialControls -Config $script:controlConfig -Runtime $script:controlRuntime |
                Should -BeTrue
            Should -Invoke Invoke-AzJson -Times 7 -Exactly
        }

        It 'rejects drift that enables ACR admin credentials' {
            $script:acrAdminEnabled = $true
            { Assert-GatewayExactAzureLocalCredentialControls -Config $script:controlConfig -Runtime $script:controlRuntime } |
                Should -Throw '*ACR local credentials*'
        }

        It 'rejects drift that enables Storage shared keys' {
            $script:storageSharedKeys = $true
            { Assert-GatewayExactAzureLocalCredentialControls -Config $script:controlConfig -Runtime $script:controlRuntime } |
                Should -Throw '*Storage local keys*'
        }
    }
}

Describe 'Provisioning preflight account and OBO environment boundary' {
    BeforeAll {
        $entraModuleRoot = Split-Path (Get-Module Entra).Path -Parent
        $script:preflightRepositoryRoot = [IO.Path]::GetFullPath((Join-Path $entraModuleRoot '../..'))
        $script:preflightPath = Join-Path $script:preflightRepositoryRoot 'operations/test-provisioning-prerequisites.ps1'
        $script:preflightSource = Get-Content -LiteralPath $script:preflightPath -Raw
        $tokens = $null
        $errors = $null
        $script:preflightAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:preflightPath,
            [ref]$tokens,
            [ref]$errors)
        $errors.Count | Should -Be 0
        $credentialFunction = $script:preflightAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-DeployedGatewayApiEntraCredentialConfiguration'
        }, $true)
        Invoke-Expression $credentialFunction.Extent.Text
    }

    BeforeEach {
        $script:preflightFailures = [Collections.Generic.List[string]]::new()
        $script:TokenExchangeAudience = 'api://AzureADTokenExchange'
        function Add-Failure { param([string]$Message) $script:preflightFailures.Add($Message) }
        function Write-Pass { param([string]$Message) }
        $script:safeApiEntries = @(
            [pscustomobject]@{ name = 'EntraId__TenantId'; value = '11111111-1111-4111-8111-111111111111' },
            [pscustomobject]@{ name = 'EntraId__ClientId'; value = '22222222-2222-4222-8222-222222222222' },
            [pscustomobject]@{ name = 'EntraId__Audience'; value = 'api://a365-gateway-safe-dev' },
            [pscustomobject]@{ name = 'EntraId__ClientCredentials__0__SourceType'; value = 'SignedAssertionFromManagedIdentity' },
            [pscustomobject]@{ name = 'EntraId__ClientCredentials__0__TokenExchangeUrl'; value = 'api://AzureADTokenExchange' }
        )
    }

    It 'requires canonical subscription and tenant inputs and passes both from final verification' {
        foreach ($parameterName in @('ExpectedSubscriptionId', 'ExpectedTenantId')) {
            $parameter = @($script:preflightAst.ParamBlock.Parameters | Where-Object {
                $_.Name.VariablePath.UserPath -eq $parameterName
            })
            $parameter.Count | Should -Be 1
            $parameter[0].Extent.Text | Should -Match 'Mandatory\s*=\s*\$true'
        }
        $script:preflightSource | Should -Match 'ExpectedSubscriptionId must be one canonical lowercase non-empty GUID'
        $script:preflightSource | Should -Match 'ExpectedTenantId must be one canonical lowercase non-empty GUID'

        $verificationSource = Get-Content -LiteralPath (Join-Path $script:preflightRepositoryRoot 'bootstrap/modules/Verification.psm1') -Raw
        $verificationSource | Should -Match "'-ExpectedSubscriptionId', \[string\]\`$Config\.subscriptionId"
        $verificationSource | Should -Match "'-ExpectedTenantId', \[string\]\`$Config\.tenantId"
    }

    It 'accepts only the five exact plain-value managed-identity OBO settings' {
        $containerApp = [pscustomobject]@{
            properties = [pscustomobject]@{
                template = [pscustomobject]@{
                    containers = @([pscustomobject]@{ env = @($script:safeApiEntries) })
                }
            }
        }

        Test-DeployedGatewayApiEntraCredentialConfiguration `
            -ContainerApp $containerApp `
            -TenantId '11111111-1111-4111-8111-111111111111' `
            -ClientId '22222222-2222-4222-8222-222222222222' `
            -Audience 'api://a365-gateway-safe-dev'

        $script:preflightFailures.Count | Should -Be 0
    }

    It 'rejects secretRef, credential variants, duplicate names, and extra credential indices' {
        $unsafeVariants = @(
            @($script:safeApiEntries + [pscustomobject]@{ name = 'EntraId__ClientSecret'; secretRef = 'unsafe' }),
            @($script:safeApiEntries + [pscustomobject]@{ name = 'EntraId__ClientCertificates__0'; value = 'unsafe' }),
            @($script:safeApiEntries + [pscustomobject]@{ name = 'EntraId__ClientCredentials__1__SourceType'; value = 'SignedAssertionFromManagedIdentity' }),
            @($script:safeApiEntries + [pscustomobject]@{ name = 'EntraId__ClientId'; value = '22222222-2222-4222-8222-222222222222' })
        )
        foreach ($entries in $unsafeVariants) {
            $script:preflightFailures.Clear()
            $containerApp = [pscustomobject]@{
                properties = [pscustomobject]@{
                    template = [pscustomobject]@{
                        containers = @([pscustomobject]@{ env = @($entries) })
                    }
                }
            }
            Test-DeployedGatewayApiEntraCredentialConfiguration `
                -ContainerApp $containerApp `
                -TenantId '11111111-1111-4111-8111-111111111111' `
                -ClientId '22222222-2222-4222-8222-222222222222' `
                -Audience 'api://a365-gateway-safe-dev'
            $script:preflightFailures.Count | Should -BeGreaterThan 0
        }
    }

    It 'keeps direct Azure CLI execution inside the rechecking and pinning wrappers only' {
        $directAzCommands = @($script:preflightAst.FindAll({
            param($node)
            if ($node -isnot [Management.Automation.Language.CommandAst]) { return $false }
            return $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand -and
                $node.CommandElements.Count -gt 0 -and
                $node.CommandElements[0].Extent.Text -eq 'az'
        }, $true))
        $owningFunctions = @($directAzCommands | ForEach-Object {
            $parent = $_.Parent
            while ($null -ne $parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) {
                $parent = $parent.Parent
            }
            $parent.Name
        } | Sort-Object -Unique)
        $owningFunctions | Should -Be @('Invoke-AzAccountShowRaw', 'Invoke-AzJson')
        $script:preflightSource | Should -Match 'Assert-ActiveAzureAccountBoundary'
        $script:preflightSource | Should -Match "@\('--subscription', \`$ExpectedSubscriptionId\)"
    }
}

Describe 'Purview worker deployment truth' {
    InModuleScope Verification {
        BeforeEach {
            $script:workerPrincipalId = '44444444-4444-4444-8444-444444444444'
            $script:apiPrincipalId = '77777777-7777-4777-8777-777777777777'
            $script:vaultScope = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev/providers/Microsoft.KeyVault/vaults/kv-safe-dev'
            $script:certificateScope = "$script:vaultScope/secrets/automation-certificate"
            $script:environment = @(
                [pscustomobject]@{ name = 'Purview__Enabled'; value = 'true' },
                [pscustomobject]@{ name = 'Purview__PolicyProvisioningEnabled'; value = 'true' },
                [pscustomobject]@{ name = 'Purview__PolicyProvisioningOrganization'; value = 'contoso.onmicrosoft.com' },
                [pscustomobject]@{ name = 'Purview__PolicyProvisioningApplicationId'; value = '33333333-3333-4333-8333-333333333333' },
                [pscustomobject]@{ name = 'Purview__PolicyProvisioningCertificateSecretUri'; value = 'https://kv-safe-dev.vault.azure.net/secrets/automation-certificate' }
            )
            $script:roleAssignments = @([pscustomobject]@{
                id = "$script:certificateScope/providers/Microsoft.Authorization/roleAssignments/55555555-5555-4555-8555-555555555555"
                principalId = $script:workerPrincipalId
                scope = $script:certificateScope
                roleDefinitionId = '/subscriptions/11111111-1111-4111-8111-111111111111/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6'
            })
            $script:apiRoleAssignments = @()
            $script:config = [pscustomobject]@{
                subscriptionId = '11111111-1111-4111-8111-111111111111'
                resourceGroupName = 'rg-safe-dev'
                environment = 'dev'
                projectName = 'safe'
                purview = [pscustomobject]@{
                    activateGatewayAdapterAfterPolicyReadback = $true
                    policyProvisioningEnabled = $true
                    policyProvisioningOrganization = 'contoso.onmicrosoft.com'
                    policyProvisioningApplicationId = '33333333-3333-4333-8333-333333333333'
                    policyProvisioningCertificateSecretUri = 'https://kv-safe-dev.vault.azure.net/secrets/automation-certificate'
                }
            }
            $script:runtime = [pscustomobject]@{
                workerPrincipalId = $script:workerPrincipalId
                apiPrincipalId = $script:apiPrincipalId
            }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                if ($Arguments[0] -eq 'containerapp') {
                    return [pscustomobject]@{
                        properties = [pscustomobject]@{
                            template = [pscustomobject]@{
                                containers = @([pscustomobject]@{ env = @($script:environment) })
                            }
                        }
                    }
                }
                if ($Arguments[0] -eq 'role') {
                    $assigneeIndex = [Array]::IndexOf($Arguments, '--assignee-object-id')
                    if ($assigneeIndex -ge 0 -and [string]$Arguments[$assigneeIndex + 1] -eq $script:apiPrincipalId) {
                        return @($script:apiRoleAssignments)
                    }
                    return @($script:roleAssignments)
                }
                if ($Arguments[0] -eq 'resource') {
                    return [pscustomobject]@{
                        id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-safe-dev/providers/Microsoft.KeyVault/vaults/kv-safe-dev/secrets/automation-certificate'
                        name = 'automation-certificate'
                        enabled = $true
                    }
                }
                throw 'Unexpected mocked Azure operation.'
            }
            Mock Invoke-AzJsonArray {
                param([string[]]$Arguments, [string]$OperationLabel)
                $assigneeIndex = [Array]::IndexOf($Arguments, '--assignee-object-id')
                if ($assigneeIndex -ge 0 -and [string]$Arguments[$assigneeIndex + 1] -eq $script:apiPrincipalId) {
                    return @($script:apiRoleAssignments)
                }
                return @($script:roleAssignments)
            }
        }

        It 'accepts exact worker settings and one exact shared-vault read role' {
            Assert-GatewayPurviewWorkerDeploymentConfiguration -Config $script:config -Runtime $script:runtime |
                Should -BeTrue
        }

        It 'rejects a policy feature silently deployed disabled' {
            ($script:environment | Where-Object name -eq 'Purview__PolicyProvisioningEnabled').value = 'false'

            { Assert-GatewayPurviewWorkerDeploymentConfiguration -Config $script:config -Runtime $script:runtime } |
                Should -Throw "*Purview__PolicyProvisioningEnabled*"
        }

        It 'rejects inherited or over-broad certificate access in place of the exact vault role' {
            $script:roleAssignments[0].scope = '/subscriptions/11111111-1111-4111-8111-111111111111'

            { Assert-GatewayPurviewWorkerDeploymentConfiguration -Config $script:config -Runtime $script:runtime } |
                Should -Throw '*exact certificate-secret scope*'
        }

        It 'rejects any additional direct or inherited role at the certificate vault' {
            $script:roleAssignments += [pscustomobject]@{
                id = '/subscriptions/11111111-1111-4111-8111-111111111111/providers/Microsoft.Authorization/roleAssignments/66666666-6666-4666-8666-666666666666'
                principalId = $script:workerPrincipalId
                scope = '/subscriptions/11111111-1111-4111-8111-111111111111'
                roleDefinitionId = '/subscriptions/11111111-1111-4111-8111-111111111111/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
            }

            { Assert-GatewayPurviewWorkerDeploymentConfiguration -Config $script:config -Runtime $script:runtime } |
                Should -Throw '*unreviewed direct or inherited role*'
        }

        It 'rejects any direct or inherited shared-vault role on the Gateway API identity' {
            $script:apiRoleAssignments = @([pscustomobject]@{
                id = "$script:vaultScope/providers/Microsoft.Authorization/roleAssignments/88888888-8888-4888-8888-888888888888"
                principalId = $script:apiPrincipalId
                scope = $script:vaultScope
                roleDefinitionId = '/subscriptions/11111111-1111-4111-8111-111111111111/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6'
            })

            { Assert-GatewayPurviewWorkerDeploymentConfiguration -Config $script:config -Runtime $script:runtime } |
                Should -Throw '*API identity must have no direct or inherited*'
        }

        It 'requires the certificate role to be absent when policy provisioning is disabled' {
            $script:config.purview.activateGatewayAdapterAfterPolicyReadback = $false
            $script:config.purview.policyProvisioningEnabled = $false
            $script:config.purview.policyProvisioningOrganization = ''
            $script:config.purview.policyProvisioningApplicationId = ''
            $script:config.purview.policyProvisioningCertificateSecretUri = ''
            foreach ($entry in $script:environment) {
                switch ($entry.name) {
                    'Purview__Enabled' { $entry.value = 'false' }
                    'Purview__PolicyProvisioningEnabled' { $entry.value = 'false' }
                    'Purview__PolicyProvisioningOrganization' { $entry.value = '' }
                    'Purview__PolicyProvisioningApplicationId' { $entry.value = '' }
                    'Purview__PolicyProvisioningCertificateSecretUri' { $entry.value = '' }
                }
            }
            $script:roleAssignments = @()

            Assert-GatewayPurviewWorkerDeploymentConfiguration -Config $script:config -Runtime $script:runtime |
                Should -BeTrue
        }

        It 'reads only exact enabled certificate metadata and keeps external Microsoft 365 authority NotChecked' {
            $evidence = Get-GatewayPurviewCertificateMetadataEvidence -Config $script:config

            $evidence.status | Should -Be 'MetadataPassed'
            $evidence.secretEnabled | Should -BeTrue
            $evidence.automationApplicationCertificateAndComplianceRbac | Should -Be 'NotChecked'
            $evidence.profileProvisioningReady | Should -BeFalse
        }
    }
}
