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
                return JsonSerializer.Deserialize<ActivityReceiptDto>(existing.ResponseBody)!;
        }

        var correlationId = Guid.NewGuid().ToString();

        var receipt = new ActivityReceipt
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            ExternalActivityId = request.ActivityId,
            SessionId = request.SessionId,
            ActivityType = Enum.Parse<ActivityType>(request.ActivityType),
            ActorType = Enum.Parse<ActorType>(request.Actor.Type),
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
            Payload = JsonSerializer.Serialize(new { AgentId = agent.Id, ReceiptId = receipt.Id, CorrelationId = correlationId }),
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
                IdempotencyKey = request.IdempotencyKey,
                RequestBodyHash = string.Empty,
                Endpoint = "SubmitActivity",
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
