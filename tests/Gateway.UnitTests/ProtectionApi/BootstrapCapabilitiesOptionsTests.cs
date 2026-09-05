using FluentAssertions;
using Gateway.Api.Options;
using Gateway.Domain.Enums;

namespace Gateway.UnitTests.ProtectionApi;

public sealed class BootstrapCapabilitiesOptionsTests
{
    private const string OwnershipId =
        "11111111-1111-4111-8111-111111111111";
    private const string SourceFingerprint =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string ApiPrincipal =
        "22222222-2222-4222-8222-222222222222";

    [Fact]
    public void CompleteCanonicalFactsCreateThreeBoundAttestations()
    {
        var options = CreateValid();
        var validator = new BootstrapCapabilitiesOptionsValidator();

        var result = validator.Validate(null, options);
        var attestation =
            BootstrapCapabilitiesOptionsValidator.CreateAttestation(
                options);

        result.Succeeded.Should().BeTrue();
        attestation.Capabilities.Should().HaveCount(3);
        attestation.Capabilities.Should().OnlyContain(fact =>
            fact.Status == ProtectionCapabilityStatus.Installed &&
            fact.ResourceIdentifiers.BootstrapDeploymentOwnershipId ==
                Guid.Parse(OwnershipId) &&
            fact.ResourceIdentifiers.BootstrapSourceFingerprint ==
                SourceFingerprint);
        attestation.Capabilities.Single(fact =>
                fact.Kind == ProtectionCapabilityKind.PromptShields)
            .ResourceIdentifiers.ContentSafetyEndpoint.Should().Be(
                "https://content-safety.cognitiveservices.azure.com/");
        attestation.Capabilities.Single(fact =>
                fact.Kind == ProtectionCapabilityKind.Purview)
            .ResourceIdentifiers.PurviewAutomationApplicationId
            .Should().NotBeNull();
        attestation.Capabilities.Single(fact =>
                fact.Kind == ProtectionCapabilityKind.Purview)
            .ResourceIdentifiers.CertificateSecretUri.Should().Be(
                "https://gateway-vault.vault.azure.net/secrets/purview-automation");
    }

    [Theory]
    [InlineData("")]
    [InlineData("Installed ")]
    [InlineData("PendingPropagation")]
    public void PartialOrUnsupportedStatusFailsClosed(string status)
    {
        var options = CreateValid();
        options.Purview.Status = status;

        new BootstrapCapabilitiesOptionsValidator()
            .Validate(null, options)
            .Failed.Should().BeTrue();
    }

    [Fact]
    public void DisabledOrNotInstalledFactsCannotCarryIdentifiers()
    {
        var disabled = new BootstrapCapabilitiesOptions
        {
            PromptShields =
            {
                ContentSafetyEndpoint =
                    "https://content-safety.cognitiveservices.azure.com/"
            }
        };
        var notInstalled = CreateValid();
        notInstalled.PromptShields.Status = "NotInstalled";

        var validator = new BootstrapCapabilitiesOptionsValidator();

        validator.Validate(null, disabled).Failed.Should().BeTrue();
        validator.Validate(null, notInstalled).Failed.Should().BeTrue();
    }

    public static BootstrapCapabilitiesOptions CreateValid() => new()
    {
        Enabled = true,
        DeploymentOwnershipId = OwnershipId,
        AcceptedSourceFingerprint = SourceFingerprint,
        AttestedAtUtc =
            new DateTimeOffset(2026, 9, 5, 13, 0, 0, TimeSpan.Zero),
        Agent365RegistrationBeta =
        {
            Status = "Installed",
            Agent365RegistryApiApplicationId =
                "33333333-3333-4333-8333-333333333333"
        },
        PromptShields =
        {
            Status = "Installed",
            ContentSafetyAccountResourceId =
                "/subscriptions/44444444-4444-4444-8444-444444444444/resourceGroups/gateway-rg/providers/Microsoft.CognitiveServices/accounts/content-safety",
            ContentSafetyEndpoint =
                "https://content-safety.cognitiveservices.azure.com/",
            GatewayApiManagedIdentityPrincipalObjectId = ApiPrincipal
        },
        Purview =
        {
            Status = "Installed",
            GatewayApiManagedIdentityPrincipalObjectId = ApiPrincipal,
            PurviewRuntimeManagedIdentityPrincipalObjectId =
                "55555555-5555-4555-8555-555555555555",
            PurviewAutomationApplicationId =
                "66666666-6666-4666-8666-666666666666",
            PurviewAutomationServicePrincipalObjectId =
                "77777777-7777-4777-8777-777777777777",
            KeyVaultResourceId =
                "/subscriptions/44444444-4444-4444-8444-444444444444/resourceGroups/gateway-rg/providers/Microsoft.KeyVault/vaults/gateway-vault",
            KeyVaultHost = "gateway-vault.vault.azure.net",
            CertificateName = "purview-automation",
            CertificateSecretUri =
                "https://gateway-vault.vault.azure.net/secrets/purview-automation"
        }
    };
}
