$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Entra.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Verification.psm1') -Force

Describe 'Final verification strict-mode delegated-scope cardinality' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Get-Module Verification).Path, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0
        $function = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Test-GatewayBootstrapDeployment'
        }, $true)
        $script:finalVerificationSource = $function.Extent.Text
        $script:finalGrantAssignment = $function.Body.Find({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                [string]$node.Left -ceq '$adminGrantScopes'
        }, $true).Extent.Text
        $script:finalGrantValidation = $function.Body.Find({ param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Extent.Text.Contains('$adminGrantScopes.Count', [StringComparison]::Ordinal)
        }, $true).Extent.Text
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path (
            Split-Path -Parent (Get-Module Verification).Path) '../..'))
        $script:bootstrapSource = Get-Content -LiteralPath (
            Join-Path $repositoryRoot 'bootstrap/bootstrap.ps1') -Raw
    }

    It 'preserves exact final scope cardinality and rejects missing or extra scopes' {
        $countRunner = [scriptblock]::Create("param(`$allAdminGrants); Set-StrictMode -Version Latest; $script:finalGrantAssignment; return ,`$adminGrantScopes")
        $validationRunner = [scriptblock]::Create("param(`$allAdminGrants,`$Identity); Set-StrictMode -Version Latest; $script:finalGrantAssignment; $script:finalGrantValidation; return `$true")
        $resourceId = '77777777-7777-4777-8777-777777777777'
        $identity = [pscustomobject]@{ gatewayApiServicePrincipalId = $resourceId }
        $zero = & $countRunner -allAdminGrants @()
        $valid = @([pscustomobject]@{ resourceId = $resourceId; consentType = 'AllPrincipals'; scope = 'access_as_user' })
        $one = & $countRunner -allAdminGrants $valid
        $zero -is [array] | Should -BeTrue
        $zero.Count | Should -Be 0
        $one -is [array] | Should -BeTrue
        $one.Count | Should -Be 1
        & $validationRunner -allAdminGrants $valid -Identity $identity | Should -BeTrue
        foreach ($scope in @('', 'access_as_user unexpected')) {
            $invalid = @([pscustomobject]@{ resourceId = $resourceId; consentType = 'AllPrincipals'; scope = $scope })
            { & $validationRunner -allAdminGrants $invalid -Identity $identity } | Should -Throw '*exactly one tenant-wide access_as_user*'
        }
    }

    It 'revalidates the full dormant database job, sole execution, intent, and job identity boundary' {
        $script:finalVerificationSource | Should -Match 'Get-GatewayDatabaseBootstrapJobEvidence'
        $script:finalVerificationSource | Should -Match 'Get-GatewayDatabaseBootstrapJobEvidence(?s:.*?)-ExecutionIntentId \(\[string\]\$Database\.databaseBootstrapExecutionIntentId\)'
        $script:finalVerificationSource | Should -Match 'Get-GatewayDatabaseBootstrapExecutions'
        $script:finalVerificationSource | Should -Match 'Get-GatewayDatabaseBootstrapExecutionEvidence'
        $script:finalVerificationSource | Should -Match 'Assert-GatewayExactAzureRoleAssignments[^\r\n]+-Database \$Database'
    }

    It 'executes the provisioning preflight beside the loaded Verification module' {
        $repositoryRootAssignment = '$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ''../..''))'
        $currentPreflightInvocation = '& (Join-Path $root ''operations/test-provisioning-prerequisites.ps1'')'

        $script:finalVerificationSource | Should -Match ([regex]::Escape($repositoryRootAssignment))
        $script:finalVerificationSource | Should -Match ([regex]::Escape($currentPreflightInvocation))
        $script:finalVerificationSource | Should -Not -Match 'Get-BootstrapExecutionSourceRoot'
    }

    It 'rejects unsupported Purview deployment and verification before provider access' {
        $orchestratorGuard = $script:bootstrapSource.IndexOf(
            'if ($configuration.purview.enabled -eq $true -and',
            [StringComparison]::Ordinal)
        $planWorkflow = $script:bootstrapSource.IndexOf(
            "if (`$Mode -in @('Plan', 'Up'))",
            [StringComparison]::Ordinal)
        $verifyWorkflow = $script:bootstrapSource.IndexOf(
            "if (`$Mode -eq 'Verify')",
            [StringComparison]::Ordinal)
        $orchestratorGuard | Should -BeGreaterOrEqual 0
        $script:bootstrapSource.Substring($orchestratorGuard, $planWorkflow - $orchestratorGuard) |
            Should -Match '\$Mode -in @\(''Apply'', ''Resume'', ''Up'', ''Verify''\)'
        $script:bootstrapSource.Substring($orchestratorGuard, $planWorkflow - $orchestratorGuard) |
            Should -Match 'Test-BootstrapSecurityCompliancePlatformSupported'
        $orchestratorGuard | Should -BeLessThan $planWorkflow
        $orchestratorGuard | Should -BeLessThan $verifyWorkflow

        $verificationGuard = $script:finalVerificationSource.IndexOf(
            'Test-BootstrapSecurityCompliancePlatformSupported',
            [StringComparison]::Ordinal)
        $firstAzureReadback = $script:finalVerificationSource.IndexOf(
            'Assert-GatewayRuntimeDeploymentOwnership',
            [StringComparison]::Ordinal)
        $firstGraphReadback = $script:finalVerificationSource.IndexOf(
            'Get-BoundedGraphCollection',
            [StringComparison]::Ordinal)
        $verificationGuard | Should -BeGreaterOrEqual 0
        $verificationGuard | Should -BeLessThan $firstAzureReadback
        $verificationGuard | Should -BeLessThan $firstGraphReadback
    }
}

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

        It 'keeps runtime preview open independently of optional Purview policy authority' {
            $config = [pscustomobject]@{
                environment = 'dev'
                agent365 = [pscustomobject]@{ allowDevelopmentRegistryPreview = $true }
                purview = [pscustomobject]@{ policyProvisioningEnabled = $true }
            }
            $runtime = [pscustomobject]@{
                provisioningExecutionEnabled = $true
            }

            $mode = Get-GatewayRuntimeProvisioningMode -Config $config -Runtime $runtime

            $mode.previewRequested | Should -BeTrue
            $mode.runtimePreviewEnabled | Should -BeTrue
        }

        It 'rejects runtime execution that closes a requested development preview' {
            $config = [pscustomobject]@{
                environment = 'dev'
                agent365 = [pscustomobject]@{ allowDevelopmentRegistryPreview = $true }
                purview = [pscustomobject]@{ policyProvisioningEnabled = $true }
            }
            $runtime = [pscustomobject]@{
                provisioningExecutionEnabled = $false
            }

            { Get-GatewayRuntimeProvisioningMode -Config $config -Runtime $runtime } |
                Should -Throw '*does not match the reviewed effective*'
        }

        It 'binds the provisioning preflight through exact named parameters without flattening manager IDs' {
            $managerIds = [string[]]@(
                '66666666-6666-4666-8666-666666666666',
                '77777777-7777-4777-8777-777777777777'
            )
            $arguments = Get-GatewayProvisioningPreflightArguments `
                -Config ([pscustomobject]@{
                    environment = 'dev'
                    subscriptionId = '11111111-1111-4111-8111-111111111111'
                    tenantId = '22222222-2222-4222-8222-222222222222'
                    resourceGroupName = 'rg-safe-dev'
                    projectName = 'safeproject'
                }) `
                -Foundation ([pscustomobject]@{ containerAppsEnvironmentName = 'cae-safe-dev' }) `
                -Runtime ([pscustomobject]@{
                    serviceBusQueueName = 'gateway-provisioning-v3'
                    workerProcessingEnabled = $true
                }) `
                -Identity ([pscustomobject]@{ gatewayApiClientId = '33333333-3333-4333-8333-333333333333' }) `
                -Blueprint ([pscustomobject]@{ managerApplicationIds = $managerIds }) `
                -RuntimePreviewEnabled $true

            $bound = & {
                [CmdletBinding()]
                param(
                    [ValidateSet('dev', 'staging', 'prod')][string]$Environment,
                    [string]$ExpectedSubscriptionId,
                    [string]$ExpectedTenantId,
                    [string]$ResourceGroup,
                    [string]$ProjectName,
                    [string]$ContainerAppsEnvironmentName,
                    [string]$WorkerContainerAppName,
                    [string]$ExpectedServiceBusQueueName,
                    [bool]$WorkerProcessingEnabled,
                    [string]$ExpectedGatewayApiApplicationClientId,
                    [string[]]$ExpectedManagerApplicationIds,
                    [string]$ExpectedGatewayApiFederatedCredentialName,
                    [switch]$ManagerApplicationsPreflightConfirmed,
                    [switch]$RequireDeployedConfigurationMatch,
                    [switch]$DelegatedRegistryEnabled,
                    [switch]$RequireExecutionReady,
                    [switch]$ExpectContinuousDevelopmentAccess
                )
                return [pscustomobject]@{
                    environment = $Environment
                    subscriptionId = $ExpectedSubscriptionId
                    tenantId = $ExpectedTenantId
                    resourceGroup = $ResourceGroup
                    projectName = $ProjectName
                    containerAppsEnvironmentName = $ContainerAppsEnvironmentName
                    workerContainerAppName = $WorkerContainerAppName
                    queueName = $ExpectedServiceBusQueueName
                    workerProcessingEnabled = $WorkerProcessingEnabled
                    gatewayApiClientId = $ExpectedGatewayApiApplicationClientId
                    managerIds = [string[]]@($ExpectedManagerApplicationIds)
                    federatedCredentialName = $ExpectedGatewayApiFederatedCredentialName
                    managerConfirmed = $ManagerApplicationsPreflightConfirmed.IsPresent
                    deploymentMatchRequired = $RequireDeployedConfigurationMatch.IsPresent
                    delegatedRegistryEnabled = $DelegatedRegistryEnabled.IsPresent
                    executionReadyRequired = $RequireExecutionReady.IsPresent
                    continuousDevelopmentExpected = $ExpectContinuousDevelopmentAccess.IsPresent
                }
            } @arguments

            $bound.environment | Should -BeExactly 'dev'
            $bound.subscriptionId | Should -BeExactly '11111111-1111-4111-8111-111111111111'
            $bound.tenantId | Should -BeExactly '22222222-2222-4222-8222-222222222222'
            $bound.resourceGroup | Should -BeExactly 'rg-safe-dev'
            $bound.projectName | Should -BeExactly 'safeproject'
            $bound.containerAppsEnvironmentName | Should -BeExactly 'cae-safe-dev'
            $bound.workerContainerAppName | Should -BeExactly 'ca-gateway-worker-dev-v3'
            $bound.queueName | Should -BeExactly 'gateway-provisioning-v3'
            $bound.workerProcessingEnabled | Should -BeTrue
            $bound.gatewayApiClientId | Should -BeExactly '33333333-3333-4333-8333-333333333333'
            @($bound.managerIds).Count | Should -Be 2
            $bound.managerIds[0] | Should -BeExactly $managerIds[0]
            $bound.managerIds[1] | Should -BeExactly $managerIds[1]
            $bound.federatedCredentialName | Should -BeExactly 'a365gw-safeproject-api-obo-dev'
            $bound.managerConfirmed | Should -BeTrue
            $bound.deploymentMatchRequired | Should -BeTrue
            $bound.delegatedRegistryEnabled | Should -BeTrue
            $bound.executionReadyRequired | Should -BeTrue
            $bound.continuousDevelopmentExpected | Should -BeTrue
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
            $script:config = [pscustomobject]@{
                subscriptionId = '99999999-9999-4999-8999-999999999999'
                resourceGroupName = 'rg-safe-dev'
                projectName = 'safe'
                environment = 'dev'
            }
            $script:runtime = [pscustomobject]@{
                sqlServerFqdn = 'sql-safe-dev.database.windows.net'
                acrLoginServer = 'acrsafe.azurecr.io'
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
                networkMode = 'PrivateContainerAppsJob'
                privateNetworkExecutionVerified = $true
                legacyPublicBootstrapClientIpv4Unused = $true
                originalSqlAdministratorRestored = $true
                originalSqlAdministratorObjectId = '66666666-6666-4666-8666-666666666666'
                originalSqlAdministratorLogin = 'operator@contoso.test'
                databaseBootstrapJobName = 'job-safe-db-init-dev'
                databaseBootstrapJobId = '/subscriptions/99999999-9999-4999-8999-999999999999/resourceGroups/rg-safe-dev/providers/Microsoft.App/jobs/job-safe-db-init-dev'
                databaseBootstrapJobImage = "acrsafe.azurecr.io/gateway-db-migrator@sha256:$('e' * 64)"
                databaseBootstrapJobPrincipalId = '77777777-7777-4777-8777-777777777777'
                databaseBootstrapExecutionName = 'job-safe-db-init-dev-abcde'
                databaseBootstrapExecutionIntentId = '88888888-8888-4888-8888-888888888888'
                databaseBootstrapEvidenceFingerprint = "sha256:$('d' * 64)"
                privateEndpointNetworkInterfaceId = '/subscriptions/99999999-9999-4999-8999-999999999999/resourcegroups/rg-safe-dev/providers/microsoft.network/networkinterfaces/pe-sql-safe-dev.nic.aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
                privateEndpointIpv4Address = '10.42.1.4'
                privateDnsARecordSetId = '/subscriptions/99999999-9999-4999-8999-999999999999/resourcegroups/rg-safe-dev/providers/microsoft.network/privatednszones/privatelink.database.windows.net/a/sql-safe-dev'
                privateDnsARecordName = 'sql-safe-dev'
                privateDnsARecordIpv4Address = '10.42.1.4'
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
                Should -Throw 'Recorded database attestation is incomplete or does not match the exact runtime ownership, source, schema, initialization-intent, and principal boundary.'
        }

        It 'preserves only the exact database property cause across its curated catch' {
            $script:database.database = 'Value-that-must-not-appear'
            $caught = $null

            try {
                Test-GatewayRecordedDatabaseAttestationBoundary `
                    -Config $script:config `
                    -Runtime $script:runtime `
                    -Database $script:database `
                    -DeploymentOwnershipId $script:ownershipId `
                    -SourceFingerprint $script:sourceFingerprint
            }
            catch {
                $caught = $_
            }

            $caught | Should -Not -BeNullOrEmpty
            Get-BootstrapExceptionValidationMismatchPropertyName -Exception $caught.Exception |
                Should -BeExactly 'database.database'
            $caught.Exception.Message | Should -Not -Match 'Value-that-must-not-appear|GatewayDb'
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
                -ExpectedAssignments @([ordered]@{
                    scope = $script:scope
                    roleDefinitionId = $script:roleId
                    assignmentId = [string]$script:assignments[0].id
                }) `
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

        It 'rejects a mismatched or malformed exact role-assignment receipt' {
            { Assert-GatewayPrincipalExactAzureRoleAssignments `
                -PrincipalId $script:principalId `
                -SubscriptionId $script:subscriptionId `
                -ExpectedAssignments @([ordered]@{
                    scope = $script:scope
                    roleDefinitionId = $script:roleId
                    assignmentId = "$script:scope/providers/Microsoft.Authorization/roleAssignments/99999999-9999-4999-8999-999999999999"
                }) `
                -PrincipalLabel 'Test identity' } |
                Should -Throw '*unreviewed Azure role assignments*'

            { Assert-GatewayPrincipalExactAzureRoleAssignments `
                -PrincipalId $script:principalId `
                -SubscriptionId $script:subscriptionId `
                -ExpectedAssignments @([ordered]@{
                    scope = $script:scope
                    roleDefinitionId = $script:roleId
                    assignmentId = "$script:scope/providers/Microsoft.Authorization/roleAssignments/not-a-guid"
                }) `
                -PrincipalLabel 'Test identity' } |
                Should -Throw '*receipt is malformed*'
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

Describe 'Dedicated runtime image-pull identity least-privilege boundary' {
    InModuleScope Verification {
        BeforeEach {
            $script:pullSubscriptionId = '11111111-1111-4111-8111-111111111111'
            $script:pullResourceGroupScope = "/subscriptions/$script:pullSubscriptionId/resourceGroups/rg-safe-dev"
            $script:pullRegistryId = "$script:pullResourceGroupScope/providers/Microsoft.ContainerRegistry/registries/acrsafe"
            $script:pullIdentityName = 'id-gateway-runtime-pull-dev'
            $script:pullIdentityId = "$script:pullResourceGroupScope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$script:pullIdentityName"
            $script:pullPrincipalId = '22222222-2222-4222-8222-222222222222'
            $script:pullRoleAssignmentId = "$script:pullRegistryId/providers/Microsoft.Authorization/roleAssignments/33333333-3333-4333-8333-333333333333"
            $script:pullOwnershipId = '44444444-4444-4444-8444-444444444444'
            $script:pullSourceFingerprint = "sha256:$('a' * 64)"
            $script:pullIdentitySourceFingerprint = $script:pullSourceFingerprint
            $script:pullConfig = [pscustomobject]@{
                subscriptionId = $script:pullSubscriptionId
                resourceGroupName = 'rg-safe-dev'
                projectName = 'safe'
                environment = 'dev'
                promptShield = [pscustomobject]@{ enabled = $false }
                purview = [pscustomobject]@{ policyProvisioningEnabled = $false }
            }
            $script:pullRuntime = [pscustomobject]@{
                acrLoginServer = 'acrsafe.azurecr.io'
                containerRegistryId = $script:pullRegistryId
                sharedKeyVaultId = "$script:pullResourceGroupScope/providers/Microsoft.KeyVault/vaults/kv-safe-dev"
                serviceBusQueueName = 'gateway-provisioning-v3'
                serviceBusQueueId = "$script:pullResourceGroupScope/providers/Microsoft.ServiceBus/namespaces/sb-safe-dev/queues/gateway-provisioning-v3"
                storageAccountId = "$script:pullResourceGroupScope/providers/Microsoft.Storage/storageAccounts/stsafe"
                apiPrincipalId = '55555555-5555-4555-8555-555555555555'
                workerPrincipalId = '66666666-6666-4666-8666-666666666666'
                runtimeImagePullIdentityId = $script:pullIdentityId
                runtimeImagePullIdentityPrincipalId = $script:pullPrincipalId
                runtimeImagePullAcrPullRoleAssignmentId = $script:pullRoleAssignmentId
                deploymentOwnershipId = $script:pullOwnershipId
                sourceFingerprint = $script:pullSourceFingerprint
            }
            $script:pullAdmin = [pscustomobject]@{
                adminUiPrincipalId = '77777777-7777-4777-8777-777777777777'
            }
            $script:pullDatabase = [pscustomobject]@{
                databaseBootstrapJobPrincipalId = '88888888-8888-4888-8888-888888888888'
            }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                if ($Arguments[0] -eq 'identity') {
                    return [pscustomobject]@{
                        id = $script:pullIdentityId
                        name = $script:pullIdentityName
                        principalId = $script:pullPrincipalId
                        type = 'Microsoft.ManagedIdentity/userAssignedIdentities'
                        ownershipId = $script:pullOwnershipId
                        sourceFingerprint = $script:pullIdentitySourceFingerprint
                    }
                }
                if ($Arguments[0] -eq 'resource') {
                    $idIndex = [Array]::IndexOf($Arguments, '--ids')
                    $id = [string]$Arguments[$idIndex + 1]
                    $type = if ($id -like '*/Microsoft.Storage/storageAccounts/*') {
                        'Microsoft.Storage/storageAccounts'
                    }
                    elseif ($id -like '*/Microsoft.ContainerRegistry/registries/*') {
                        'Microsoft.ContainerRegistry/registries'
                    }
                    elseif ($id -like '*/Microsoft.KeyVault/vaults/*') {
                        'Microsoft.KeyVault/vaults'
                    }
                    else { 'Microsoft.ServiceBus/namespaces/queues' }
                    return [pscustomobject]@{
                        id = $id
                        type = $type
                        ownershipId = $script:pullOwnershipId
                        sourceFingerprint = $script:pullSourceFingerprint
                    }
                }
                throw 'Unexpected mocked Azure identity readback.'
            }
            Mock Assert-GatewayServicePrincipalHasNoDirectoryMemberships { return $true }
            Mock Assert-GatewayPrincipalExactAzureRoleAssignments { return $true }
            Mock Start-Sleep { }
        }

        It 'removes AcrPull from runtime system identities and binds one exact receipt to the pull UAMI' {
            Assert-GatewayExactAzureRoleAssignments `
                -Config $script:pullConfig -Runtime $script:pullRuntime -AdminUi $script:pullAdmin -Database $script:pullDatabase |
                Should -BeTrue

            Should -Invoke Assert-GatewayServicePrincipalHasNoDirectoryMemberships -Times 1 -Exactly -ParameterFilter {
                $PrincipalId -eq $script:pullPrincipalId -and $PrincipalLabel -eq 'Runtime image-pull identity'
            }
            Should -Invoke Assert-GatewayPrincipalExactAzureRoleAssignments -Times 1 -Exactly -ParameterFilter {
                $PrincipalId -eq $script:pullPrincipalId -and
                    $PrincipalLabel -eq 'Runtime image-pull identity' -and
                    @($ExpectedAssignments).Count -eq 1 -and
                    [string]$ExpectedAssignments[0].scope -eq $script:pullRegistryId -and
                    [string]$ExpectedAssignments[0].roleDefinitionId -eq '7f951dda-4ed3-4680-a7ca-43fe172d538d' -and
                    [string]$ExpectedAssignments[0].assignmentId -eq $script:pullRoleAssignmentId
            }
            Should -Invoke Assert-GatewayServicePrincipalHasNoDirectoryMemberships -Times 1 -Exactly -ParameterFilter {
                $PrincipalId -eq $script:pullDatabase.databaseBootstrapJobPrincipalId -and
                    $PrincipalLabel -eq 'Database-bootstrap job identity'
            }
            Should -Invoke Assert-GatewayPrincipalExactAzureRoleAssignments -Times 1 -Exactly -ParameterFilter {
                $PrincipalId -eq $script:pullDatabase.databaseBootstrapJobPrincipalId -and
                    $PrincipalLabel -eq 'Database-bootstrap job identity' -and
                    @($ExpectedAssignments).Count -eq 0
            }
            foreach ($systemPrincipalId in @($script:pullRuntime.apiPrincipalId, $script:pullRuntime.workerPrincipalId)) {
                Should -Invoke Assert-GatewayPrincipalExactAzureRoleAssignments -Times 1 -Exactly -ParameterFilter {
                    $PrincipalId -eq $systemPrincipalId -and
                        @($ExpectedAssignments | Where-Object { [string]$_.roleDefinitionId -eq '7f951dda-4ed3-4680-a7ca-43fe172d538d' }).Count -eq 0
                }
            }
        }

        It 'rejects pull-UAMI directory membership and any extra Azure role' {
            Mock Assert-GatewayServicePrincipalHasNoDirectoryMemberships {
                if ($PrincipalLabel -eq 'Runtime image-pull identity') { throw 'unreviewed membership' }
                return $true
            }
            { Assert-GatewayExactAzureRoleAssignments `
                -Config $script:pullConfig -Runtime $script:pullRuntime -AdminUi $script:pullAdmin -Database $script:pullDatabase } |
                Should -Throw '*unreviewed membership*'

            Mock Assert-GatewayServicePrincipalHasNoDirectoryMemberships { return $true }
            Mock Assert-GatewayPrincipalExactAzureRoleAssignments {
                if ($PrincipalLabel -eq 'Runtime image-pull identity') { throw 'unreviewed extra role' }
                return $true
            }
            { Assert-GatewayExactAzureRoleAssignments `
                -Config $script:pullConfig -Runtime $script:pullRuntime -AdminUi $script:pullAdmin -Database $script:pullDatabase } |
                Should -Throw '*least-privilege role/scope matrix*'
        }

        It 'rejects malformed role receipts and wrong identity ownership or source tags' {
            $script:pullRuntime.runtimeImagePullAcrPullRoleAssignmentId = "$script:pullRegistryId/providers/Microsoft.Authorization/roleAssignments/not-a-guid"
            { Assert-GatewayExactAzureRoleAssignments `
                -Config $script:pullConfig -Runtime $script:pullRuntime -AdminUi $script:pullAdmin -Database $script:pullDatabase } |
                Should -Throw '*resource IDs*'

            $script:pullRuntime.runtimeImagePullAcrPullRoleAssignmentId = $script:pullRoleAssignmentId
            $script:pullIdentitySourceFingerprint = "sha256:$('b' * 64)"
            { Assert-GatewayExactAzureRoleAssignments `
                -Config $script:pullConfig -Runtime $script:pullRuntime -AdminUi $script:pullAdmin -Database $script:pullDatabase } |
                Should -Throw '*ownership, and source boundary*'
        }
    }
}

Describe 'Exact Azure local-credential and transport controls' {
    InModuleScope Verification {
        BeforeEach {
            $script:controlConfig = [pscustomobject]@{
                tenantId = '11111111-1111-4111-8111-111111111111'
                subscriptionId = '22222222-2222-4222-8222-222222222222'
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
            $script:acrArmAudienceStatus = 'enabled'
            $script:storageSharedKeys = $false
            $script:keyVaultDefaultAction = 'Allow'
            $script:keyVaultBypass = 'AzureServices'
            $script:controlRegistryId = '/subscriptions/22222222-2222-4222-8222-222222222222/resourceGroups/rg-safe-dev/providers/Microsoft.ContainerRegistry/registries/acrsafe'
            Mock Invoke-AzTsv { return 'true' }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                switch ([string]$Arguments[0]) {
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
                            publicNetworkAccess = 'Disabled'
                            defaultAction = $script:keyVaultDefaultAction; bypass = $script:keyVaultBypass
                            ownershipId = $script:controlRuntime.deploymentOwnershipId
                            sourceFingerprint = $script:controlRuntime.sourceFingerprint
                        }
                    }
                    'resource' {
                        $idsIndex = [Array]::IndexOf([object[]]$Arguments, '--ids')
                        if ($idsIndex -ge 0 -and [string]$Arguments[$idsIndex + 1] -ceq $script:controlRegistryId) {
                            return [pscustomobject]@{
                                id = $script:controlRegistryId
                                adminUserEnabled = $script:acrAdminEnabled
                                armAudienceStatus = $script:acrArmAudienceStatus
                                ownershipId = $script:controlRuntime.deploymentOwnershipId
                                sourceFingerprint = $script:controlRuntime.sourceFingerprint
                            }
                        }
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

        It 'accepts the exact no-local-secret and TLS/network matrix with explicit Key Vault ACL values' {
            Assert-GatewayExactAzureLocalCredentialControls -Config $script:controlConfig -Runtime $script:controlRuntime |
                Should -BeTrue
            Should -Invoke Invoke-AzJson -Times 6 -Exactly
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                [string]$Arguments[0] -ceq 'resource' -and
                [string]$Arguments[1] -ceq 'show' -and
                [Array]::IndexOf([object[]]$Arguments, '--ids') -ge 0 -and
                [string]$Arguments[[Array]::IndexOf([object[]]$Arguments, '--ids') + 1] -ceq $script:controlRegistryId -and
                [Array]::IndexOf([object[]]$Arguments, '--api-version') -ge 0 -and
                [string]$Arguments[[Array]::IndexOf([object[]]$Arguments, '--api-version') + 1] -ceq '2023-11-01-preview' -and
                [string]$Arguments[-1] -like '*properties.policies.azureADAuthenticationAsArmPolicy.status*'
            }
        }

        It 'accepts provider-normalized absence of both Key Vault ACL values while public access is disabled' {
            $script:keyVaultDefaultAction = $null
            $script:keyVaultBypass = ''

            Assert-GatewayExactAzureLocalCredentialControls -Config $script:controlConfig -Runtime $script:controlRuntime |
                Should -BeTrue
        }

        It 'rejects partial provider-normalized absence of Key Vault ACL values' {
            $script:keyVaultDefaultAction = $null
            $script:keyVaultBypass = 'AzureServices'
            { Assert-GatewayExactAzureLocalCredentialControls -Config $script:controlConfig -Runtime $script:controlRuntime } |
                Should -Throw '*Key Vault RBAC*'

            $script:keyVaultDefaultAction = 'Allow'
            $script:keyVaultBypass = ''
            { Assert-GatewayExactAzureLocalCredentialControls -Config $script:controlConfig -Runtime $script:controlRuntime } |
                Should -Throw '*Key Vault RBAC*'
        }

        It 'rejects noncanonical Key Vault ACL values' {
            $script:keyVaultDefaultAction = 'Deny'
            $script:keyVaultBypass = 'None'

            { Assert-GatewayExactAzureLocalCredentialControls -Config $script:controlConfig -Runtime $script:controlRuntime } |
                Should -Throw '*Key Vault RBAC*'
        }

        It 'rejects drift that enables ACR admin credentials' {
            $script:acrAdminEnabled = $true
            { Assert-GatewayExactAzureLocalCredentialControls -Config $script:controlConfig -Runtime $script:controlRuntime } |
                Should -Throw '*ACR local credentials*'
        }

        It 'rejects ACR without managed-identity ARM-audience authentication' {
            $script:acrArmAudienceStatus = 'disabled'
            { Assert-GatewayExactAzureLocalCredentialControls -Config $script:controlConfig -Runtime $script:controlRuntime } |
                Should -Throw '*ARM-audience authentication*'
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
        foreach ($functionName in @(
            'Get-ExactPlainContainerEnvironmentValue',
            'Test-GatewayApiV2TokenApplicationContract',
            'Test-DeployedDelegatedRegistryConfiguration',
            'Test-DeployedProvisioningAccessConfiguration'
        )) {
            $functionDefinition = $script:preflightAst.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            }, $true)
            $null = $functionDefinition | Should -Not -BeNullOrEmpty
            Invoke-Expression $functionDefinition.Extent.Text
        }
    }

    BeforeEach {
        $script:preflightFailures = [Collections.Generic.List[string]]::new()
        $script:TokenExchangeAudience = 'api://AzureADTokenExchange'
        function Add-Failure { param([string]$Message) $script:preflightFailures.Add($Message) }
        function Write-Pass { param([string]$Message) }
        function Get-ContainerEnvironmentEntriesWithPrefix {
            param([Parameter(Mandatory)]$ContainerApp, [Parameter(Mandatory)][string]$Prefix)
            return @($ContainerApp.properties.template.containers[0].env | Where-Object {
                ([string]$_.name).StartsWith($Prefix, [StringComparison]::Ordinal)
            })
        }
        $script:safeApiEntries = @(
            [pscustomobject]@{ name = 'EntraId__TenantId'; value = '11111111-1111-4111-8111-111111111111' },
            [pscustomobject]@{ name = 'EntraId__ClientId'; value = '22222222-2222-4222-8222-222222222222' },
            [pscustomobject]@{ name = 'EntraId__Audience'; value = '22222222-2222-4222-8222-222222222222' },
            [pscustomobject]@{ name = 'EntraId__ClientCredentials__0__SourceType'; value = 'SignedAssertionFromManagedIdentity' },
            [pscustomobject]@{ name = 'EntraId__ClientCredentials__0__TokenExchangeUrl'; value = 'api://AzureADTokenExchange' }
        )
        function New-ContinuousDevelopmentAccessEntries {
            return @(
                [pscustomobject]@{ name = 'Agent365__DelegatedRegistry__Enabled'; value = 'true' }
                [pscustomobject]@{ name = 'Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess'; value = 'true' }
                [pscustomobject]@{ name = 'Agent365__DelegatedRegistry__Scopes__0'; value = 'https://graph.microsoft.com/AgentRegistration.ReadWrite.All' }
                [pscustomobject]@{ name = 'Agent365__DelegatedRegistry__Scopes__1'; value = 'https://graph.microsoft.com/AgentRegistration.Read.All' }
                [pscustomobject]@{ name = 'EntraId__ClientCredentials__0__SourceType'; value = 'SignedAssertionFromManagedIdentity' }
                [pscustomobject]@{ name = 'EntraId__ClientCredentials__0__TokenExchangeUrl'; value = 'api://AzureADTokenExchange' }
                [pscustomobject]@{ name = 'Provisioning__AllowContinuousDevelopmentAccess'; value = 'true' }
            )
        }
        function New-ClosedAccessEntries {
            return @(
                [pscustomobject]@{ name = 'Agent365__DelegatedRegistry__Enabled'; value = 'false' }
                [pscustomobject]@{ name = 'Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess'; value = 'false' }
                [pscustomobject]@{ name = 'Agent365__DelegatedRegistry__Scopes__0'; value = 'https://graph.microsoft.com/AgentRegistration.ReadWrite.All' }
                [pscustomobject]@{ name = 'Agent365__DelegatedRegistry__Scopes__1'; value = 'https://graph.microsoft.com/AgentRegistration.Read.All' }
                [pscustomobject]@{ name = 'EntraId__ClientCredentials__0__SourceType'; value = 'SignedAssertionFromManagedIdentity' }
                [pscustomobject]@{ name = 'EntraId__ClientCredentials__0__TokenExchangeUrl'; value = 'api://AzureADTokenExchange' }
                [pscustomobject]@{ name = 'Provisioning__AllowContinuousDevelopmentAccess'; value = 'false' }
            )
        }
        function New-AccessContainerApp {
            param([Parameter(Mandatory = $true)][object[]]$Entries)
            return [pscustomobject]@{
                properties = [pscustomobject]@{
                    template = [pscustomobject]@{
                        containers = @([pscustomobject]@{ env = @($Entries) })
                    }
                }
            }
        }
        function Invoke-AccessChecks {
            param(
                [Parameter(Mandatory = $true)][object]$ContainerApp,
                [Parameter(Mandatory = $true)][bool]$ContinuousDevelopment
            )
            Test-DeployedDelegatedRegistryConfiguration `
                -ContainerApp $ContainerApp `
                -ExpectedContinuousDevelopmentAccess $ContinuousDevelopment
            Test-DeployedProvisioningAccessConfiguration `
                -ContainerApp $ContainerApp `
                -ExpectedContinuousDevelopmentAccess $ContinuousDevelopment
        }
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
        $verificationSource | Should -Match 'ExpectedSubscriptionId\s*=\s*\[string\]\$Config\.subscriptionId'
        $verificationSource | Should -Match 'ExpectedTenantId\s*=\s*\[string\]\$Config\.tenantId'
    }

    It 'accepts only the explicit continuous development admission and delegated Registry surface' {
        $containerApp = New-AccessContainerApp -Entries @(New-ContinuousDevelopmentAccessEntries)

        Invoke-AccessChecks -ContainerApp $containerApp -ContinuousDevelopment $true

        $script:preflightFailures.Count | Should -Be 0
    }

    It 'accepts the explicit closed admission and delegated Registry surface' {
        $containerApp = New-AccessContainerApp -Entries @(New-ClosedAccessEntries)

        Invoke-AccessChecks -ContainerApp $containerApp -ContinuousDevelopment $false

        $script:preflightFailures.Count | Should -Be 0
    }

    It 'fails every continuous-mode security-critical setting closed on case-conflicting duplicates and secret references' {
        $safeEntries = @(New-ContinuousDevelopmentAccessEntries)
        foreach ($targetName in @($safeEntries.name)) {
            $duplicateEntries = @($safeEntries | ForEach-Object {
                [pscustomobject]@{ name = [string]$_.name; value = [string]$_.value }
            })
            $duplicateEntries += [pscustomobject]@{
                name = $targetName.ToUpperInvariant()
                value = 'contradictory-redacted-value'
            }
            $script:preflightFailures.Clear()
            Invoke-AccessChecks `
                -ContainerApp (New-AccessContainerApp -Entries $duplicateEntries) `
                -ContinuousDevelopment $true
            $script:preflightFailures.Count | Should -BeGreaterThan 0

            $secretReferenceEntries = @($safeEntries | ForEach-Object {
                if ([string]::Equals([string]$_.name, $targetName, [StringComparison]::Ordinal)) {
                    [pscustomobject]@{
                        name = [string]$_.name
                        value = [string]$_.value
                        secretRef = 'redacted-reference'
                    }
                }
                else {
                    [pscustomobject]@{ name = [string]$_.name; value = [string]$_.value }
                }
            })
            $script:preflightFailures.Clear()
            Invoke-AccessChecks `
                -ContainerApp (New-AccessContainerApp -Entries $secretReferenceEntries) `
                -ContinuousDevelopment $true
            $script:preflightFailures.Count | Should -BeGreaterThan 0
        }
    }

    It 'requires one container and one plain Provisioning execution-gate value' {
        $validContainerApp = New-AccessContainerApp -Entries @(
            [pscustomobject]@{ name = 'Provisioning__ExecutionEnabled'; value = 'true' }
        )
        Get-ExactPlainContainerEnvironmentValue `
            -ContainerApp $validContainerApp `
            -Name 'Provisioning__ExecutionEnabled' | Should -BeExactly 'true'
        $script:preflightFailures.Count | Should -Be 0

        $unsafeContainerApps = @(
            (New-AccessContainerApp -Entries @(
                [pscustomobject]@{ name = 'Provisioning__ExecutionEnabled'; value = 'true' }
                [pscustomobject]@{ name = 'provisioning__executionenabled'; value = 'false' }
            )),
            (New-AccessContainerApp -Entries @(
                [pscustomobject]@{
                    name = 'Provisioning__ExecutionEnabled'
                    value = 'true'
                    secretRef = 'redacted-reference'
                }
            )),
            (New-AccessContainerApp -Entries @(
                [pscustomobject]@{ name = 'Provisioning__ExecutionEnabled' }
            )),
            ([pscustomobject]@{
                properties = [pscustomobject]@{
                    template = [pscustomobject]@{
                        containers = @(
                            [pscustomobject]@{ env = @([pscustomobject]@{ name = 'Provisioning__ExecutionEnabled'; value = 'true' }) }
                            [pscustomobject]@{ env = @([pscustomobject]@{ name = 'Provisioning__ExecutionEnabled'; value = 'true' }) }
                        )
                    }
                }
            })
        )
        foreach ($unsafeContainerApp in $unsafeContainerApps) {
            $script:preflightFailures.Clear()
            Get-ExactPlainContainerEnvironmentValue `
                -ContainerApp $unsafeContainerApp `
                -Name 'Provisioning__ExecutionEnabled' | Should -BeNullOrEmpty
            $script:preflightFailures.Count | Should -BeGreaterThan 0
        }

        $script:preflightSource | Should -Match '(?s)deployedRegistrationGate\s*=\s*Get-ExactPlainContainerEnvironmentValue.+Provisioning__ExecutionEnabled'
    }

    It 'rejects a continuous deployed surface when the closed contract is expected' {
        $continuousContainerApp = New-AccessContainerApp `
            -Entries @(New-ContinuousDevelopmentAccessEntries)

        Invoke-AccessChecks `
            -ContainerApp $continuousContainerApp `
            -ContinuousDevelopment $false

        $script:preflightFailures.Count | Should -BeGreaterThan 0
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
            -Audience '22222222-2222-4222-8222-222222222222'

        $script:preflightFailures.Count | Should -Be 0
    }

    It 'requires the canonical Gateway API application to explicitly request v2 access tokens' {
        $clientId = '22222222-2222-4222-8222-222222222222'
        $application = [pscustomobject]@{
            appId = $clientId
            api = [pscustomobject]@{ requestedAccessTokenVersion = 2 }
        }

        Test-GatewayApiV2TokenApplicationContract `
            -Applications @($application) `
            -ClientId $clientId
        $script:preflightFailures.Count | Should -Be 0

        $script:preflightFailures.Clear()
        Test-GatewayApiV2TokenApplicationContract `
            -Applications @() `
            -ClientId $clientId
        $script:preflightFailures.Count | Should -BeGreaterThan 0

        foreach ($unsafeApplications in @(
            @([pscustomobject]@{
                appId = $clientId
                api = [pscustomobject]@{ requestedAccessTokenVersion = 1 }
            }),
            @([pscustomobject]@{
                appId = '33333333-3333-4333-8333-333333333333'
                api = [pscustomobject]@{ requestedAccessTokenVersion = 2 }
            }),
            @($application, $application)
        )) {
            $script:preflightFailures.Clear()
            Test-GatewayApiV2TokenApplicationContract `
                -Applications $unsafeApplications `
                -ClientId $clientId
            $script:preflightFailures.Count | Should -BeGreaterThan 0
        }
    }

    It 'rejects the custom scope URI when substituted for the v2 token audience' {
        $entries = @($script:safeApiEntries | ForEach-Object {
            if ([string]$_.name -ceq 'EntraId__Audience') {
                [pscustomobject]@{ name = [string]$_.name; value = 'api://a365-gateway-safe-dev' }
            }
            else { $_ }
        })
        $containerApp = [pscustomobject]@{
            properties = [pscustomobject]@{
                template = [pscustomobject]@{
                    containers = @([pscustomobject]@{ env = $entries })
                }
            }
        }

        Test-DeployedGatewayApiEntraCredentialConfiguration `
            -ContainerApp $containerApp `
            -TenantId '11111111-1111-4111-8111-111111111111' `
            -ClientId '22222222-2222-4222-8222-222222222222' `
            -Audience '22222222-2222-4222-8222-222222222222'

        $script:preflightFailures.Count | Should -BeGreaterThan 0

        $script:preflightFailures.Clear()
        $containerApp.properties.template.containers[0].env = @($script:safeApiEntries)
        Test-DeployedGatewayApiEntraCredentialConfiguration `
            -ContainerApp $containerApp `
            -TenantId '11111111-1111-4111-8111-111111111111' `
            -ClientId '22222222-2222-4222-8222-222222222222' `
            -Audience 'api://a365-gateway-safe-dev'

        $script:preflightFailures.Count | Should -BeGreaterThan 0
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
                -Audience '22222222-2222-4222-8222-222222222222'
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
                [pscustomobject]@{ name = 'Purview__Enabled'; value = 'False' },
                [pscustomobject]@{ name = 'Purview__PolicyProvisioningEnabled'; value = 'True' },
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
            ($script:environment | Where-Object name -eq 'Purview__PolicyProvisioningEnabled').value = 'False'

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
            $script:config.purview.policyProvisioningEnabled = $false
            $script:config.purview.policyProvisioningOrganization = ''
            $script:config.purview.policyProvisioningApplicationId = ''
            $script:config.purview.policyProvisioningCertificateSecretUri = ''
            foreach ($entry in $script:environment) {
                switch ($entry.name) {
                    'Purview__Enabled' { $entry.value = 'False' }
                    'Purview__PolicyProvisioningEnabled' { $entry.value = 'False' }
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

        It 'does not report profile provisioning ready when policy automation is not configured' {
            $script:config.purview.policyProvisioningEnabled = $false

            $evidence = Get-GatewayPurviewCertificateMetadataEvidence -Config $script:config

            $evidence.status | Should -Be 'NotConfigured'
            $evidence.automationApplicationCertificateAndComplianceRbac | Should -Be 'NotRequired'
            $evidence.profileProvisioningReady | Should -BeFalse
        }
    }
}
