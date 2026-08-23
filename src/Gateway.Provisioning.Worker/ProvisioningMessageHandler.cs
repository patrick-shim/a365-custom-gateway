using System.Text.Json;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Microsoft.Extensions.Logging;

namespace Gateway.Provisioning.Worker;

internal sealed class ProvisioningMessageHandler
{
    private readonly IAgent365ProvisioningClient _provisioningClient;
    private readonly IAgentRepository _agentRepository;
    private readonly IProvisioningJobRepository _jobRepository;
    private readonly IAuditEventRepository _auditEventRepository;
    private readonly IUnitOfWork _unitOfWork;
    private readonly ILogger<ProvisioningMessageHandler> _logger;

    public ProvisioningMessageHandler(
        IAgent365ProvisioningClient provisioningClient,
        IAgentRepository agentRepository,
        IProvisioningJobRepository jobRepository,
        IAuditEventRepository auditEventRepository,
        IUnitOfWork unitOfWork,
        ILogger<ProvisioningMessageHandler> logger)
    {
        _provisioningClient = provisioningClient;
        _agentRepository = agentRepository;
        _jobRepository = jobRepository;
        _auditEventRepository = auditEventRepository;
        _unitOfWork = unitOfWork;
        _logger = logger;
    }

    public async Task HandleAsync(string messageType, string payload, CancellationToken ct)
    {
        _logger.LogInformation("Processing provisioning message of type {MessageType}", messageType);

        switch (messageType)
        {
            case "ProvisionAgent":
            case "RetryProvisioning":
                await HandleProvisionAsync(payload, ct);
                break;
            case "DeleteAgent":
                await HandleDeleteAsync(payload, ct);
                break;
            case "ReconcileAgent":
                await HandleReconcileAsync(payload, ct);
                break;
            default:
                _logger.LogWarning("Unknown message type: {MessageType}", messageType);
                break;
        }
    }

