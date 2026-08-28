using System.Text.Json;
using Gateway.Application.Common;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Activities.Commands;

internal sealed class SubmitActivityHandler : IRequestHandler<SubmitActivityCommand, ActivityReceiptDto>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IActivityReceiptRepository _activityReceiptRepository;
    private readonly IIdempotencyService _idempotencyService;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;

    public SubmitActivityHandler(
        IAgentRepository agentRepository,
        IActivityReceiptRepository activityReceiptRepository,
        IIdempotencyService idempotencyService,
        IOutboxRepository outboxRepository,
        IAuditEventRepository auditEventRepository,
        IUnitOfWork unitOfWork)
    {
        _agentRepository = agentRepository;
        _activityReceiptRepository = activityReceiptRepository;
        _idempotencyService = idempotencyService;
        _outboxRepository = outboxRepository;
        _auditEventRepository = auditEventRepository;
        _unitOfWork = unitOfWork;
    }

    public async Task<ActivityReceiptDto> Handle(SubmitActivityCommand request, CancellationToken ct)
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

        if (request.Actor is null)
        {
            throw new ValidationException(new Dictionary<string, string[]>
            {
                ["Actor"] = ["Actor is required."]
            });
        }

        var actor = request.Actor;

        Agent365ActorRequirement.EnsureSupported(
            agent.FeatureConfiguration.ObservabilityMode,
            actor.Type,
            "Actor.Type");

        Agent365UserContextRequirement.EnsureSatisfied(
            agent.FeatureConfiguration.ObservabilityMode,
            actor.TenantUserObjectId,
            "Actor.TenantUserObjectId");

        var observabilityDestinations =
            agent.FeatureConfiguration.ObservabilityMode.ToDestinations();

        string? requestBodyHash = null;
        IIdempotencyScopeLease? idempotencyScope = null;
        if (request.IdempotencyKey is not null)
        {
            requestBodyHash = IdempotencyRequestHasher.Compute(request);
            idempotencyScope = await _idempotencyService.AcquireScopeAsync(
                agent.Id,
                IdempotencyRequestHasher.ActivityEndpoint,
                request.IdempotencyKey,
                ct);
        }

        await using (idempotencyScope)
        {
            if (request.IdempotencyKey is not null)
            {
                var existing = await _idempotencyService.GetAsync(
                    agent.Id,
                    IdempotencyRequestHasher.ActivityEndpoint,
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
                            "The Idempotency-Key was already used for a different activity payload in this agent registration.",
                            ErrorCodes.IDEMPOTENCY_CONFLICT);
                    }

                    return JsonSerializer.Deserialize<ActivityReceiptDto>(existing.ResponseBody)!;
                }
            }

            var correlationId = Guid.NewGuid().ToString();

            var receipt = new ActivityReceipt
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agent.Id,
                ExternalActivityId = request.ActivityId,
                SessionId = request.SessionId,
                ActivityType = Enum.Parse<ActivityType>(request.ActivityType),
                ActorType = Enum.Parse<ActorType>(actor.Type),
                ProcessingStatus = ProcessingStatus.Accepted,
                CorrelationId = correlationId,
                OccurredAtUtc = request.OccurredAtUtc,
                ReceivedAtUtc = DateTime.UtcNow
            };

            await _activityReceiptRepository.AddAsync(receipt, ct);

            var outboxMessage = new OutboxMessage
            {
                Id = Guid.NewGuid(),
                MessageType = "ProcessActivity",
                Payload = JsonSerializer.Serialize(new
                {
                    AgentId = agent.Id,
                    ReceiptId = receipt.Id,
                    CorrelationId = correlationId,
                    ActorTenantUserObjectId = actor.TenantUserObjectId,
                    observabilityDestinations.Agent365ObservabilityEnabled,
                    observabilityDestinations.AzureMonitorExportEnabled
                }),
                Status = OutboxMessageStatus.Pending,
                RetryCount = 0,
                CreatedAtUtc = DateTime.UtcNow
            };

            await _outboxRepository.AddAsync(outboxMessage, ct);

            var auditEvent = new AuditEvent
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agent.Id,
                EventType = "ActivitySubmitted",
                CorrelationId = correlationId,
                OccurredAtUtc = DateTime.UtcNow
            };

            await _auditEventRepository.AddAsync(auditEvent, ct);

            var response = new ActivityReceiptDto(receipt.Id, request.ActivityId, receipt.ProcessingStatus.ToString(), receipt.ReceivedAtUtc, correlationId);

            if (request.IdempotencyKey is not null)
            {
                var idempotencyRecord = new IdempotencyRecord
                {
                    Id = Guid.NewGuid(),
                    AgentRegistrationId = agent.Id,
                    IdempotencyKey = request.IdempotencyKey,
                    RequestBodyHash = requestBodyHash!,
                    Endpoint = IdempotencyRequestHasher.ActivityEndpoint,
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
