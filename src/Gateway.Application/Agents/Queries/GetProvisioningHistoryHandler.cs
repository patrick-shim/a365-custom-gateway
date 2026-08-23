using Gateway.Application.Exceptions;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Agents.Queries;

internal sealed class GetProvisioningHistoryHandler : IRequestHandler<GetProvisioningHistoryQuery, ProvisioningHistoryResponse>
{
    private readonly IProvisioningJobRepository _provisioningJobRepository;
    private readonly IAgentRepository _agentRepository;

    public GetProvisioningHistoryHandler(
        IProvisioningJobRepository provisioningJobRepository,
        IAgentRepository agentRepository)
    {
        _provisioningJobRepository = provisioningJobRepository;
        _agentRepository = agentRepository;
    }

    public async Task<ProvisioningHistoryResponse> Handle(GetProvisioningHistoryQuery request, CancellationToken cancellationToken)
    {
        var agent = await _agentRepository.GetByIdAsync(request.AgentId, cancellationToken)
            ?? throw new NotFoundException("AgentRegistration", request.AgentId);

        var jobs = await _provisioningJobRepository.GetByAgentIdAsync(request.AgentId, cancellationToken);

        var mappedJobs = jobs
            .Select(job =>
            {
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

                return new ProvisioningJobDto(
                    job.Id,
                    job.Type.ToString(),
                    job.Status.ToString(),
                    job.PercentComplete,
                    job.StartedAtUtc,
                    job.CompletedAtUtc,
                    error,
                    steps);
            })
            .ToList();

        return new ProvisioningHistoryResponse(request.AgentId, mappedJobs);
    }
}
