using FluentAssertions;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Provisioning.Worker;
using NSubstitute;

namespace Gateway.ObservabilityRuntime.Tests.ProtectionAdmin;

public sealed class PurviewRuntimeReadinessValidatorTests
{
    [Fact]
    public async Task ValidateAllowAsync_RequiresExactInlineAllow()
    {
        var fixture = new RuntimeFixture();
        fixture.Policy.EvaluatePromptAsync(
                Arg.Any<PurviewInteraction>(),
                Arg.Any<CancellationToken>())
            .Returns(new PurviewEvaluationResult(
                true,
                PurviewDecisionType.Allowed,
                PolicyAction: null,
                ProtectionScopeState: null));

        var result = await fixture.Validator.ValidateAllowAsync(
            Guid.NewGuid(),
            AdministratorObjectId,
            fixture.Profile,
            CancellationToken.None);

        result.Status.Should().Be(PurviewRuntimeValidationStatus.Ready);
        await fixture.Policy.Received(1).EvaluatePromptAsync(
            Arg.Is<PurviewInteraction>(interaction =>
                interaction.AgentRegistrationId == fixture.Agent.Id &&
                interaction.AgentIdentityClientId == fixture.Agent.Agent365AgentId &&
                interaction.BlueprintClientId ==
                    fixture.Profile.BlueprintApplicationId.Value.ToString("D") &&
                interaction.ExecutionMode == PurviewExecutionMode.EvaluateInline),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task ValidateBlockAsync_RejectsAllowedOrAuditOnlyVerdict()
    {
        var fixture = new RuntimeFixture();
        fixture.Policy.EvaluatePromptAsync(
                Arg.Any<PurviewInteraction>(),
                Arg.Any<CancellationToken>())
            .Returns(new PurviewEvaluationResult(
                true,
                PurviewDecisionType.AuditLogged,
                "Audit",
                ProtectionScopeState: null));

        var result = await fixture.Validator.ValidateBlockAsync(
            Guid.NewGuid(),
            AdministratorObjectId,
            fixture.Profile,
            CancellationToken.None);

        result.Status.Should().Be(PurviewRuntimeValidationStatus.Failed);
        result.FailureCode.Should().Be("PURVIEW_RUNTIME_BLOCK_NOT_OBSERVED");
    }

    [Fact]
    public async Task ValidateBlockAsync_FailsClosedWithoutExactActiveChildIdentity()
    {
        var fixture = new RuntimeFixture(includeAgent: false);

        var result = await fixture.Validator.ValidateBlockAsync(
            Guid.NewGuid(),
            AdministratorObjectId,
            fixture.Profile,
            CancellationToken.None);

        result.Status.Should().Be(PurviewRuntimeValidationStatus.Failed);
        result.FailureCode.Should().Be("PURVIEW_RUNTIME_AGENT_NOT_DISCOVERABLE");
        await fixture.Policy.DidNotReceiveWithAnyArgs()
            .EvaluatePromptAsync(default!, default);
    }

    [Fact]
    public void ValidationResult_ExposesOnlyBoundedVerdictMetadata()
    {
        typeof(PurviewRuntimeValidationResult)
            .GetProperties()
            .Select(property => property.Name)
            .Should()
            .BeEquivalentTo(
                nameof(PurviewRuntimeValidationResult.Status),
                nameof(PurviewRuntimeValidationResult.ObservedAtUtc),
                nameof(PurviewRuntimeValidationResult.FailureCode));
    }

    private sealed class RuntimeFixture
    {
        public RuntimeFixture(bool includeAgent = true)
        {
            Profile = new PurviewDlpProfile
            {
                Id = new PurviewDlpProfileId(Guid.NewGuid()),
                BlueprintApplicationId = new BlueprintApplicationId(Guid.NewGuid()),
                Mode = PurviewMode.Enforce
            };
            Agent = new AgentRegistration
            {
                Id = Guid.NewGuid(),
                ExternalAgentId = new ExternalAgentId("synthetic-agent"),
                Name = "Synthetic runtime agent",
                Status = AgentStatus.Active,
                BlueprintId = Profile.BlueprintApplicationId.Value.ToString("D"),
                Agent365AgentId = Guid.NewGuid().ToString("D")
            };
            Agents.ListAsync(
                    Arg.Any<AgentListFilter>(),
                    Arg.Any<CancellationToken>())
                .Returns((
                    includeAgent ? new List<AgentRegistration> { Agent } : [],
                    includeAgent ? 1 : 0));
            Policy.IsEnabled.Returns(true);
            Validator = new PurviewRuntimeReadinessValidator(Agents, Policy);
        }

        public IAgentRepository Agents { get; } = Substitute.For<IAgentRepository>();
        public IPurviewPolicyClient Policy { get; } =
            Substitute.For<IPurviewPolicyClient>();
        public AgentRegistration Agent { get; }
        public PurviewDlpProfile Profile { get; }
        public PurviewRuntimeReadinessValidator Validator { get; }
    }

    private const string AdministratorObjectId =
        "00000000-0000-4000-8000-000000000001";
}
