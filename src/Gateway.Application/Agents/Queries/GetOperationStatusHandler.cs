using Gateway.Application.Exceptions;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
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

        var error = job.ErrorCode is not null
            ? new OperationErrorDto(job.ErrorCode, job.ErrorSummary)
            : null;

        var steps = job.Steps
            .OrderBy(s => s.OrderIndex)
            .Select(s => new OperationStepDto(
                s.StepType.ToString(),
                s.Status.ToString(),
                s.CompletedAtUtc))
            .ToList();

        return new OperationStatusDto(
            job.Id,
            job.Type.ToString(),
            job.Status.ToString(),
            runningStep?.StepType.ToString(),
            job.PercentComplete,
            job.AgentRegistrationId,
            job.StartedAtUtc,
            job.CompletedAtUtc,
            error,
            steps);
    }
}
