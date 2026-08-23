using System.Text.Json;
using FluentAssertions;
using Gateway.Application.Activities.Commands;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public class SubmitActivityHandlerTests
{
    private readonly IAgentRepository _agentRepository;
    private readonly IActivityReceiptRepository _activityReceiptRepository;
    private readonly IIdempotencyService _idempotencyService;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;
    private readonly SubmitActivityHandler _handler;

    public SubmitActivityHandlerTests()
    {
        _agentRepository = Substitute.For<IAgentRepository>();
        _activityReceiptRepository = Substitute.For<IActivityReceiptRepository>();
        _idempotencyService = Substitute.For<IIdempotencyService>();
        _outboxRepository = Substitute.For<IOutboxRepository>();
        _auditEventRepository = Substitute.For<IAuditEventRepository>();
        _unitOfWork = Substitute.For<IUnitOfWork>();

        _handler = new SubmitActivityHandler(
            _agentRepository,
            _activityReceiptRepository,
            _idempotencyService,
            _outboxRepository,
            _auditEventRepository,
            _unitOfWork);
    }

    private static AgentRegistration CreateActiveAgent(string externalClientId = "client-001") =>
        new()
        {
            Id = Guid.NewGuid(),
            ExternalAgentId = new ExternalAgentId("agent-001"),
            Name = "Test Agent",
            OwnerObjectId = "owner-oid-001",
            Environment = AgentEnvironment.Development,
            Status = AgentStatus.Active,
            ExternalClientId = externalClientId,
            CreatedAtUtc = DateTime.UtcNow.AddDays(-1),
            UpdatedAtUtc = DateTime.UtcNow.AddDays(-1),
            CreatedByObjectId = "owner-oid-001",
            UpdatedByObjectId = "owner-oid-001"
        };

    private static SubmitActivityCommand CreateValidCommand(string callerClientId = "client-001") =>
        new(
            ExternalAgentId: "agent-001",
            ActivityId: "activity-001",
            SessionId: "session-001",
            ActivityType: "ToolInvocation",
            OccurredAtUtc: DateTime.UtcNow.AddMinutes(-5),
            Actor: new ActorDto("Agent"),
            Tool: null,
            Attributes: null,
            CallerClientId: callerClientId,
            IdempotencyKey: null);

    [Fact]
    public async Task Handle_Should_ReturnActivityReceipt_When_ValidSubmission()
    {
        var agent = CreateActiveAgent();
        var command = CreateValidCommand();

        _agentRepository.GetByExternalAgentIdAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(agent);

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Should().NotBeNull();
        result.ActivityId.Should().Be("activity-001");
        result.Status.Should().Be(ProcessingStatus.Accepted.ToString());
        result.ReceiptId.Should().NotBeEmpty();
        result.CorrelationId.Should().NotBeNullOrEmpty();
    }

    [Fact]
    public async Task Handle_Should_CreateActivityReceipt_When_ValidSubmission()
    {
        var agent = CreateActiveAgent();
        var command = CreateValidCommand();

        _agentRepository.GetByExternalAgentIdAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _activityReceiptRepository.Received(1).AddAsync(
            Arg.Is<ActivityReceipt>(r =>
                r.ExternalActivityId == "activity-001" &&
                r.ProcessingStatus == ProcessingStatus.Accepted &&
                r.AgentRegistrationId == agent.Id),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_CreateOutboxMessage_When_ValidSubmission()
    {
        var agent = CreateActiveAgent();
        var command = CreateValidCommand();

        _agentRepository.GetByExternalAgentIdAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _outboxRepository.Received(1).AddAsync(
            Arg.Is<OutboxMessage>(m =>
                m.MessageType == "ProcessActivity" &&
                m.Status == OutboxMessageStatus.Pending),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_CreateAuditEvent_When_ValidSubmission()
    {
        var agent = CreateActiveAgent();
        var command = CreateValidCommand();

        _agentRepository.GetByExternalAgentIdAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _auditEventRepository.Received(1).AddAsync(
            Arg.Is<AuditEvent>(e =>
                e.EventType == "ActivitySubmitted" &&
                e.AgentRegistrationId == agent.Id),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_CallSaveChanges_When_ValidSubmission()
    {
        var agent = CreateActiveAgent();
        var command = CreateValidCommand();

        _agentRepository.GetByExternalAgentIdAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _unitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_ThrowDomainException_When_CallerClientIdDoesNotMatchAgent()
    {
        var agent = CreateActiveAgent("registered-client-id");
        var command = CreateValidCommand("wrong-client-id");

        _agentRepository.GetByExternalAgentIdAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(agent);

        var act = () => _handler.Handle(command, CancellationToken.None);

        var exception = await act.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_IDENTITY_MISMATCH);
    }

    [Fact]
    public async Task Handle_Should_ThrowDomainException_When_AgentIsDisabled()
    {
        var agent = CreateActiveAgent();
        agent.Status = AgentStatus.Disabled;
        var command = CreateValidCommand();

        _agentRepository.GetByExternalAgentIdAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(agent);

        var act = () => _handler.Handle(command, CancellationToken.None);

        var exception = await act.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_DISABLED);
    }

    [Fact]
    public async Task Handle_Should_ThrowDomainException_When_AgentIsDraft()
    {
        var agent = CreateActiveAgent();
        agent.Status = AgentStatus.Draft;
        var command = CreateValidCommand();

        _agentRepository.GetByExternalAgentIdAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(agent);

        var act = () => _handler.Handle(command, CancellationToken.None);

        var exception = await act.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_DISABLED);
    }

    [Fact]
    public async Task Handle_Should_ThrowNotFoundException_When_AgentDoesNotExist()
    {
        var command = CreateValidCommand();

        _agentRepository.GetByExternalAgentIdAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns((AgentRegistration?)null);

        var act = () => _handler.Handle(command, CancellationToken.None);

        await act.Should().ThrowAsync<NotFoundException>();
    }

    [Fact]
    public async Task Handle_Should_ReturnCachedResponse_When_IdempotencyKeyMatchesExistingRecord()
    {
        var agent = CreateActiveAgent();
        var cachedReceipt = new ActivityReceiptDto(
            Guid.NewGuid(), "activity-001", "Accepted", DateTime.UtcNow.AddMinutes(-1), "corr-123");
        var cachedRecord = new IdempotencyRecord
        {
            Id = Guid.NewGuid(),
            IdempotencyKey = "idempotency-key-001",
            RequestBodyHash = "",
            Endpoint = "SubmitActivity",
            ResponseStatusCode = 202,
            ResponseBody = JsonSerializer.Serialize(cachedReceipt),
            CreatedAtUtc = DateTime.UtcNow.AddMinutes(-1),
            ExpiresAtUtc = DateTime.UtcNow.AddHours(23)
        };

        var command = CreateValidCommand() with { IdempotencyKey = "idempotency-key-001" };

        _agentRepository.GetByExternalAgentIdAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(agent);
        _idempotencyService.GetAsync("idempotency-key-001", Arg.Any<CancellationToken>())
            .Returns(cachedRecord);

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Should().NotBeNull();
        result.ActivityId.Should().Be("activity-001");
        result.ReceiptId.Should().Be(cachedReceipt.ReceiptId);

        // Should NOT create new records when returning cached response
        await _activityReceiptRepository.DidNotReceive()
            .AddAsync(Arg.Any<ActivityReceipt>(), Arg.Any<CancellationToken>());
        await _outboxRepository.DidNotReceive()
            .AddAsync(Arg.Any<OutboxMessage>(), Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_SaveIdempotencyRecord_When_IdempotencyKeyProvidedAndNoExistingRecord()
    {
        var agent = CreateActiveAgent();
        var command = CreateValidCommand() with { IdempotencyKey = "new-idempotency-key" };

        _agentRepository.GetByExternalAgentIdAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(agent);
        _idempotencyService.GetAsync("new-idempotency-key", Arg.Any<CancellationToken>())
            .Returns((IdempotencyRecord?)null);

        await _handler.Handle(command, CancellationToken.None);

        await _idempotencyService.Received(1).SaveAsync(
            Arg.Is<IdempotencyRecord>(r =>
                r.IdempotencyKey == "new-idempotency-key" &&
                r.Endpoint == "SubmitActivity" &&
                r.ResponseStatusCode == 202),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_NotSaveIdempotencyRecord_When_NoIdempotencyKeyProvided()
    {
        var agent = CreateActiveAgent();
        var command = CreateValidCommand(); // IdempotencyKey is null

        _agentRepository.GetByExternalAgentIdAsync(command.ExternalAgentId, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _idempotencyService.DidNotReceive()
            .SaveAsync(Arg.Any<IdempotencyRecord>(), Arg.Any<CancellationToken>());
    }
}
