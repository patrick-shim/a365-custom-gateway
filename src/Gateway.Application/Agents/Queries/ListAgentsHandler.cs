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

    public ListAgentsHandler(IAgentRepository agentRepository)
    {
        _agentRepository = agentRepository;
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
                    null,
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
