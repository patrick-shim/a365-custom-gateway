using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using MediatR;

namespace Gateway.Application.Agents.Commands;

internal sealed class RegisterAgentHandler : IRequestHandler<RegisterAgentCommand, RegisterAgentResponse>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IProvisioningJobRepository _provisioningJobRepository;
    private readonly IOutboxRepository _outboxRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;

    public RegisterAgentHandler(
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

    public async Task<RegisterAgentResponse> Handle(RegisterAgentCommand request, CancellationToken cancellationToken)
    {
        if (await _agentRepository.ExistsAsync(request.ExternalAgentId, cancellationToken))
        {
            throw new ConflictException(
                $"An agent with external ID '{request.ExternalAgentId}' already exists.",
                ErrorCodes.DUPLICATE_EXTERNAL_AGENT_ID);
        }

        var agent = new AgentRegistration
        {
            Id = Guid.NewGuid(),
            ExternalAgentId = new ExternalAgentId(request.ExternalAgentId),
            Name = request.Name,
            Description = request.Description,
            OwnerObjectId = request.OwnerObjectId,
            Environment = Enum.Parse<AgentEnvironment>(request.Environment),
            Status = AgentStatus.Draft,
            CreatedAtUtc = DateTime.UtcNow,
            UpdatedAtUtc = DateTime.UtcNow,
            CreatedByObjectId = request.CallerObjectId,
            UpdatedByObjectId = request.CallerObjectId
        };

        var observabilityMode = ObservabilityMode.GatewayOnly;
        var purviewEnabled = false;
        PurviewMode? purviewMode = null;

        if (request.Features is not null)
        {
            if (request.Features.ObservabilityMode is not null)
                observabilityMode = Enum.Parse<ObservabilityMode>(request.Features.ObservabilityMode);

            if (request.Features.PurviewEnabled is not null)
                purviewEnabled = request.Features.PurviewEnabled.Value;

            if (request.Features.PurviewMode is not null)
                purviewMode = Enum.Parse<PurviewMode>(request.Features.PurviewMode);
        }

        var features = new AgentFeatureConfiguration
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            ObservabilityMode = observabilityMode,
            PurviewEnabled = purviewEnabled,
            PurviewMode = purviewMode,
            UpdatedAtUtc = DateTime.UtcNow
        };

        agent.FeatureConfiguration = features;

        var job = new ProvisioningJob
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            Type = OperationType.ProvisionAgent,
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

        await _agentRepository.AddAsync(agent, cancellationToken);
        await _provisioningJobRepository.AddAsync(job, cancellationToken);

        var outboxMessage = new OutboxMessage
        {
            Id = Guid.NewGuid(),
            MessageType = "ProvisionAgent",
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
            EventType = "AgentRegistered",
            PerformedByObjectId = request.CallerObjectId,
            OccurredAtUtc = DateTime.UtcNow
        };
        await _auditEventRepository.AddAsync(auditEvent, cancellationToken);

        await _unitOfWork.SaveChangesAsync(cancellationToken);

        return new RegisterAgentResponse(
            agent.Id,
            request.ExternalAgentId,
            agent.Name,
            agent.Status.ToString(),
            job.Id,
            agent.CreatedAtUtc,
            null);
    }
}
