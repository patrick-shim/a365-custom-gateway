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

public class SubmitBatchActivityHandlerTests
{
    private readonly IAgentRepository _agentRepository;
    private readonly IActivityReceiptRepository _activityReceiptRepository;
    private readonly IIdempotencyService _idempotencyService;
    private readonly IIdempotencyScopeLease _idempotencyScopeLease;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;
    private readonly SubmitBatchActivityHandler _handler;

    public SubmitBatchActivityHandlerTests()
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
        _handler = new SubmitBatchActivityHandler(
            _agentRepository,
            _activityReceiptRepository,
            _idempotencyService,
            _outboxRepository,
            _auditEventRepository,
            _unitOfWork);
    }

    [Theory]
    [InlineData(ObservabilityMode.Agent365, null)]
    [InlineData(ObservabilityMode.Agent365, "not-a-guid")]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, null)]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, "00000000-0000-0000-0000-000000000000")]
    public async Task Handle_Should_RejectOnlyInvalidItemsBeforePersistence_When_Agent365RequiresUserContext(
        ObservabilityMode mode,
        string? invalidTenantUserObjectId)
    {
        var agent = CreateAgent(mode);
        var invalidItem = CreateItem("activity-invalid", invalidTenantUserObjectId);
        var validItem = CreateItem("activity-valid", Guid.NewGuid().ToString());
        var command = new SubmitBatchActivityCommand(
            "agent-001",
            [invalidItem, validItem],
            agent.Id);
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);
        _activityReceiptRepository.ExistsByExternalIdAsync(
                agent.Id,
                Arg.Any<string>(),
                Arg.Any<CancellationToken>())
            .Returns(false);

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Accepted.Should().Be(1);
        result.Rejected.Should().Be(1);
        var expectedDetail = invalidTenantUserObjectId is null
            ? "A valid tenant user object ID is required when Agent 365 observability is enabled."
            : "Tenant user object ID must be a valid, non-empty GUID.";
        result.Items.Should().ContainEquivalentOf(new BatchActivityItemResult(
            "activity-invalid",
            "Rejected",
            null,
            ErrorCodes.VALIDATION_FAILED,
            expectedDetail));
        await _activityReceiptRepository.DidNotReceive()
            .ExistsByExternalIdAsync(agent.Id, "activity-invalid", Arg.Any<CancellationToken>());
        await _activityReceiptRepository.Received(1)
            .AddAsync(
                Arg.Is<ActivityReceipt>(receipt => receipt.ExternalActivityId == "activity-valid"),
                Arg.Any<CancellationToken>());
        await _outboxRepository.Received(1)
            .AddAsync(Arg.Any<OutboxMessage>(), Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData(ObservabilityMode.Agent365, "Agent")]
    [InlineData(ObservabilityMode.Agent365, "System")]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, "Agent")]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, "System")]
    public async Task Handle_Should_RejectOnlyUnsupportedActorItem_When_Agent365IsADestination(
        ObservabilityMode mode,
        string unsupportedActorType)
    {
        var agent = CreateAgent(mode);
        var unsupportedItem = CreateItem(
            "activity-unsupported",
            null,
            unsupportedActorType);
        var validItem = CreateItem("activity-valid", Guid.NewGuid().ToString("D"));
        var command = new SubmitBatchActivityCommand(
            "agent-001",
            [unsupportedItem, validItem],
            agent.Id);
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);
        _activityReceiptRepository.ExistsByExternalIdAsync(
                agent.Id,
                Arg.Any<string>(),
                Arg.Any<CancellationToken>())
            .Returns(false);

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Accepted.Should().Be(1);
        result.Rejected.Should().Be(1);
        result.Items.Should().ContainEquivalentOf(new BatchActivityItemResult(
            "activity-unsupported",
            "Rejected",
            null,
            ErrorCodes.VALIDATION_FAILED,
            "Actor.Type must be User when Agent 365 observability is enabled."));
        await _activityReceiptRepository.DidNotReceive()
            .ExistsByExternalIdAsync(agent.Id, "activity-unsupported", Arg.Any<CancellationToken>());
        await _activityReceiptRepository.Received(1)
            .AddAsync(
                Arg.Is<ActivityReceipt>(receipt => receipt.ExternalActivityId == "activity-valid"),
                Arg.Any<CancellationToken>());
        await _outboxRepository.Received(1)
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
        var agent = CreateAgent(mode);
        var command = new SubmitBatchActivityCommand(
            "agent-001",
            [CreateItem("activity-001", null, actorType)],
            agent.Id);
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);
        _activityReceiptRepository.ExistsByExternalIdAsync(
                agent.Id,
                Arg.Any<string>(),
                Arg.Any<CancellationToken>())
            .Returns(false);

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Accepted.Should().Be(1);
        result.Rejected.Should().Be(0);
        await _activityReceiptRepository.Received(1)
            .AddAsync(Arg.Any<ActivityReceipt>(), Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData(ObservabilityMode.Disabled)]
    [InlineData(ObservabilityMode.GatewayOnly)]
    public async Task Handle_Should_RejectInvalidUserContext_When_Agent365IsNotADestination(
        ObservabilityMode mode)
    {
        var agent = CreateAgent(mode);
        var command = new SubmitBatchActivityCommand(
            "agent-001",
            [CreateItem("activity-001", "not-a-guid")],
            agent.Id);
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Accepted.Should().Be(0);
        result.Rejected.Should().Be(1);
        result.Items.Single().Code.Should().Be(ErrorCodes.VALIDATION_FAILED);
        await _activityReceiptRepository.DidNotReceive()
            .AddAsync(Arg.Any<ActivityReceipt>(), Arg.Any<CancellationToken>());
        await _outboxRepository.DidNotReceive()
            .AddAsync(Arg.Any<OutboxMessage>(), Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData(ObservabilityMode.Disabled, false, false)]
    [InlineData(ObservabilityMode.GatewayOnly, false, true)]
    [InlineData(ObservabilityMode.Agent365, true, false)]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, true, true)]
    public async Task Handle_Should_SnapshotResolvedObservabilityDestinationsInEachOutboxPayload(
        ObservabilityMode mode,
        bool expectedAgent365,
        bool expectedAzureMonitor)
    {
        var agent = CreateAgent(mode);
        var command = new SubmitBatchActivityCommand(
            "agent-001",
            [CreateItem("activity-001", Guid.NewGuid().ToString("D"))],
            agent.Id);
        OutboxMessage? queuedMessage = null;
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);
        _activityReceiptRepository.ExistsByExternalIdAsync(
                agent.Id,
                Arg.Any<string>(),
                Arg.Any<CancellationToken>())
            .Returns(false);
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
    public async Task Handle_ShouldReturnCachedResponse_WhenScopedKeyAndPayloadMatch()
    {
        var agent = CreateAgent(ObservabilityMode.GatewayOnly);
        var command = new SubmitBatchActivityCommand(
            "agent-001",
            [CreateItem("activity-idempotent", null)],
            agent.Id,
            "batch-key");
        var cachedResponse = new BatchActivityResponse(
            1,
            0,
            [new BatchActivityItemResult(
                "activity-idempotent",
                "Accepted",
                Guid.NewGuid(),
                null,
                null)],
            "cached-correlation");
        var record = new IdempotencyRecord
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            IdempotencyKey = command.IdempotencyKey!,
            RequestBodyHash = IdempotencyRequestHasher.Compute(command),
            Endpoint = IdempotencyRequestHasher.BatchActivityEndpoint,
            ResponseStatusCode = 202,
            ResponseBody = JsonSerializer.Serialize(cachedResponse),
            CreatedAtUtc = DateTime.UtcNow.AddMinutes(-1),
            ExpiresAtUtc = DateTime.UtcNow.AddHours(23)
        };
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);
        _idempotencyService.GetAsync(
                agent.Id,
                IdempotencyRequestHasher.BatchActivityEndpoint,
                command.IdempotencyKey!,
                Arg.Any<DateTime>(),
                Arg.Any<CancellationToken>())
            .Returns(record);

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Should().BeEquivalentTo(cachedResponse);
        await _activityReceiptRepository.DidNotReceiveWithAnyArgs()
            .AddAsync(default!, default);
        await _unitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_ShouldRejectSameScopedKey_WhenBatchPayloadDiffers()
    {
        var agent = CreateAgent(ObservabilityMode.GatewayOnly);
        var command = new SubmitBatchActivityCommand(
            "agent-001",
            [CreateItem("activity-current", null)],
            agent.Id,
            "batch-conflict");
        var record = new IdempotencyRecord
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            IdempotencyKey = command.IdempotencyKey!,
            RequestBodyHash = IdempotencyRequestHasher.Compute(command with
            {
                Activities = [CreateItem("activity-different", null)]
            }),
            Endpoint = IdempotencyRequestHasher.BatchActivityEndpoint,
            ResponseStatusCode = 202,
            ResponseBody = JsonSerializer.Serialize(new BatchActivityResponse(
                1,
                0,
                [],
                "cached-correlation")),
            CreatedAtUtc = DateTime.UtcNow.AddMinutes(-1),
            ExpiresAtUtc = DateTime.UtcNow.AddHours(23)
        };
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);
        _idempotencyService.GetAsync(
                agent.Id,
                IdempotencyRequestHasher.BatchActivityEndpoint,
                command.IdempotencyKey!,
                Arg.Any<DateTime>(),
                Arg.Any<CancellationToken>())
            .Returns(record);

        var action = () => _handler.Handle(command, CancellationToken.None);

        var exception = await action.Should().ThrowAsync<ConflictException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.IDEMPOTENCY_CONFLICT);
        await _activityReceiptRepository.DidNotReceiveWithAnyArgs()
            .AddAsync(default!, default);
    }

    [Fact]
    public async Task Handle_ShouldPersistScopedIdempotencyRecordWithCanonicalHash()
    {
        var agent = CreateAgent(ObservabilityMode.GatewayOnly);
        var command = new SubmitBatchActivityCommand(
            "agent-001",
            [CreateItem("activity-new", null)],
            agent.Id,
            "batch-new-key");
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);
        _activityReceiptRepository.ExistsByExternalIdAsync(
                agent.Id,
                "activity-new",
                Arg.Any<CancellationToken>())
            .Returns(false);

        await _handler.Handle(command, CancellationToken.None);

        await _idempotencyService.Received(1).SaveAsync(
            Arg.Is<IdempotencyRecord>(record =>
                record.AgentRegistrationId == agent.Id &&
                record.Endpoint == IdempotencyRequestHasher.BatchActivityEndpoint &&
                record.IdempotencyKey == command.IdempotencyKey &&
                record.RequestBodyHash == IdempotencyRequestHasher.Compute(command) &&
                record.ResponseStatusCode == 202),
            Arg.Any<CancellationToken>());
        await _unitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
        await _idempotencyScopeLease.Received(1)
            .CompleteAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldAbortWholeBatch_WhenUnexpectedPersistenceFailureOccurs()
    {
        var agent = CreateAgent(ObservabilityMode.GatewayOnly);
        var command = new SubmitBatchActivityCommand(
            "agent-001",
            [CreateItem("activity-failure", null)],
            agent.Id,
            "batch-failure-key");
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);
        _activityReceiptRepository.ExistsByExternalIdAsync(
                agent.Id,
                "activity-failure",
                Arg.Any<CancellationToken>())
            .Returns<bool>(_ => throw new InvalidOperationException("provider detail"));

        var action = () => _handler.Handle(command, CancellationToken.None);

        await action.Should().ThrowAsync<InvalidOperationException>();
        await _idempotencyService.DidNotReceiveWithAnyArgs()
            .SaveAsync(default!, default);
        await _unitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    private static AgentRegistration CreateAgent(ObservabilityMode mode)
    {
        var agentId = Guid.NewGuid();

        return new AgentRegistration
        {
            Id = agentId,
            ExternalAgentId = new ExternalAgentId("agent-001"),
            Name = "Test Agent",
            ExternalClientId = "client-001",
            OwnerObjectId = Guid.NewGuid().ToString(),
            Environment = AgentEnvironment.Development,
            Status = AgentStatus.Active,
            CreatedAtUtc = DateTime.UtcNow.AddDays(-1),
            UpdatedAtUtc = DateTime.UtcNow.AddDays(-1),
            CreatedByObjectId = Guid.NewGuid().ToString(),
            UpdatedByObjectId = Guid.NewGuid().ToString(),
            FeatureConfiguration = new AgentFeatureConfiguration
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agentId,
                ObservabilityMode = mode,
                PurviewEnabled = false,
                UpdatedAtUtc = DateTime.UtcNow.AddDays(-1)
            }
        };
    }

    private static BatchActivityItemDto CreateItem(
        string activityId,
        string? tenantUserObjectId,
        string actorType = "User") =>
        new(
            ActivityId: activityId,
            SessionId: "session-001",
            ActivityType: "Chat",
            OccurredAtUtc: DateTime.UtcNow.AddMinutes(-1),
            Actor: new ActorDto(actorType, tenantUserObjectId),
            Tool: null,
            Attributes: null);
}
