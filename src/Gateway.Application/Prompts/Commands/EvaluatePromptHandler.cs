using System.Text.Json;
using Gateway.Application.Common;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using MediatR;
using Microsoft.Extensions.Logging;

namespace Gateway.Application.Prompts.Commands;

internal sealed class EvaluatePromptHandler : IRequestHandler<EvaluatePromptCommand, PromptEvaluationResultDto>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IPromptEvaluationRepository _promptEvaluationRepository;
    private readonly IPromptShieldClient _promptShieldClient;
    private readonly IPurviewPolicyClient _purviewPolicyClient;
    private readonly IIdempotencyService _idempotencyService;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;
    private readonly TimeProvider _timeProvider;
    private readonly ILogger<EvaluatePromptHandler> _logger;

    public EvaluatePromptHandler(
        IAgentRepository agentRepository,
        IPromptEvaluationRepository promptEvaluationRepository,
        IPromptShieldClient promptShieldClient,
        IPurviewPolicyClient purviewPolicyClient,
        IIdempotencyService idempotencyService,
        IAuditEventRepository auditEventRepository,
        IUnitOfWork unitOfWork,
        TimeProvider timeProvider,
        ILogger<EvaluatePromptHandler> logger)
    {
        _agentRepository = agentRepository;
        _promptEvaluationRepository = promptEvaluationRepository;
        _promptShieldClient = promptShieldClient;
        _purviewPolicyClient = purviewPolicyClient;
        _idempotencyService = idempotencyService;
        _auditEventRepository = auditEventRepository;
        _unitOfWork = unitOfWork;
        _timeProvider = timeProvider;
        _logger = logger;
    }

    public async Task<PromptEvaluationResultDto> Handle(EvaluatePromptCommand request, CancellationToken cancellationToken)
    {
        var agent = await _agentRepository.GetByIdAsync(request.CallerAgentRegistrationId, cancellationToken)
            ?? throw new DomainException("Caller identity does not match the registered agent.", ErrorCodes.AGENT_IDENTITY_MISMATCH);
        if (!string.Equals(agent.ExternalAgentId.Value, request.ExternalAgentId, StringComparison.Ordinal))
            throw new DomainException("Caller identity does not match the registered agent.", ErrorCodes.AGENT_IDENTITY_MISMATCH);
        if (agent.Status != AgentStatus.Active)
            throw new DomainException("Agent is not active.", ErrorCodes.AGENT_DISABLED);

        Agent365UserContextRequirement.EnsureSatisfied(
            agent.FeatureConfiguration.ObservabilityMode,
            request.UserContext?.TenantUserObjectId,
            "UserContext.TenantUserObjectId");

        if (agent.FeatureConfiguration.PromptShieldEnabled && !_promptShieldClient.IsEnabled)
            throw new DomainException("Prompt Shields is not configured for this Gateway deployment.", ErrorCodes.PROMPT_EVALUATION_UNAVAILABLE);
        if (agent.FeatureConfiguration.PurviewEnabled && !_purviewPolicyClient.IsEnabled)
            throw new DomainException("Purview is not configured for this Gateway deployment.", ErrorCodes.PROMPT_EVALUATION_UNAVAILABLE);

        var tenantUserObjectId = request.UserContext?.TenantUserObjectId;
        if (agent.FeatureConfiguration.PurviewEnabled
            && (!Guid.TryParse(tenantUserObjectId, out var userId) || userId == Guid.Empty))
        {
            throw new ValidationException(new Dictionary<string, string[]>
            {
                ["UserContext.TenantUserObjectId"] = ["A non-empty Microsoft Entra user object ID is required when Purview is enabled."]
            });
        }

        var requestBodyHash = IdempotencyRequestHasher.Compute(request);
        await using var idempotencyScope = await _idempotencyService.AcquireScopeAsync(
            agent.Id,
            IdempotencyRequestHasher.PromptEvaluationEndpoint,
            request.IdempotencyKey,
            cancellationToken);
        var now = _timeProvider.GetUtcNow().UtcDateTime;
        var existing = await _idempotencyService.GetAsync(
            agent.Id,
            IdempotencyRequestHasher.PromptEvaluationEndpoint,
            request.IdempotencyKey,
            now,
            cancellationToken);
        if (existing is not null)
        {
            if (!string.Equals(existing.RequestBodyHash, requestBodyHash, StringComparison.Ordinal))
                throw new ConflictException("The Idempotency-Key was already used for a different prompt evaluation.", ErrorCodes.IDEMPOTENCY_CONFLICT);
            return JsonSerializer.Deserialize<PromptEvaluationResultDto>(existing.ResponseBody)!;
        }

        var correlationId = Guid.NewGuid().ToString("D");
        var promptShieldTask = EvaluatePromptShieldAsync(agent, request.Prompt.Content, correlationId, cancellationToken);
        var purviewTask = EvaluatePurviewAsync(agent, request, correlationId, cancellationToken);
        await Task.WhenAll(promptShieldTask, purviewTask);
        var promptShieldDecision = await promptShieldTask;
        var purviewDecision = await purviewTask;
        var blockedByShield = promptShieldDecision == PromptShieldDecisionType.Blocked;
        var blockedByPurview = purviewDecision == PurviewDecisionType.Blocked;
        var allowed = !blockedByShield && !blockedByPurview;
        var decisionCode = blockedByShield && blockedByPurview
            ? ErrorCodes.PROMPT_BLOCKED_BY_MULTIPLE_CONTROLS
            : blockedByShield
                ? ErrorCodes.PROMPT_BLOCKED_BY_PROMPT_SHIELD
                : blockedByPurview
                    ? ErrorCodes.PROMPT_BLOCKED_BY_DLP
                    : "PROMPT_ALLOWED";
        var userMessage = decisionCode switch
        {
            ErrorCodes.PROMPT_BLOCKED_BY_PROMPT_SHIELD => "Your message was not sent because it resembles a prompt-injection attempt. Revise it and try again.",
            ErrorCodes.PROMPT_BLOCKED_BY_DLP => "Your message was not sent because it contains information restricted by your organization's data protection policy.",
            ErrorCodes.PROMPT_BLOCKED_BY_MULTIPLE_CONTROLS => "Your message was not sent because it was blocked by the configured prompt protection policies.",
            _ => "The prompt passed the configured Gateway protection checks."
        };

        var evaluationId = Guid.NewGuid();
        var (salt, hash) = PromptReceiptSecurity.Create(request.Prompt.ContentType, request.Prompt.Content);
        var expiresAtUtc = now.Add(_promptShieldClient.ReceiptLifetime);
        var record = new PromptEvaluationRecord
        {
            Id = evaluationId,
            AgentRegistrationId = agent.Id,
            ExternalInteractionId = request.InteractionId,
            TenantUserObjectId = tenantUserObjectId ?? string.Empty,
            PromptHashSalt = salt,
            PromptHash = hash,
            Outcome = allowed ? PromptEvaluationOutcome.Allowed : PromptEvaluationOutcome.Blocked,
            PromptShieldDecision = promptShieldDecision,
            PurviewDecision = purviewDecision,
            CorrelationId = correlationId,
            CreatedAtUtc = now,
            ExpiresAtUtc = expiresAtUtc
        };
        await _promptEvaluationRepository.AddAsync(record, cancellationToken);
        await _auditEventRepository.AddAsync(new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = allowed ? "PromptEvaluationAllowed" : "PromptEvaluationBlocked",
            CorrelationId = correlationId,
            OccurredAtUtc = now
        }, cancellationToken);

        var response = new PromptEvaluationResultDto(
            evaluationId,
            allowed ? evaluationId : null,
            request.InteractionId,
            allowed,
            decisionCode,
            promptShieldDecision.ToString(),
            purviewDecision.ToString(),
            allowed ? expiresAtUtc : null,
            userMessage,
            correlationId);
        await _idempotencyService.SaveAsync(new IdempotencyRecord
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            IdempotencyKey = request.IdempotencyKey,
            RequestBodyHash = requestBodyHash,
            Endpoint = IdempotencyRequestHasher.PromptEvaluationEndpoint,
            ResponseStatusCode = allowed ? 200 : 403,
            ResponseBody = JsonSerializer.Serialize(response),
            CreatedAtUtc = now,
            ExpiresAtUtc = default
        }, cancellationToken);
        await _unitOfWork.SaveChangesAsync(cancellationToken);
        await idempotencyScope.CompleteAsync(cancellationToken);
        return response;
    }

    private async Task<PromptShieldDecisionType> EvaluatePromptShieldAsync(
        AgentRegistration agent,
        string prompt,
        string correlationId,
        CancellationToken cancellationToken)
    {
        if (!agent.FeatureConfiguration.PromptShieldEnabled)
            return PromptShieldDecisionType.Disabled;
        try
        {
            var result = await _promptShieldClient.EvaluateAsync(prompt, cancellationToken);
            return result.AttackDetected ? PromptShieldDecisionType.Blocked : PromptShieldDecisionType.Allowed;
        }
        catch (PromptShieldException exception)
        {
            _logger.LogWarning(
                "Prompt Shield evaluation failed closed for agent registration {AgentRegistrationId}, correlation {CorrelationId}, failure {FailureCode}",
                agent.Id,
                correlationId,
                exception.FailureCode);
            throw new DomainException("Prompt Shields could not return a trusted decision.", ErrorCodes.PROMPT_EVALUATION_UNAVAILABLE);
        }
    }

    private async Task<PurviewDecisionType> EvaluatePurviewAsync(
        AgentRegistration agent,
        EvaluatePromptCommand request,
        string correlationId,
        CancellationToken cancellationToken)
    {
        if (!agent.FeatureConfiguration.PurviewEnabled)
            return PurviewDecisionType.PurviewDisabled;
        if (!Guid.TryParse(agent.Agent365AgentId, out var agentIdentityId) || agentIdentityId == Guid.Empty
            || !Guid.TryParse(agent.BlueprintId, out var blueprintId) || blueprintId == Guid.Empty)
        {
            throw new DomainException("The agent does not have verified identity metadata required for Purview.", ErrorCodes.PROMPT_EVALUATION_UNAVAILABLE);
        }

        var interaction = new PurviewInteraction(
            agent.Id,
            request.UserContext!.TenantUserObjectId!,
            request.InteractionId,
            request.Prompt.Content,
            request.Prompt.ContentType,
            string.Empty,
            request.Prompt.ContentType,
            null,
            null,
            agent.Agent365AgentId!,
            agent.BlueprintId!,
            agent.Name,
            request.OccurredAtUtc,
            agent.FeatureConfiguration.PurviewMode == PurviewMode.Enforce
                ? PurviewExecutionMode.EvaluateInline
                : PurviewExecutionMode.EvaluateOffline,
            correlationId);
        try
        {
            return (await _purviewPolicyClient.EvaluatePromptAsync(interaction, cancellationToken)).Decision;
        }
        catch (PurviewPolicyException exception)
        {
            _logger.LogWarning(
                "Purview prompt evaluation failed closed for agent registration {AgentRegistrationId}, correlation {CorrelationId}, failure {FailureCode}",
                agent.Id,
                correlationId,
                exception.FailureCode);
            throw new DomainException("Purview could not return a trusted prompt decision.", ErrorCodes.PROMPT_EVALUATION_UNAVAILABLE);
        }
    }
}
