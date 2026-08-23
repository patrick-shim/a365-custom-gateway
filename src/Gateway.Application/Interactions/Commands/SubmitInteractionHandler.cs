using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using MediatR;

namespace Gateway.Application.Interactions.Commands;

internal sealed class SubmitInteractionHandler : IRequestHandler<SubmitInteractionCommand, InteractionReceiptDto>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IAiInteractionRepository _aiInteractionRepository;
    private readonly IInteractionContentStore _interactionContentStore;
    private readonly IPurviewPolicyClient _purviewPolicyClient;
    private readonly IIdempotencyService _idempotencyService;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;

    public SubmitInteractionHandler(
        IAgentRepository agentRepository,
        IAiInteractionRepository aiInteractionRepository,
        IInteractionContentStore interactionContentStore,
        IPurviewPolicyClient purviewPolicyClient,
        IIdempotencyService idempotencyService,
        IOutboxRepository outboxRepository,
        IAuditEventRepository auditEventRepository,
        IUnitOfWork unitOfWork)
    {
        _agentRepository = agentRepository;
        _aiInteractionRepository = aiInteractionRepository;
        _interactionContentStore = interactionContentStore;
        _purviewPolicyClient = purviewPolicyClient;
        _idempotencyService = idempotencyService;
        _outboxRepository = outboxRepository;
        _auditEventRepository = auditEventRepository;
        _unitOfWork = unitOfWork;
    }

    public async Task<InteractionReceiptDto> Handle(SubmitInteractionCommand request, CancellationToken ct)
    {
        var agent = await _agentRepository.GetByExternalAgentIdAsync(request.ExternalAgentId, ct)
            ?? throw new NotFoundException("AgentRegistration", request.ExternalAgentId);

        if (agent.ExternalClientId != request.CallerClientId)
            throw new DomainException("Caller identity does not match the registered agent.", ErrorCodes.AGENT_IDENTITY_MISMATCH);

        if (agent.Status != AgentStatus.Active)
            throw new DomainException("Agent is not active.", ErrorCodes.AGENT_DISABLED);

        if (request.IdempotencyKey is not null)
        {
            var existing = await _idempotencyService.GetAsync(request.IdempotencyKey, ct);
            if (existing is not null)
                return JsonSerializer.Deserialize<InteractionReceiptDto>(existing.ResponseBody)!;
        }

        var correlationId = Guid.NewGuid().ToString();
        var recordId = Guid.NewGuid();

        var contentBlobUri = await _interactionContentStore.StoreAsync(
            agent.Id,
            recordId,
            request.Prompt.Content,
            request.Prompt.ContentType,
            request.Response.Content,
            request.Response.ContentType,
            ct);

        var interaction = new AiInteractionRecord
        {
            Id = recordId,
            AgentRegistrationId = agent.Id,
            ExternalInteractionId = request.InteractionId,
            SessionId = request.SessionId,
            TenantUserObjectId = request.UserContext?.TenantUserObjectId,
            ContentBlobUri = contentBlobUri,
            ModelProvider = request.Model?.Provider,
            ModelName = request.Model?.Name,
            ProcessingStatus = ProcessingStatus.Accepted,
            PurviewStatus = PurviewDecisionType.PurviewDisabled,
            ObservabilityStatus = "Pending",
            CorrelationId = correlationId,
            OccurredAtUtc = request.OccurredAtUtc,
            ReceivedAtUtc = DateTime.UtcNow
        };

        if (agent.FeatureConfiguration.PurviewEnabled && request.UserContext?.TenantUserObjectId is not null)
        {
            var purviewInteraction = new PurviewInteraction(
                agent.Id,
                request.UserContext.TenantUserObjectId,
                contentBlobUri,
                contentBlobUri,
                request.Model?.Provider,
                request.Model?.Name,
                agent.FeatureConfiguration.PurviewMode == PurviewMode.Enforce
                    ? PurviewExecutionMode.EvaluateInline
                    : PurviewExecutionMode.EvaluateOffline,
                correlationId);

            var evalResult = await _purviewPolicyClient.EvaluateInteractionAsync(purviewInteraction, ct);

            var purviewDecision = new PurviewDecision
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agent.Id,
                AiInteractionRecordId = recordId,
                Decision = evalResult.Decision,
                PolicyAction = evalResult.PolicyAction,
                ExecutionMode = agent.FeatureConfiguration.PurviewMode == PurviewMode.Enforce
                    ? PurviewExecutionMode.EvaluateInline
                    : PurviewExecutionMode.EvaluateOffline,
                ProtectionScopeId = evalResult.ProtectionScopeId,
                TenantUserObjectId = request.UserContext.TenantUserObjectId,
                EvaluatedAtUtc = DateTime.UtcNow
            };

            interaction.PurviewStatus = evalResult.Decision;
            interaction.PurviewDecision = purviewDecision;

            if (agent.FeatureConfiguration.PurviewMode == PurviewMode.Enforce && !evalResult.IsAllowed)
                interaction.ProcessingStatus = ProcessingStatus.Failed;
        }
        else if (agent.FeatureConfiguration.PurviewEnabled)
        {
            interaction.PurviewStatus = PurviewDecisionType.PurviewSkipped_NoUserContext;
        }
        else
        {
            interaction.PurviewStatus = PurviewDecisionType.PurviewDisabled;
        }

        await _aiInteractionRepository.AddAsync(interaction, ct);

        if (agent.FeatureConfiguration.ObservabilityMode != ObservabilityMode.Disabled
            && interaction.ProcessingStatus != ProcessingStatus.Failed)
        {
            var outboxMessage = new OutboxMessage
            {
                Id = Guid.NewGuid(),
                MessageType = "ExportInteraction",
                Payload = JsonSerializer.Serialize(new { AgentId = agent.Id, RecordId = recordId, CorrelationId = correlationId }),
                Status = OutboxMessageStatus.Pending,
                RetryCount = 0,
                CreatedAtUtc = DateTime.UtcNow
            };

            await _outboxRepository.AddAsync(outboxMessage, ct);

            interaction.ObservabilityStatus = "Queued";
        }

        var auditEvent = new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "InteractionSubmitted",
            CorrelationId = correlationId,
            OccurredAtUtc = DateTime.UtcNow
        };

        await _auditEventRepository.AddAsync(auditEvent, ct);

        var response = new InteractionReceiptDto(
            recordId,
            request.InteractionId,
            interaction.ProcessingStatus.ToString(),
            interaction.PurviewStatus.ToString(),
            interaction.ObservabilityStatus,
            correlationId);

        if (request.IdempotencyKey is not null)
        {
            var idempotencyRecord = new IdempotencyRecord
            {
                Id = Guid.NewGuid(),
                IdempotencyKey = request.IdempotencyKey,
                RequestBodyHash = string.Empty,
                Endpoint = "SubmitInteraction",
                ResponseStatusCode = 202,
                ResponseBody = JsonSerializer.Serialize(response),
                CreatedAtUtc = DateTime.UtcNow,
                ExpiresAtUtc = DateTime.UtcNow.AddHours(24)
            };

            await _idempotencyService.SaveAsync(idempotencyRecord, ct);
        }

        await _unitOfWork.SaveChangesAsync(ct);

        return response;
    }
}
