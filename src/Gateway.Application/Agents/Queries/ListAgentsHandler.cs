using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Application.Protection;
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
    private readonly ProtectionEffectiveFeatureEvaluator? _protectionFeatures;

    public ListAgentsHandler(
        IAgentRepository agentRepository,
        IAiInteractionRepository interactionRepository,
        IActivityReceiptRepository activityReceiptRepository,
        ProtectionEffectiveFeatureEvaluator? protectionFeatures = null)
    {
        _agentRepository = agentRepository;
        _interactionRepository = interactionRepository;
        _activityReceiptRepository = activityReceiptRepository;
        _protectionFeatures = protectionFeatures;
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

        var items = new List<AgentSummaryDto>(agents.Count);
        foreach (var agent in agents)
        {
            var destinations = agent.FeatureConfiguration.ObservabilityMode.ToDestinations();
            var features = _protectionFeatures is null
                ? new AgentFeaturesDto(
                    agent.FeatureConfiguration.ObservabilityMode.ToString(),
                    agent.FeatureConfiguration.PurviewEnabled,
                    agent.FeatureConfiguration.PurviewMode?.ToString(),
                    destinations.Agent365ObservabilityEnabled,
                    destinations.AzureMonitorExportEnabled,
                    agent.FeatureConfiguration.PromptShieldEnabled)
                : await _protectionFeatures.ToDtoAsync(
                    agent,
                    cancellationToken);
            items.Add(new AgentSummaryDto(
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
                    features,
                    AgentLastActivity.For(lastActivity, agent.Id),
                    agent.CreatedAtUtc,
                    agent.UpdatedAtUtc));
        }

        var nextCursor = items.Count == limit
            ? agents[^1].Id.ToString()
            : null;

        return new AgentListResponse(items, nextCursor, totalCount);
    }
}
