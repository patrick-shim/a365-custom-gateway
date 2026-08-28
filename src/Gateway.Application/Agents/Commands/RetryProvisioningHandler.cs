using System.Text.Json;
using Gateway.Application.Agents;
using Gateway.Application.Exceptions;
using Gateway.Contracts.Messages;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
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

        var priorJobs = agent.Status is AgentStatus.Failed or AgentStatus.RequiresManualIntervention
            ? await _provisioningJobRepository.GetByAgentIdAsync(agent.Id, cancellationToken)
            : [];
        var retryDecision = ProvisioningRetryPolicy.Evaluate(agent.Status, priorJobs);
        if (!retryDecision.Supported)
        {
            throw new InvalidStateTransitionException(
                agent.Status.ToString(),
                retryDecision.RejectedAction ?? "RetryProvisioning");
        }

        var sourceJob = retryDecision.SourceJob
            ?? throw new ConflictException(
                "The retry source could not be resolved safely.",
                Gateway.Contracts.ErrorCodes.PROVISIONING_STATE_INVALID);
        var resumeStepIndex = retryDecision.ResumeStepIndex;
        if (resumeStepIndex < 0 || resumeStepIndex >= ProvisioningWorkflow.CurrentSteps.Count)
        {
            throw new ConflictException(
                "The retry source has no safe incomplete stage.",
                Gateway.Contracts.ErrorCodes.PROVISIONING_STATE_INVALID);
        }

        var now = DateTime.UtcNow;
        agent.Status = resumeStepIndex == 5
            ? AgentStatus.AwaitingAdminApproval
            : AgentStatus.Provisioning;
        agent.LastProvisioningErrorCode = null;
        agent.LastProvisioningErrorSummary = null;
        agent.UpdatedAtUtc = now;
        agent.UpdatedByObjectId = request.CallerObjectId;

        var job = new ProvisioningJob
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            Type = OperationType.RetryProvisioning,
            Status = resumeStepIndex == 5
                ? JobStatus.AwaitingAdministratorAction
                : JobStatus.Pending,
            PercentComplete = (resumeStepIndex * 100) / ProvisioningWorkflow.CurrentSteps.Count,
            WorkflowVersion = ProvisioningWorkflow.CurrentVersion,
            StartedAtUtc = now,
            CreatedAtUtc = now
        };

        var stepTypes = ProvisioningWorkflow.CurrentSteps;
        var sourceSteps = sourceJob.Steps
            .OrderBy(step => step.OrderIndex)
            .ToArray();
        var steps = new List<ProvisioningJobStep>();
        for (var i = 0; i < stepTypes.Count; i++)
        {
            var completedSource = i < resumeStepIndex ? sourceSteps[i] : null;
            steps.Add(new ProvisioningJobStep
            {
                Id = Guid.NewGuid(),
                ProvisioningJobId = job.Id,
                StepType = stepTypes[i],
                Status = completedSource is null ? StepStatus.Pending : StepStatus.Completed,
                OrderIndex = i,
                ResultData = completedSource?.ResultData,
                StartedAtUtc = completedSource?.StartedAtUtc,
                CompletedAtUtc = completedSource?.CompletedAtUtc
            });
        }
        job.Steps = steps;

        await _provisioningJobRepository.AddAsync(job, cancellationToken);

        if (resumeStepIndex != 5)
        {
            var outboxMessage = new OutboxMessage
            {
                Id = Guid.NewGuid(),
                MessageType = "RetryProvisioning",
                Payload = JsonSerializer.Serialize(new ProvisionAgentMessage(
                    agent.Id,
                    job.Id,
                    ExpectedStepIndex: resumeStepIndex,
                    CorrelationId: null)),
                Status = OutboxMessageStatus.Pending,
                RetryCount = 0,
                CreatedAtUtc = now
            };
            await _outboxRepository.AddAsync(outboxMessage, cancellationToken);
        }

        var auditEvent = new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "ProvisioningRetried",
            PerformedByObjectId = request.CallerObjectId,
            Details = JsonSerializer.Serialize(new
            {
                sourceOperationId = sourceJob.Id,
                resumeStepIndex,
                resumeStep = stepTypes[resumeStepIndex].ToString()
            }),
            OccurredAtUtc = now
        };
        await _auditEventRepository.AddAsync(auditEvent, cancellationToken);

        await _unitOfWork.SaveChangesAsync(cancellationToken);

        return new AsyncOperationResponse(agent.Id, agent.Status.ToString(), job.Id, null);
    }
}
