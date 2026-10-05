using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using MediatR;

namespace Gateway.Application.Agents.Commands;

internal sealed class DeleteAgentHandler(
    IAgentRepository agents,
    IProvisioningJobRepository jobs,
    IAuditEventRepository audit,
    IUnitOfWork unitOfWork,
    IAgent365DelegatedRegistryClient registry) : IRequestHandler<DeleteAgentCommand, DeleteAgentResponse>
{
    public async Task<DeleteAgentResponse> Handle(DeleteAgentCommand request, CancellationToken cancellationToken)
    {
        var agent = await agents.GetByIdAsync(request.AgentId, cancellationToken)
            ?? throw new NotFoundException("AgentRegistration", request.AgentId);
        if (string.IsNullOrWhiteSpace(request.ExpectedRowVersion) ||
            Convert.ToBase64String(agent.RowVersion) != request.ExpectedRowVersion)
            throw new ConflictException("The agent changed after review. Refresh and confirm deletion again.");
        if (agent.Status is not (AgentStatus.Active or AgentStatus.Disabled or AgentStatus.Deleting))
            throw new InvalidStateTransitionException(agent.Status.ToString(), "Delete registered agent");
        if (!Guid.TryParse(agent.Agent365InstanceId, out var registrationId) || registrationId == Guid.Empty ||
            !Guid.TryParse(agent.AgentIdentityObjectId, out var identityId) || identityId == Guid.Empty ||
            !Guid.TryParse(agent.BlueprintId, out var blueprintId) || blueprintId == Guid.Empty)
            throw new ConflictException("This agent has no verified Agent 365 registration mapping. Complete or reconcile registration first.");
        var history = await jobs.GetByAgentIdAsync(agent.Id, cancellationToken);
        if (history.Any(job => job.Type != OperationType.DeleteAgent && job.Status is JobStatus.Pending or JobStatus.Running))
            throw new ConflictException("Wait for the agent's current operation to finish before deleting it.");
        var operation = history.Where(job => job.Type == OperationType.DeleteAgent)
            .OrderByDescending(job => job.CreatedAtUtc).FirstOrDefault();
        if (operation is null)
        {
            operation = new ProvisioningJob { Id = Guid.NewGuid(), AgentRegistrationId = agent.Id,
                Type = OperationType.DeleteAgent, CreatedAtUtc = DateTime.UtcNow, StartedAtUtc = DateTime.UtcNow };
            await jobs.AddAsync(operation, cancellationToken);
        }
        // Commit the runtime denial and concurrency token before any external mutation.
        agent.Status = AgentStatus.Deleting;
        agent.ProtectionRevision = Guid.NewGuid();
        agent.UpdatedAtUtc = DateTime.UtcNow;
        agent.UpdatedByObjectId = request.CallerObjectId;
        operation.Status = JobStatus.Running;
        operation.ErrorCode = null;
        operation.ErrorSummary = null;
        operation.PercentComplete = 10;
        await audit.AddAsync(new AuditEvent { Id = Guid.NewGuid(), AgentRegistrationId = agent.Id,
            EventType = "AgentDeregistrationConfirmed", PerformedByObjectId = request.CallerObjectId,
            OccurredAtUtc = DateTime.UtcNow }, cancellationToken);
        await unitOfWork.SaveChangesAsync(cancellationToken);
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await registry.DeleteAsync(registrationId, identityId, blueprintId, timeout.Token);
        }
        catch (Exception exception) when (exception is Agent365DelegatedRegistryException or HttpRequestException or OperationCanceledException or JsonException)
        {
            operation.Status = JobStatus.Failed;
            operation.ErrorCode = "AGENT_DEREGISTRATION_UNCONFIRMED";
            operation.ErrorSummary = exception is Agent365DelegatedRegistryException known
                ? known.SafeSummary : "Microsoft deletion could not be confirmed. Retry to reconcile this agent.";
            using var persistence = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await unitOfWork.SaveChangesAsync(persistence.Token);
            throw new DomainException(operation.ErrorSummary, "AGENT365_DEPENDENCY_UNAVAILABLE");
        }
        agent.Status = AgentStatus.Deleted;
        agent.IsDeleted = true;
        agent.DeletedAtUtc = DateTime.UtcNow;
        operation.Status = JobStatus.Completed;
        operation.PercentComplete = 100;
        operation.CompletedAtUtc = DateTime.UtcNow;
        await audit.AddAsync(new AuditEvent { Id = Guid.NewGuid(), AgentRegistrationId = agent.Id,
            EventType = "AgentDeregistered", PerformedByObjectId = request.CallerObjectId,
            Details = JsonSerializer.Serialize(new { RegistryId = registrationId, RegistryAbsenceVerified = true }),
            OccurredAtUtc = DateTime.UtcNow }, CancellationToken.None);
        using var commit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        await unitOfWork.SaveChangesAsync(commit.Token);
        return new DeleteAgentResponse(agent.Id, "Deleted", operation.Id, null);
    }
}
