$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Azure.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Entra.psm1') -Force

Describe 'Exact Entra discovery cardinality' {
    InModuleScope Entra {
        BeforeEach {
            $script:discoveryValues = @()
            Mock Invoke-AzJson {
                return [pscustomobject]@{ value = @($script:discoveryValues) }
            }
        }

        It 'returns no application when the exact display name is absent' {
            Get-ExactApplicationByDisplayName -DisplayName 'A365 Gateway API - safe-dev' |
                Should -BeNullOrEmpty
        }

        It 'returns the one exact application instead of invoking a runtime if command' {
            $script:discoveryValues = @([pscustomobject]@{ id = 'application-object-id' })

            (Get-ExactApplicationByDisplayName -DisplayName 'A365 Gateway API - safe-dev').id |
                Should -Be 'application-object-id'
        }

        It 'rejects ambiguous application discovery' {
            $script:discoveryValues = @(
                [pscustomobject]@{ id = 'first-application' },
                [pscustomobject]@{ id = 'second-application' }
            )

            { Get-ExactApplicationByDisplayName -DisplayName 'A365 Gateway API - safe-dev' } |
                Should -Throw '*refusing ambiguous adoption*'
        }

        It 'returns zero or one service principal and rejects duplicates' {
            Get-ServicePrincipalByAppId -AppId '11111111-1111-4111-8111-111111111111' |
                Should -BeNullOrEmpty

            $script:discoveryValues = @([pscustomobject]@{ id = 'service-principal-id' })
            (Get-ServicePrincipalByAppId -AppId '11111111-1111-4111-8111-111111111111').id |
                Should -Be 'service-principal-id'

            $script:discoveryValues = @(
                [pscustomobject]@{ id = 'first-principal' },
                [pscustomobject]@{ id = 'second-principal' }
            )
            { Get-ServicePrincipalByAppId -AppId '11111111-1111-4111-8111-111111111111' } |
                Should -Throw '*Multiple service principals*'
        }
    }
}

