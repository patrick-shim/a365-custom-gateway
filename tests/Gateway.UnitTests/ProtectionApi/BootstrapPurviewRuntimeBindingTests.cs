using FluentAssertions;
using Gateway.Api.Infrastructure;
using Gateway.Api.Options;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Purview;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Options;
using NSubstitute;

namespace Gateway.UnitTests.ProtectionApi;

public sealed class BootstrapPurviewRuntimeBindingTests
{
    [Theory]
    [InlineData("runtime-pair")]
    [InlineData("disabled")]
    [InlineData("missing-runtime-client")]
    [InlineData("conflicting-client")]
    [InlineData("not-installed")]
    [InlineData("failure")]
    [InlineData("readback-time")]
    [InlineData("source")]
    [InlineData("ownership")]
    [InlineData("api-principal")]
    [InlineData("runtime-principal")]
    [InlineData("automation-app")]
    [InlineData("automation-principal")]
    [InlineData("vault")]
    [InlineData("vault-host")]
    [InlineData("certificate")]
    [InlineData("certificate-uri")]
    [InlineData("unexpected-identifier")]
    public async Task DriftRevokesReadyProfileBeforeRuntimeUse(string drift)
    {
        var bootstrap = BootstrapCapabilitiesOptionsTests.CreateValid();
        var runtime = new PurviewOptions { Enabled = true };
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["PurviewRuntimeIdentity:ManagedIdentityClientId"] = "88888888-8888-4888-8888-888888888888",
            ["PurviewRuntimeIdentity:ManagedIdentityPrincipalObjectId"] =
                bootstrap.Purview.PurviewRuntimeManagedIdentityPrincipalObjectId
        }).Build();
        var attestation = BootstrapCapabilitiesOptionsValidator.CreateAttestation(bootstrap);
        var capability = new ProtectionCapability
        {
            Id = Guid.NewGuid(),
            Kind = ProtectionCapabilityKind.Purview,
            Status = ProtectionCapabilityStatus.Installed,
            LastReadbackAtUtc = attestation.AttestedAtUtc,
            ResourceIdentifiers = attestation.Capabilities.Single(item => item.Kind == ProtectionCapabilityKind.Purview).ResourceIdentifiers
        };
        var binding = new BootstrapPurviewRuntimeBinding(Options.Create(bootstrap), Options.Create(runtime), configuration);
        var readiness = new PurviewReadinessFixture();
        var now = DateTime.UtcNow;
        var profile = readiness.Seed(new PurviewDlpProfile
        {
            Id = new(Guid.NewGuid()),
            BlueprintApplicationId = new(Guid.NewGuid()),
            SensitiveInformationTypeSnapshotExpiresAtUtc = now.AddHours(1),
            Status = PurviewDlpProfileStatus.Ready,
            Readiness = ProtectionReadiness.Ready,
            DlpPolicyProviderId = "synthetic-policy",
            DlpRuleProviderId = "synthetic-rule",
            LastReadbackAtUtc = now,
            PropagationVerifiedAtUtc = now,
            TokenRolesVerifiedAtUtc = now,
            RuntimeAllowVerifiedAtUtc = now,
            RuntimeBlockVerifiedAtUtc = now
        });
        var capabilities = Substitute.For<IProtectionCapabilityRepository>();
        var profiles = Substitute.For<IPurviewDlpProfileRepository>();
        capabilities.GetByKindAsync(ProtectionCapabilityKind.Purview, Arg.Any<CancellationToken>()).Returns(capability);
        profiles.GetByBlueprintApplicationIdAsync(profile.BlueprintApplicationId, Arg.Any<CancellationToken>()).Returns(profile);
        var evaluator = new ProtectionEffectiveFeatureEvaluator(capabilities, profiles, TimeProvider.System,
            purviewBinding: binding, connections: readiness.Connections, inventory: readiness.Inventory);
        var agent = new AgentRegistration
        {
            Id = Guid.NewGuid(),
            BlueprintId = profile.BlueprintApplicationId.Value.ToString("D"),
            FeatureConfiguration = new AgentFeatureConfiguration { PurviewEnabled = true }
        };

        binding.IsExact(capability).Should().BeTrue();
        await evaluator.EnsureRuntimeReadyAsync(agent, CancellationToken.None);
        (await evaluator.ToDtoAsync(agent, CancellationToken.None)).PurviewEffectivelyEnabled.Should().BeTrue();
        var ids = capability.ResourceIdentifiers;
        switch (drift)
        {
            case "runtime-pair":
                configuration["PurviewRuntimeIdentity:ManagedIdentityClientId"] = Guid.NewGuid().ToString("D");
                configuration["PurviewRuntimeIdentity:ManagedIdentityPrincipalObjectId"] = Guid.NewGuid().ToString("D");
                break;
            case "disabled": runtime.Enabled = false; break;
            case "missing-runtime-client": configuration["PurviewRuntimeIdentity:ManagedIdentityClientId"] = null; break;
            case "conflicting-client": runtime.ManagedIdentityClientId = Guid.NewGuid().ToString("D"); break;
            case "not-installed": capability.Status = ProtectionCapabilityStatus.NotInstalled; break;
            case "failure": capability.LastFailureCode = "SYNTHETIC_FAILURE"; break;
            case "readback-time": capability.LastReadbackAtUtc = capability.LastReadbackAtUtc!.Value.AddSeconds(1); break;
            case "source": ids = ids with { BootstrapSourceFingerprint = $"sha256:{new string('b', 64)}" }; break;
            case "ownership": ids = ids with { BootstrapDeploymentOwnershipId = Guid.NewGuid() }; break;
            case "api-principal": ids = ids with { GatewayApiManagedIdentityPrincipalObjectId = new(Guid.NewGuid()) }; break;
            case "runtime-principal": ids = ids with { PurviewRuntimeManagedIdentityPrincipalObjectId = new(Guid.NewGuid()) }; break;
            case "automation-app": ids = ids with { PurviewAutomationApplicationId = new(Guid.NewGuid()) }; break;
            case "automation-principal": ids = ids with { PurviewAutomationServicePrincipalObjectId = new(Guid.NewGuid()) }; break;
            case "vault": ids = ids with { KeyVaultResourceId = ids.KeyVaultResourceId + "-other" }; break;
            case "vault-host": ids = ids with { KeyVaultHost = "other.vault.azure.net" }; break;
            case "certificate": ids = ids with { CertificateName = "other" }; break;
            case "certificate-uri": ids = ids with { CertificateSecretUri = ids.CertificateSecretUri + "-other" }; break;
            case "unexpected-identifier": ids = ids with { Agent365RegistryApiApplicationId = new(Guid.NewGuid()) }; break;
        }
        capability.ResourceIdentifiers = ids;

        binding.IsExact(capability).Should().BeFalse();
        var action = () => evaluator.EnsureRuntimeReadyAsync(agent, CancellationToken.None);
        (await action.Should().ThrowAsync<DomainException>()).Which.ErrorCode.Should().Be(ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE);
        var features = await evaluator.ToDtoAsync(agent, CancellationToken.None);
        features.PurviewEffectivelyEnabled.Should().BeFalse();
        features.PurviewReadiness!.IsReady.Should().BeFalse();
        features.PurviewReadiness.Capability.Should().Be("Unavailable");
        profile.Status.Should().Be(PurviewDlpProfileStatus.Ready);
        profile.Readiness.Should().Be(ProtectionReadiness.Ready);
    }
}
