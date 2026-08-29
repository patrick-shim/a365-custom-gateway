$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Agent365.psm1') -Force

Describe 'Agent 365 typed blueprint paging' {
    InModuleScope Agent365 {
        BeforeEach {
            $script:pageCalls = 0
            $script:reviewedManagerId = '33333333-3333-4333-8333-333333333333'
            $script:ownerId = '55555555-5555-4555-8555-555555555555'
            $script:ownershipId = '66666666-6666-4666-8666-666666666666'
            $script:sourceFingerprint = "sha256:$('a' * 64)"
            $script:config = [pscustomobject]@{
                tenantId = '77777777-7777-4777-8777-777777777777'
                agent365 = [pscustomobject]@{
                    seedBlueprintName = 'Reviewed'
                    reviewedManagerApplicationIds = @($script:reviewedManagerId)
                }
            }
            $script:displayName = Get-Agent365SeedBlueprintDisplayName `
                -Config $script:config `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint
            $script:blueprint = [pscustomobject]@{
                id = '11111111-1111-4111-8111-111111111111'
                appId = '22222222-2222-4222-8222-222222222222'
                displayName = $script:displayName
                managerApplications = @($script:reviewedManagerId)
                signInAudience = 'AzureADMyOrg'
                identifierUris = @()
                tags = @()
                api = [pscustomobject]@{
                    oauth2PermissionScopes = @()
                    knownClientApplications = @()
                    preAuthorizedApplications = @()
                }
                appRoles = @()
                requiredResourceAccess = @()
                passwordCredentials = @()
                keyCredentials = @()
                web = [pscustomobject]@{ redirectUris = @(); homePageUrl = $null; logoutUrl = $null }
                spa = [pscustomobject]@{ redirectUris = @() }
                publicClient = [pscustomobject]@{ redirectUris = @() }
                isFallbackPublicClient = $false
            }
            Mock Invoke-AzJson {
                $url = [string]$Arguments[([array]::IndexOf($Arguments, '--url') + 1)]
                if ($url -like '*/owners?*' -or $url -like '*/sponsors?*') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = $script:ownerId }) }
                }
                if ($url -like '*/federatedIdentityCredentials?*' -or $url -like '*servicePrincipals?*') {
                    return [pscustomobject]@{ value = @() }
                }
                return [pscustomobject]@{}
            }
        }

        It 'finds an exact blueprint on a later Graph page' {
            Mock Invoke-AzJson {
                $script:pageCalls++
                if ($script:pageCalls -eq 1) {
                    return [pscustomobject]@{
                        value = @([pscustomobject]@{ displayName = 'Different Blueprint' })
                        '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint?$skiptoken=safe-page-two'
                    }
                }
                return [pscustomobject]@{
                    value = @([pscustomobject]@{
                        id = '11111111-1111-4111-8111-111111111111'
                        appId = '22222222-2222-4222-8222-222222222222'
                        displayName = 'Reviewed Blueprint'
                        managerApplications = @('33333333-3333-4333-8333-333333333333')
                    })
                }
            }

            $result = Get-Agent365BlueprintByName -DisplayName 'Reviewed Blueprint'

            $result.appId | Should -Be '22222222-2222-4222-8222-222222222222'
            $script:pageCalls | Should -Be 2
        }

        It 'rejects duplicate exact names split across Graph pages' {
            Mock Invoke-AzJson {
                $script:pageCalls++
                if ($script:pageCalls -eq 1) {
                    return [pscustomobject]@{
                        value = @([pscustomobject]@{ displayName = 'Reviewed Blueprint' })
                        '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint?$skiptoken=duplicate-page'
                    }
                }
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ displayName = 'Reviewed Blueprint' })
                }
            }

            { Get-Agent365BlueprintByName -DisplayName 'Reviewed Blueprint' } |
                Should -Throw '*More than one typed Agent ID blueprint*'
            $script:pageCalls | Should -Be 2
        }

        It 'rejects an off-origin continuation without sending a second request' {
            Mock Invoke-AzJson {
                $script:pageCalls++
                return [pscustomobject]@{
                    value = @()
                    '@odata.nextLink' = 'https://example.invalid/collect?$skiptoken=unsafe'
                }
            }

            { Get-Agent365BlueprintByName -DisplayName 'Reviewed Blueprint' } |
                Should -Throw '*invalid or off-origin continuation URL*'
            $script:pageCalls | Should -Be 1
        }

        It 'rejects null or scalar blueprint collections instead of treating them as authoritative absence' {
            Mock Invoke-AzJson { return [pscustomobject]@{ value = $null } }
            { Get-Agent365BlueprintByName -DisplayName 'Reviewed Blueprint' } |
                Should -Throw '*malformed value collection*'

            Mock Invoke-AzJson { return [pscustomobject]@{ value = [pscustomobject]@{ id = 'scalar' } } }
            { Get-Agent365BlueprintByName -DisplayName 'Reviewed Blueprint' } |
                Should -Throw '*malformed value collection*'
        }

        It 'rejects malformed generic Graph collections' {
            Mock Invoke-AzJson { return [pscustomobject]@{ value = 'scalar' } }

            { Get-Agent365BoundedGraphCollection `
                -InitialUrl 'https://graph.microsoft.com/v1.0/servicePrincipals?`$select=id' `
                -ExpectedPath '/v1.0/servicePrincipals' `
                -OperationLabel 'Test collection' } |
                Should -Throw '*malformed value collection*'
        }

        It 'requires selected principal collection properties to be present arrays' {
            { Get-Agent365RequiredCollectionItems `
                -InputObject ([pscustomobject]@{}) `
                -Name 'passwordCredentials' `
                -Label 'Agent ID blueprint principal' } |
                Should -Throw "*omitted or duplicated required property 'passwordCredentials'*"

            { Get-Agent365RequiredCollectionItems `
                -InputObject ([pscustomobject]@{ passwordCredentials = $null }) `
                -Name 'passwordCredentials' `
                -Label 'Agent ID blueprint principal' } |
                Should -Throw "*is not a collection*"

            @(Get-Agent365RequiredCollectionItems `
                -InputObject ([pscustomobject]@{ passwordCredentials = @() }) `
                -Name 'passwordCredentials' `
                -Label 'Agent ID blueprint principal').Count | Should -Be 0
        }

        It 'returns only the exact independently reviewed manager authority set' {
            Mock Get-Agent365BlueprintByName { return $script:blueprint }

            $result = Ensure-Agent365SeedBlueprint `
                -Config $script:config `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -SponsorObjectId $script:ownerId `
                -NonInteractive `
                -ReconcileOnly

            $result.managerApplicationIds | Should -Be @($script:reviewedManagerId)
            $result.managerApplicationsPreflightConfirmed | Should -BeTrue
            $result.credentialCreationPerformed | Should -BeFalse
            $result.pristineAuthoritySurfaceConfirmed | Should -BeTrue
        }

        It 'rejects provider-discovered manager authority that was not reviewed in config' {
            $script:blueprint.managerApplications = @('44444444-4444-4444-8444-444444444444')
            Mock Get-Agent365BlueprintByName { return $script:blueprint }

            { Ensure-Agent365SeedBlueprint `
                -Config $script:config `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -SponsorObjectId $script:ownerId `
                -NonInteractive `
                -ReconcileOnly } |
                Should -Throw '*do not exactly match the independently reviewed configuration*'
        }

        It 'binds the exact name to deployment ownership and accepted source' {
            $script:displayName | Should -Be "Reviewed Blueprint [a365gw:$($script:ownershipId):$('a' * 64)]"
        }

        It 'refuses to adopt an exact preexisting name before the create intent' {
            Mock Get-Agent365BlueprintByName { return $script:blueprint }

            { Ensure-Agent365SeedBlueprint `
                -Config $script:config `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -SponsorObjectId $script:ownerId } |
                Should -Throw '*already exists before this bootstrap create intent*'

            Should -Invoke Invoke-AzJson -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'POST' }
        }

        It 'issues exactly one direct credential-free Graph create and verifies pristine readback' {
            $script:nameReads = 0
            Mock Get-Agent365BlueprintByName {
                $script:nameReads++
                if ($script:nameReads -eq 1) { return $null }
                return $script:blueprint
            }
            Mock Start-Sleep {}

            $result = Ensure-Agent365SeedBlueprint `
                -Config $script:config `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -SponsorObjectId $script:ownerId

            $result.provenance | Should -Be 'BootstrapOwnedDirectGraphV1'
            Should -Invoke Invoke-AzJson -Times 1 -Exactly -ParameterFilter {
                $Arguments -contains 'POST' -and
                $Arguments -contains 'https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint' -and
                ($Arguments -join ' ') -notmatch '(?i)passwordCredential|keyCredential|clientSecret'
            }
        }

        It 'never repeats create when read-only reconciliation cannot find the exact object' {
            Mock Get-Agent365BlueprintByName { return $null }

            { Ensure-Agent365SeedBlueprint `
                -Config $script:config `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -SponsorObjectId $script:ownerId `
                -ReconcileOnly } |
                Should -Throw '*must not be repeated automatically*'

            Should -Invoke Invoke-AzJson -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'POST' }
        }

        It 'accepts only the one exact Gateway-activated FIC and typed principal transition' {
            $gatewayPrincipalId = '88888888-8888-4888-8888-888888888888'
            $gatewayApplicationId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            Mock Invoke-AzJson {
                $url = [string]$Arguments[([array]::IndexOf($Arguments, '--url') + 1)]
                if ($url -like '*/microsoft.graph.agentIdentityBlueprintPrincipal/owners?*') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = $gatewayPrincipalId }) }
                }
                if ($url -like '*/microsoft.graph.agentIdentityBlueprintPrincipal/sponsors?*' -or
                    $url -like '*/appRoleAssignments?*' -or
                    $url -like '*/appRoleAssignedTo?*' -or
                    $url -like '*/oauth2PermissionGrants?*' -or
                    $url -like '*/memberOf?*') {
                    return [pscustomobject]@{ value = @() }
                }
                if ($url -like '*/microsoft.graph.agentIdentityBlueprint/owners?*' -or
                    $url -like '*/microsoft.graph.agentIdentityBlueprint/sponsors?*') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = $script:ownerId }) }
                }
                if ($url -like '*/federatedIdentityCredentials?*') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{
                        id = 'fic-safe'
                        name = "a365-gateway-$(([guid]$gatewayPrincipalId).ToString('N'))"
                        issuer = "https://login.microsoftonline.com/$($script:config.tenantId)/v2.0"
                        subject = $gatewayPrincipalId
                        audiences = @('api://AzureADTokenExchange')
                    }) }
                }
                if ($url -like '*/microsoft.graph.agentIdentityBlueprintPrincipal?*') {
                    return [pscustomobject]@{
                        id = '99999999-9999-4999-8999-999999999999'
                        appId = $script:blueprint.appId
                        appDisplayName = $script:displayName
                        appOwnerOrganizationId = $script:config.tenantId
                        accountEnabled = $true
                        appRoleAssignmentRequired = $false
                        createdByAppId = $gatewayApplicationId
                        disabledByMicrosoftStatus = $null
                        displayName = $script:displayName
                        appRoles = @()
                        keyCredentials = @()
                        passwordCredentials = @()
                        publishedPermissionScopes = @()
                        servicePrincipalNames = @($script:blueprint.appId)
                        servicePrincipalType = 'Application'
                        signInAudience = 'AzureADMyOrg'
                        tags = @()
                    }
                }
                if ($url -like "*/servicePrincipals/${gatewayPrincipalId}?*") {
                    return [pscustomobject]@{ id = $gatewayPrincipalId; appId = $gatewayApplicationId }
                }
                if ($url -match '/servicePrincipals\?') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{
                        id = '99999999-9999-4999-8999-999999999999'
                        appId = $script:blueprint.appId
                        displayName = $script:displayName
                    }) }
                }
                throw "Unexpected Graph URL: $url"
            }

            $result = Assert-Agent365SeedBlueprintSurface `
                -Blueprint $script:blueprint `
                -Config $script:config `
                -ExpectedDisplayName $script:displayName `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -SponsorObjectId $script:ownerId `
                -GatewayManagedIdentityPrincipalId $gatewayPrincipalId

            $result.runtimeAuthorityMode | Should -Be 'GatewayActivated'
        }

        It 'rejects credentials or alternate service-principal names on the typed blueprint principal' {
            $gatewayPrincipalId = '88888888-8888-4888-8888-888888888888'
            $gatewayApplicationId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            Mock Invoke-AzJson {
                $url = [string]$Arguments[([array]::IndexOf($Arguments, '--url') + 1)]
                if ($url -like '*/microsoft.graph.agentIdentityBlueprintPrincipal/owners?*') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = $gatewayPrincipalId }) }
                }
                if ($url -like '*/microsoft.graph.agentIdentityBlueprintPrincipal/sponsors?*' -or
                    $url -like '*/appRoleAssignments?*' -or $url -like '*/appRoleAssignedTo?*' -or
                    $url -like '*/oauth2PermissionGrants?*' -or $url -like '*/memberOf?*') {
                    return [pscustomobject]@{ value = @() }
                }
                if ($url -like '*/microsoft.graph.agentIdentityBlueprint/owners?*' -or
                    $url -like '*/microsoft.graph.agentIdentityBlueprint/sponsors?*') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = $script:ownerId }) }
                }
                if ($url -like '*/federatedIdentityCredentials?*') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{
                        id = 'fic-safe'
                        name = "a365-gateway-$(([guid]$gatewayPrincipalId).ToString('N'))"
                        issuer = "https://login.microsoftonline.com/$($script:config.tenantId)/v2.0"
                        subject = $gatewayPrincipalId
                        audiences = @('api://AzureADTokenExchange')
                    }) }
                }
                if ($url -like '*/microsoft.graph.agentIdentityBlueprintPrincipal?*') {
                    return [pscustomobject]@{
                        id = '99999999-9999-4999-8999-999999999999'
                        appId = $script:blueprint.appId
                        appDisplayName = $script:displayName
                        appOwnerOrganizationId = $script:config.tenantId
                        accountEnabled = $true
                        appRoleAssignmentRequired = $false
                        createdByAppId = $gatewayApplicationId
                        disabledByMicrosoftStatus = $null
                        displayName = $script:displayName
                        appRoles = @()
                        keyCredentials = @([pscustomobject]@{ keyId = 'unexpected' })
                        passwordCredentials = @()
                        publishedPermissionScopes = @()
                        servicePrincipalNames = @($script:blueprint.appId, 'unexpected-alternate-name')
                        servicePrincipalType = 'Application'
                        signInAudience = 'AzureADMyOrg'
                        tags = @()
                    }
                }
                if ($url -like "*/servicePrincipals/${gatewayPrincipalId}?*") {
                    return [pscustomobject]@{ id = $gatewayPrincipalId; appId = $gatewayApplicationId }
                }
                if ($url -match '/servicePrincipals\?') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{
                        id = '99999999-9999-4999-8999-999999999999'
                        appId = $script:blueprint.appId
                        displayName = $script:displayName
                    }) }
                }
                throw "Unexpected Graph URL: $url"
            }

            { Assert-Agent365SeedBlueprintSurface `
                -Blueprint $script:blueprint `
                -Config $script:config `
                -ExpectedDisplayName $script:displayName `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -SponsorObjectId $script:ownerId `
                -GatewayManagedIdentityPrincipalId $gatewayPrincipalId } |
                Should -Throw '*did not pass exact typed Microsoft Graph readback*'
        }

        It 'rejects any extra blueprint federated credential' {
            Mock Invoke-AzJson {
                $url = [string]$Arguments[([array]::IndexOf($Arguments, '--url') + 1)]
                if ($url -like '*/owners?*' -or $url -like '*/sponsors?*') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = $script:ownerId }) }
                }
                if ($url -like '*/federatedIdentityCredentials?*') {
                    return [pscustomobject]@{ value = @(
                        [pscustomobject]@{ id = 'one'; name = 'unexpected'; issuer = 'https://issuer.invalid'; subject = $script:ownerId; audiences = @('api://AzureADTokenExchange') },
                        [pscustomobject]@{ id = 'two'; name = 'extra'; issuer = 'https://issuer.invalid'; subject = $script:ownerId; audiences = @('api://AzureADTokenExchange') }
                    ) }
                }
                if ($url -like '*servicePrincipals?*') { return [pscustomobject]@{ value = @() } }
                throw "Unexpected Graph URL: $url"
            }

            { Assert-Agent365SeedBlueprintSurface `
                -Blueprint $script:blueprint `
                -Config $script:config `
                -ExpectedDisplayName $script:displayName `
                -DeploymentOwnershipId $script:ownershipId `
                -SourceFingerprint $script:sourceFingerprint `
                -SponsorObjectId $script:ownerId `
                -GatewayManagedIdentityPrincipalId '88888888-8888-4888-8888-888888888888' } |
                Should -Throw '*outside the exact pristine-or-Gateway-activated authority boundary*'
        }
    }
}
