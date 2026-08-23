using Gateway.Application.Exceptions;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Agents.Queries;

internal sealed class GetAgentHandler : IRequestHandler<GetAgentQuery, AgentDetailDto>
{
    private readonly IAgentRepository _agentRepository;

    public GetAgentHandler(IAgentRepository agentRepository)
    {
        _agentRepository = agentRepository;
    }

    public async Task<AgentDetailDto> Handle(GetAgentQuery request, CancellationToken cancellationToken)
    {
        var agent = await _agentRepository.GetByIdAsync(request.AgentId, cancellationToken)
            ?? throw new NotFoundException("AgentRegistration", request.AgentId);

        var latestJob = agent.ProvisioningJobs
            .OrderByDescending(j => j.CreatedAtUtc)
            .FirstOrDefault();

        ProvisioningStatusDto? provisioning = null;

        if (latestJob is not null)
        {
            var runningStep = latestJob.Steps
                .FirstOrDefault(s => s.Status == StepStatus.Running);

            provisioning = new ProvisioningStatusDto(
                runningStep?.StepType.ToString(),
                latestJob.PercentComplete,
                latestJob.ErrorSummary);
        }

        return new AgentDetailDto(
            agent.Id,
            agent.ExternalAgentId.Value,
            agent.Name,
            agent.Description,
            agent.Status.ToString(),
            agent.Environment.ToString(),
            new Agent365InfoDto(agent.Agent365AgentId, agent.BlueprintId, agent.Agent365InstanceId),
            new AgentFeaturesDto(
                agent.FeatureConfiguration.ObservabilityMode.ToString(),
                agent.FeatureConfiguration.PurviewEnabled,
                agent.FeatureConfiguration.PurviewMode?.ToString()),
            null,
            agent.CreatedAtUtc,
            agent.UpdatedAtUtc,
            agent.OwnerObjectId,
            provisioning,
            agent.CreatedByObjectId,
            agent.UpdatedByObjectId,
            agent.RowVersion,
            null);
    }
}