Describe 'Bounded Microsoft Graph collection traversal' {
    InModuleScope Entra {
        BeforeEach {
            $script:requestedUrls = [Collections.Generic.List[string]]::new()
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                $url = [string]$Arguments[$Arguments.Count - 1]
                $script:requestedUrls.Add($url)
                if ($url -match 'safe-page-two') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'second' }) }
                }
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'first' })
                    '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants?$skiptoken=safe-page-two'
                }
            }
        }

        It 'returns every page from the exact same Graph collection' {
            $items = @(Get-BoundedGraphCollection -InitialUrl 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants?$select=id')

            @($items.id) | Should -Be @('first', 'second')
            $script:requestedUrls.Count | Should -Be 2
        }

        It 'rejects a cross-origin, cross-path, repeated, or over-limit continuation' {
            foreach ($unsafeNextLink in @(
                'https://example.invalid/v1.0/oauth2PermissionGrants?$skiptoken=unsafe',
                'https://graph.microsoft.com/v1.0/applications?$skiptoken=unsafe',
                'https://graph.microsoft.com/v1.0/oauth2PermissionGrants?$select=id'
            )) {
                Mock Invoke-AzJson {
                    return [pscustomobject]@{ value = @(); '@odata.nextLink' = $unsafeNextLink }
                }
                { Get-BoundedGraphCollection -InitialUrl 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants?$select=id' } |
                    Should -Throw '*continuation*'
            }

            Mock Invoke-AzJson {
                return [pscustomobject]@{
                    value = @()
                    '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants?$skiptoken=page-two'
                }
            }
            { Get-BoundedGraphCollection -InitialUrl 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants?$select=id' -MaximumPages 1 } |
                Should -Throw '*page limit*'
        }

        It 'rejects a malformed collection response instead of treating it as empty' {
            Mock Invoke-AzJson { return [pscustomobject]@{ value = [pscustomobject]@{ id = 'not-an-array' } } }

            { Get-BoundedGraphCollection -InitialUrl 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants?$select=id' } |
                Should -Throw '*required value array*'
        }
    }
}

Describe 'Exact application identifier URI collision discovery' {
    InModuleScope Entra {
        BeforeEach {
            $script:requestedUrl = ''
            $script:collisionObjects = @()
            Mock Get-BoundedGraphCollection {
                param([string]$InitialUrl)
                $script:requestedUrl = $InitialUrl
                return @($script:collisionObjects)
            }
        }

        It 'uses the documented Graph v1.0 identifierUris filter and exact readback' {
            $identifierUri = 'api://a365-gateway-safe-dev'
            $script:collisionObjects = @([pscustomobject]@{
                id = '11111111-1111-4111-8111-111111111111'
                identifierUris = @($identifierUri)
            })

            $matches = @(Get-ApplicationsByExactIdentifierUri -IdentifierUri $identifierUri)

            $matches.Count | Should -Be 1
            $matches[0].id | Should -BeExactly '11111111-1111-4111-8111-111111111111'
            ([Uri]::UnescapeDataString($script:requestedUrl)) |
                Should -BeExactly "https://graph.microsoft.com/v1.0/applications?`$filter=identifierUris/any(uri:uri eq '$identifierUri')&`$select=id,identifierUris"
        }

        It 'rejects a provider object outside the exact requested identifier URI' {
            $script:collisionObjects = @([pscustomobject]@{
                id = '11111111-1111-4111-8111-111111111111'
                identifierUris = @('api://different-audience')
            })

            { Get-ApplicationsByExactIdentifierUri -IdentifierUri 'api://a365-gateway-safe-dev' } |
                Should -Throw '*outside the exact requested boundary*'
        }
    }
}

Describe 'Exact application authentication surface' {
    InModuleScope Entra {
        It 'accepts only disabled or null optional authentication switches and empty client authority' {
            $safe = [pscustomobject]@{
                isFallbackPublicClient = $false
                api = [pscustomobject]@{
                    acceptMappedClaims = $null
                    preAuthorizedApplications = @()
                    knownClientApplications = @()
                }
                web = [pscustomobject]@{
                    implicitGrantSettings = [pscustomobject]@{
                        enableAccessTokenIssuance = $false
                        enableIdTokenIssuance = $null
                    }
                }
            }

            Assert-ExactApplicationAuthenticationSurface -Application $safe -ApplicationLabel 'Safe application' |
                Should -BeTrue

            $safe.isFallbackPublicClient = $null
            $safe.api.acceptMappedClaims = $false
            Assert-ExactApplicationAuthenticationSurface -Application $safe -ApplicationLabel 'Safe application with Graph null defaults' |
                Should -BeTrue
        }

        It 'rejects public-client fallback, implicit tokens, mapped claims, preauthorization, and known clients' {
            $unsafeApplications = @(
                [pscustomobject]@{ isFallbackPublicClient = $true; api = [pscustomobject]@{}; web = [pscustomobject]@{} },
                [pscustomobject]@{ isFallbackPublicClient = 'false'; api = [pscustomobject]@{}; web = [pscustomobject]@{} },
                [pscustomobject]@{ api = [pscustomobject]@{ acceptMappedClaims = $true }; web = [pscustomobject]@{} },
                [pscustomobject]@{ api = [pscustomobject]@{ preAuthorizedApplications = @([pscustomobject]@{ appId = 'unreviewed' }) }; web = [pscustomobject]@{} },
                [pscustomobject]@{ api = [pscustomobject]@{ knownClientApplications = @('11111111-1111-4111-8111-111111111111') }; web = [pscustomobject]@{} },
                [pscustomobject]@{ api = [pscustomobject]@{}; web = [pscustomobject]@{ implicitGrantSettings = [pscustomobject]@{ enableAccessTokenIssuance = $true } } },
                [pscustomobject]@{ api = [pscustomobject]@{}; web = [pscustomobject]@{ implicitGrantSettings = [pscustomobject]@{ enableIdTokenIssuance = $true } } }
            )

            foreach ($application in $unsafeApplications) {
                { Assert-ExactApplicationAuthenticationSurface -Application $application -ApplicationLabel 'Unsafe application' } |
                    Should -Throw '*unapproved*'
            }
        }
    }
}

Describe 'Admin UI Gateway application-role contract' {
    InModuleScope Entra {
        BeforeEach {
            $script:roleOwnershipId = '33333333-3333-4333-8333-333333333333'
        }

        It 'derives the four canonical user-only roles from ownership and exact role-value casing' {
            $roles = @(Get-AdminUiGatewayApplicationRoles -DeploymentOwnershipId $script:roleOwnershipId)

            @($roles.value) | Should -Be @(
                'Administrator',
                'Operator',
                'Auditor',
                'Reader'
            )
            @($roles.id) | Should -Be @(
                '5be000b5-2e38-5fee-9318-f99718772d70',
                'd1e7fb82-c8d8-5529-b485-6a2d5df24a4a',
                'dab0436c-f9d4-5cee-b0ce-9a1fe90a705d',
                '147d6012-177a-5922-b516-5c0d5eabc650'
            )
            @($roles | Where-Object {
                $_.isEnabled -ne $true -or
                @($_.allowedMemberTypes).Count -ne 1 -or
                [string]$_.allowedMemberTypes[0] -cne 'User'
            }).Count | Should -Be 0
        }

        It 'rejects an extra role and deterministic identifier or canonical metadata drift' {
            $validRoles = @(Get-AdminUiGatewayApplicationRoles -DeploymentOwnershipId $script:roleOwnershipId)
            @(Assert-ExactAdminUiGatewayRoleContract `
                -AppRoles $validRoles `
                -DeploymentOwnershipId $script:roleOwnershipId).Count | Should -Be 4

            $extraRoles = @($validRoles) + @([pscustomobject]@{
                id = '99999999-9999-4999-8999-999999999999'
                displayName = 'Unapproved'
                description = 'Unapproved'
                value = 'Gateway.Unapproved'
                allowedMemberTypes = @('User')
                isEnabled = $true
            })
            { Assert-ExactAdminUiGatewayRoleContract `
                -AppRoles $extraRoles `
                -DeploymentOwnershipId $script:roleOwnershipId } |
                Should -Throw '*exactly the four canonical user-only Gateway roles*'

            foreach ($drift in @(
                [ordered]@{ property = 'id'; value = '88888888-8888-4888-8888-888888888888' },
                [ordered]@{ property = 'displayName'; value = 'Drifted role' },
                [ordered]@{ property = 'description'; value = 'Drifted description.' },
                [ordered]@{ property = 'value'; value = 'Gateway.Administrator' },
                [ordered]@{ property = 'allowedMemberTypes'; value = @('Application') },
                [ordered]@{ property = 'isEnabled'; value = $false }
            )) {
                $driftedRoles = @($validRoles | ForEach-Object {
                    [pscustomobject]@{
                        id = [string]$_.id
                        displayName = [string]$_.displayName
                        description = [string]$_.description
                        value = [string]$_.value
                        allowedMemberTypes = @($_.allowedMemberTypes)
                        isEnabled = $_.isEnabled
                    }
                })
                $driftedRoles[0].PSObject.Properties[[string]$drift.property].Value = $drift.value

                { Assert-ExactAdminUiGatewayRoleContract `
                    -AppRoles $driftedRoles `
                    -DeploymentOwnershipId $script:roleOwnershipId } |
                    Should -Throw '*exactly the four canonical user-only Gateway roles*'
            }
        }

        It 'wires the owner-only Administrator assignment into the Admin UI service-principal boundary' {
            $tokens = $null
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile(
                (Get-Module Entra).Path, [ref]$tokens, [ref]$errors)
            $errors.Count | Should -Be 0
            $function = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq 'Ensure-AdminUiApplication'
            }, $true).Extent.Text

            $function | Should -Match 'appRoles = \$expectedRoles'
            $function | Should -Match 'ExpectedAppRoleAssigneePrincipalId = \[string\]\$Identity\.userObjectId'
            $function | Should -Match 'ExpectedAppRoleId = \[string\]\$adminRole\[0\]\.id'
            $function | Should -Match '/appRoleAssignedTo'
            $function | Should -Not -Match 'gatewayApiServicePrincipalId.+appRoleAssignedTo'
        }
    }
}

