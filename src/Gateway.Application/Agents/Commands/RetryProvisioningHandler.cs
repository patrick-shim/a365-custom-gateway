using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Agents.Commands;

internal sealed class RetryProvisioningHandler : IRequestHandler<RetryProvisioningCommand, AsyncOperationResponse>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IProvisioningJobRepository _provisioningJobRepository;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;

    public RetryProvisioningHandler(
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

    public async Task<AsyncOperationResponse> Handle(RetryProvisioningCommand request, CancellationToken cancellationToken)
    {
        var agent = await _agentRepository.GetByIdAsync(request.AgentId, cancellationToken)
            ?? throw new NotFoundException("AgentRegistration", request.AgentId);

        if (agent.Status is not AgentStatus.Failed and not AgentStatus.RequiresManualIntervention)
        {
            throw new InvalidStateTransitionException(agent.Status.ToString(), "RetryProvisioning");
        }

        var job = new ProvisioningJob
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            Type = OperationType.RetryProvisioning,
            Status = JobStatus.Pending,
            PercentComplete = 0,
            StartedAtUtc = DateTime.UtcNow,
            CreatedAtUtc = DateTime.UtcNow
        };

        var stepTypes = Enum.GetValues<ProvisioningStepType>();
        var steps = new List<ProvisioningJobStep>();
        for (var i = 0; i < stepTypes.Length; i++)
        {
            steps.Add(new ProvisioningJobStep
            {
                Id = Guid.NewGuid(),
                ProvisioningJobId = job.Id,
                StepType = stepTypes[i],
                Status = StepStatus.Pending,
                OrderIndex = i
            });
        }
        job.Steps = steps;

        await _provisioningJobRepository.AddAsync(job, cancellationToken);

        var outboxMessage = new OutboxMessage
        {
            Id = Guid.NewGuid(),
            MessageType = "RetryProvisioning",
            Payload = JsonSerializer.Serialize(new { AgentId = agent.Id, JobId = job.Id }),
            Status = OutboxMessageStatus.Pending,
            RetryCount = 0,
            CreatedAtUtc = DateTime.UtcNow
        };
        await _outboxRepository.AddAsync(outboxMessage, cancellationToken);

        var auditEvent = new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "ProvisioningRetried",
            PerformedByObjectId = request.CallerObjectId,
            OccurredAtUtc = DateTime.UtcNow
        };
        await _auditEventRepository.AddAsync(auditEvent, cancellationToken);

        await _unitOfWork.SaveChangesAsync(cancellationToken);

        return new AsyncOperationResponse(agent.Id, agent.Status.ToString(), job.Id, null);
    }
}
