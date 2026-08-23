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
using NSubstitute;

namespace Gateway.SecurityTests;

/// <summary>
/// Verifies that data-plane handlers enforce agent-to-client identity binding
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
            _auditEventRepository, _unitOfWork);

    private static SubmitActivityCommand CreateActivityCommand(
        string externalAgentId, string callerClientId) =>
        new(ExternalAgentId: externalAgentId,
            ActivityId: Guid.NewGuid().ToString(),
            SessionId: null,
            ActivityType: "UserMessage",
            OccurredAtUtc: DateTime.UtcNow,
            Actor: new ActorDto("User"),
            Tool: null,
            Attributes: null,
            CallerClientId: callerClientId,
            IdempotencyKey: null);

    private static SubmitInteractionCommand CreateInteractionCommand(
        string externalAgentId, string callerClientId) =>
        new(ExternalAgentId: externalAgentId,
            InteractionId: Guid.NewGuid().ToString(),
            SessionId: null,
            OccurredAtUtc: DateTime.UtcNow,
            UserContext: null,
            Prompt: new ContentDto("text/plain", "test prompt"),
            Response: new ContentDto("text/plain", "test response"),
            Model: null,
            Metadata: null,
            CallerClientId: callerClientId,
            IdempotencyKey: null);

    // ---------------------------------------------------------------
    // SubmitActivityHandler: identity mismatch
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitActivity_Should_ThrowAgentIdentityMismatch_When_CallerClientIdDoesNotMatchAgent()
    {
        var agent = CreateAgent("test-agent-001", externalClientId: "correct-client-id");
        _agentRepository.GetByExternalAgentIdAsync("test-agent-001", Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateActivityHandler();
        var command = CreateActivityCommand("test-agent-001", callerClientId: "wrong-client-id");

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
        _agentRepository.GetByExternalAgentIdAsync("test-agent-002", Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateActivityHandler();
        var command = CreateActivityCommand("test-agent-002", callerClientId: "client-id-123");

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
        _agentRepository.GetByExternalAgentIdAsync("test-agent-status", Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateActivityHandler();
        var command = CreateActivityCommand("test-agent-status", callerClientId: "client-id-789");

        var act = () => handler.Handle(command, CancellationToken.None);

        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_DISABLED);
    }

    // ---------------------------------------------------------------
    // SubmitActivityHandler: agent not found
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitActivity_Should_ThrowNotFoundException_When_AgentDoesNotExist()
    {
        _agentRepository.GetByExternalAgentIdAsync("nonexistent-agent", Arg.Any<CancellationToken>())
            .Returns((AgentRegistration?)null);

        var handler = CreateActivityHandler();
        var command = CreateActivityCommand("nonexistent-agent", callerClientId: "any-client");

        var act = () => handler.Handle(command, CancellationToken.None);

        await act.Should().ThrowAsync<NotFoundException>();
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
        _agentRepository.GetByExternalAgentIdAsync("test-agent-order", Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateActivityHandler();
        var command = CreateActivityCommand("test-agent-order", callerClientId: "wrong-client");

        var act = () => handler.Handle(command, CancellationToken.None);

        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_IDENTITY_MISMATCH,
            "identity check must come before status check (fail-closed)");
    }

    // ---------------------------------------------------------------
    // SubmitInteractionHandler: identity mismatch
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitInteraction_Should_ThrowAgentIdentityMismatch_When_CallerClientIdDoesNotMatchAgent()
    {
        var agent = CreateAgent("test-agent-003", externalClientId: "correct-client-id");
        _agentRepository.GetByExternalAgentIdAsync("test-agent-003", Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateInteractionHandler();
        var command = CreateInteractionCommand("test-agent-003", callerClientId: "wrong-client-id");

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
        _agentRepository.GetByExternalAgentIdAsync("test-agent-004", Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateInteractionHandler();
        var command = CreateInteractionCommand("test-agent-004", callerClientId: "client-id-456");

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
        _agentRepository.GetByExternalAgentIdAsync("test-agent-int-order", Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateInteractionHandler();
        var command = CreateInteractionCommand("test-agent-int-order", callerClientId: "wrong-client");

        var act = () => handler.Handle(command, CancellationToken.None);

        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_IDENTITY_MISMATCH,
            "identity check must come before status check (fail-closed)");
    }

    // ---------------------------------------------------------------
    // SubmitInteractionHandler: agent not found
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitInteraction_Should_ThrowNotFoundException_When_AgentDoesNotExist()
    {
        _agentRepository.GetByExternalAgentIdAsync("nonexistent-agent-int", Arg.Any<CancellationToken>())
            .Returns((AgentRegistration?)null);

        var handler = CreateInteractionHandler();
        var command = CreateInteractionCommand("nonexistent-agent-int", callerClientId: "any-client");

        var act = () => handler.Handle(command, CancellationToken.None);

        await act.Should().ThrowAsync<NotFoundException>();
    }

    // ---------------------------------------------------------------
    // Both handlers: null ExternalClientId on agent triggers mismatch
    // ---------------------------------------------------------------

    [Fact]
    public async Task SubmitActivity_Should_ThrowAgentIdentityMismatch_When_AgentHasNullExternalClientId()
    {
        var agent = CreateAgent("test-agent-null-client", externalClientId: "placeholder");
        agent.ExternalClientId = null; // Simulate agent without bound client
        _agentRepository.GetByExternalAgentIdAsync("test-agent-null-client", Arg.Any<CancellationToken>())
            .Returns(agent);

        var handler = CreateActivityHandler();
        var command = CreateActivityCommand("test-agent-null-client", callerClientId: "some-client");

        var act = () => handler.Handle(command, CancellationToken.None);

        // null != "some-client" so identity mismatch is expected
        var ex = await act.Should().ThrowAsync<DomainException>();
        ex.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_IDENTITY_MISMATCH);
    }
}
