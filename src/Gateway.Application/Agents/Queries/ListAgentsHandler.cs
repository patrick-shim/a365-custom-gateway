using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using MediatR;

namespace Gateway.Application.Agents.Queries;

internal sealed class ListAgentsHandler : IRequestHandler<ListAgentsQuery, AgentListResponse>
{
    private readonly IAgentRepository _agentRepository;
    private readonly IAiInteractionRepository _interactionRepository;
    private readonly IActivityReceiptRepository _activityReceiptRepository;

    public ListAgentsHandler(
        IAgentRepository agentRepository,
        IAiInteractionRepository interactionRepository,
        IActivityReceiptRepository activityReceiptRepository)
    {
        _agentRepository = agentRepository;
        _interactionRepository = interactionRepository;
        _activityReceiptRepository = activityReceiptRepository;
    }

    public async Task<AgentListResponse> Handle(ListAgentsQuery request, CancellationToken cancellationToken)
    {
        var limit = Math.Clamp(request.Limit, 1, 200);

        var filter = new AgentListFilter(
            request.Status,
            request.Environment,
            request.Search,
            limit,
            request.Cursor);

        var (agents, totalCount) = await _agentRepository.ListAsync(filter, cancellationToken);

        var lastActivity = await AgentLastActivity.ResolveAsync(
            _interactionRepository,
            _activityReceiptRepository,
            agents.Select(agent => agent.Id).ToList(),
            cancellationToken);

        var items = agents
            .Select(agent =>
            {
                var destinations = agent.FeatureConfiguration.ObservabilityMode.ToDestinations();

                return new AgentSummaryDto(
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
                        destinations.Agent365ObservabilityEnabled,
                        destinations.AzureMonitorExportEnabled,
                        agent.FeatureConfiguration.PromptShieldEnabled),
                    AgentLastActivity.For(lastActivity, agent.Id),
                    agent.CreatedAtUtc,
                    agent.UpdatedAtUtc);
            })
            .ToList();

        var nextCursor = items.Count == limit
            ? agents[^1].Id.ToString()
            : null;

        return new AgentListResponse(items, nextCursor, totalCount);
    }
}