Describe 'Exact Gateway-owned service-principal boundary' {
    InModuleScope Entra {
        BeforeEach {
            $script:servicePrincipalId = '11111111-1111-4111-8111-111111111111'
            $script:applicationId = '22222222-2222-4222-8222-222222222222'
            $script:operatorId = '33333333-3333-4333-8333-333333333333'
            $script:roleId = '44444444-4444-4444-8444-444444444444'
            $script:collectionValues = @{
                owners = @()
                transitiveMemberOf = @()
                appRoleAssignments = @()
                appRoleAssignedTo = @([pscustomobject]@{
                    principalId = $script:operatorId
                    resourceId = $script:servicePrincipalId
                    appRoleId = $script:roleId
                })
            }
            $script:servicePrincipal = [pscustomobject]@{
                id = $script:servicePrincipalId
                appId = $script:applicationId
                accountEnabled = $true
                appRoleAssignmentRequired = $false
                servicePrincipalType = 'Application'
                servicePrincipalNames = @($script:applicationId, 'api://a365-gateway-safe-dev')
                tags = @('A365GatewayBootstrap', 'A365GatewayOwnership:55555555-5555-4555-8555-555555555555')
                alternativeNames = @()
                passwordCredentials = @()
                keyCredentials = @()
                appRoles = @([pscustomobject]@{
                    id = $script:roleId
                    value = 'Gateway.Administrator'
                    isEnabled = $true
                    allowedMemberTypes = @('User')
                })
                oauth2PermissionScopes = @([pscustomobject]@{
                    id = '66666666-6666-4666-8666-666666666666'
                    value = 'access_as_user'
                    isEnabled = $true
                    type = 'Admin'
                })
            }
            $script:expectedAppRoles = @($script:servicePrincipal.appRoles)
            $script:expectedOauth2PermissionScopes = @($script:servicePrincipal.oauth2PermissionScopes)
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                $url = [string]$Arguments[$Arguments.Count - 1]
                foreach ($collectionName in @('owners', 'transitiveMemberOf', 'appRoleAssignments', 'appRoleAssignedTo')) {
                    if ($url -match "/$collectionName(?:\?|$)") {
                        return [pscustomobject]@{ value = @($script:collectionValues[$collectionName]) }
                    }
                }
                throw "Unexpected Graph collection URL: $url"
            }

            $script:exactServicePrincipalAssertion = {
                Assert-ExactBootstrapServicePrincipalBoundary `
                -ServicePrincipal $script:servicePrincipal `
                -ExpectedId $script:servicePrincipalId `
                -ExpectedAppId $script:applicationId `
                -ServicePrincipalLabel 'Gateway API service principal' `
                -ExpectedServicePrincipalNames @($script:applicationId, 'api://a365-gateway-safe-dev') `
                -ExpectedTags @('A365GatewayBootstrap', 'A365GatewayOwnership:55555555-5555-4555-8555-555555555555') `
                -ExpectedAppRoles $script:expectedAppRoles `
                -ExpectedOauth2PermissionScopes $script:expectedOauth2PermissionScopes `
                -ExpectedAppRoleAssigneePrincipalId $script:operatorId `
                -ExpectedAppRoleId $script:roleId
            }
        }

        It 'accepts only the exact enabled credential-free, unowned, membership-free service principal' {
            (& $script:exactServicePrincipalAssertion).appRoleAssignedTo.Count | Should -Be 1
        }

        It 'rejects service-principal credentials and locally exposed permissions' {
            $script:servicePrincipal.passwordCredentials = @([pscustomobject]@{ keyId = 'unapproved' })
            { & $script:exactServicePrincipalAssertion } | Should -Throw '*must not contain service-principal credentials*'

            $script:servicePrincipal.passwordCredentials = @()
            $script:servicePrincipal.appRoles += [pscustomobject]@{
                id = '77777777-7777-4777-8777-777777777777'
                value = 'Unapproved.Role'
                isEnabled = $true
                allowedMemberTypes = @('Application')
            }
            { & $script:exactServicePrincipalAssertion } | Should -Throw '*unapproved service-principal-local permission*'
        }

        It 'rejects owners, transitive memberships, client assignments, and extra Gateway-role assignees' {
            foreach ($boundary in @(
                [ordered]@{ collection = 'owners'; expectedMessage = '*must not have service-principal owners*' },
                [ordered]@{ collection = 'transitiveMemberOf'; expectedMessage = '*must not have group or directory-role memberships*' },
                [ordered]@{ collection = 'appRoleAssignments'; expectedMessage = '*must not have client application-role assignments*' }
            )) {
                $script:collectionValues[$boundary.collection] = @([pscustomobject]@{ id = 'unapproved' })
                { & $script:exactServicePrincipalAssertion } | Should -Throw $boundary.expectedMessage
                $script:collectionValues[$boundary.collection] = @()
            }

            $script:collectionValues.appRoleAssignedTo += [pscustomobject]@{
                principalId = '88888888-8888-4888-8888-888888888888'
                resourceId = $script:servicePrincipalId
                appRoleId = $script:roleId
            }
            { & $script:exactServicePrincipalAssertion } | Should -Throw '*outside the exact reviewed boundary*'
        }

        It 'requires the complete service-principal selector instead of treating omitted arrays as empty' {
            $script:servicePrincipal.PSObject.Properties.Remove('keyCredentials')

            { & $script:exactServicePrincipalAssertion } | Should -Throw '*credential absence was not proven*'
        }
    }
}

