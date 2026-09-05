using FluentAssertions;
using Gateway.Api.Infrastructure;
using Gateway.Application.Protection;
using Gateway.Domain.Enums;
using Gateway.EndToEndTests.Fixtures;
using Gateway.Infrastructure.Persistence;
using Gateway.Purview;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Gateway.EndToEndTests.ProtectionApi;

[Collection(EndToEndTestCollection.Name)]
public sealed class BootstrapCapabilitiesStartupTests
{
    [Fact]
    public async Task StartupMaterializesCompleteEnvironmentAttestation()
    {
        await using var baseFactory =
            new GatewayWebApplicationFactory();
        await using var factory = baseFactory.WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, configuration) =>
                configuration.AddInMemoryCollection(CreateConfiguration())));

        using var client = factory.CreateClient();
        using var response = await client.GetAsync("/health/checks");
        response.IsSuccessStatusCode.Should().BeTrue();

        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var capabilities = db.ProtectionCapabilities
            .OrderBy(capability => capability.Kind)
            .ToArray();
        capabilities.Should().HaveCount(3);
        capabilities.Should().OnlyContain(capability =>
            capability.Status == ProtectionCapabilityStatus.Installed);
        capabilities.Single(capability =>
                capability.Kind == ProtectionCapabilityKind.PromptShields)
            .ResourceIdentifiers.ContentSafetyAccountResourceId
            .Should().NotBeNullOrWhiteSpace();
        capabilities.Single(capability =>
                capability.Kind == ProtectionCapabilityKind.Purview)
            .ResourceIdentifiers.PurviewAutomationServicePrincipalObjectId
            .Should().NotBeNull();
        scope.ServiceProvider.GetRequiredService<IBootstrapPurviewRuntimeBinding>()
            .Should().BeOfType<BootstrapPurviewRuntimeBinding>()
            .And.BeSameAs(scope.ServiceProvider.GetRequiredService<IPurviewRuntimeIdentityBinding>());
    }

    [Fact]
    public void ApiTokenProviderCannotResolveWhenMandatoryRuntimeGuardIsRemoved()
    {
        using var baseFactory = new GatewayWebApplicationFactory();
        using var factory = baseFactory.WithWebHostBuilder(builder =>
            builder.ConfigureTestServices(services => services.RemoveAll<IPurviewRuntimeIdentityBinding>()));
        using var client = factory.CreateClient();

        var action = () => factory.Services.GetRequiredService<IPurviewTokenRoleAttestor>();

        action.Should().Throw<InvalidOperationException>();
    }

    private static Dictionary<string, string?> CreateConfiguration() => new()
    {
        ["BootstrapCapabilities:Enabled"] = "true",
        ["BootstrapCapabilities:DeploymentOwnershipId"] =
            "11111111-1111-4111-8111-111111111111",
        ["BootstrapCapabilities:AcceptedSourceFingerprint"] =
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ["BootstrapCapabilities:AttestedAtUtc"] =
            DateTimeOffset.UtcNow.AddMinutes(-1).ToString("O"),
        ["BootstrapCapabilities:Agent365RegistrationBeta:Status"] =
            "Installed",
        ["BootstrapCapabilities:Agent365RegistrationBeta:Agent365RegistryApiApplicationId"] =
            "33333333-3333-4333-8333-333333333333",
        ["BootstrapCapabilities:PromptShields:Status"] = "Installed",
        ["BootstrapCapabilities:PromptShields:ContentSafetyAccountResourceId"] =
            "/subscriptions/44444444-4444-4444-8444-444444444444/resourceGroups/gateway-rg/providers/Microsoft.CognitiveServices/accounts/content-safety",
        ["BootstrapCapabilities:PromptShields:ContentSafetyEndpoint"] =
            "https://content-safety.cognitiveservices.azure.com/",
        ["BootstrapCapabilities:PromptShields:GatewayApiManagedIdentityPrincipalObjectId"] =
            "22222222-2222-4222-8222-222222222222",
        ["BootstrapCapabilities:Purview:Status"] = "Installed",
        ["BootstrapCapabilities:Purview:GatewayApiManagedIdentityPrincipalObjectId"] =
            "22222222-2222-4222-8222-222222222222",
        ["BootstrapCapabilities:Purview:PurviewRuntimeManagedIdentityPrincipalObjectId"] =
            "55555555-5555-4555-8555-555555555555",
        ["BootstrapCapabilities:Purview:PurviewAutomationApplicationId"] =
            "66666666-6666-4666-8666-666666666666",
        ["BootstrapCapabilities:Purview:PurviewAutomationServicePrincipalObjectId"] =
            "77777777-7777-4777-8777-777777777777",
        ["BootstrapCapabilities:Purview:KeyVaultResourceId"] =
            "/subscriptions/44444444-4444-4444-8444-444444444444/resourceGroups/gateway-rg/providers/Microsoft.KeyVault/vaults/gateway-vault",
        ["BootstrapCapabilities:Purview:KeyVaultHost"] =
            "gateway-vault.vault.azure.net",
        ["BootstrapCapabilities:Purview:CertificateName"] =
            "purview-automation",
        ["BootstrapCapabilities:Purview:CertificateSecretUri"] =
            "https://gateway-vault.vault.azure.net/secrets/purview-automation"
    };
}