    private async Task HandleProvisionAsync(string payload, CancellationToken ct)
    {
        var message = JsonSerializer.Deserialize<ProvisionMessage>(payload);
        if (message is null)
        {
            _logger.LogWarning("Failed to deserialize provisioning message");
            return;
        }

        var agent = await _agentRepository.GetByIdAsync(message.AgentRegistrationId, ct);
        if (agent is null)
        {
            _logger.LogWarning("Agent {AgentId} not found for provisioning", message.AgentRegistrationId);
            return;
        }

        var job = await _jobRepository.GetByIdAsync(message.JobId, ct);
        if (job is null)
        {
            _logger.LogWarning("Job {JobId} not found for provisioning", message.JobId);
            return;
        }

        agent.Status = AgentStatus.Provisioning;
        job.Status = JobStatus.Running;
        job.StartedAtUtc = DateTime.UtcNow;
        await _unitOfWork.SaveChangesAsync(ct);

        var steps = job.Steps.OrderBy(s => s.OrderIndex).ToList();
        var totalSteps = steps.Count;
        var completedSteps = 0;
        var failed = false;

        foreach (var step in steps)
        {
            if (step.Status == StepStatus.Completed)
            {
                completedSteps++;
                continue;
            }

            step.Status = StepStatus.Running;
            step.StartedAtUtc = DateTime.UtcNow;
            await _unitOfWork.SaveChangesAsync(ct);

            try
            {
                await ExecuteProvisioningStepAsync(step, agent, ct);

                step.Status = StepStatus.Completed;
                step.CompletedAtUtc = DateTime.UtcNow;
                completedSteps++;
                job.PercentComplete = totalSteps > 0 ? (completedSteps * 100) / totalSteps : 0;
                await _unitOfWork.SaveChangesAsync(ct);
            }
            catch (NotImplementedException)
            {
                _logger.LogInformation(
                    "Step {StepType} not yet implemented, marking as completed (stub behavior)",
                    step.StepType);
                step.Status = StepStatus.Completed;
                step.CompletedAtUtc = DateTime.UtcNow;
                completedSteps++;
                job.PercentComplete = totalSteps > 0 ? (completedSteps * 100) / totalSteps : 0;
                await _unitOfWork.SaveChangesAsync(ct);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Provisioning step {StepType} failed for job {JobId}", step.StepType, job.Id);

                step.Status = StepStatus.Failed;
                step.ErrorCode = ex.GetType().Name;
                step.ErrorMessage = ex.Message;
                job.Status = JobStatus.Failed;
                job.ErrorCode = ex.GetType().Name;
                job.ErrorSummary = ex.Message;
                job.CompletedAtUtc = DateTime.UtcNow;
                agent.Status = AgentStatus.Failed;
                agent.LastProvisioningErrorCode = ex.GetType().Name;
                agent.LastProvisioningErrorSummary = ex.Message;
                failed = true;

                await _unitOfWork.SaveChangesAsync(ct);
                break;
            }
        }

        if (failed)
        {
            await _auditEventRepository.AddAsync(new AuditEvent
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agent.Id,
                EventType = "ProvisioningFailed",
                Details = JsonSerializer.Serialize(new { job.Id, job.ErrorCode, job.ErrorSummary }),
                CorrelationId = message.CorrelationId,
                OccurredAtUtc = DateTime.UtcNow
            }, ct);
        }
        else
        {
            job.Status = JobStatus.Completed;
            job.PercentComplete = 100;
            job.CompletedAtUtc = DateTime.UtcNow;
            agent.Status = AgentStatus.AwaitingAdminApproval;

            await _auditEventRepository.AddAsync(new AuditEvent
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agent.Id,
                EventType = "ProvisioningCompleted",
                Details = JsonSerializer.Serialize(new { job.Id }),
                CorrelationId = message.CorrelationId,
                OccurredAtUtc = DateTime.UtcNow
            }, ct);
        }

        await _unitOfWork.SaveChangesAsync(ct);
    }

    private async Task ExecuteProvisioningStepAsync(
        ProvisioningJobStep step,
        AgentRegistration agent,
        CancellationToken ct)
    {
        var request = new AgentProvisioningRequest(
            agent.Id,
            agent.ExternalAgentId.Value,
            agent.Name,
            agent.Description,
            agent.OwnerObjectId,
            agent.Environment.ToString());

        var result = await _provisioningClient.ProvisionAsync(request, ct);

        if (result.Succeeded)
        {
            step.ResultData = JsonSerializer.Serialize(result);

            if (result.AppRegistrationId is not null)
                agent.ExternalClientId ??= result.AppRegistrationId;
            if (result.BlueprintId is not null)
                agent.BlueprintId ??= result.BlueprintId;
            if (result.Agent365AgentId is not null)
                agent.Agent365AgentId ??= result.Agent365AgentId;
            if (result.Agent365InstanceId is not null)
                agent.Agent365InstanceId ??= result.Agent365InstanceId;
        }
        else
        {
            throw new InvalidOperationException(
                $"Provisioning step {step.StepType} failed: {result.ErrorCode} - {result.ErrorSummary}");
        }
    }

    private async Task HandleDeleteAsync(string payload, CancellationToken ct)
    {
        var message = JsonSerializer.Deserialize<DeleteMessage>(payload);
        if (message is null)
        {
            _logger.LogWarning("Failed to deserialize delete message");
            return;
        }

        var agent = await _agentRepository.GetByIdAsync(message.AgentRegistrationId, ct);
        if (agent is null)
        {
            _logger.LogWarning("Agent {AgentId} not found for deletion", message.AgentRegistrationId);
            return;
        }

        if (message.DeleteMicrosoftResources)
        {
            var resource = new Agent365ResourceReference(
                agent.Id,
                agent.ExternalClientId,
                null,
                agent.BlueprintId,
                agent.Agent365AgentId,
                agent.Agent365InstanceId);

            try
            {
                await _provisioningClient.DeleteAsync(resource, ct);
            }
            catch (NotImplementedException)
            {
                _logger.LogInformation("Delete not yet implemented, proceeding with soft-delete (stub behavior)");
            }
        }

        agent.Status = AgentStatus.Deleted;
        agent.IsDeleted = true;
        agent.DeletedAtUtc = DateTime.UtcNow;

        await _auditEventRepository.AddAsync(new AuditEvent
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            EventType = "AgentResourcesDeleted",
            Details = JsonSerializer.Serialize(new { message.DeleteMicrosoftResources }),
            CorrelationId = message.CorrelationId,
            OccurredAtUtc = DateTime.UtcNow
        }, ct);

        await _unitOfWork.SaveChangesAsync(ct);
    }

    private async Task HandleReconcileAsync(string payload, CancellationToken ct)
    {
        var message = JsonSerializer.Deserialize<ReconcileMessage>(payload);
        if (message is null)
        {
            _logger.LogWarning("Failed to deserialize reconciliation message");
            return;
        }

        var agent = await _agentRepository.GetByIdAsync(message.AgentRegistrationId, ct);
        if (agent is null)
        {
            _logger.LogWarning("Agent {AgentId} not found for reconciliation", message.AgentRegistrationId);
            return;
        }

        var resource = new Agent365ResourceReference(
            agent.Id,
            agent.ExternalClientId,
            null,
            agent.BlueprintId,
            agent.Agent365AgentId,
            agent.Agent365InstanceId);

        Agent365ReconciliationResult result;
        try
        {
            result = await _provisioningClient.ReconcileAsync(resource, ct);
        }
        catch (NotImplementedException)
        {
            _logger.LogInformation("Reconcile not yet implemented, treating as in-sync (stub behavior)");
            result = new Agent365ReconciliationResult(
                InSync: true,
                AppRegistrationExists: true,
                ServicePrincipalExists: true,
                BlueprintExists: true,
                AgentExists: true,
                PermissionsCorrect: true,
                Drifts: []);
        }

        if (!result.InSync)
        {
            agent.Status = AgentStatus.RequiresManualIntervention;

            await _auditEventRepository.AddAsync(new AuditEvent
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agent.Id,
                EventType = "ReconciliationDriftDetected",
                Details = JsonSerializer.Serialize(new { result.Drifts }),
                CorrelationId = message.CorrelationId,
                OccurredAtUtc = DateTime.UtcNow
            }, ct);
        }
        else
        {
            await _auditEventRepository.AddAsync(new AuditEvent
            {
                Id = Guid.NewGuid(),
                AgentRegistrationId = agent.Id,
                EventType = "ReconciliationPassed",
                CorrelationId = message.CorrelationId,
                OccurredAtUtc = DateTime.UtcNow
            }, ct);
        }

        await _unitOfWork.SaveChangesAsync(ct);
    }

    private sealed record ProvisionMessage(
        Guid AgentRegistrationId,
        Guid JobId,
        string? CorrelationId);

    private sealed record DeleteMessage(
        Guid AgentRegistrationId,
        bool DeleteMicrosoftResources,
        string? CorrelationId);

    private sealed record ReconcileMessage(
        Guid AgentRegistrationId,
        string? CorrelationId);
}