Describe 'Workload Entra pre-mutation authority boundary' {
    InModuleScope Entra {
        BeforeEach {
            $script:graphPrincipalId = '11111111-1111-4111-8111-111111111111'
            $script:assignments = @()
            Mock Get-GraphPermissionCatalog {
                return [ordered]@{
                    servicePrincipal = [pscustomobject]@{ id = $script:graphPrincipalId }
                }
            }
            Mock Get-UniqueGraphPermissionId {
                param($Graph, [string]$Value, [string]$Type)
                return "id-$Value"
            }
            Mock Invoke-AzJson {
                return [pscustomobject]@{ value = @($script:assignments) }
            }
        }

        It 'allows only a duplicate-free subset of the reviewed roles before mutation' {
            $script:assignments = @([pscustomobject]@{
                resourceId = $script:graphPrincipalId
                appRoleId = 'id-AgentIdentity.Read.All'
            })

            Assert-GraphApplicationRoleAssignmentBoundary `
                -PrincipalId '22222222-2222-4222-8222-222222222222' `
                -ExpectedRoleValues @('AgentIdentity.Read.All', 'AgentIdentity.Create.All') |
                Should -BeTrue
        }

        It 'rejects an unknown application role before adding a missing reviewed role' {
            $script:assignments = @([pscustomobject]@{
                resourceId = $script:graphPrincipalId
                appRoleId = 'id-Unreviewed.Role'
            })

            { Assert-GraphApplicationRoleAssignmentBoundary `
                -PrincipalId '22222222-2222-4222-8222-222222222222' `
                -ExpectedRoleValues @('AgentIdentity.Read.All') } |
                Should -Throw '*outside the exact reviewed*'
        }

        It 'proves a persistent infrastructure identity has exactly zero application-role assignments' {
            Assert-ExactGraphApplicationRoleAssignments `
                -PrincipalId '22222222-2222-4222-8222-222222222222' `
                -ExpectedRoleValues @() |
                Should -BeTrue

            $script:assignments = @([pscustomobject]@{
                resourceId = $script:graphPrincipalId
                appRoleId = 'id-Unreviewed.Role'
            })
            { Assert-ExactGraphApplicationRoleAssignments `
                -PrincipalId '22222222-2222-4222-8222-222222222222' `
                -ExpectedRoleValues @() } |
                Should -Throw '*outside the exact reviewed*'
        }

        It 'rejects an unknown application role returned only on a continuation page' {
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                $url = [string]$Arguments[$Arguments.Count - 1]
                if ($url -match 'second-role-page') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{
                        resourceId = $script:graphPrincipalId
                        appRoleId = 'id-Unreviewed.Role'
                    }) }
                }
                return [pscustomobject]@{
                    value = @([pscustomobject]@{
                        resourceId = $script:graphPrincipalId
                        appRoleId = 'id-AgentIdentity.Read.All'
                    })
                    '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/servicePrincipals/22222222-2222-4222-8222-222222222222/appRoleAssignments?$skiptoken=second-role-page'
                }
            }

            { Assert-GraphApplicationRoleAssignmentBoundary `
                -PrincipalId '22222222-2222-4222-8222-222222222222' `
                -ExpectedRoleValues @('AgentIdentity.Read.All') } |
                Should -Throw '*outside the exact reviewed*'
        }

        It 'rejects an unreviewed delegated grant returned only on a continuation page' {
            $identity = [pscustomobject]@{
                gatewayApiApplicationObjectId = '33333333-3333-4333-8333-333333333333'
                gatewayApiClientId = '44444444-4444-4444-8444-444444444444'
                gatewayApiServicePrincipalId = '55555555-5555-4555-8555-555555555555'
            }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)
                $url = [string]$Arguments[$Arguments.Count - 1]
                if ($url -match '/applications/') {
                    return [pscustomobject]@{
                        appId = $identity.gatewayApiClientId
                        requiredResourceAccess = @()
                        passwordCredentials = @()
                        keyCredentials = @()
                        web = [pscustomobject]@{ redirectUris = @(); logoutUrl = $null; homePageUrl = $null }
                        spa = [pscustomobject]@{ redirectUris = @() }
                        publicClient = [pscustomobject]@{ redirectUris = @() }
                        api = [pscustomobject]@{ preAuthorizedApplications = @(); knownClientApplications = @(); acceptMappedClaims = $false }
                        isFallbackPublicClient = $false
                    }
                }
                if ($url -match 'second-grant-page') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{
                        resourceId = '99999999-9999-4999-8999-999999999999'
                        consentType = 'AllPrincipals'
                        scope = 'AgentRegistration.Read.All'
                    }) }
                }
                return [pscustomobject]@{
                    value = @()
                    '@odata.nextLink' = "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$skiptoken=second-grant-page"
                }
            }

            { Assert-GatewayApiDelegatedPermissionBoundary -Identity $identity } |
                Should -Throw '*outside the exact tenant-wide*'
        }

        It 'allows an empty FIC collection but rejects any extra credential before mutation' {
            $config = [pscustomobject]@{
                projectName = 'safe'
                environment = 'dev'
                tenantId = '33333333-3333-4333-8333-333333333333'
            }
            $identity = [pscustomobject]@{
                gatewayApiApplicationObjectId = '44444444-4444-4444-8444-444444444444'
            }
            $apiPrincipalId = '55555555-5555-4555-8555-555555555555'

            Assert-GatewayFederatedCredentialBoundary `
                -Config $config -Identity $identity -ApiPrincipalId $apiPrincipalId -AllowMissing |
                Should -BeTrue

            $script:assignments = @(
                [pscustomobject]@{
                    name = 'a365gw-safe-api-obo-dev'
                    issuer = 'https://login.microsoftonline.com/33333333-3333-4333-8333-333333333333/v2.0'
                    subject = $apiPrincipalId
                    audiences = @('api://AzureADTokenExchange')
                },
                [pscustomobject]@{
                    name = 'unreviewed-extra'
                    issuer = 'https://login.microsoftonline.com/33333333-3333-4333-8333-333333333333/v2.0'
                    subject = $apiPrincipalId
                    audiences = @('api://AzureADTokenExchange')
                }
            )

            { Assert-GatewayFederatedCredentialBoundary `
                -Config $config -Identity $identity -ApiPrincipalId $apiPrincipalId -AllowMissing } |
                Should -Throw '*empty-or-one exact*'
        }
    }
}

