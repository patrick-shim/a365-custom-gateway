using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Responses;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using MediatR;

namespace Gateway.Application.Agents.Queries;

internal sealed class ListAgentIdentityBlueprintsHandler
    : IRequestHandler<ListAgentIdentityBlueprintsQuery, AgentIdentityBlueprintListResponse>
{
    private readonly IAgentIdentityBlueprintCatalog _catalog;

    public ListAgentIdentityBlueprintsHandler(IAgentIdentityBlueprintCatalog catalog)
    {
        _catalog = catalog;
    }

    public async Task<AgentIdentityBlueprintListResponse> Handle(
        ListAgentIdentityBlueprintsQuery request,
        CancellationToken cancellationToken)
    {
        try
        {
            var blueprints = await _catalog.ListAsync(cancellationToken);
            var items = blueprints
                .Select(blueprint => new AgentIdentityBlueprintSummaryDto(
                    blueprint.BlueprintObjectId,
                    blueprint.BlueprintClientId,
                    blueprint.DisplayName,
                    blueprint.IsAgent365Compatible,
                    blueprint.Agent365CompatibilityIssue))
                .ToArray();

            return new AgentIdentityBlueprintListResponse(items);
        }
        catch (Agent365ProvisioningException exception)
        {
            var invalidResponse = exception.ErrorCode is
                "MICROSOFT_GRAPH_RESPONSE_INVALID" or
                "MICROSOFT_GRAPH_NEXT_LINK_INVALID" or
                "MICROSOFT_GRAPH_REQUEST_REJECTED" or
                "MICROSOFT_GRAPH_RESOURCE_NOT_FOUND";

            throw new DomainException(
                invalidResponse
                    ? "Microsoft Graph returned an invalid Agent Identity blueprint catalog response."
                    : "The Agent Identity blueprint catalog is temporarily unavailable.",
                invalidResponse
                    ? ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_INVALID_RESPONSE
                    : ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_UNAVAILABLE);
        }
    }
}
