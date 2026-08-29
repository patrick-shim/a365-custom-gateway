using System.Text.Json;
using FluentAssertions;
using Gateway.Application.Common;
using Gateway.Application.Exceptions;
using Gateway.Application.Interactions.Commands;
using Gateway.Application.Prompts;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public class SubmitInteractionHandlerTests
{
    private static readonly Guid AgentRegistrationId =
        Guid.Parse("510a6458-10aa-446b-9db5-56a04a066422");
    private readonly IAgentRepository _agentRepository;
    private readonly IAiInteractionRepository _aiInteractionRepository;
    private readonly IInteractionContentStore _interactionContentStore;
    private readonly IPurviewPolicyClient _purviewPolicyClient;
    private readonly IIdempotencyService _idempotencyService;
    private readonly IIdempotencyScopeLease _idempotencyScopeLease;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IPromptEvaluationRepository _promptEvaluationRepository;
    private readonly IUnitOfWork _unitOfWork;
    private readonly SubmitInteractionHandler _handler;

    public SubmitInteractionHandlerTests()
    {
        _agentRepository = Substitute.For<IAgentRepository>();
        _aiInteractionRepository = Substitute.For<IAiInteractionRepository>();
        _interactionContentStore = Substitute.For<IInteractionContentStore>();
        _purviewPolicyClient = Substitute.For<IPurviewPolicyClient>();
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
        _promptEvaluationRepository = Substitute.For<IPromptEvaluationRepository>();
        _unitOfWork = Substitute.For<IUnitOfWork>();
        _handler = new SubmitInteractionHandler(
            _agentRepository,
            _aiInteractionRepository,
            _interactionContentStore,
            _purviewPolicyClient,
            _idempotencyService,
            _outboxRepository,
            _auditEventRepository,
            _promptEvaluationRepository,
            _unitOfWork,
            NullLogger<SubmitInteractionHandler>.Instance);
    }

    [Theory]
    [InlineData(ObservabilityMode.Agent365, null)]
    [InlineData(ObservabilityMode.Agent365, "not-a-guid")]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, null)]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, "00000000-0000-0000-0000-000000000000")]
    public async Task Handle_Should_RejectBeforeStoringOrQueueing_When_Agent365RequiresValidUserContext(
        ObservabilityMode mode,
        string? tenantUserObjectId)
    {
        var agent = CreateAgent(mode);
        var command = CreateCommand(tenantUserObjectId);
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);

        var act = () => _handler.Handle(command, CancellationToken.None);

        var exception = await act.Should().ThrowAsync<ValidationException>();
        exception.Which.Errors.Should().ContainKey("UserContext.TenantUserObjectId");
        await _interactionContentStore.DidNotReceiveWithAnyArgs()
            .StoreAsync(default, default, default!, default!, default!, default!, default);
        await _aiInteractionRepository.DidNotReceive()
            .AddAsync(Arg.Any<AiInteractionRecord>(), Arg.Any<CancellationToken>());
        await _outboxRepository.DidNotReceive()
            .AddAsync(Arg.Any<OutboxMessage>(), Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData(ObservabilityMode.Disabled)]
    [InlineData(ObservabilityMode.GatewayOnly)]
    public async Task Handle_Should_AllowMissingUserContext_When_Agent365IsNotADestination(
        ObservabilityMode mode)
    {
        var agent = CreateAgent(mode);
        var command = CreateCommand(tenantUserObjectId: null);
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);
        _interactionContentStore.StoreAsync(
                agent.Id,
                Arg.Any<Guid>(),
                command.Prompt.Content,
                command.Prompt.ContentType,
                command.Response.Content,
                command.Response.ContentType,
                Arg.Any<CancellationToken>())
            .Returns("https://content.invalid/interaction");

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Status.Should().Be(ProcessingStatus.Accepted.ToString());
        await _aiInteractionRepository.Received(1)
            .AddAsync(Arg.Any<AiInteractionRecord>(), Arg.Any<CancellationToken>());
    }

    [Theory]
    [InlineData(ObservabilityMode.Agent365, true, false)]
    [InlineData(ObservabilityMode.GatewayOnly, false, true)]
    [InlineData(ObservabilityMode.Agent365AzureMonitor, true, true)]
    public async Task Handle_Should_SnapshotResolvedObservabilityDestinationsInOutboxPayload(
        ObservabilityMode mode,
        bool expectedAgent365,
        bool expectedAzureMonitor)
    {
        var agent = CreateAgent(mode);
        var command = WithAllowedReceipt(CreateCommand(Guid.NewGuid().ToString("D")), agent);
        OutboxMessage? queuedMessage = null;
        _agentRepository.GetByIdAsync(command.CallerAgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);
        _interactionContentStore.StoreAsync(
                agent.Id,
                Arg.Any<Guid>(),
                command.Prompt.Content,
                command.Prompt.ContentType,
                command.Response.Content,
                command.Response.ContentType,
                Arg.Any<CancellationToken>())
            .Returns("https://content.invalid/interaction");
        _outboxRepository.AddAsync(
                Arg.Do<OutboxMessage>(message => queuedMessage = message),
                Arg.Any<CancellationToken>())
            .Returns(Task.CompletedTask);

        await _handler.Handle(command, CancellationToken.None);
        agent.FeatureConfiguration.ObservabilityMode = ObservabilityMode.Disabled;

        queuedMessage.Should().NotBeNull();
        queuedMessage!.MessageType.Should().Be("ExportInteraction");
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
        var command = CreateCommand(null) with { IdempotencyKey = "interaction-key" };
        var cachedResponse = new InteractionReceiptDto(
            Guid.NewGuid(),
            command.InteractionId,
            "Accepted",
            "PurviewDisabled",
            "Queued",
            "cached-correlation");
        var record = new IdempotencyRecord
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            IdempotencyKey = command.IdempotencyKey,
            RequestBodyHash = IdempotencyRequestHasher.Compute(command),
            Endpoint = IdempotencyRequestHasher.InteractionEndpoint,
            ResponseStatusCode = 202,
            ResponseBody = JsonSerializer.Serialize(cachedResponse),
            CreatedAtUtc = DateTime.UtcNow.AddMinutes(-1),
            ExpiresAtUtc = DateTime.UtcNow.AddHours(23)
        };
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);
        _idempotencyService.GetAsync(
                agent.Id,
                IdempotencyRequestHasher.InteractionEndpoint,
                command.IdempotencyKey,
                Arg.Any<DateTime>(),
                Arg.Any<CancellationToken>())
            .Returns(record);

        var result = await _handler.Handle(command, CancellationToken.None);

        result.Should().BeEquivalentTo(cachedResponse);
        await _interactionContentStore.DidNotReceiveWithAnyArgs()
            .StoreAsync(default, default, default!, default!, default!, default!, default);
        await _unitOfWork.DidNotReceiveWithAnyArgs().SaveChangesAsync(default);
    }

    [Fact]
    public async Task Handle_ShouldRejectSameScopedKey_WhenInteractionPayloadDiffers()
    {
        var agent = CreateAgent(ObservabilityMode.GatewayOnly);
        var command = CreateCommand(null) with { IdempotencyKey = "interaction-conflict" };
        var record = new IdempotencyRecord
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            IdempotencyKey = command.IdempotencyKey,
            RequestBodyHash = IdempotencyRequestHasher.Compute(command with
            {
                Prompt = new ContentDto("text/plain", "different prompt")
            }),
            Endpoint = IdempotencyRequestHasher.InteractionEndpoint,
            ResponseStatusCode = 202,
            ResponseBody = JsonSerializer.Serialize(new InteractionReceiptDto(
                Guid.NewGuid(),
                command.InteractionId,
                "Accepted",
                "PurviewDisabled",
                "Queued",
                "cached-correlation")),
            CreatedAtUtc = DateTime.UtcNow.AddMinutes(-1),
            ExpiresAtUtc = DateTime.UtcNow.AddHours(23)
        };
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);
        _idempotencyService.GetAsync(
                agent.Id,
                IdempotencyRequestHasher.InteractionEndpoint,
                command.IdempotencyKey,
                Arg.Any<DateTime>(),
                Arg.Any<CancellationToken>())
            .Returns(record);

        var action = () => _handler.Handle(command, CancellationToken.None);

        var exception = await action.Should().ThrowAsync<ConflictException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.IDEMPOTENCY_CONFLICT);
        await _interactionContentStore.DidNotReceiveWithAnyArgs()
            .StoreAsync(default, default, default!, default!, default!, default!, default);
    }

    [Fact]
    public async Task Handle_ShouldPersistScopedIdempotencyRecordWithCanonicalHash()
    {
        var agent = CreateAgent(ObservabilityMode.GatewayOnly);
        var command = CreateCommand(null) with { IdempotencyKey = "interaction-new" };
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>())
            .Returns(agent);
        _interactionContentStore.StoreAsync(
                agent.Id,
                Arg.Any<Guid>(),
                command.Prompt.Content,
                command.Prompt.ContentType,
                command.Response.Content,
                command.Response.ContentType,
                Arg.Any<CancellationToken>())
            .Returns("https://content.invalid/interaction");

        await _handler.Handle(command, CancellationToken.None);

        await _idempotencyService.Received(1).SaveAsync(
            Arg.Is<IdempotencyRecord>(record =>
                record.AgentRegistrationId == agent.Id &&
                record.Endpoint == IdempotencyRequestHasher.InteractionEndpoint &&
                record.IdempotencyKey == command.IdempotencyKey &&
                record.RequestBodyHash == IdempotencyRequestHasher.Compute(command) &&
                record.ResponseStatusCode == 202),
            Arg.Any<CancellationToken>());
        await _unitOfWork.Received(1).SaveChangesAsync(Arg.Any<CancellationToken>());
        await _idempotencyScopeLease.Received(1)
            .CompleteAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldSendRawContentAndAgentIdentityMetadataToPurview()
    {
        var agent = CreateAgent(ObservabilityMode.Agent365);
        agent.Agent365AgentId = Guid.NewGuid().ToString("D");
        agent.BlueprintId = Guid.NewGuid().ToString("D");
        agent.FeatureConfiguration.PurviewEnabled = true;
        agent.FeatureConfiguration.PurviewMode = PurviewMode.Enforce;
        var command = WithAllowedReceipt(CreateCommand(Guid.NewGuid().ToString("D")), agent);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
        _purviewPolicyClient.IsEnabled.Returns(true);
        _purviewPolicyClient.EvaluateInteractionAsync(
                Arg.Any<PurviewInteraction>(),
                Arg.Any<CancellationToken>())
            .Returns(new PurviewEvaluationResult(true, PurviewDecisionType.Allowed, null, "notModified"));
        _interactionContentStore.StoreAsync(
                agent.Id,
                Arg.Any<Guid>(),
                command.Prompt.Content,
                command.Prompt.ContentType,
                command.Response.Content,
                command.Response.ContentType,
                Arg.Any<CancellationToken>())
            .Returns("https://content.invalid/interaction");

        await _handler.Handle(command, CancellationToken.None);

        await _purviewPolicyClient.Received(1).EvaluateInteractionAsync(
            Arg.Is<PurviewInteraction>(value =>
                value.PromptContent == command.Prompt.Content
                && value.ResponseContent == command.Response.Content
                && value.AgentIdentityClientId == agent.Agent365AgentId
                && value.BlueprintClientId == agent.BlueprintId
                && value.ExternalInteractionId == command.InteractionId),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldNotStoreContent_WhenPurviewDecisionIsUnavailable()
    {
        var agent = CreateAgent(ObservabilityMode.Agent365);
        agent.Agent365AgentId = Guid.NewGuid().ToString("D");
        agent.BlueprintId = Guid.NewGuid().ToString("D");
        agent.FeatureConfiguration.PurviewEnabled = true;
        agent.FeatureConfiguration.PurviewMode = PurviewMode.Enforce;
        var command = WithAllowedReceipt(CreateCommand(Guid.NewGuid().ToString("D")), agent);
        _agentRepository.GetByIdAsync(agent.Id, Arg.Any<CancellationToken>()).Returns(agent);
        _purviewPolicyClient.IsEnabled.Returns(true);
        _purviewPolicyClient.EvaluateInteractionAsync(
                Arg.Any<PurviewInteraction>(),
                Arg.Any<CancellationToken>())
            .Returns<Task<PurviewEvaluationResult>>(_ => throw new PurviewPolicyException(
                "PURVIEW_GRAPH_HTTP_503",
                "Microsoft Graph is unavailable.",
                isTransient: true));

        var action = () => _handler.Handle(command, CancellationToken.None);

        var exception = await action.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PURVIEW_DEPENDENCY_UNAVAILABLE);
        await _interactionContentStore.DidNotReceiveWithAnyArgs()
            .StoreAsync(default, default, default!, default!, default!, default!, default);
        await _unitOfWork.DidNotReceive().SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task Handle_ShouldRejectBeforeSideEffects_WhenReceiptWasConsumedConcurrently()
    {
        var agent = CreateAgent(ObservabilityMode.Disabled);
        agent.FeatureConfiguration.PromptShieldEnabled = true;
        var command = WithAllowedReceipt(CreateCommand(null), agent) with
        {
            IdempotencyKey = Guid.NewGuid().ToString("D")
        };
        _agentRepository.GetByIdAsync(AgentRegistrationId, Arg.Any<CancellationToken>())
            .Returns(agent);
        _promptEvaluationRepository.TryConsumeAsync(
                command.PromptEvaluationReceiptId!.Value,
                Arg.Any<DateTime>(),
                Arg.Any<CancellationToken>())
            .Returns(false);

        var action = () => _handler.Handle(command, CancellationToken.None);

        var exception = await action.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROMPT_EVALUATION_INVALID);
        await _interactionContentStore.DidNotReceiveWithAnyArgs()
            .StoreAsync(default, default, default!, default!, default!, default!, default);
        await _purviewPolicyClient.DidNotReceiveWithAnyArgs()
            .EvaluateInteractionAsync(default!, default);
        await _unitOfWork.DidNotReceive().SaveChangesAsync(Arg.Any<CancellationToken>());
    }

    private static AgentRegistration CreateAgent(ObservabilityMode mode)
    {
        var agentId = AgentRegistrationId;

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

    private static SubmitInteractionCommand CreateCommand(string? tenantUserObjectId) =>
        new(
            ExternalAgentId: "agent-001",
            InteractionId: "interaction-001",
            SessionId: "session-001",
            OccurredAtUtc: DateTime.UtcNow.AddMinutes(-1),
            UserContext: tenantUserObjectId is null ? null : new UserContextDto(tenantUserObjectId),
            Prompt: new ContentDto("text/plain", "test prompt"),
            Response: new ContentDto("text/plain", "test response"),
            Model: null,
            Metadata: null,
            CallerAgentRegistrationId: AgentRegistrationId,
            IdempotencyKey: null);

    private SubmitInteractionCommand WithAllowedReceipt(
        SubmitInteractionCommand command,
        AgentRegistration agent)
    {
        var receiptId = Guid.NewGuid();
        var (salt, hash) = PromptReceiptSecurity.Create(
            command.Prompt.ContentType,
            command.Prompt.Content);
        _promptEvaluationRepository.GetByIdAsync(receiptId, Arg.Any<CancellationToken>())
            .Returns(new PromptEvaluationRecord
            {
                Id = receiptId,
                AgentRegistrationId = agent.Id,
                ExternalInteractionId = command.InteractionId,
                TenantUserObjectId = command.UserContext?.TenantUserObjectId ?? string.Empty,
                PromptHashSalt = salt,
                PromptHash = hash,
                Outcome = PromptEvaluationOutcome.Allowed,
                ExpiresAtUtc = DateTime.UtcNow.AddMinutes(5)
            });
        _promptEvaluationRepository.TryConsumeAsync(
                receiptId,
                Arg.Any<DateTime>(),
                Arg.Any<CancellationToken>())
            .Returns(true);
        return command with { PromptEvaluationReceiptId = receiptId };
    }
}
