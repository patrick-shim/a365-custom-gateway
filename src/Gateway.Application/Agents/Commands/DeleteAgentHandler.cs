using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts.Messages;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Agents.Commands;

internal sealed class DeleteAgentHandler : IRequestHandler<DeleteAgentCommand, DeleteAgentResponse>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IProvisioningJobRepository _provisioningJobRepository;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;

    public DeleteAgentHandler(
        IAgentRepository agentRepository,
        IProvisioningJobRepository provisioningJobRepository,
        IOutboxRepository outboxRepository,
        IAuditEventRepository auditEventRepository,
        IUnitOfWork unitOfWork)
    {
        _agentRepository = agentRepository;
        _provisioningJobRepository = provisioningJobRepository;
        _outboxRepository = outboxRepository;
        _auditEventRepository = auditEventRepository;
        _unitOfWork = unitOfWork;
    }

    public async Task<DeleteAgentResponse> Handle(DeleteAgentCommand request, CancellationToken cancellationToken)
    {
        var agent = await _agentRepository.GetByIdAsync(request.AgentId, cancellationToken)
            ?? throw new NotFoundException("AgentRegistration", request.AgentId);

        if (agent.Status is AgentStatus.Deleting or AgentStatus.Deleted)
            throw new InvalidStateTransitionException(agent.Status.ToString(), "Delete");

        agent.Status = AgentStatus.Deleting;
        agent.UpdatedAtUtc = DateTime.UtcNow;
        agent.UpdatedByObjectId = request.CallerObjectId;

        var job = new ProvisioningJob
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            Type = OperationType.DeleteAgent,
            Status = JobStatus.Pending,
            PercentComplete = 0,
            StartedAtUtc = DateTime.UtcNow,
            CreatedAtUtc = DateTime.UtcNow,
            Steps = new List<ProvisioningJobStep>()
        };

        await _provisioningJobRepository.AddAsync(job, cancellationToken);

        var outboxMessage = new OutboxMessage
        {
            Id = Guid.NewGuid(),
            MessageType = "DeleteAgent",
            Payload = JsonSerializer.Serialize(new DeleteAgentMessage(
                agent.Id,
                job.Id,
                request.DeleteMicrosoftResources,
                CorrelationId: null)),
            Status = OutboxMessageStatus.Pending,
            RetryCount = 0,
            CreatedAtUtc = DateTime.UtcNow
        };
        await _outboxRepository.AddAsync(outboxMessage, cancellationToken);

        var auditEvent = new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "AgentDeletionRequested",
            PerformedByObjectId = request.CallerObjectId,
            OccurredAtUtc = DateTime.UtcNow
        };
        await _auditEventRepository.AddAsync(auditEvent, cancellationToken);

        await _unitOfWork.SaveChangesAsync(cancellationToken);

        return new DeleteAgentResponse(
            agent.Id,
            agent.Status.ToString(),
            job.Id,
            request.DeleteMicrosoftResources,
            null);
    }
}
