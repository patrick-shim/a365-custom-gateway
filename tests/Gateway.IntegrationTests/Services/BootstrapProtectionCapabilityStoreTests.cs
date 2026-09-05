using FluentAssertions;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Services;
using Gateway.IntegrationTests.Fixtures;

namespace Gateway.IntegrationTests.Services;

public sealed class BootstrapProtectionCapabilityStoreTests
{
    private static readonly DateTime AttestedAt =
        new(2026, 9, 5, 13, 0, 0, DateTimeKind.Utc);
    private static readonly DateTime StartedAt =
        new(2026, 9, 5, 13, 5, 0, DateTimeKind.Utc);
    private static readonly Guid OwnershipId =
        Guid.Parse("11111111-1111-4111-8111-111111111111");
    private const string SourceFingerprint =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    [Fact]
    public async Task FreshDatabaseAndRestartProduceExactlyThreeStableRows()
    {
        await using var context = TestDbContextFactory.Create();
        var store = new BootstrapProtectionCapabilityStore(context);
        var attestation = CreateInstalledAttestation();

        await store.SynchronizeAsync(
            attestation,
            StartedAt,
            CancellationToken.None);
        var first = context.ProtectionCapabilities
            .OrderBy(capability => capability.Kind)
            .Select(capability => new
            {
                capability.Id,
                capability.Kind,
                capability.Status,
                capability.UpdatedAtUtc,
                RowVersion =
                    Convert.ToBase64String(capability.RowVersion)
            })
            .ToArray();
        context.ChangeTracker.Clear();
        var persistedAgent = context.ProtectionCapabilities.Single(
            capability =>
                capability.Kind ==
                ProtectionCapabilityKind.Agent365RegistrationBeta);
        persistedAgent.ResourceIdentifiers.Should().BeEquivalentTo(
            attestation.Capabilities.Single(fact =>
                    fact.Kind ==
                    ProtectionCapabilityKind.Agent365RegistrationBeta)
                .ResourceIdentifiers);
        persistedAgent.LastReadbackAtUtc.Should().Be(AttestedAt);
        persistedAgent.LastFailureCode.Should().BeNull();
        context.ChangeTracker.Clear();
        await store.SynchronizeAsync(
            attestation,
            StartedAt.AddMinutes(5),
            CancellationToken.None);
        var restarted = context.ProtectionCapabilities
            .OrderBy(capability => capability.Kind)
            .Select(capability => new
            {
                capability.Id,
                capability.Kind,
                capability.Status,
                capability.UpdatedAtUtc,
                RowVersion =
                    Convert.ToBase64String(capability.RowVersion)
            })
            .ToArray();

        first.Should().Equal(restarted);
        first.Should().HaveCount(3);
        first.Should().OnlyContain(item =>
            item.Status == ProtectionCapabilityStatus.Installed);
        context.ProtectionCapabilities.Single(capability =>
                capability.Kind == ProtectionCapabilityKind.PromptShields)
            .ResourceIdentifiers.ContentSafetyEndpoint.Should().Be(
                "https://content-safety.cognitiveservices.azure.com/");
        context.ProtectionCapabilities.Single(capability =>
                capability.Kind == ProtectionCapabilityKind.Purview)
            .ResourceIdentifiers.PurviewAutomationApplicationId
            .Should().Be(new ApplicationClientId(
                Guid.Parse(
                    "66666666-6666-4666-8666-666666666666")));
    }

    [Fact]
    public async Task ChangedDeploymentBindingAndPartialPersistenceFailClosed()
    {
        await using var context = TestDbContextFactory.Create();
        var store = new BootstrapProtectionCapabilityStore(context);
        await store.SynchronizeAsync(
            CreateInstalledAttestation(),
            StartedAt,
            CancellationToken.None);
        context.ChangeTracker.Clear();
        var changedOwnershipId = Guid.NewGuid();
        var drifted = CreateInstalledAttestation();
        drifted = drifted with
        {
            DeploymentOwnershipId = changedOwnershipId,
            Capabilities = drifted.Capabilities
                .Select(fact => fact with
                {
                    ResourceIdentifiers =
                        fact.ResourceIdentifiers with
                        {
                            BootstrapDeploymentOwnershipId =
                                changedOwnershipId
                        }
                })
                .ToArray()
        };

        var changedBinding = () => store.SynchronizeAsync(
            drifted,
            StartedAt.AddMinutes(1),
            CancellationToken.None);
        await changedBinding.Should().ThrowAsync<InvalidOperationException>();
        const string changedFingerprint =
            "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        var sourceAttestation = CreateInstalledAttestation();
        sourceAttestation = sourceAttestation with
        {
            AcceptedSourceFingerprint = changedFingerprint,
            Capabilities = sourceAttestation.Capabilities
                .Select(fact => fact with
                {
                    ResourceIdentifiers =
                        fact.ResourceIdentifiers with
                        {
                            BootstrapSourceFingerprint =
                                changedFingerprint
                        }
                })
                .ToArray()
        };
        var changedSource = () => store.SynchronizeAsync(
            sourceAttestation,
            StartedAt.AddMinutes(1),
            CancellationToken.None);
        await changedSource.Should().ThrowAsync<InvalidOperationException>();

        context.ProtectionCapabilities.RemoveRange(
            context.ProtectionCapabilities.Skip(1));
        await context.SaveChangesAsync();
        context.ChangeTracker.Clear();
        var partial = () => store.SynchronizeAsync(
            CreateInstalledAttestation(),
            StartedAt.AddMinutes(2),
            CancellationToken.None);
        await partial.Should().ThrowAsync<InvalidOperationException>();
    }

