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

    public GetOperationStatusHandler(IProvisioningJobRepository provisioningJobRepository)
    {
        _provisioningJobRepository = provisioningJobRepository;
    }

    public async Task<OperationStatusDto> Handle(GetOperationStatusQuery request, CancellationToken cancellationToken)
    {
        var job = await _provisioningJobRepository.GetByIdAsync(request.OperationId, cancellationToken)
            ?? throw new NotFoundException("ProvisioningJob", request.OperationId);

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
}
