using Gateway.Application.Agents;
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
    private readonly IProvisioningJobRepository _provisioningJobRepository;

    public GetAgentHandler(
        IAgentRepository agentRepository,
        IProvisioningJobRepository provisioningJobRepository)
    {
        _agentRepository = agentRepository;
        _provisioningJobRepository = provisioningJobRepository;
    }

    public async Task<AgentDetailDto> Handle(GetAgentQuery request, CancellationToken cancellationToken)
    {
        var agent = await _agentRepository.GetByIdAsync(request.AgentId, cancellationToken)
            ?? throw new NotFoundException("AgentRegistration", request.AgentId);

        var priorJobs = await _provisioningJobRepository.GetByAgentIdAsync(agent.Id, cancellationToken);
        var latestJob = priorJobs
            .OrderByDescending(j => j.CreatedAtUtc)
            .FirstOrDefault();
        var retryDecision = ProvisioningRetryPolicy.Evaluate(agent.Status, priorJobs);

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

        var observabilityDestinations = agent.FeatureConfiguration.ObservabilityMode.ToDestinations();

        return new AgentDetailDto(
            agent.Id,
            agent.ExternalAgentId.Value,
            agent.Name,
            agent.Description,
            agent.Status.ToString(),
            agent.Environment.ToString(),
            new Agent365InfoDto(
                agent.Agent365AgentId,
                agent.BlueprintId,
                agent.Agent365InstanceId,
                agent.AgentIdentityObjectId,
                agent.BlueprintObjectId),
            new AgentFeaturesDto(
                agent.FeatureConfiguration.ObservabilityMode.ToString(),
                agent.FeatureConfiguration.PurviewEnabled,
                agent.FeatureConfiguration.PurviewMode?.ToString(),
                observabilityDestinations.Agent365ObservabilityEnabled,
                observabilityDestinations.AzureMonitorExportEnabled,
                agent.FeatureConfiguration.PromptShieldEnabled),
            null,
            agent.CreatedAtUtc,
            agent.UpdatedAtUtc,
            agent.OwnerObjectId,
            provisioning,
            agent.CreatedByObjectId,
            agent.UpdatedByObjectId,
            agent.RowVersion,
            null,
            new ProvisioningRetryEligibilityDto(
                retryDecision.Supported,
                retryDecision.SafeReason));
    }
}
