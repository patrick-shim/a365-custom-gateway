using FluentAssertions;
using Gateway.Application.Activities.Commands;
using Gateway.Application.Exceptions;
using Gateway.Application.Interactions.Commands;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;

namespace Gateway.SecurityTests;

/// <summary>
/// Verifies that data-plane handlers enforce per-registration credential binding
/// and reject requests from disabled agents. These are security-critical checks
/// that must never be bypassed.
/// </summary>
public class IdentityBindingTests
{
    // Shared mocks for SubmitActivityHandler
    private readonly IAgentRepository _agentRepository = Substitute.For<IAgentRepository>();
    private readonly IActivityReceiptRepository _activityReceiptRepository = Substitute.For<IActivityReceiptRepository>();
    private readonly IIdempotencyService _idempotencyService = Substitute.For<IIdempotencyService>();
    private readonly IOutboxRepository _outboxRepository = Substitute.For<IOutboxRepository>();
    private readonly IAuditEventRepository _auditEventRepository = Substitute.For<IAuditEventRepository>();
    private readonly IUnitOfWork _unitOfWork = Substitute.For<IUnitOfWork>();

    // Additional mocks for SubmitInteractionHandler
    private readonly IAiInteractionRepository _aiInteractionRepository = Substitute.For<IAiInteractionRepository>();
    private readonly IInteractionContentStore _interactionContentStore = Substitute.For<IInteractionContentStore>();
    private readonly IPurviewPolicyClient _purviewPolicyClient = Substitute.For<IPurviewPolicyClient>();
    private readonly IPromptEvaluationRepository _promptEvaluationRepository = Substitute.For<IPromptEvaluationRepository>();

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    private static AgentRegistration CreateAgent(
        string externalAgentId,
        string externalClientId,
        AgentStatus status = AgentStatus.Active)
    {
        return new AgentRegistration
        {
            Id = Guid.NewGuid(),
            ExternalAgentId = new ExternalAgentId(externalAgentId),
            Name = "Test Agent",
            ExternalClientId = externalClientId,
            Status = status,
            OwnerObjectId = Guid.NewGuid().ToString(),
            CreatedByObjectId = Guid.NewGuid().ToString(),
            UpdatedByObjectId = Guid.NewGuid().ToString(),
            CreatedAtUtc = DateTime.UtcNow,
            UpdatedAtUtc = DateTime.UtcNow,
            FeatureConfiguration = new AgentFeatureConfiguration
            {
                Id = Guid.NewGuid(),
                ObservabilityMode = ObservabilityMode.Disabled,
                PurviewEnabled = false,
                UpdatedAtUtc = DateTime.UtcNow
            }
        };
    }

    private SubmitActivityHandler CreateActivityHandler() =>
        new(_agentRepository, _activityReceiptRepository, _idempotencyService,
            _outboxRepository, _auditEventRepository, _unitOfWork);

    private SubmitInteractionHandler CreateInteractionHandler() =>
        new(_agentRepository, _aiInteractionRepository, _interactionContentStore,
            _purviewPolicyClient, _idempotencyService, _outboxRepository,
            _auditEventRepository, _promptEvaluationRepository, _unitOfWork,
            NullLogger<SubmitInteractionHandler>.Instance);

    private static SubmitActivityCommand CreateActivityCommand(
        string externalAgentId, Guid callerAgentRegistrationId) =>
        new(ExternalAgentId: externalAgentId,
            ActivityId: Guid.NewGuid().ToString(),
            SessionId: null,
            ActivityType: "UserMessage",
            OccurredAtUtc: DateTime.UtcNow,
            Actor: new ActorDto("User"),
            Tool: null,
            Attributes: null,
            CallerAgentRegistrationId: callerAgentRegistrationId,
            IdempotencyKey: null);

    private static SubmitInteractionCommand CreateInteractionCommand(
        string externalAgentId, Guid callerAgentRegistrationId) =>
        new(ExternalAgentId: externalAgentId,
            InteractionId: Guid.NewGuid().ToString(),
            SessionId: null,
            OccurredAtUtc: DateTime.UtcNow,
            UserContext: null,
            Prompt: new ContentDto("text/plain", "test prompt"),
            Response: new ContentDto("text/plain", "test response"),
            Model: null,
            Metadata: null,
            CallerAgentRegistrationId: callerAgentRegistrationId,
            IdempotencyKey: null);

