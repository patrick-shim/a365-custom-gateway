$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Azure.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Entra.psm1') -Force

Describe 'Purview automation exact compliance RBAC boundary' {
    BeforeAll {
        # Decode bags and import RSA directly: macOS cannot load an X509 private key
        # with EphemeralKeySet. No keychain or temporary certificate store is used.
        # https://learn.microsoft.com/dotnet/api/system.security.cryptography.pkcs.pkcs12info
        # https://learn.microsoft.com/dotnet/api/system.security.cryptography.pkcs.pkcs12info.verifymac
        # https://learn.microsoft.com/dotnet/api/system.security.cryptography.rsa.importencryptedpkcs8privatekey
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs
        if (-not ('Gateway.Bootstrap.Tests.Pkcs12PrivateKeyProof' -as [type])) {
            Add-Type -ReferencedAssemblies @(
                'System.Security.Cryptography.Pkcs', 'System.Security.Cryptography',
                'System.Runtime', 'System.Memory', 'System.Collections'
            ) -TypeDefinition @'
using System;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;

namespace Gateway.Bootstrap.Tests
{
    public static class Pkcs12PrivateKeyProof
    {
        public static byte[] CreateEncodingFixture(X509Certificate2 certificate, RSA privateKey, int variant)
        {
            if (variant < 0 || variant > 8)
                throw new ArgumentOutOfRangeException(nameof(variant));
            string macPassword = variant == 8 ? "synthetic-nonempty" : (variant & 1) == 0 ? string.Empty : null;
            string safePassword = (variant & 2) == 0 ? string.Empty : null;
            string keyPassword = (variant & 4) == 0 ? string.Empty : null;
            var pbe = new PbeParameters(PbeEncryptionAlgorithm.TripleDes3KeyPkcs12, HashAlgorithmName.SHA1, 1);
            var contents = new Pkcs12SafeContents();
            contents.AddCertificate(certificate);
            contents.AddShroudedKey(privateKey, keyPassword, pbe);
            var builder = new Pkcs12Builder();
            builder.AddSafeContentsEncrypted(contents, safePassword, pbe);
            builder.SealWithMac(macPassword, HashAlgorithmName.SHA256, 1);
            return builder.Encode();
        }

        public static bool Verify(byte[] pfx, byte[] expectedCertificate)
            => Verify(pfx, expectedCertificate, out _);

        public static bool Verify(byte[] pfx, byte[] expectedCertificate, out string failure)
        {
            failure = "PfxLength";
            var info = Pkcs12Info.Decode(pfx, out int consumed, skipCopy: true);
            if (consumed != pfx.Length)
                return false;
            failure = "PasswordlessMac";
            // PKCS12 distinguishes null (default span) from empty (string span).
            // Both are passwordless, and each protected section chooses its encoding.
            if (info.IntegrityMode != Pkcs12IntegrityMode.Password ||
                !(info.VerifyMac(ReadOnlySpan<char>.Empty) || info.VerifyMac(string.Empty.AsSpan())))
                return false;

            using var privateKey = RSA.Create();
            RSA publicKey = null;
            int keyCount = 0;
            int certificateCount = 0;
            try
            {
                foreach (var contents in info.AuthenticatedSafe)
                {
                    failure = "SafeContents";
                    if (contents.ConfidentialityMode == Pkcs12ConfidentialityMode.Password)
                    {
                        try
                        {
                            contents.Decrypt(ReadOnlySpan<char>.Empty);
                        }
                        catch (CryptographicException)
                        {
                            contents.Decrypt(string.Empty.AsSpan());
                        }
                    }
                    if (contents.ConfidentialityMode != Pkcs12ConfidentialityMode.None)
                        return false;

                    foreach (var bag in contents.GetBags())
                    {
                        if (bag is Pkcs12ShroudedKeyBag encrypted)
                        {
                            failure = "EncryptedPrivateKey";
                            int keyBytes;
                            try
                            {
                                privateKey.ImportEncryptedPkcs8PrivateKey(ReadOnlySpan<char>.Empty,
                                    encrypted.EncryptedPkcs8PrivateKey.Span, out keyBytes);
                            }
                            catch (CryptographicException)
                            {
                                privateKey.ImportEncryptedPkcs8PrivateKey(string.Empty.AsSpan(),
                                    encrypted.EncryptedPkcs8PrivateKey.Span, out keyBytes);
                            }
                            if (++keyCount != 1 || keyBytes != encrypted.EncryptedPkcs8PrivateKey.Length)
                                return false;
                        }
                        else if (bag is Pkcs12KeyBag plain)
                        {
                            failure = "PrivateKey";
                            privateKey.ImportPkcs8PrivateKey(plain.Pkcs8PrivateKey.Span, out int keyBytes);
                            if (++keyCount != 1 || keyBytes != plain.Pkcs8PrivateKey.Length)
                                return false;
                        }
                        else if (bag is Pkcs12CertBag certBag && certBag.IsX509Certificate)
                        {
                            failure = "CertificateMatch";
                            using var certificate = certBag.GetCertificate();
                            if (++certificateCount != 1 ||
                                !certificate.RawData.AsSpan().SequenceEqual(expectedCertificate))
                                return false;
                            publicKey = certificate.GetRSAPublicKey();
                        }
                        else
                        {
                            failure = "UnexpectedBag";
                            return false;
                        }
                    }
                }

                failure = "KeyAndCertificateCounts";
                if (keyCount != 1 || certificateCount != 1 || publicKey == null)
                    return false;
                failure = "SignatureMatch";
                byte[] challenge = { 1, 2, 3, 4 };
                byte[] signature = privateKey.SignData(challenge, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                bool verified = publicKey.VerifyData(challenge, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                if (verified)
                    failure = "None";
                return verified;
            }
            finally
            {
                publicKey?.Dispose();
            }
        }
    }
}
'@
        }
    }

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
            $publicOnlyPfx = $null
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
                $proofFailure = ''
                [Gateway.Bootstrap.Tests.Pkcs12PrivateKeyProof]::Verify($pfx, $certificate.RawData, [ref]$proofFailure) |
                    Should -BeTrue -Because "the exported certificate must retain its matching private key (bounded proof stage: $proofFailure)"

                # PKCS12 independently encodes null versus empty passwords for
                # integrity, safe contents, and private keys. Exercise all eight.
                foreach ($variant in 0..8) {
                    $encodingPfx = $null
                    try {
                        $encodingPfx = [Gateway.Bootstrap.Tests.Pkcs12PrivateKeyProof]::CreateEncodingFixture(
                            $certificate, $rsa, $variant)
                        $verified = [Gateway.Bootstrap.Tests.Pkcs12PrivateKeyProof]::Verify($encodingPfx, $certificate.RawData)
                        if ($variant -eq 8) {
                            $verified | Should -BeFalse -Because 'a nonempty password is outside the passwordless contract'
                        }
                        else {
                            $verified | Should -BeTrue -Because "passwordless encoding variant $variant must retain the matching private key"
                        }
                    }
                    finally {
                        if ($encodingPfx) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($encodingPfx) }
                    }
                }

                # A parseable PFX containing only the public certificate must fail.
                $publicContents = [Security.Cryptography.Pkcs.Pkcs12SafeContents]::new()
                $null = $publicContents.AddCertificate($certificate)
                $publicBuilder = [Security.Cryptography.Pkcs.Pkcs12Builder]::new()
                $publicBuilder.AddSafeContentsUnencrypted($publicContents)
                $publicBuilder.SealWithMac([string]::Empty, [Security.Cryptography.HashAlgorithmName]::SHA256, 1)
                $publicOnlyPfx = $publicBuilder.Encode()
                [Gateway.Bootstrap.Tests.Pkcs12PrivateKeyProof]::Verify($publicOnlyPfx, $certificate.RawData) |
                    Should -BeFalse
            }
            finally {
                if ($pfx) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($pfx) }
                if ($publicOnlyPfx) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($publicOnlyPfx) }
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
