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

internal sealed class SubmitBatchActivityHandler : IRequestHandler<SubmitBatchActivityCommand, BatchActivityResponse>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IActivityReceiptRepository _activityReceiptRepository;
    private readonly IIdempotencyService _idempotencyService;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;

    public SubmitBatchActivityHandler(
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

    public async Task<BatchActivityResponse> Handle(SubmitBatchActivityCommand request, CancellationToken ct)
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

        string? requestBodyHash = null;
        IIdempotencyScopeLease? idempotencyScope = null;
        if (request.IdempotencyKey is not null)
        {
            requestBodyHash = IdempotencyRequestHasher.Compute(request);
            idempotencyScope = await _idempotencyService.AcquireScopeAsync(
                agent.Id,
                IdempotencyRequestHasher.BatchActivityEndpoint,
                request.IdempotencyKey,
                ct);
        }

        await using (idempotencyScope)
        {
            if (request.IdempotencyKey is not null)
            {
                var existing = await _idempotencyService.GetAsync(
                    agent.Id,
                    IdempotencyRequestHasher.BatchActivityEndpoint,
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
                            "The Idempotency-Key was already used for a different batch activity payload in this agent registration.",
                            ErrorCodes.IDEMPOTENCY_CONFLICT);
                    }

                    return JsonSerializer.Deserialize<BatchActivityResponse>(existing.ResponseBody)!;
                }
            }

            var observabilityDestinations =
                agent.FeatureConfiguration.ObservabilityMode.ToDestinations();
            var correlationId = Guid.NewGuid().ToString();
            var results = new List<BatchActivityItemResult>();
            int accepted = 0;
            int rejected = 0;

            foreach (var item in request.Activities)
            {
                if (item.Actor is null)
                {
                    results.Add(new BatchActivityItemResult(
                        item.ActivityId,
                        "Rejected",
                        null,
                        ErrorCodes.VALIDATION_FAILED,
                        "Actor is required."));
                    rejected++;
                    continue;
                }

                var actor = item.Actor;

                if (!Agent365ActorRequirement.IsSupported(
                        agent.FeatureConfiguration.ObservabilityMode,
                        actor.Type))
                {
                    results.Add(new BatchActivityItemResult(
                        item.ActivityId,
                        "Rejected",
                        null,
                        ErrorCodes.VALIDATION_FAILED,
                        Agent365ActorRequirement.UnsupportedActorErrorMessage));
                    rejected++;
                    continue;
                }

                if (!Agent365UserContextRequirement.IsSatisfied(
                        agent.FeatureConfiguration.ObservabilityMode,
                        actor.TenantUserObjectId))
                {
                    results.Add(new BatchActivityItemResult(
                        item.ActivityId,
                        "Rejected",
                        null,
                        ErrorCodes.VALIDATION_FAILED,
                        Agent365UserContextRequirement.GetErrorMessage(actor.TenantUserObjectId)));
                    rejected++;
                    continue;
                }

                var exists = await _activityReceiptRepository.ExistsByExternalIdAsync(agent.Id, item.ActivityId, ct);
                if (exists)
                {
                    results.Add(new BatchActivityItemResult(item.ActivityId, "Rejected", null, "DUPLICATE", "Activity already exists"));
                    rejected++;
                    continue;
                }

                var receipt = new ActivityReceipt
                {
                    Id = Guid.NewGuid(),
                    AgentRegistrationId = agent.Id,
                    ExternalActivityId = item.ActivityId,
                    SessionId = item.SessionId,
                    ActivityType = Enum.Parse<ActivityType>(item.ActivityType),
                    ActorType = Enum.Parse<ActorType>(actor.Type),
                    ProcessingStatus = ProcessingStatus.Accepted,
                    CorrelationId = correlationId,
                    OccurredAtUtc = item.OccurredAtUtc,
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

                results.Add(new BatchActivityItemResult(item.ActivityId, "Accepted", receipt.Id, null, null));
                accepted++;
            }

            var auditEvent = new AuditEvent
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agent.Id,
                EventType = "BatchActivitySubmitted",
                CorrelationId = correlationId,
                OccurredAtUtc = DateTime.UtcNow
            };

            await _auditEventRepository.AddAsync(auditEvent, ct);

            var response = new BatchActivityResponse(accepted, rejected, results, correlationId);

            if (request.IdempotencyKey is not null)
            {
                var createdAtUtc = DateTime.UtcNow;
                var idempotencyRecord = new IdempotencyRecord
                {
                    Id = Guid.NewGuid(),
                    AgentRegistrationId = agent.Id,
                    IdempotencyKey = request.IdempotencyKey,
                    RequestBodyHash = requestBodyHash!,
                    Endpoint = IdempotencyRequestHasher.BatchActivityEndpoint,
                    ResponseStatusCode = 202,
                    ResponseBody = JsonSerializer.Serialize(response),
                    CreatedAtUtc = createdAtUtc,
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
