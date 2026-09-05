using FluentAssertions;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using NSubstitute;

namespace Gateway.UnitTests.ProtectionApi;

public sealed class ProtectionEffectiveFeatureEvaluatorTests
{
    private readonly IProtectionCapabilityRepository _capabilities =
        Substitute.For<IProtectionCapabilityRepository>();
    private readonly IPurviewDlpProfileRepository _profiles =
        Substitute.For<IPurviewDlpProfileRepository>();
    private readonly IBootstrapPromptShieldRuntimeBinding _promptShieldBinding =
        Substitute.For<IBootstrapPromptShieldRuntimeBinding>();
    private readonly PurviewReadinessFixture _runtime = new();

    [Fact]
    public async Task RuntimeFailsClosedWhenBindingIsAbsentDespiteInstalledCapabilityAndReadyProfile()
    {
        var now = DateTime.UtcNow;
        var blueprintId = Guid.NewGuid();
        _capabilities.GetByKindAsync(
                ProtectionCapabilityKind.Purview,
                Arg.Any<CancellationToken>())
            .Returns(new ProtectionCapability
            {
                Id = Guid.NewGuid(),
                Kind = ProtectionCapabilityKind.Purview,
                Status = ProtectionCapabilityStatus.Installed,
                LastReadbackAtUtc = now
            });
        var profile = CreateReadyProfile(blueprintId, now);
        _profiles.GetByBlueprintApplicationIdAsync(
                new BlueprintApplicationId(blueprintId),
                Arg.Any<CancellationToken>())
            .Returns(profile);
        var evaluator = new ProtectionEffectiveFeatureEvaluator(
            _capabilities, _profiles, TimeProvider.System);
        var agent = CreateAgent(blueprintId, purviewEnabled: true);

        var action = () => evaluator.EnsureRuntimeReadyAsync(agent, CancellationToken.None);

        (await action.Should().ThrowAsync<DomainException>()).Which.ErrorCode.Should().Be(
            ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE);
        var features = await evaluator.ToDtoAsync(agent, CancellationToken.None);
        features.PurviewEffectivelyEnabled.Should().BeFalse();
        features.PurviewReadiness!.IsReady.Should().BeFalse();
    }

    [Theory]
    [InlineData("current", true)]
    [InlineData("binding", false)]
    [InlineData("pending", false)]
    [InlineData("replaced", false)]
    [InlineData("missing-selection", false)]
    [InlineData("renamed-selection", false)]
    [InlineData("expired-connection", false)]
    [InlineData("other-tenant", false)]
    public async Task EveryReadinessPathRequiresBoundRuntimeAndCurrentInventory(string state, bool expectedReady)
    {
        var now = DateTime.UtcNow;
        var blueprint = Guid.NewGuid();
        var profile = CreateReadyProfile(blueprint, now);
        var capability = new ProtectionCapability
        {
            Id = Guid.NewGuid(),
            Kind = ProtectionCapabilityKind.Purview,
            Status = ProtectionCapabilityStatus.Installed,
            LastReadbackAtUtc = now
        };
        _capabilities.GetByKindAsync(ProtectionCapabilityKind.Purview, Arg.Any<CancellationToken>()).Returns(capability);
        _profiles.GetByIdAsync(profile.Id, Arg.Any<CancellationToken>()).Returns(profile);
        _profiles.GetByBlueprintApplicationIdAsync(profile.BlueprintApplicationId, Arg.Any<CancellationToken>()).Returns(profile);
        _profiles.ListAsync(Arg.Any<CancellationToken>()).Returns(new[] { profile });
        switch (state)
        {
            case "binding": _runtime.Binding.IsExact(capability).Returns(false); break;
            case "pending":
                _runtime.Connection.Status = PurviewTenantConnectionStatus.PendingVerification;
                _runtime.Connection.ActiveInventoryGenerationId = null;
                break;
            case "replaced": _runtime.Connection.ActiveInventoryGenerationId = new(Guid.NewGuid()); break;
            case "missing-selection": _runtime.Generation.Items.Clear(); break;
            case "renamed-selection": _runtime.Generation.Items.Single().ExactName = "Changed name"; break;
            case "expired-connection": _runtime.Connection.ExpiresAtUtc = now.AddSeconds(-1); break;
            case "other-tenant": _runtime.Generation.TenantId = new(Guid.NewGuid()); break;
        }
        var evaluator = new ProtectionEffectiveFeatureEvaluator(_capabilities, _profiles, TimeProvider.System,
            _promptShieldBinding, _runtime.Binding, _runtime.Connections, _runtime.Inventory);
        var agent = CreateAgent(blueprint, purviewEnabled: true);

        (await evaluator.HasAnyReadyDlpProfileAsync(CancellationToken.None)).Should().Be(expectedReady);
        var features = await evaluator.ToDtoAsync(agent, CancellationToken.None);
        features.PurviewEffectivelyEnabled.Should().Be(expectedReady);
        features.PurviewReadiness!.IsReady.Should().Be(expectedReady);
        (await evaluator.ToProfileDtoAsync(profile, CancellationToken.None)).Readiness.IsReady.Should().Be(expectedReady);
        var runtime = () => evaluator.EnsureRuntimeReadyAsync(agent, CancellationToken.None);
        var selection = () => evaluator.RequireReadyProfileAsync(blueprint,
            new PurviewDlpProfileSelectionDto(profile.Id.Value, blueprint), CancellationToken.None);
        if (expectedReady)
        {
            await runtime.Should().NotThrowAsync();
            await selection.Should().NotThrowAsync();
        }
        else
        {
            await runtime.Should().ThrowAsync<DomainException>();
            await selection.Should().ThrowAsync<DomainException>();
            features.PurviewReadiness.Blockers.Should().Contain(state == "binding"
                ? ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE : ErrorCodes.PURVIEW_INVENTORY_STALE);
        }
    }

