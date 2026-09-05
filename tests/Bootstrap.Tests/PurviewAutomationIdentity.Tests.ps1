$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Azure.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Entra.psm1') -Force

Describe 'Purview automation exact compliance RBAC boundary' {
    InModuleScope Entra {
        BeforeEach {
            $script:purviewOwnershipId = '11111111-1111-4111-8111-111111111111'
            $script:purviewApplicationId = '33333333-3333-4333-8333-333333333333'
            $script:purviewPrincipalId = '44444444-4444-4444-8444-444444444444'
            $script:exchangePrincipalId = '55555555-5555-4555-8555-555555555555'
            $script:exchangeRole = [ordered]@{
                servicePrincipalId = $script:exchangePrincipalId
                roleId = '455e5cd2-84e8-4751-8344-5672145dfa17'
            }
            $script:exchangeAssignments = @([pscustomobject]@{
                id = '66666666-6666-4666-8666-666666666666'
                resourceId = $script:exchangePrincipalId
                appRoleId = '455e5cd2-84e8-4751-8344-5672145dfa17'
            })
            $script:complianceAssignments = @([pscustomobject]@{
                id = '77777777-7777-4777-8777-777777777777'
                principalId = $script:purviewPrincipalId
                roleDefinitionId = '17315797-102d-40b4-93e0-432062caca18'
                directoryScopeId = '/'
            })
            $script:purviewGroups = @()
            $script:purviewPrincipal = [pscustomobject]@{
                id = $script:purviewPrincipalId
                appId = $script:purviewApplicationId
                accountEnabled = $true
                appRoleAssignmentRequired = $false
                servicePrincipalType = 'Application'
                servicePrincipalNames = @($script:purviewApplicationId)
                tags = @(
                    'A365GatewayBootstrap',
                    "A365GatewayOwnership:$script:purviewOwnershipId")
                passwordCredentials = @()
                keyCredentials = @()
                appRoles = @()
                oauth2PermissionScopes = @()
            }
            $script:purviewApplication = [pscustomobject]@{
                id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
                appId = $script:purviewApplicationId
                displayName = 'A365 Gateway Purview Automation - safe-dev'
                signInAudience = 'AzureADMyOrg'
                identifierUris = @()
                tags = @(
                    'A365GatewayBootstrap',
                    "A365GatewayOwnership:$script:purviewOwnershipId")
                isFallbackPublicClient = $false
                api = [pscustomobject]@{
                    acceptMappedClaims = $false
                    preAuthorizedApplications = @()
                    knownClientApplications = @()
                    oauth2PermissionScopes = @()
                }
                web = [pscustomobject]@{
                    redirectUris = @()
                    implicitGrantSettings = [pscustomobject]@{
                        enableAccessTokenIssuance = $false
                        enableIdTokenIssuance = $false
                    }
                }
                spa = [pscustomobject]@{ redirectUris = @() }
                publicClient = [pscustomobject]@{ redirectUris = @() }
                appRoles = @()
                passwordCredentials = @()
                keyCredentials = @([pscustomobject]@{
                    keyId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
                })
                requiredResourceAccess = @([pscustomobject]@{
                    resourceAppId = '00000007-0000-0ff1-ce00-000000000000'
                    resourceAccess = @([pscustomobject]@{
                        id = '455e5cd2-84e8-4751-8344-5672145dfa17'
                        type = 'Role'
                    })
                })
            }
            Mock Get-BoundedGraphCollection {
                param([string]$InitialUrl)
                if ($InitialUrl -match '/appRoleAssignments') {
                    return @($script:exchangeAssignments)
                }
                if ($InitialUrl -match '/roleManagement/directory/roleAssignments') {
                    return @($script:complianceAssignments)
                }
                if ($InitialUrl -match '/transitiveMemberOf/microsoft.graph.group') {
                    return @($script:purviewGroups)
                }
                if ($InitialUrl -match '/owners|/appRoleAssignedTo') {
                    return @()
                }
                throw "Unexpected Purview RBAC collection: $InitialUrl"
            }
            Mock Assert-BootstrapApplicationOwnership { return $true }
        }

        It 'accepts only the exact EOP requiredResourceAccess and one certificate' {
            Assert-BootstrapPurviewAutomationApplication `
                -Application $script:purviewApplication `
                -DisplayName 'A365 Gateway Purview Automation - safe-dev' `
                -DeploymentOwnershipId $script:purviewOwnershipId `
                -OwnerObjectId '22222222-2222-4222-8222-222222222222' `
                -ExchangeRole $script:exchangeRole |
                Should -BeTrue
        }

        It 'rejects another app-only permission before provider mutation' {
            $script:purviewApplication.requiredResourceAccess[0].resourceAccess +=
                [pscustomobject]@{
                    id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
                    type = 'Role'
                }

            {
                Assert-BootstrapPurviewAutomationApplication `
                    -Application $script:purviewApplication `
                    -DisplayName 'A365 Gateway Purview Automation - safe-dev' `
                    -DeploymentOwnershipId $script:purviewOwnershipId `
                    -OwnerObjectId '22222222-2222-4222-8222-222222222222' `
                    -ExchangeRole $script:exchangeRole
            } | Should -Throw '*exact Security and Compliance app-only permission*'
        }

        It 'accepts only one EOP Exchange.ManageAsApp and one Compliance Administrator assignment' {
            $result = Assert-BootstrapPurviewAutomationServicePrincipal `
                -Principal $script:purviewPrincipal `
                -ApplicationId $script:purviewApplicationId `
                -DeploymentOwnershipId $script:purviewOwnershipId `
                -ExchangeRole $script:exchangeRole

            $result.exchangeAssignments.Count | Should -Be 1
            $result.complianceAssignments.Count | Should -Be 1
        }

        It 'rejects an additional app role or directory role before any mutation' {
            $script:exchangeAssignments += [pscustomobject]@{
                id = '88888888-8888-4888-8888-888888888888'
                resourceId = $script:exchangePrincipalId
                appRoleId = '99999999-9999-4999-8999-999999999999'
            }
            {
                Assert-BootstrapPurviewAutomationServicePrincipal `
                    -Principal $script:purviewPrincipal `
                    -ApplicationId $script:purviewApplicationId `
                    -DeploymentOwnershipId $script:purviewOwnershipId `
                    -ExchangeRole $script:exchangeRole
            } | Should -Throw '*outside the exact reviewed boundary*'

            $script:exchangeAssignments = @($script:exchangeAssignments[0])
            $script:complianceAssignments += [pscustomobject]@{
                id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
                principalId = $script:purviewPrincipalId
                roleDefinitionId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
                directoryScopeId = '/'
            }
            {
                Assert-BootstrapPurviewAutomationServicePrincipal `
                    -Principal $script:purviewPrincipal `
                    -ApplicationId $script:purviewApplicationId `
                    -DeploymentOwnershipId $script:purviewOwnershipId `
                    -ExchangeRole $script:exchangeRole
            } | Should -Throw '*outside the exact reviewed boundary*'
        }

        It 'rejects any group membership on the automation principal' {
            $script:purviewGroups = @([pscustomobject]@{
                id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
            })

            {
                Assert-BootstrapPurviewAutomationServicePrincipal `
                    -Principal $script:purviewPrincipal `
                    -ApplicationId $script:purviewApplicationId `
                    -DeploymentOwnershipId $script:purviewOwnershipId `
                    -ExchangeRole $script:exchangeRole
            } | Should -Throw '*unreviewed owner, group membership, or local role assignee*'
        }

        It 'accepts only one verified initial tenant domain' {
            Mock Get-BoundedGraphCollection {
                return @([pscustomobject]@{
                    id = 'Contoso.OnMicrosoft.com'
                    isInitial = $true
                    isVerified = $true
                })
            }

            Get-BootstrapInitialTenantDomain |
                Should -BeExactly 'contoso.onmicrosoft.com'
        }

        It 'uses a CSP RSA key on Windows and a non-CNG RSA key elsewhere' {
            $rsa = New-BootstrapPurviewCertificateRsa
            try {
                $rsa.KeySize | Should -Be 2048
                if ($IsWindows) {
                    $rsa | Should -BeOfType [Security.Cryptography.RSACryptoServiceProvider]
                    $rsa.PersistKeyInCsp | Should -BeFalse
                }
            }
            finally {
                $rsa.Dispose()
            }
        }

        It 'exports a passwordless PKCS12 certificate that retains its private key' {
            $rsa = New-BootstrapPurviewCertificateRsa
            $certificate = $null
            $pfx = $null
            $loaded = $null
            try {
                $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                    'CN=a365gw-test-purview',
                    $rsa,
                    [Security.Cryptography.HashAlgorithmName]::SHA256,
                    [Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $certificate = $request.CreateSelfSigned(
                    [DateTimeOffset]::UtcNow.AddMinutes(-1),
                    [DateTimeOffset]::UtcNow.AddDays(1))
                $pfx = $certificate.Export(
                    [Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12)
                $loaded = [Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadPkcs12(
                    $pfx,
                    $null,
                    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)

                $loaded.HasPrivateKey | Should -BeTrue
            }
            finally {
                if ($pfx) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($pfx) }
                if ($loaded) { $loaded.Dispose() }
                if ($certificate) { $certificate.Dispose() }
                $rsa.Dispose()
            }
        }

        It 'validates the automation projection inside combined capability evidence' {
            $readback = [ordered]@{
                enabled = $true
                status = 'Installed'
                automationApplicationId = $script:purviewApplicationId
                policyConfiguration = 'NotPerformed'
                policyReadiness = 'NotClaimed'
            }
            Mock Get-BootstrapPurviewAutomationIdentityEvidence { return $readback }
            $combined = [ordered]@{
                enabled = $true
                status = 'Installed'
                automationApplicationId = $script:purviewApplicationId
                policyConfiguration = 'NotPerformed'
                policyReadiness = 'NotClaimed'
                apiGraphRoles = 'Installed'
                protectionAdminQueue = 'Requested'
            }

            Test-BootstrapPurviewAutomationIdentityEvidence `
                -Config ([pscustomobject]@{}) `
                -AzureIdentity ([pscustomobject]@{}) `
                -KeyVaultUri 'https://unused.invalid/' `
                -DeploymentOwnershipId $script:purviewOwnershipId `
                -SourceFingerprint "sha256:$('a' * 64)" `
                -Evidence $combined |
                Should -BeTrue
        }
    }
}