    [Fact]
    public async Task NotInstalledFactsClearStaleIdentifiersWithoutClaimingReady()
    {
        await using var context = TestDbContextFactory.Create();
        var store = new BootstrapProtectionCapabilityStore(context);
        var attestation = CreateNotInstalledAttestation();
        await store.SynchronizeAsync(
            attestation,
            StartedAt,
            CancellationToken.None);
        var prompt = context.ProtectionCapabilities.Single(capability =>
            capability.Kind == ProtectionCapabilityKind.PromptShields);
        prompt.ResourceIdentifiers =
            prompt.ResourceIdentifiers with
            {
                ContentSafetyEndpoint =
                    "https://stale.cognitiveservices.azure.com/"
            };
        await context.SaveChangesAsync();
        context.ChangeTracker.Clear();

        await store.SynchronizeAsync(
            attestation,
            StartedAt.AddMinutes(1),
            CancellationToken.None);
        prompt = context.ProtectionCapabilities.Single(capability =>
            capability.Kind == ProtectionCapabilityKind.PromptShields);

        prompt.Status.Should().Be(
            ProtectionCapabilityStatus.NotInstalled);
        prompt.ResourceIdentifiers.ContentSafetyEndpoint.Should().BeNull();
        prompt.ResourceIdentifiers.BootstrapDeploymentOwnershipId
            .Should().Be(OwnershipId);
        context.ProtectionCapabilities.Should().OnlyContain(capability =>
            capability.Status ==
                ProtectionCapabilityStatus.NotInstalled &&
            capability.Status != ProtectionCapabilityStatus.PendingPropagation);
    }

    private static BootstrapProtectionCapabilityAttestation
        CreateInstalledAttestation() =>
        new(
            OwnershipId,
            SourceFingerprint,
            AttestedAt,
            [
                Fact(
                    ProtectionCapabilityKind.Agent365RegistrationBeta,
                    new ProtectionCapabilityResourceIdentifiers(
                        Agent365RegistryApiApplicationId:
                            new ApplicationClientId(Guid.Parse(
                                "33333333-3333-4333-8333-333333333333")),
                        BootstrapDeploymentOwnershipId: OwnershipId,
                        BootstrapSourceFingerprint: SourceFingerprint)),
                Fact(
                    ProtectionCapabilityKind.PromptShields,
                    new ProtectionCapabilityResourceIdentifiers(
                        ContentSafetyAccountResourceId:
                            "/subscriptions/44444444-4444-4444-8444-444444444444/resourceGroups/gateway-rg/providers/Microsoft.CognitiveServices/accounts/content-safety",
                        ContentSafetyEndpoint:
                            "https://content-safety.cognitiveservices.azure.com/",
                        GatewayApiManagedIdentityPrincipalObjectId:
                            new ServicePrincipalObjectId(Guid.Parse(
                                "22222222-2222-4222-8222-222222222222")),
                        BootstrapDeploymentOwnershipId: OwnershipId,
                        BootstrapSourceFingerprint: SourceFingerprint)),
                Fact(
                    ProtectionCapabilityKind.Purview,
                    new ProtectionCapabilityResourceIdentifiers(
                        GatewayApiManagedIdentityPrincipalObjectId:
                            new ServicePrincipalObjectId(Guid.Parse(
                                "22222222-2222-4222-8222-222222222222")),
                        PurviewRuntimeManagedIdentityPrincipalObjectId:
                            new ServicePrincipalObjectId(Guid.Parse(
                                "55555555-5555-4555-8555-555555555555")),
                        PurviewAutomationApplicationId:
                            new ApplicationClientId(Guid.Parse(
                                "66666666-6666-4666-8666-666666666666")),
                        PurviewAutomationServicePrincipalObjectId:
                            new ServicePrincipalObjectId(Guid.Parse(
                                "77777777-7777-4777-8777-777777777777")),
                        KeyVaultResourceId:
                            "/subscriptions/44444444-4444-4444-8444-444444444444/resourceGroups/gateway-rg/providers/Microsoft.KeyVault/vaults/gateway-vault",
                        CertificateName: "purview-automation",
                        BootstrapDeploymentOwnershipId: OwnershipId,
                        BootstrapSourceFingerprint: SourceFingerprint,
                        KeyVaultHost:
                            "gateway-vault.vault.azure.net",
                        CertificateSecretUri:
                            "https://gateway-vault.vault.azure.net/secrets/purview-automation"))
            ]);

    private static BootstrapProtectionCapabilityAttestation
        CreateNotInstalledAttestation() =>
        new(
            OwnershipId,
            SourceFingerprint,
            AttestedAt,
            Enum.GetValues<ProtectionCapabilityKind>()
                .Select(kind => new BootstrapProtectionCapabilityFact(
                    kind,
                    ProtectionCapabilityStatus.NotInstalled,
                    new ProtectionCapabilityResourceIdentifiers(
                        BootstrapDeploymentOwnershipId: OwnershipId,
                        BootstrapSourceFingerprint: SourceFingerprint)))
                .ToArray());

    private static BootstrapProtectionCapabilityFact Fact(
        ProtectionCapabilityKind kind,
        ProtectionCapabilityResourceIdentifiers identifiers) =>
        new(
            kind,
            ProtectionCapabilityStatus.Installed,
            identifiers);
}