Describe 'Admin UI one-time credential role boundary' {
    InModuleScope Entra {
        BeforeEach {
            $script:testSubscriptionId = '11111111-1111-4111-8111-111111111111'
            $script:testResourceGroup = 'rg-gwtest-dev'
            $script:testPrincipalId = '22222222-2222-4222-8222-222222222222'
            $script:testApplicationObjectId = '33333333-3333-4333-8333-333333333333'
            $script:testCredentialKeyId = '44444444-4444-4444-8444-444444444444'
            $script:testAdminClientId = '55555555-5555-4555-8555-555555555555'
            $script:testDeploymentOwnershipId = '77777777-7777-4777-8777-777777777777'
            $script:testSourceFingerprint = "sha256:$('a' * 64)"
            $script:invokeTestAdminUiCredentialCreate = {
                param($Config, $AdminIdentity, [string]$KeyVaultUri, [string]$UserObjectId)
                $arguments = @{
                    Config = $Config
                    AdminIdentity = $AdminIdentity
                    KeyVaultUri = $KeyVaultUri
                }
                $command = Get-Command New-AdminUiCredentialInKeyVault -CommandType Function
                if ($command.Parameters.ContainsKey('UserObjectId')) {
                    $arguments.UserObjectId = $UserObjectId
                }
                if ($command.Parameters.ContainsKey('DeploymentOwnershipId')) {
                    $arguments.DeploymentOwnershipId = $script:testDeploymentOwnershipId
                }
                if ($command.Parameters.ContainsKey('SourceFingerprint')) {
                    $arguments.SourceFingerprint = $script:testSourceFingerprint
                }
                return New-AdminUiCredentialInKeyVault @arguments
            }
            $script:invokeTestAdminUiCredentialResolve = {
                param($Config, $AdminIdentity, [string]$KeyVaultUri, [string]$UserObjectId)
                $arguments = @{
                    Config = $Config
                    AdminIdentity = $AdminIdentity
                    KeyVaultUri = $KeyVaultUri
                    UserObjectId = $UserObjectId
                }
                $command = Get-Command Resolve-AdminUiCredentialAfterStartedOutcome -CommandType Function
                if ($command.Parameters.ContainsKey('DeploymentOwnershipId')) {
                    $arguments.DeploymentOwnershipId = $script:testDeploymentOwnershipId
                }
                if ($command.Parameters.ContainsKey('SourceFingerprint')) {
                    $arguments.SourceFingerprint = $script:testSourceFingerprint
                }
                return Resolve-AdminUiCredentialAfterStartedOutcome @arguments
            }
            $script:testScope = "/subscriptions/$script:testSubscriptionId/resourceGroups/$script:testResourceGroup/providers/Microsoft.KeyVault/vaults/kv-gwtest-dev"
            $script:testRoleDefinitionId = "/subscriptions/$script:testSubscriptionId/providers/Microsoft.Authorization/roleDefinitions/b86a8fe4-44ce-4948-aee5-eccb2c155cd7"
            $script:assignmentRoleDefinitionId = $script:testRoleDefinitionId
            $script:testAssignmentName = Get-BootstrapDeterministicRoleAssignmentName -Scope $script:testScope -PrincipalId $script:testPrincipalId
            $script:testAssignmentId = "$script:testScope/providers/Microsoft.Authorization/roleAssignments/$script:testAssignmentName"
            $script:assignmentExists = $false
            $script:deleteRemovesAssignment = $true
            $script:createCount = 0
            $script:createArguments = @()
            $script:deleteArguments = @()
            $script:bootstrapCredentialExists = $true
            $script:vaultMetadataExists = $true
            $script:vaultCredentialKeyId = $script:testCredentialKeyId
            $script:putFailsAfterCommit = $false
            $script:putCount = 0
            $script:roleListCount = 0
            $script:accessTokenCount = 0
            $script:dataPlaneCallCount = 0
            $script:armDeploymentCount = 0
            $script:armTemplateFile = ''
            $script:armParameters = $null
            $script:armDeploymentFailsAfterCommit = $false
            $script:armMetadataReadCount = 0
            $script:armMetadataPresentFromRead = 0

            if (-not (Get-Command Get-GatewayAdminUiCredentialSecretArmMetadata -ErrorAction SilentlyContinue)) {
                function Get-GatewayAdminUiCredentialSecretArmMetadata {
                    param($Config, [string]$KeyVaultUri, [string]$DeploymentOwnershipId, [string]$SourceFingerprint)
                    throw 'Synthetic ARM metadata helper must be mocked.'
                }
            }
            if (-not (Get-Command Deploy-GatewayAdminUiCredentialSecret -ErrorAction SilentlyContinue)) {
                function Deploy-GatewayAdminUiCredentialSecret {
                    param(
                        $Config,
                        [string]$KeyVaultUri,
                        [string]$CredentialKeyId,
                        [string]$SecretText,
                        [string]$DeploymentOwnershipId,
                        [string]$SourceFingerprint
                    )
                    throw 'Synthetic ARM deployment helper must be mocked.'
                }
            }

            Mock Start-Sleep { }
            Mock Invoke-RestMethod {
                param($Method, [string]$Uri, $Headers, $Body)
                $script:dataPlaneCallCount++
                if ([string]$Method -eq 'Put') {
                    $script:putCount++
                    $script:vaultMetadataExists = $true
                    if ($script:putFailsAfterCommit) {
                        throw 'Synthetic lost Key Vault response.'
                    }
                    return [pscustomobject]@{
                        id = 'https://kv-gwtest-dev.vault.azure.net/secrets/admin-ui-entra-client-secret/version-one'
                        attributes = [pscustomobject]@{ enabled = $true }
                        tags = [pscustomobject]@{ credentialKeyId = $script:vaultCredentialKeyId; managedBy = 'a365gw-bootstrap' }
                    }
                }
                $metadataValues = @()
                if ($script:vaultMetadataExists) {
                    $metadataValues = @([pscustomobject]@{
                        id = 'https://kv-gwtest-dev.vault.azure.net/secrets/admin-ui-entra-client-secret/version-one'
                        attributes = [pscustomobject]@{ enabled = $true }
                        tags = [pscustomobject]@{ credentialKeyId = $script:vaultCredentialKeyId; managedBy = 'a365gw-bootstrap' }
                    })
                }
                return [pscustomobject]@{ value = $metadataValues }
            }
            Mock Get-GatewayAdminUiCredentialSecretArmMetadata {
                param(
                    $Config,
                    [string]$KeyVaultUri,
                    [string]$DeploymentOwnershipId,
                    [string]$SourceFingerprint
                )
                $script:armMetadataReadCount++
                $metadataPresent = $script:vaultMetadataExists -or
                    ($script:armMetadataPresentFromRead -gt 0 -and
                        $script:armMetadataReadCount -ge $script:armMetadataPresentFromRead)
                if (-not $metadataPresent) {
                    return [pscustomobject]@{ status = 'Absent' }
                }
                return [pscustomobject]@{
                    status = 'Present'
                    id = "$script:testScope/secrets/admin-ui-entra-client-secret"
                    name = 'admin-ui-entra-client-secret'
                    enabled = $true
                    contentType = 'application/vnd.a365-gateway.admin-ui-entra-client-secret'
                    tags = [pscustomobject]@{
                        managedBy = 'a365gw-bootstrap'
                        credentialKeyId = $script:vaultCredentialKeyId
                        bootstrapOwnershipId = $script:testDeploymentOwnershipId
                        bootstrapSourceFingerprint = $script:testSourceFingerprint
                    }
                }
            }
            Mock Deploy-GatewayAdminUiCredentialSecret {
                param(
                    $Config,
                    [string]$KeyVaultUri,
                    [string]$CredentialKeyId,
                    [string]$SecretText,
                    [string]$DeploymentOwnershipId,
                    [string]$SourceFingerprint
                )
                $script:armDeploymentCount++
                $script:armTemplateFile = Join-Path $script:RepositoryRoot 'bootstrap/infra/admin-ui-credential.bicep'
                $script:armParameters = [ordered]@{
                    secretValue = $SecretText
                    credentialKeyId = $CredentialKeyId
                    bootstrapOwnershipId = $DeploymentOwnershipId
                    bootstrapSourceFingerprint = $SourceFingerprint
                }
                $script:vaultMetadataExists = $true
                $script:vaultCredentialKeyId = $CredentialKeyId
                if ($script:armDeploymentFailsAfterCommit) {
                    throw 'Synthetic lost ARM deployment response.'
                }
                return [pscustomobject]@{
                    status = 'Present'
                    id = "$script:testScope/secrets/admin-ui-entra-client-secret"
                    name = 'admin-ui-entra-client-secret'
                    enabled = $true
                    contentType = 'application/vnd.a365-gateway.admin-ui-entra-client-secret'
                    tags = [pscustomobject]@{
                        managedBy = 'a365gw-bootstrap'
                        credentialKeyId = $CredentialKeyId
                        bootstrapOwnershipId = $DeploymentOwnershipId
                        bootstrapSourceFingerprint = $SourceFingerprint
                    }
                }
            }
            Mock Invoke-AzJson {
                param([string[]]$Arguments)

                $command = $Arguments -join ' '
                if ($command -match '^role assignment list ' -and $Arguments -contains '--assignee-object-id') {
                    if ($script:assignmentExists) {
                        return [pscustomobject]@{ id = $script:testAssignmentId }
                    }
                    return @()
                }
                if ($command -match '^role assignment list ') {
                    if ($script:assignmentExists) {
                        return [pscustomobject]@{
                            id = $script:testAssignmentId
                            principalId = $script:testPrincipalId
                            scope = $script:testScope
                            roleDefinitionId = $script:assignmentRoleDefinitionId
                        }
                    }
                    return @()
                }
                if ($command -match '^role assignment create ') {
                    $script:createCount++
                    $script:createArguments = @($Arguments)
                    $script:assignmentExists = $true
                    return [pscustomobject]@{
                        id = $script:testAssignmentId
                        principalId = $script:testPrincipalId
                        scope = $script:testScope
                        roleDefinitionId = $script:testRoleDefinitionId
                    }
                }
                if ($command -match '^account get-access-token ') {
                    $script:accessTokenCount++
                    return [pscustomobject]@{ accessToken = "private-test-access-token-$($script:accessTokenCount)" }
                }
                if ($command -match 'graph\.microsoft\.com/v1\.0/applications/') {
                    return [pscustomobject]@{
                        appId = $script:testAdminClientId
                        passwordCredentials = if ($script:bootstrapCredentialExists) { @([pscustomobject]@{
                            displayName = 'a365gw-bootstrap-admin-ui'
                            keyId = $script:testCredentialKeyId
                            endDateTime = '2027-08-29T00:00:00Z'
                        }) } else { @() }
                    }
                }
                if ($command -match '^resource show ') {
                    if (-not $script:vaultMetadataExists) {
                        throw 'Synthetic Key Vault ARM secret metadata not found.'
                    }
                    return [pscustomobject]@{
                        id = "$script:testScope/secrets/admin-ui-entra-client-secret"
                        name = 'admin-ui-entra-client-secret'
                        enabled = $true
                        tags = [pscustomobject]@{
                            credentialKeyId = $script:vaultCredentialKeyId
                            managedBy = 'a365gw-bootstrap'
                        }
                    }
                }
                throw "Unexpected mocked Azure call category: $($Arguments[0..2] -join ' ')"
            }
            Mock Invoke-BootstrapCommand {
                param(
                    [string]$FilePath,
                    [string[]]$ArgumentList,
                    [switch]$AllowFailure,
                    [switch]$NoCapture
                )
                if ($ArgumentList[0] -eq 'role' -and $ArgumentList[1] -eq 'assignment' -and $ArgumentList[2] -eq 'list') {
                    $script:roleListCount++
                    if (-not $script:assignmentExists) { return '[]' }
                    $roleEvidence = if ($ArgumentList -contains '--assignee-object-id') {
                        [ordered]@{ id = $script:testAssignmentId; roleDefinitionId = $script:assignmentRoleDefinitionId }
                    }
                    else {
                        [ordered]@{
                            id = $script:testAssignmentId
                            principalId = $script:testPrincipalId
                            scope = $script:testScope
                            roleDefinitionId = $script:assignmentRoleDefinitionId
                        }
                    }
                    return ConvertTo-Json -InputObject @($roleEvidence) -Compress
                }
                $script:deleteArguments = @($ArgumentList)
                if ($script:deleteRemovesAssignment) {
                    $script:assignmentExists = $false
                }
                return 0
            }
        }

        It 'derives a stable project-bound assignment name' {
            $first = Get-BootstrapDeterministicRoleAssignmentName -Scope $script:testScope -PrincipalId $script:testPrincipalId
            $same = Get-BootstrapDeterministicRoleAssignmentName -Scope $script:testScope.ToUpperInvariant() -PrincipalId $script:testPrincipalId.ToUpperInvariant()
            $different = Get-BootstrapDeterministicRoleAssignmentName -Scope "$script:testScope-other" -PrincipalId $script:testPrincipalId

            $first | Should -Match '^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
            $same | Should -Be $first
            $different | Should -Not -Be $first
        }

        It 'distinguishes a proven empty Azure JSON array from empty or non-array output' {
            Mock Invoke-BootstrapCommand { return '[]' }
            @(Invoke-AzJsonArray -Arguments @('role', 'assignment', 'list') -OperationLabel 'Test role list').Count |
                Should -Be 0

            Mock Invoke-BootstrapCommand { return '' }
            { Invoke-AzJsonArray -Arguments @('role', 'assignment', 'list') -OperationLabel 'Test role list' } |
                Should -Throw '*absence was not proven*'

            Mock Invoke-BootstrapCommand { return '{}' }
            { Invoke-AzJsonArray -Arguments @('role', 'assignment', 'list') -OperationLabel 'Test role list' } |
                Should -Throw '*non-array JSON contract*'
        }

        It 'requires consecutive exact absence reads before temporary role cleanup is complete' {
            $script:assignmentExists = $false
            $script:roleListCount = 0

            Wait-ExactBootstrapRoleAssignmentAbsent `
                -Scope $script:testScope `
                -AssignmentId $script:testAssignmentId `
                -PrincipalId $script:testPrincipalId `
                -RoleDefinitionId $script:testRoleDefinitionId |
                Should -BeTrue

            $script:roleListCount | Should -Be 3
        }

        It 'removes only the exact legacy temporary assignment during Resume and proves absence' {
            $config = [pscustomobject]@{
                subscriptionId = $script:testSubscriptionId
                resourceGroupName = $script:testResourceGroup
            }
            $adminIdentity = [pscustomobject]@{
                adminUiApplicationObjectId = $script:testApplicationObjectId
                adminUiClientId = $script:testAdminClientId
                deploymentOwnershipId = $script:testDeploymentOwnershipId
            }
            $script:assignmentExists = $true

            $result = & $script:invokeTestAdminUiCredentialResolve `
                -Config $config `
                -AdminIdentity $adminIdentity `
                -KeyVaultUri 'https://kv-gwtest-dev.vault.azure.net/' `
                -UserObjectId $script:testPrincipalId

            $result.credentialKeyId | Should -Be $script:testCredentialKeyId
            $script:createCount | Should -Be 0
            $script:assignmentExists | Should -BeFalse
            $script:deleteArguments | Should -Be @(
                'role', 'assignment', 'delete', '--ids', $script:testAssignmentId, '--only-show-errors'
            )
        }

        It 'uses one secure ARM child-secret deployment for a private vault without local vault authority or secret output' {
            $config = [pscustomobject]@{
                subscriptionId = $script:testSubscriptionId
                resourceGroupName = $script:testResourceGroup
            }
            $adminIdentity = [pscustomobject]@{
                adminUiApplicationObjectId = $script:testApplicationObjectId
                adminUiClientId = $script:testAdminClientId
                deploymentOwnershipId = $script:testDeploymentOwnershipId
            }
            $script:bootstrapCredentialExists = $false
            $script:vaultMetadataExists = $false
            $script:graphMutationCount = 0
            $script:syntheticSecretValue = 'private-one-time-test-value'
            $script:armDeploymentFailsAfterCommit = $true
            $script:armMetadataPresentFromRead = 2
            Mock Invoke-GraphJsonBody {
                $script:graphMutationCount++
                $script:bootstrapCredentialExists = $true
                return [pscustomobject]@{
                    keyId = $script:testCredentialKeyId
                    secretText = $script:syntheticSecretValue
                }
            }

            $output = @(& $script:invokeTestAdminUiCredentialCreate `
                -Config $config `
                -AdminIdentity $adminIdentity `
                -KeyVaultUri 'https://kv-gwtest-dev.vault.azure.net/' `
                -UserObjectId $script:testPrincipalId)

            $output.Count | Should -Be 1
            $output[0].credentialKeyId | Should -Be $script:testCredentialKeyId
            ($output | ConvertTo-Json -Depth 20 -Compress) |
                Should -Not -Match ([regex]::Escape($script:syntheticSecretValue))
            $script:armDeploymentCount | Should -Be 1
            $script:graphMutationCount | Should -Be 1
            $script:dataPlaneCallCount | Should -Be 0
            $script:putCount | Should -Be 0
            $script:accessTokenCount | Should -Be 0
            $script:createCount | Should -Be 0
            $script:roleListCount | Should -Be 0
            $script:deleteArguments.Count | Should -Be 0

            Should -Invoke Deploy-GatewayAdminUiCredentialSecret -Times 1 -Exactly -ParameterFilter {
                $CredentialKeyId -ceq $script:testCredentialKeyId -and
                $SecretText -ceq $script:syntheticSecretValue -and
                $DeploymentOwnershipId -ceq $script:testDeploymentOwnershipId -and
                $SourceFingerprint -ceq $script:testSourceFingerprint
            }
            $moduleDirectory = Split-Path -Parent (Get-Module Entra).Path
            $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $moduleDirectory '../..'))
            $templateFile = Join-Path $repositoryRoot 'bootstrap/infra/admin-ui-credential.bicep'
            $templateSource = Get-Content -LiteralPath $templateFile -Raw
            $templateSource | Should -Match "(?s)@secure\(\)\s*(?:@minLength\(\d+\)\s*)*param\s+secretValue\s+string"
            $templateSource | Should -Match "'(?:Microsoft\.KeyVault/vaults/)?secrets@2023-07-01'"
            $templateSource | Should -Match "var\s+secretContentType\s*=\s*'application/vnd\.a365-gateway\.admin-ui-entra-client-secret'"
            $templateSource | Should -Match 'contentType:\s*secretContentType'
            foreach ($requiredTag in @('managedBy', 'credentialKeyId', 'bootstrapOwnershipId', 'bootstrapSourceFingerprint')) {
                $templateSource | Should -Match "(?m)^\s*$requiredTag\s*:"
            }
            $templateSource | Should -Not -Match '(?im)^\s*output\s+\w+\s+\w+\s*=\s*secretValue\s*$'
        }

        It 'rejects a legacy deterministic temporary assignment bound to any other role definition ID during Resume' {
            $config = [pscustomobject]@{
                subscriptionId = $script:testSubscriptionId
                resourceGroupName = $script:testResourceGroup
            }
            $adminIdentity = [pscustomobject]@{
                adminUiApplicationObjectId = $script:testApplicationObjectId
                adminUiClientId = $script:testAdminClientId
                deploymentOwnershipId = $script:testDeploymentOwnershipId
            }
            $script:assignmentExists = $true
            $script:assignmentRoleDefinitionId = "/subscriptions/$script:testSubscriptionId/providers/Microsoft.Authorization/roleDefinitions/99999999-9999-4999-8999-999999999999"

            { & $script:invokeTestAdminUiCredentialResolve `
                -Config $config `
                -AdminIdentity $adminIdentity `
                -KeyVaultUri 'https://kv-gwtest-dev.vault.azure.net/' `
                -UserObjectId $script:testPrincipalId } |
                Should -Throw '*different authority*'
        }

        It 'retries one fresh credential transfer on Resume after cleanup and exact provider absence' {
            $config = [pscustomobject]@{
                subscriptionId = $script:testSubscriptionId
                resourceGroupName = $script:testResourceGroup
            }
            $adminIdentity = [pscustomobject]@{
                adminUiApplicationObjectId = $script:testApplicationObjectId
                adminUiClientId = $script:testAdminClientId
                deploymentOwnershipId = $script:testDeploymentOwnershipId
            }
            $script:assignmentExists = $true
            $script:bootstrapCredentialExists = $false
            $script:vaultMetadataExists = $false
            $script:graphMutationCount = 0
            $script:armMetadataPresentFromRead = 5
            Mock Invoke-GraphJsonBody {
                $script:graphMutationCount++
                $script:bootstrapCredentialExists = $true
                return [pscustomobject]@{
                    keyId = $script:testCredentialKeyId
                    secretText = 'private-one-time-test-value'
                }
            }

            $result = & $script:invokeTestAdminUiCredentialResolve `
                -Config $config `
                -AdminIdentity $adminIdentity `
                -KeyVaultUri 'https://kv-gwtest-dev.vault.azure.net/' `
                -UserObjectId $script:testPrincipalId

            $result.credentialKeyId | Should -Be $script:testCredentialKeyId
            $script:graphMutationCount | Should -Be 1
            $script:armDeploymentCount | Should -Be 1
            $script:putCount | Should -Be 0
            $script:createCount | Should -Be 0
            $script:assignmentExists | Should -BeFalse
        }

        It 'fails closed on partial or mismatched Resume evidence without Graph or secret mutation' {
            $config = [pscustomobject]@{
                subscriptionId = $script:testSubscriptionId
                resourceGroupName = $script:testResourceGroup
            }
            $adminIdentity = [pscustomobject]@{
                adminUiApplicationObjectId = $script:testApplicationObjectId
                adminUiClientId = $script:testAdminClientId
                deploymentOwnershipId = $script:testDeploymentOwnershipId
            }

            foreach ($scenario in @(
                @{ credentialExists = $true; vaultExists = $false; vaultKeyId = $script:testCredentialKeyId },
                @{ credentialExists = $false; vaultExists = $true; vaultKeyId = $script:testCredentialKeyId },
                @{ credentialExists = $true; vaultExists = $true; vaultKeyId = '66666666-6666-4666-8666-666666666666' }
            )) {
                $script:assignmentExists = $true
                $script:bootstrapCredentialExists = $scenario.credentialExists
                $script:vaultMetadataExists = $scenario.vaultExists
                $script:vaultCredentialKeyId = $scenario.vaultKeyId
                $script:graphMutationCount = 0
                $script:putCount = 0
                $script:armDeploymentCount = 0
                Mock Invoke-GraphJsonBody {
                    $script:graphMutationCount++
                    return [pscustomobject]@{
                        keyId = $script:testCredentialKeyId
                        secretText = 'private-one-time-test-value'
                    }
                }

                { & $script:invokeTestAdminUiCredentialResolve `
                    -Config $config `
                    -AdminIdentity $adminIdentity `
                    -KeyVaultUri 'https://kv-gwtest-dev.vault.azure.net/' `
                    -UserObjectId $script:testPrincipalId } |
                    Should -Throw

                $script:graphMutationCount | Should -Be 0
                $script:putCount | Should -Be 0
                $script:armDeploymentCount | Should -Be 0
            }
        }

        It 'fails closed on unproven cleanup and Resume adopts then removes the exact assignment' {
            $config = [pscustomobject]@{
                subscriptionId = $script:testSubscriptionId
                resourceGroupName = $script:testResourceGroup
            }
            $adminIdentity = [pscustomobject]@{
                adminUiApplicationObjectId = $script:testApplicationObjectId
                adminUiClientId = $script:testAdminClientId
                deploymentOwnershipId = $script:testDeploymentOwnershipId
            }
            $script:assignmentExists = $true
            $script:deleteRemovesAssignment = $false

            try {
                & $script:invokeTestAdminUiCredentialResolve `
                    -Config $config `
                    -AdminIdentity $adminIdentity `
                    -KeyVaultUri 'https://kv-gwtest-dev.vault.azure.net/' `
                    -UserObjectId $script:testPrincipalId
                throw 'Expected cleanup verification to fail.'
            }
            catch {
                $_.Exception.Message | Should -BeLike '*could not be proven removed*'
                $_.Exception.Message | Should -Not -Match 'private-test-access-token'
            }

            $script:assignmentExists | Should -BeTrue
            $script:createCount | Should -Be 0

            $script:deleteRemovesAssignment = $true
            $result = & $script:invokeTestAdminUiCredentialResolve `
                -Config $config `
                -AdminIdentity $adminIdentity `
                -KeyVaultUri 'https://kv-gwtest-dev.vault.azure.net/' `
                -UserObjectId $script:testPrincipalId

            $result.credentialKeyId | Should -Be $script:testCredentialKeyId
            $script:createCount | Should -Be 0
            $script:assignmentExists | Should -BeFalse
        }
    }
}
