using System.Text.RegularExpressions;
using FluentAssertions;

namespace Gateway.ArchitectureTests;

public sealed class BootstrapCapabilityEvidenceTests
{
    [Fact]
    public void ApiBicep_UsesOnlyTheStrictBootstrapCapabilityEnvironmentContract()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "infrastructure",
            "bicep",
            "modules",
            "container-app-api.bicep"));
        var expected = new[]
        {
            "BootstrapCapabilities__Enabled",
            "BootstrapCapabilities__AttestedAtUtc",
            "BootstrapCapabilities__DeploymentOwnershipId",
            "BootstrapCapabilities__AcceptedSourceFingerprint",
            "BootstrapCapabilities__Agent365RegistrationBeta__Status",
            "BootstrapCapabilities__Agent365RegistrationBeta__Agent365RegistryApiApplicationId",
            "BootstrapCapabilities__PromptShields__Status",
            "BootstrapCapabilities__PromptShields__ContentSafetyAccountResourceId",
            "BootstrapCapabilities__PromptShields__ContentSafetyEndpoint",
            "BootstrapCapabilities__PromptShields__GatewayApiManagedIdentityPrincipalObjectId",
            "BootstrapCapabilities__Purview__Status",
            "BootstrapCapabilities__Purview__GatewayApiManagedIdentityPrincipalObjectId",
            "BootstrapCapabilities__Purview__PurviewRuntimeManagedIdentityPrincipalObjectId",
            "BootstrapCapabilities__Purview__PurviewAutomationApplicationId",
            "BootstrapCapabilities__Purview__PurviewAutomationServicePrincipalObjectId",
            "BootstrapCapabilities__Purview__KeyVaultResourceId",
            "BootstrapCapabilities__Purview__KeyVaultHost",
            "BootstrapCapabilities__Purview__CertificateName",
            "BootstrapCapabilities__Purview__CertificateSecretUri"
        };

        foreach (var name in expected)
            source.Should().Contain($"name: '{name}'");

        var actual = Regex.Matches(
                source,
                @"name: '(BootstrapCapabilities__[A-Za-z0-9_]+)'",
                RegexOptions.CultureInvariant)
            .Select(match => match.Groups[1].Value)
            .ToArray();
        actual.Should().Equal(expected);
        source.Should().Contain("value: bootstrapCapabilities.purview.purviewRuntimeManagedIdentityPrincipalObjectId");
        source.Should().NotContain("gatewayWorkerManagedIdentityPrincipalObjectId");
        source.Should().NotContain("BootstrapCapabilities__Purview__Policy");
        source.Should().NotContain("BootstrapCapabilities__Purview__Readiness");
        source.Should().NotContain("BootstrapCapabilities__Purview__Propagation");
        source.Should().NotContain("BootstrapCapabilities__Purview__RuntimeVerdict");
        source.Should().NotContain("BootstrapCapabilities__Purview__TokenRoles");
    }

    [Fact]
    public void ApiBicep_EnvironmentContract_MatchesApiOptionPropertyNames()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "infrastructure", "bicep", "modules", "container-app-api.bicep"));
        var options = File.ReadAllText(FindRepositoryFile(
            "src", "Gateway.Api", "Options", "BootstrapCapabilitiesOptions.cs"));

        foreach (var property in new[]
                 {
                     "AttestedAtUtc",
                     "AcceptedSourceFingerprint",
                     "Agent365RegistryApiApplicationId",
                     "PurviewRuntimeManagedIdentityPrincipalObjectId",
                     "PurviewAutomationApplicationId",
                     "PurviewAutomationServicePrincipalObjectId",
                     "KeyVaultHost"
                 })
        {
            source.Should().Contain($"__{property}'");
            options.Should().Contain($" {property} {{ get; set; }}");
        }
    }

    private static string FindRepositoryFile(params string[] segments)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory);
             directory is not null;
             directory = directory.Parent)
        {
            var candidate = Path.Combine([directory.FullName, .. segments]);
            if (File.Exists(candidate))
                return candidate;
        }

        throw new FileNotFoundException("Could not locate repository source.");
    }
}
