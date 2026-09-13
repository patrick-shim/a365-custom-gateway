using System.Text.Json;
using Gateway.Application.Common;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Application.Prompts;
using MediatR;
using Microsoft.Extensions.Logging;

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
    private readonly IPromptEvaluationRepository _promptEvaluationRepository;
    private readonly IUnitOfWork _unitOfWork;
    private readonly ILogger<SubmitInteractionHandler> _logger;
    private readonly ProtectionEffectiveFeatureEvaluator? _protectionFeatures;

    public SubmitInteractionHandler(
        IAgentRepository agentRepository,
        IAiInteractionRepository aiInteractionRepository,
        IInteractionContentStore interactionContentStore,
        IPurviewPolicyClient purviewPolicyClient,
        IIdempotencyService idempotencyService,
        IOutboxRepository outboxRepository,
        IAuditEventRepository auditEventRepository,
        IPromptEvaluationRepository promptEvaluationRepository,
        IUnitOfWork unitOfWork,
        ILogger<SubmitInteractionHandler> logger,
        ProtectionEffectiveFeatureEvaluator? protectionFeatures = null)
    {
        _agentRepository = agentRepository;
        _aiInteractionRepository = aiInteractionRepository;
        _interactionContentStore = interactionContentStore;
        _purviewPolicyClient = purviewPolicyClient;
        _idempotencyService = idempotencyService;
        _outboxRepository = outboxRepository;
        _auditEventRepository = auditEventRepository;
        _promptEvaluationRepository = promptEvaluationRepository;
        _unitOfWork = unitOfWork;
        _logger = logger;
        _protectionFeatures = protectionFeatures;
    }

    public async Task<InteractionReceiptDto> Handle(SubmitInteractionCommand request, CancellationToken ct)
    {
        var agent = await _agentRepository.GetByIdAsync(request.CallerAgentRegistrationId, ct)
            ?? throw new DomainException(
                "Caller identity does not match the registered agent.",
                ErrorCodes.AGENT_IDENTITY_MISMATCH);

        if (!string.Equals(
                agent.ExternalAgentId.Value,
                request.ExternalAgentId,
                StringComparison.Ordinal))
            throw new DomainException("Caller identity does not match the registered agent.", ErrorCodes.AGENT_IDENTITY_MISMATCH);

        if (agent.Status != AgentStatus.Active)
            throw new DomainException("Agent is not active.", ErrorCodes.AGENT_DISABLED);

        Agent365UserContextRequirement.EnsureSatisfied(
            agent.FeatureConfiguration.ObservabilityMode,
            request.UserContext?.TenantUserObjectId,
            "UserContext.TenantUserObjectId");

        var purviewPolicyMode = _protectionFeatures is null
            ? agent.FeatureConfiguration.PurviewEnabled
                ? agent.RequestedPurviewPolicyMode ?? PurviewPolicyModeCompatibility.FromLegacy(agent.FeatureConfiguration.PurviewMode ?? PurviewMode.Enforce)
                : PurviewPolicyMode.Disabled
            : await _protectionFeatures.GetRuntimePolicyModeAsync(agent, ct);
        if (purviewPolicyMode == PurviewPolicyMode.Enforce)
        {
            if (_protectionFeatures is null)
            {
                throw new DomainException(
                    "Purview capability and profile readiness cannot be verified.",
                    ErrorCodes.PROTECTION_CAPABILITY_UNAVAILABLE);
            }
            await _protectionFeatures.EnsureRuntimeReadyAsync(
                agent,
                ct);

            if (!_purviewPolicyClient.IsEnabled)
            {
                throw new DomainException(
                    "Purview is not configured for this Gateway deployment.",
                    ErrorCodes.UNSUPPORTED_FEATURE_CONFIGURATION);
            }

            if (!Guid.TryParse(request.UserContext?.TenantUserObjectId, out var userObjectId)
                || userObjectId == Guid.Empty)
            {
                throw new ValidationException(new Dictionary<string, string[]>
                {
                    ["UserContext.TenantUserObjectId"] =
                    ["A non-empty Microsoft Entra user object ID is required when Purview is enabled."]
                });
            }

            if (!Guid.TryParse(agent.Agent365AgentId, out var agentIdentityId)
                || agentIdentityId == Guid.Empty
                || !Guid.TryParse(agent.BlueprintId, out var blueprintId)
                || blueprintId == Guid.Empty)
            {
                throw new DomainException(
                    "The agent does not have verified Agent Identity metadata required for Purview.",
                    ErrorCodes.PURVIEW_DEPENDENCY_UNAVAILABLE);
            }
        }

        var observabilityDestinations =
            agent.FeatureConfiguration.ObservabilityMode.ToDestinations();

        string? requestBodyHash = null;
        IIdempotencyScopeLease? idempotencyScope = null;
        if (request.IdempotencyKey is not null)
        {
            requestBodyHash = IdempotencyRequestHasher.Compute(request);
            idempotencyScope = await _idempotencyService.AcquireDataPlaneScopeAsync(
                agent.Id,
                IdempotencyRequestHasher.InteractionEndpoint,
                request.IdempotencyKey,
                ct);
        }

        await using (idempotencyScope)
        {
            if (request.IdempotencyKey is not null)
            {
                var existing = await _idempotencyService.GetAsync(
                    agent.Id,
                    IdempotencyRequestHasher.InteractionEndpoint,
                    request.IdempotencyKey,
                    DateTime.UtcNow,
                    ct);
                if (existing is not null)
                {
                    if (!string.Equals(
                            existing.RequestBodyHash,
                            requestBodyHash,
                            StringComparison.Ordinal))
                    {
                        throw new ConflictException(
                            "The Idempotency-Key was already used for a different interaction payload in this agent registration.",
                            ErrorCodes.IDEMPOTENCY_CONFLICT);
                    }

                    return JsonSerializer.Deserialize<InteractionReceiptDto>(existing.ResponseBody)!;
                }
            }

            var protectionContext = await _promptEvaluationRepository.GetProtectionContextAsync(agent.Id, ct);
            if (protectionContext is null || !protectionContext.MatchesAgent(agent) ||
                protectionContext.PurviewMode != purviewPolicyMode)
                throw new DomainException("The interaction protection context changed before ingestion.", ErrorCodes.PROMPT_EVALUATION_INVALID);
            var requiresReceipt = protectionContext.RequiresReceipt;
            PromptEvaluationRecord? receipt = null;
            if (requiresReceipt || request.PromptEvaluationReceiptId is not null)
            {
                if (request.PromptEvaluationReceiptId is not { } receiptId || receiptId == Guid.Empty)
                {
                    throw new DomainException(
                        "A successful prompt evaluation receipt is required for this protected registration.",
                        request.PromptEvaluationReceiptId is null ? ErrorCodes.PROMPT_EVALUATION_REQUIRED : ErrorCodes.PROMPT_EVALUATION_INVALID);
                }

                receipt = await _promptEvaluationRepository.GetByIdAsync(receiptId, ct);
                var now = DateTime.UtcNow;
                if (receipt is null
                    || !protectionContext.MatchesReceipt(receipt, now)
                    || !string.Equals(receipt.ExternalInteractionId, request.InteractionId, StringComparison.Ordinal)
                    || !string.Equals(receipt.TenantUserObjectId, request.UserContext?.TenantUserObjectId ?? string.Empty, StringComparison.Ordinal)
                    || !PromptReceiptSecurity.Verify(
                        receipt.PromptHashSalt,
                        receipt.PromptHash,
                        request.Prompt.ContentType,
                        request.Prompt.Content))
                {
                    throw new DomainException(
                        "The prompt evaluation receipt is unbound, stale, expired, consumed, or does not match this interaction and its protection context.",
                        ErrorCodes.PROMPT_EVALUATION_INVALID);
                }

            }

            var correlationId = Guid.NewGuid().ToString();
            var recordId = Guid.NewGuid();

            PurviewEvaluationResult? evaluation = null;
            if (purviewPolicyMode != PurviewPolicyMode.Disabled && _purviewPolicyClient.IsEnabled &&
                Guid.TryParse(request.UserContext?.TenantUserObjectId, out var purviewUserId) && purviewUserId != Guid.Empty &&
                Guid.TryParse(agent.Agent365AgentId, out var purviewAgentId) && purviewAgentId != Guid.Empty &&
                Guid.TryParse(agent.BlueprintId, out var purviewBlueprintId) && purviewBlueprintId != Guid.Empty)
            {
                var purviewInteraction = new PurviewInteraction(
                    agent.Id,
                    request.UserContext!.TenantUserObjectId!,
                    request.InteractionId,
                    request.Prompt.Content,
                    request.Prompt.ContentType,
                    request.Response.Content,
                    request.Response.ContentType,
                    request.Model?.Provider,
                    request.Model?.Name,
                    agent.Agent365AgentId!,
                    agent.BlueprintId!,
                    agent.Name,
                    request.OccurredAtUtc,
                    purviewPolicyMode.ToExecutionMode(),
                    correlationId);

                try
                {
                    evaluation = await _purviewPolicyClient.EvaluateInteractionAsync(
                        purviewInteraction,
                        ct);
                }
                catch (PurviewPolicyException exception)
                {
                    _logger.LogWarning(
                        "Purview evaluation failed closed for agent registration {AgentRegistrationId}, correlation {CorrelationId}, failure {FailureCode}",
                        agent.Id,
                        correlationId,
                        exception.FailureCode);
                    if (purviewPolicyMode == PurviewPolicyMode.Enforce)
                        throw new DomainException(
                        "Purview could not return a trusted policy decision; the interaction was not accepted.",
                        ErrorCodes.PURVIEW_DEPENDENCY_UNAVAILABLE);
                }
            }

            var contentBlobUri = await _interactionContentStore.StoreAsync(
                agent.Id,
                recordId,
                request.Prompt.Content,
                request.Prompt.ContentType,
                request.Response.Content,
                request.Response.ContentType,
                ct);

            if (idempotencyScope is not null)
                await idempotencyScope.BeginCommitAsync(ct);
            var contextAccepted = receipt is not null
                ? await _promptEvaluationRepository.TryConsumeAsync(receipt, protectionContext, ct)
                : await _promptEvaluationRepository.IsProtectionContextCurrentAsync(protectionContext, ct);
            if (!contextAccepted)
            {
                if (idempotencyScope is not null)
                    await idempotencyScope.DisposeAsync();
                // Compensation is only for a known pre-commit rejection, never an ambiguous commit.
                using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                try
                {
                    await _interactionContentStore.DiscardStagedAsync(agent.Id, recordId, contentBlobUri, cleanup.Token);
                }
                catch (Exception)
                {
                    _logger.LogWarning(
                        "Staged interaction cleanup was not confirmed for record {RecordId}, correlation {CorrelationId}",
                        recordId, correlationId);
                }
                throw new DomainException(
                    "The prompt evaluation receipt is unbound, stale, expired, consumed, or does not match this interaction and its protection context.",
                    ErrorCodes.PROMPT_EVALUATION_INVALID);
            }

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
                PurviewStatus = purviewPolicyMode == PurviewPolicyMode.Disabled
                    ? PurviewDecisionType.PurviewDisabled : PurviewDecisionType.SimulationUnavailable,
                ObservabilityStatus = "Pending",
                CorrelationId = correlationId,
                OccurredAtUtc = request.OccurredAtUtc,
                ReceivedAtUtc = DateTime.UtcNow
            };

            if (evaluation is not null)
            {
                var purviewDecision = new PurviewDecision
                {
                    Id = Guid.NewGuid(),
                    AgentRegistrationId = agent.Id,
                    AiInteractionRecordId = recordId,
                    Decision = evaluation.Decision,
                    PolicyAction = evaluation.PolicyAction,
                    ExecutionMode = purviewPolicyMode.ToExecutionMode(),
                    // The legacy column name is retained for schema compatibility;
                    // Graph returns a protectionScopeState, not a scope ID.
                    ProtectionScopeId = evaluation.ProtectionScopeState,
                    TenantUserObjectId = request.UserContext!.TenantUserObjectId,
                    EvaluatedAtUtc = DateTime.UtcNow
                };

                interaction.PurviewStatus = evaluation.Decision;
                interaction.PurviewDecision = purviewDecision;

                if (purviewPolicyMode == PurviewPolicyMode.Enforce && !evaluation.IsAllowed)
                    interaction.ProcessingStatus = ProcessingStatus.Failed;
            }
            await _aiInteractionRepository.AddAsync(interaction, ct);

            if (agent.FeatureConfiguration.ObservabilityMode != ObservabilityMode.Disabled
                && interaction.ProcessingStatus != ProcessingStatus.Failed)
            {
                var outboxMessage = new OutboxMessage
                {
                    Id = Guid.NewGuid(),
                    MessageType = "ExportInteraction",
                    Payload = JsonSerializer.Serialize(new
                    {
                        AgentId = agent.Id,
                        RecordId = recordId,
                        CorrelationId = correlationId,
                        observabilityDestinations.Agent365ObservabilityEnabled,
                        observabilityDestinations.AzureMonitorExportEnabled
                    }),
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
                    AgentRegistrationId = agent.Id,
                    IdempotencyKey = request.IdempotencyKey,
                    RequestBodyHash = requestBodyHash!,
                    Endpoint = IdempotencyRequestHasher.InteractionEndpoint,
                    ResponseStatusCode = 202,
                    ResponseBody = JsonSerializer.Serialize(response),
                    CreatedAtUtc = DateTime.UtcNow,
                    ExpiresAtUtc = default
                };

                await _idempotencyService.SaveAsync(idempotencyRecord, ct);
            }

            await _unitOfWork.SaveChangesAsync(ct);
            if (idempotencyScope is not null)
                await idempotencyScope.CompleteAsync(ct);

            return response;
        }
    }
}
