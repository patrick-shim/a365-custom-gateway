using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using MediatR;

namespace Gateway.Application.Agents.Queries;

internal sealed class GetOperationStatusHandler : IRequestHandler<GetOperationStatusQuery, OperationStatusDto>
{
    private readonly IProvisioningJobRepository _provisioningJobRepository;
    private readonly IPurviewConnectorStore _purviewConnectorStore;

    public GetOperationStatusHandler(
        IProvisioningJobRepository provisioningJobRepository,
        IPurviewConnectorStore purviewConnectorStore)
    {
        _provisioningJobRepository = provisioningJobRepository;
        _purviewConnectorStore = purviewConnectorStore;
    }

    public async Task<OperationStatusDto> Handle(GetOperationStatusQuery request, CancellationToken cancellationToken)
    {
        var job = await _provisioningJobRepository.GetByIdAsync(request.OperationId, cancellationToken);
        if (job is null)
        {
            var connectorOperation = await _purviewConnectorStore.GetOperationAsync(
                request.OperationId,
                cancellationToken);
            return connectorOperation is null
                ? throw new NotFoundException("Operation", request.OperationId)
                : MapConnectorOperation(connectorOperation);
        }

        var runningStep = job.Steps
            .FirstOrDefault(s => s.Status == StepStatus.Running);
        var orderedSteps = job.Steps
            .OrderBy(s => s.OrderIndex)
            .ToArray();
        var currentStep = runningStep ?? orderedSteps
            .FirstOrDefault(s => s.Status is StepStatus.Pending or StepStatus.Failed);

        var error = job.ErrorCode is not null
            ? new OperationErrorDto(job.ErrorCode, job.ErrorSummary)
            : null;

        var steps = orderedSteps
            .Select(s => new OperationStepDto(
                s.StepType.ToString(),
                s.Status.ToString(),
                s.CompletedAtUtc))
            .ToList();
        var stepTypes = orderedSteps
            .Select(s => s.StepType)
            .ToList();
        var isCurrentWorkflow = ProvisioningWorkflow.IsCurrent(job.WorkflowVersion, stepTypes);
        var isTerminal = job.Status is JobStatus.Completed or JobStatus.Failed or
            JobStatus.RequiresManualIntervention;
        var replaySupported = isCurrentWorkflow &&
            job.Status != JobStatus.AwaitingAdministratorAction &&
            job.Status != JobStatus.RequiresManualIntervention &&
            !string.Equals(
                job.ErrorCode,
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                StringComparison.Ordinal) &&
            !(job.Status == JobStatus.Running &&
              runningStep?.StepType == ProvisioningStepType.RegisterAgent);
        var requiresDelegatedRegistryAction =
            isCurrentWorkflow &&
            job.Status == JobStatus.AwaitingAdministratorAction &&
            orderedSteps.Count(step => step.Status == StepStatus.Completed) == 5 &&
            orderedSteps[5].StepType == ProvisioningStepType.RegisterAgent &&
            orderedSteps[5].Status is StepStatus.Pending or StepStatus.Running &&
            orderedSteps[6].Status == StepStatus.Pending;

        return new OperationStatusDto(
            job.Id,
            job.Type.ToString(),
            job.Status.ToString(),
            currentStep?.StepType.ToString(),
            job.PercentComplete,
            job.AgentRegistrationId,
            job.StartedAtUtc,
            job.CompletedAtUtc,
            error,
            steps,
            job.WorkflowVersion,
            Legacy: !isCurrentWorkflow,
            ReplaySupported: replaySupported,
            PollingRecommended: isCurrentWorkflow && !isTerminal &&
                job.Status != JobStatus.AwaitingAdministratorAction,
            RequiredAction: requiresDelegatedRegistryAction
                ? "CompleteAgent365Registration"
                : null);
    }

    private static OperationStatusDto MapConnectorOperation(
        Gateway.Domain.Entities.PurviewConnectorOperation operation)
    {
        var terminal = operation.Status is
            PurviewConnectorOperationStatus.Succeeded or
            PurviewConnectorOperationStatus.Failed or
            PurviewConnectorOperationStatus.NeedsAttention or
            PurviewConnectorOperationStatus.TimedOut or
            PurviewConnectorOperationStatus.Cancelled;
        var error = operation.FailureCode is null
            ? null
            : new OperationErrorDto(operation.FailureCode, operation.FailureSummary);
        var steps = new List<OperationStepDto>
        {
            new("Queue", operation.Status == PurviewConnectorOperationStatus.Pending ? "Running" : "Completed",
                operation.Status == PurviewConnectorOperationStatus.Pending ? null : operation.StartedAtUtc),
            new(operation.Type == PurviewConnectorOperationType.Connect ? "VerifyConnection" : "RefreshCatalog",
                operation.Status switch
                {
                    PurviewConnectorOperationStatus.Pending => "Pending",
                    PurviewConnectorOperationStatus.Running => "Running",
                    PurviewConnectorOperationStatus.Succeeded => "Completed",
                    _ => "Failed"
                }, operation.CompletedAtUtc)
        };

        return new OperationStatusDto(
            operation.Id,
            operation.Type.ToString(),
            operation.Status.ToString(),
            operation.CurrentStep,
            operation.PercentComplete,
            AgentId: null,
            operation.StartedAtUtc ?? operation.CreatedAtUtc,
            operation.CompletedAtUtc,
            error,
            steps,
            WorkflowVersion: 1,
            Legacy: false,
            ReplaySupported: false,
            PollingRecommended: !terminal,
            TargetKind: "PurviewConnector",
            TargetId: operation.ConnectorInstanceId);
    }
}