    // ---------------------------------------------------------------
    // SubmitActivityHandler: identity mismatch
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitActivity_Should_ThrowAgentIdentityMismatch_When_CredentialRegistrationDoesNotMatchAgent()
    {
        var agent = CreateAgent("credential-agent-001", externalClientId: "correct-client-id");
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateActivityHandler();
        var command = CreateActivityCommand("test-agent-001", agent.Id);

        var act = () => handler.Handle(command, CancellationToken.None);

        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_IDENTITY_MISMATCH);
    }

    // ---------------------------------------------------------------
    // SubmitActivityHandler: disabled agent
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitActivity_Should_ThrowAgentDisabled_When_AgentIsNotActive()
    {
        var agent = CreateAgent("test-agent-002", "client-id-123", AgentStatus.Disabled);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateActivityHandler();
        var command = CreateActivityCommand("test-agent-002", agent.Id);

        var act = () => handler.Handle(command, CancellationToken.None);

        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_DISABLED);
    }

    // ---------------------------------------------------------------
    // SubmitActivityHandler: various non-Active statuses
    // ---------------------------------------------------------------

    [Theory]
    [InlineData(AgentStatus.Draft)]
    [InlineData(AgentStatus.Provisioning)]
    [InlineData(AgentStatus.AwaitingAdminApproval)]
    [InlineData(AgentStatus.Failed)]
    [InlineData(AgentStatus.Deleting)]
    [InlineData(AgentStatus.Deleted)]
    [InlineData(AgentStatus.RequiresManualIntervention)]
    public async Task SubmitActivity_Should_ThrowAgentDisabled_When_AgentStatusIsNonActive(
        AgentStatus nonActiveStatus)
    {
        var agent = CreateAgent("test-agent-status", "client-id-789", nonActiveStatus);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateActivityHandler();
        var command = CreateActivityCommand("test-agent-status", agent.Id);

        var act = () => handler.Handle(command, CancellationToken.None);

        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_DISABLED);
    }

    // ---------------------------------------------------------------
    // SubmitActivityHandler: agent not found
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitActivity_Should_ThrowIdentityMismatch_When_CallerRegistrationDoesNotExist()
    {
        var handler = CreateActivityHandler();
        var command = CreateActivityCommand("nonexistent-agent", Guid.NewGuid());
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns((AgentRegistration?)null);

        var act = () => handler.Handle(command, CancellationToken.None);

        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_IDENTITY_MISMATCH);
    }

    // ---------------------------------------------------------------
    // SubmitActivityHandler: enforcement order (identity before status)
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitActivity_Should_CheckIdentityBeforeStatus_When_BothConditionsFail()
    {
        // When both identity mismatch AND disabled status apply, the handler
        // must check identity first (fail-closed security principle).
        var agent = CreateAgent("test-agent-order", "correct-client", AgentStatus.Disabled);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateActivityHandler();
        var command = CreateActivityCommand("different-target", agent.Id);

        var act = () => handler.Handle(command, CancellationToken.None);

        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_IDENTITY_MISMATCH,
            "identity check must come before status check (fail-closed)");
    }

    // ---------------------------------------------------------------
    // SubmitInteractionHandler: identity mismatch
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitInteraction_Should_ThrowAgentIdentityMismatch_When_CredentialRegistrationDoesNotMatchAgent()
    {
        var agent = CreateAgent("credential-agent-003", externalClientId: "correct-client-id");
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateInteractionHandler();
        var command = CreateInteractionCommand("test-agent-003", agent.Id);

        var act = () => handler.Handle(command, CancellationToken.None);

        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_IDENTITY_MISMATCH);
    }

    // ---------------------------------------------------------------
    // SubmitInteractionHandler: disabled agent
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitInteraction_Should_ThrowAgentDisabled_When_AgentIsNotActive()
    {
        var agent = CreateAgent("test-agent-004", "client-id-456", AgentStatus.Disabled);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateInteractionHandler();
        var command = CreateInteractionCommand("test-agent-004", agent.Id);

        var act = () => handler.Handle(command, CancellationToken.None);

        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_DISABLED);
    }

    // ---------------------------------------------------------------
    // SubmitInteractionHandler: enforcement order (identity before status)
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitInteraction_Should_CheckIdentityBeforeStatus_When_BothConditionsFail()
    {
        var agent = CreateAgent("test-agent-int-order", "correct-client", AgentStatus.Disabled);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateInteractionHandler();
        var command = CreateInteractionCommand("different-target", agent.Id);

        var act = () => handler.Handle(command, CancellationToken.None);

        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_IDENTITY_MISMATCH,
            "identity check must come before status check (fail-closed)");
    }

    // ---------------------------------------------------------------
    // SubmitInteractionHandler: agent not found
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitInteraction_Should_ThrowIdentityMismatch_When_CallerRegistrationDoesNotExist()
    {
        var handler = CreateInteractionHandler();
        var command = CreateInteractionCommand("nonexistent-agent-int", Guid.NewGuid());
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns((AgentRegistration?)null);

        var act = () => handler.Handle(command, CancellationToken.None);

        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_IDENTITY_MISMATCH);
    }

    // ---------------------------------------------------------------
    // Child Agent ID client identifiers are not accepted as ingress binding.
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitActivity_Should_IgnoreChildAgentClientIdForIngressBinding()
    {
        var agent = CreateAgent("credential-agent-null-client", externalClientId: "placeholder");
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateActivityHandler();
        var command = CreateActivityCommand("test-agent-null-client", agent.Id);

        var act = () => handler.Handle(command, CancellationToken.None);

        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_IDENTITY_MISMATCH);
    }
}
