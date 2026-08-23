using System.Text.Json;
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
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;

    public SubmitBatchActivityHandler(
        IAgentRepository agentRepository,
        IActivityReceiptRepository activityReceiptRepository,
        IOutboxRepository outboxRepository,
        IAuditEventRepository auditEventRepository,
        IUnitOfWork unitOfWork)
    {
        _agentRepository = agentRepository;
        _activityReceiptRepository = activityReceiptRepository;
        _outboxRepository = outboxRepository;
        _auditEventRepository = auditEventRepository;
        _unitOfWork = unitOfWork;
    }

    public async Task<BatchActivityResponse> Handle(SubmitBatchActivityCommand request, CancellationToken ct)
    {
        var agent = await _agentRepository.GetByExternalAgentIdAsync(request.ExternalAgentId, ct)
            ?? throw new NotFoundException("AgentRegistration", request.ExternalAgentId);

        if (agent.ExternalClientId != request.CallerClientId)
            throw new DomainException("Caller identity does not match the registered agent.", ErrorCodes.AGENT_IDENTITY_MISMATCH);

        if (agent.Status != AgentStatus.Active)
            throw new DomainException("Agent is not active.", ErrorCodes.AGENT_DISABLED);

        var correlationId = Guid.NewGuid().ToString();
        var results = new List<BatchActivityItemResult>();
        int accepted = 0;
        int rejected = 0;

        foreach (var item in request.Activities)
        {
            try
            {
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
                    ActorType = Enum.Parse<ActorType>(item.Actor.Type),
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
                    Payload = JsonSerializer.Serialize(new { AgentId = agent.Id, ReceiptId = receipt.Id, CorrelationId = correlationId }),
                    Status = OutboxMessageStatus.Pending,
                    RetryCount = 0,
                    CreatedAtUtc = DateTime.UtcNow
                };

                await _outboxRepository.AddAsync(outboxMessage, ct);

                results.Add(new BatchActivityItemResult(item.ActivityId, "Accepted", receipt.Id, null, null));
                accepted++;
            }
            catch (Exception ex)
            {
                results.Add(new BatchActivityItemResult(item.ActivityId, "Rejected", null, "PROCESSING_ERROR", ex.Message));
                rejected++;
            }
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

        await _unitOfWork.SaveChangesAsync(ct);

        return new BatchActivityResponse(accepted, rejected, results, correlationId);
    }
}
