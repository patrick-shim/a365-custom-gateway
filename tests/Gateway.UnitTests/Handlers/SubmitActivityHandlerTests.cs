using System.Text.Json;
using FluentAssertions;
using Gateway.Application.Activities.Commands;
using Gateway.Application.Common;
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
    private static readonly Guid AgentRegistrationId =
        Guid.Parse("e7289b82-2637-48ed-b394-6e3c1ff70262");
    private readonly IAgentRepository _agentRepository;
    private readonly IActivityReceiptRepository _activityReceiptRepository;
    private readonly IIdempotencyService _idempotencyService;
    private readonly IIdempotencyScopeLease _idempotencyScopeLease;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;
    private readonly SubmitActivityHandler _handler;

    public SubmitActivityHandlerTests()
    {
        _agentRepository = Substitute.For<IAgentRepository>();
        _activityReceiptRepository = Substitute.For<IActivityReceiptRepository>();
        _idempotencyService = Substitute.For<IIdempotencyService>();
        _idempotencyScopeLease = Substitute.For<IIdempotencyScopeLease>();
        _idempotencyService.AcquireScopeAsync(
                Arg.Any<Guid>(),
                Arg.Any<string>(),
                Arg.Any<string>(),
                Arg.Any<CancellationToken>())
            .Returns(Task.FromResult(_idempotencyScopeLease));
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
            Id = AgentRegistrationId,
            ExternalAgentId = new ExternalAgentId("agent-001"),
            Name = "Test Agent",
            OwnerObjectId = "owner-oid-001",
            Environment = AgentEnvironment.Development,
            Status = AgentStatus.Active,
            ExternalClientId = externalClientId,
            CreatedAtUtc = DateTime.UtcNow.AddDays(-1),
            UpdatedAtUtc = DateTime.UtcNow.AddDays(-1),
            CreatedByObjectId = "owner-oid-001",
            UpdatedByObjectId = "owner-oid-001",
            FeatureConfiguration = new AgentFeatureConfiguration
            {
                Id = Guid.NewGuid(),
                ObservabilityMode = ObservabilityMode.GatewayOnly,
                UpdatedAtUtc = DateTime.UtcNow.AddDays(-1)
            }
        };

    private static SubmitActivityCommand CreateValidCommand(
        Guid? callerAgentRegistrationId = null) =>
        new(
            ExternalAgentId: "agent-001",
            ActivityId: "activity-001",
            SessionId: "session-001",
            ActivityType: "ToolInvocation",
            OccurredAtUtc: DateTime.UtcNow.AddMinutes(-5),
            Actor: new ActorDto("Agent"),
            Tool: null,
            Attributes: null,
            CallerAgentRegistrationId:
                callerAgentRegistrationId ?? AgentRegistrationId,
            IdempotencyKey: null);

    [Fact]
    public async Task Handle_Should_ReturnActivityReceipt_When_ValidSubmission()
    {
        var agent = CreateActiveAgent();
        var command = CreateValidCommand();

        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
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

        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
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

        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _outboxRepository.Received(1).AddAsync(
            Arg.Is<OutboxMessage>(m =>
                m.MessageType == "ProcessActivity" &&
                m.Status == OutboxMessageStatus.Pending),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_IncludeTenantUserObjectIdInSanitizedOutboxPayload_WhenProvided()
    {
        var agent = CreateActiveAgent();
        var tenantUserObjectId = Guid.NewGuid();
        var command = CreateValidCommand() with
        {
            Actor = new ActorDto("User", tenantUserObjectId.ToString())
        };
        OutboxMessage? createdMessage = null;
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);
        _outboxRepository.AddAsync(
                Arg.Do<OutboxMessage>(message => createdMessage = message),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        await _handler.Handle(command, CancellationToken.None);

        createdMessage.Should().NotBeNull();
        using var payload = JsonDocument.Parse(createdMessage!.Payload);
        payload.RootElement.GetProperty("ActorTenantUserObjectId").GetString()
            .Should().Be(tenantUserObjectId.ToString());
    }

    [Theory]
    [InlineData(ObservabilityMode.Disabled, false, false)]
    [InlineData(ObservabilityMode.GatewayOnly, false, true)]
    [InlineData(ObservabilityMode.Agent365, true, false)]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, true, true)]
    public async Task Handle_Should_SnapshotResolvedObservabilityDestinationsInOutboxPayload(
        ObservabilityMode mode,
        bool expectedAgent365,
        bool expectedAzureMonitor)
    {
        var agent = CreateActiveAgent();
        agent.FeatureConfiguration.ObservabilityMode = mode;
        var command = CreateValidCommand() with
        {
            Actor = new ActorDto("User", Guid.NewGuid().ToString("D"))
        };
        OutboxMessage? queuedMessage = null;
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);
        _outboxRepository.AddAsync(
                Arg.Do<OutboxMessage>(message => queuedMessage = message),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        await _handler.Handle(command, CancellationToken.None);
        agent.FeatureConfiguration.ObservabilityMode = ObservabilityMode.Disabled;

        queuedMessage.Should().NotBeNull();
        queuedMessage!.MessageType.Should().Be("ProcessActivity");
        using var payload = JsonDocument.Parse(queuedMessage.Payload);
        payload.RootElement.GetProperty("Agent365ObservabilityEnabled").GetBoolean()
            .Should().Be(expectedAgent365);
        payload.RootElement.GetProperty("AzureMonitorExportEnabled").GetBoolean()
            .Should().Be(expectedAzureMonitor);
    }

    [Fact]
    public async Task Handle_Should_CreateAuditEvent_When_ValidSubmission()
    {
        var agent = CreateActiveAgent();
        var command = CreateValidCommand();

        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
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

        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _unitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_Should_ThrowDomainException_When_BodyAgentDoesNotMatchCallerRegistration()
    {
        var agent = CreateActiveAgent("registered-client-id");
        var command = CreateValidCommand() with { ExternalAgentId = "different-agent" };

        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
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

        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
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

        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);

        var act = () => _handler.Handle(command, CancellationToken.None);

        var exception = await act.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_DISABLED);
    }

    [Fact]
    public async Task Handle_Should_ThrowIdentityMismatch_When_CallerRegistrationDoesNotExist()
    {
        var command = CreateValidCommand();

        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns((AgentRegistration?)null);

        var act = () => _handler.Handle(command, CancellationToken.None);

        var exception = await act.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.AGENT_IDENTITY_MISMATCH);
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
            AgentRegistrationId = agent.Id,
            IdempotencyKey = "idempotency-key-001",
            Endpoint = IdempotencyRequestHasher.ActivityEndpoint,
            ResponseStatusCode = 202,
            ResponseBody = JsonSerializer.Serialize(cachedReceipt),
            CreatedAtUtc = DateTime.UtcNow.AddMinutes(-1),
            ExpiresAtUtc = DateTime.UtcNow.AddHours(23)
        };

        var command = CreateValidCommand() with { IdempotencyKey = "idempotency-key-001" };
        cachedRecord.RequestBodyHash = IdempotencyRequestHasher.Compute(command);

        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);
        _idempotencyService.GetAsync(
                agent.Id,
                IdempotencyRequestHasher.ActivityEndpoint,
                "idempotency-key-001",
                Arg.Any<DateTime>(),
                Arg.Any<CancellationToken>())
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

        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);
        _idempotencyService.GetAsync(
                agent.Id,
                IdempotencyRequestHasher.ActivityEndpoint,
                "new-idempotency-key",
                Arg.Any<DateTime>(),
                Arg.Any<CancellationToken>())
            .Returns((IdempotencyRecord?)null);

        await _handler.Handle(command, CancellationToken.None);

        await _idempotencyService.Received(1).SaveAsync(
            Arg.Is<IdempotencyRecord>(r =>
                r.IdempotencyKey == "new-idempotency-key" &&
                r.AgentRegistrationId == agent.Id &&
                r.Endpoint == IdempotencyRequestHasher.ActivityEndpoint &&
                r.RequestBodyHash == IdempotencyRequestHasher.Compute(command) &&
                r.ResponseStatusCode == 202),
            Arg.Any<CancellationToken>());
        await _idempotencyScopeLease.Received(1)
            .CompleteAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldRejectSameScopedKeyForDifferentPayload()
    {
        var agent = CreateActiveAgent();
        var command = CreateValidCommand() with { IdempotencyKey = "conflicting-key" };
        var cachedRecord = new IdempotencyRecord
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            IdempotencyKey = command.IdempotencyKey,
            RequestBodyHash = IdempotencyRequestHasher.Compute(command with
            {
                ActivityId = "different-activity"
            }),
            Endpoint = IdempotencyRequestHasher.ActivityEndpoint,
            ResponseStatusCode = 202,
            ResponseBody = JsonSerializer.Serialize(new ActivityReceiptDto(
                Guid.NewGuid(),
                "different-activity",
                "Accepted",
                DateTime.UtcNow,
                "cached-correlation")),
            CreatedAtUtc = DateTime.UtcNow.AddMinutes(-1),
            ExpiresAtUtc = DateTime.UtcNow.AddHours(23)
        };
        _agentRepository.GetByIdAsync(
                command.CallerAgentRegistrationId,
                Arg.Any<CancellationToken>())
            .Returns(agent);
        _idempotencyService.GetAsync(
                agent.Id,
                IdempotencyRequestHasher.ActivityEndpoint,
                command.IdempotencyKey,
                Arg.Any<DateTime>(),
                Arg.Any<CancellationToken>())
            .Returns(cachedRecord);

        var action = () => _handler.Handle(command, CancellationToken.None);

        var exception = await action.Should().ThrowAsync<ConflictException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.IDEMPOTENCY_CONFLICT);
        await _activityReceiptRepository.DidNotReceiveWithAnyArgs()
            .AddAsync(default!, default);
        await _unitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_Should_NotSaveIdempotencyRecord_When_NoIdempotencyKeyProvided()
    {
        var agent = CreateActiveAgent();
        var command = CreateValidCommand(); // IdempotencyKey is null

        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);

        await _handler.Handle(command, CancellationToken.None);

        await _idempotencyService.DidNotReceive()
            .SaveAsync(Arg.Any<IdempotencyRecord>(), Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData(ObservabilityMode.Agent365, "Agent")]
    [InlineData(ObservabilityMode.Agent365, "System")]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, "Agent")]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, "System")]
    public async Task Handle_Should_RejectUnsupportedActorBeforePersistence_When_Agent365IsADestination(
        ObservabilityMode mode,
        string actorType)
    {
        var agent = CreateActiveAgent();
        agent.FeatureConfiguration.ObservabilityMode = mode;
        var command = CreateValidCommand() with
        {
            Actor = new ActorDto(actorType)
        };
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);

        var act = () => _handler.Handle(command, CancellationToken.None);

        var exception = await act.Should().ThrowAsync<ValidationException>();
        exception.Which.Errors.Should().ContainKey("Actor.Type")
            .WhoseValue.Should().ContainSingle()
            .Which.Should().Be("Actor.Type must be User when Agent 365 observability is enabled.");
        await _activityReceiptRepository.DidNotReceive()
            .AddAsync(Arg.Any<ActivityReceipt>(), Arg.Any<CancellationToken>());
        await _outboxRepository.DidNotReceive()
            .AddAsync(Arg.Any<OutboxMessage>(), Arg.Any<CancellationToken>());
        await _unitOfWork.DidNotReceive()
            .SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData(ObservabilityMode.Agent365, null)]
    [InlineData(ObservabilityMode.Agent365, "not-a-guid")]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, null)]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, "00000000-0000-0000-0000-000000000000")]
    public async Task Handle_Should_RejectBeforePersistence_When_Agent365RequiresValidUserContext(
        ObservabilityMode mode,
        string? tenantUserObjectId)
    {
        var agent = CreateActiveAgent();
        agent.FeatureConfiguration.ObservabilityMode = mode;
        var command = CreateValidCommand() with
        {
            Actor = new ActorDto("User", tenantUserObjectId)
        };
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);

        var act = () => _handler.Handle(command, CancellationToken.None);

        var exception = await act.Should().ThrowAsync<ValidationException>();
        exception.Which.Errors.Should().ContainKey("Actor.TenantUserObjectId");
        await _activityReceiptRepository.DidNotReceive()
            .AddAsync(Arg.Any<ActivityReceipt>(), Arg.Any<CancellationToken>());
        await _outboxRepository.DidNotReceive()
            .AddAsync(Arg.Any<OutboxMessage>(), Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData(ObservabilityMode.Disabled, "Agent")]
    [InlineData(ObservabilityMode.Disabled, "System")]
    [InlineData(ObservabilityMode.GatewayOnly, "Agent")]
    [InlineData(ObservabilityMode.GatewayOnly, "System")]
    public async Task Handle_Should_AllowAgentAndSystemActors_When_Agent365IsNotADestination(
        ObservabilityMode mode,
        string actorType)
    {
        var agent = CreateActiveAgent();
        agent.FeatureConfiguration.ObservabilityMode = mode;
        var command = CreateValidCommand() with
        {
            Actor = new ActorDto(actorType)
        };
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Status.Should().Be(ProcessingStatus.Accepted.ToString());
        await _activityReceiptRepository.Received(1)
            .AddAsync(Arg.Any<ActivityReceipt>(), Arg.Any<CancellationToken>());
    }
}