    [Fact]
    public async Task RuntimeFailsClosedWhenCapabilityExistsWithoutExactReadyProfile()
    {
        var now = DateTime.UtcNow;
        var blueprintId = Guid.NewGuid();
        _capabilities.GetByKindAsync(
                ProtectionCapabilityKind.Purview,
                Arg.Any<CancellationToken>())
            .Returns(new ProtectionCapability
            {
                Id = Guid.NewGuid(),
                Kind = ProtectionCapabilityKind.Purview,
                Status = ProtectionCapabilityStatus.Installed,
                LastReadbackAtUtc = now
            });
        _profiles.GetByBlueprintApplicationIdAsync(
                new BlueprintApplicationId(blueprintId),
                Arg.Any<CancellationToken>())
            .Returns((PurviewDlpProfile?)null);
        var evaluator = new ProtectionEffectiveFeatureEvaluator(
            _capabilities,
            _profiles,
            TimeProvider.System,
            _promptShieldBinding, _runtime.Binding, _runtime.Connections, _runtime.Inventory);
        var agent = CreateAgent(blueprintId, purviewEnabled: true);

        var action = () => evaluator.EnsureRuntimeReadyAsync(
            agent,
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(
            ErrorCodes.PURVIEW_DLP_PROFILE_NOT_READY);
    }

    [Fact]
    public async Task EffectiveReadinessRequiresEveryIndependentDimension()
    {
        var now = DateTime.UtcNow;
        var blueprintId = Guid.NewGuid();
        var profile = CreateReadyProfile(blueprintId, now);
        _capabilities.GetByKindAsync(
                ProtectionCapabilityKind.Purview,
                Arg.Any<CancellationToken>())
            .Returns(new ProtectionCapability
            {
                Id = Guid.NewGuid(),
                Kind = ProtectionCapabilityKind.Purview,
                Status = ProtectionCapabilityStatus.Installed,
                LastReadbackAtUtc = now
            });
        _profiles.GetByBlueprintApplicationIdAsync(
                new BlueprintApplicationId(blueprintId),
                Arg.Any<CancellationToken>())
            .Returns(profile);
        var evaluator = new ProtectionEffectiveFeatureEvaluator(
            _capabilities,
            _profiles,
            TimeProvider.System,
            _promptShieldBinding, _runtime.Binding, _runtime.Connections, _runtime.Inventory);

        var ready = await evaluator.ToDtoAsync(
            CreateAgent(blueprintId, purviewEnabled: true),
            CancellationToken.None);
        ready.PurviewEffectivelyEnabled.Should().BeTrue();

        profile.Readiness = profile.Readiness with
        {
            TokenRoles = ProtectionTokenRoleStatus.MissingRequiredRoles
        };
        var notReady = await evaluator.ToDtoAsync(
            CreateAgent(blueprintId, purviewEnabled: true),
            CancellationToken.None);
        notReady.PurviewEffectivelyEnabled.Should().BeFalse();
        notReady.PurviewReadiness!.Blockers.Should().Contain(
            "PURVIEW_TOKEN_ROLES_NOT_READY");
    }

    [Fact]
    public async Task DefaultCannotEnableWithoutAnyExactReadyProfile()
    {
        _capabilities.GetByKindAsync(
                ProtectionCapabilityKind.Purview,
                Arg.Any<CancellationToken>())
            .Returns(new ProtectionCapability
            {
                Id = Guid.NewGuid(),
                Kind = ProtectionCapabilityKind.Purview,
                Status = ProtectionCapabilityStatus.Installed,
                LastReadbackAtUtc = DateTime.UtcNow
            });
        _profiles.ListAsync(Arg.Any<CancellationToken>())
            .Returns(Array.Empty<PurviewDlpProfile>());
        var evaluator = new ProtectionEffectiveFeatureEvaluator(
            _capabilities,
            _profiles,
            TimeProvider.System,
            _promptShieldBinding, _runtime.Binding, _runtime.Connections, _runtime.Inventory);

        (await evaluator.HasAnyReadyDlpProfileAsync(
            CancellationToken.None)).Should().BeFalse();
    }

    [Fact]
    public async Task MissingCapabilityRowsFailClosedForSelectedProtections()
    {
        _capabilities.GetByKindAsync(
                Arg.Any<ProtectionCapabilityKind>(),
                Arg.Any<CancellationToken>())
            .Returns((ProtectionCapability?)null);
        var evaluator = new ProtectionEffectiveFeatureEvaluator(
            _capabilities,
            _profiles,
            TimeProvider.System,
            _promptShieldBinding, _runtime.Binding, _runtime.Connections, _runtime.Inventory);
        var agent = CreateAgent(Guid.NewGuid(), purviewEnabled: true);

        var purview = () => evaluator.EnsureRuntimeReadyAsync(
            agent,
            CancellationToken.None);
        var prompt = () => evaluator.EnsurePromptShieldReadyAsync(
            CancellationToken.None);

        (await purview.Should().ThrowAsync<DomainException>())
            .Which.ErrorCode.Should().Be(
                ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE);
        (await prompt.Should().ThrowAsync<DomainException>())
            .Which.ErrorCode.Should().Be(
                ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE);
    }

    [Fact]
    public async Task PromptShieldReadinessRequiresExactRuntimeCapabilityBinding()
    {
        var capability = new ProtectionCapability
        {
            Id = Guid.NewGuid(),
            Kind = ProtectionCapabilityKind.PromptShields,
            Status = ProtectionCapabilityStatus.Installed,
            LastReadbackAtUtc = DateTime.UtcNow
        };
        _capabilities.GetByKindAsync(
                ProtectionCapabilityKind.PromptShields,
                Arg.Any<CancellationToken>())
            .Returns(capability);
        _promptShieldBinding.IsExact(capability).Returns(false);
        var evaluator = new ProtectionEffectiveFeatureEvaluator(
            _capabilities,
            _profiles,
            TimeProvider.System,
            _promptShieldBinding, _runtime.Binding, _runtime.Connections, _runtime.Inventory);
        var agent = CreateAgent(
            Guid.NewGuid(),
            purviewEnabled: false,
            promptShieldEnabled: true);

        var unavailable = () => evaluator.EnsurePromptShieldReadyAsync(
            CancellationToken.None);

        (await unavailable.Should().ThrowAsync<DomainException>())
            .Which.ErrorCode.Should().Be(
                ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE);
        (await evaluator.ToDtoAsync(agent, CancellationToken.None))
            .PromptShieldEffectivelyEnabled.Should().BeFalse();

        _promptShieldBinding.IsExact(capability).Returns(true);

        await evaluator.EnsurePromptShieldReadyAsync(CancellationToken.None);
        (await evaluator.ToDtoAsync(agent, CancellationToken.None))
            .PromptShieldEffectivelyEnabled.Should().BeTrue();
    }

    private static AgentRegistration CreateAgent(
        Guid blueprintId,
        bool purviewEnabled,
        bool promptShieldEnabled = false)
    {
        var agent = new AgentRegistration
        {
            Id = Guid.NewGuid(),
            BlueprintId = blueprintId.ToString("D")
        };
        agent.FeatureConfiguration = new AgentFeatureConfiguration
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            ObservabilityMode = ObservabilityMode.Agent365,
            PurviewEnabled = purviewEnabled,
            PurviewMode = PurviewMode.Enforce,
            PromptShieldEnabled = promptShieldEnabled
        };
        return agent;
    }

    private PurviewDlpProfile CreateReadyProfile(
        Guid blueprintId,
        DateTime now) => _runtime.Seed(new PurviewDlpProfile()
        {
            Id = new PurviewDlpProfileId(Guid.NewGuid()),
            BlueprintApplicationId = new BlueprintApplicationId(blueprintId),
            SensitiveInformationTypeSnapshotExpiresAtUtc = now.AddHours(1),
            Status = PurviewDlpProfileStatus.Ready,
            Readiness = ProtectionReadiness.Ready,
            DlpPolicyProviderId = "policy-id",
            DlpRuleProviderId = "rule-id",
            LastReadbackAtUtc = now,
            PropagationVerifiedAtUtc = now,
            TokenRolesVerifiedAtUtc = now,
            RuntimeAllowVerifiedAtUtc = now,
            RuntimeBlockVerifiedAtUtc = now,
            CreatedAtUtc = now,
            UpdatedAtUtc = now
        });
}
