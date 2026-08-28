using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Contracts;
using Microsoft.Extensions.Options;

namespace Gateway.Agent365;

internal sealed class AgentIdentityBlueprintCatalog : IAgentIdentityBlueprintCatalog
{
    private readonly MicrosoftGraphProvisioningClient _graph;
    private readonly Agent365Options _options;

    public AgentIdentityBlueprintCatalog(
        IHttpClientFactory httpClientFactory,
        IAgent365ProvisioningTokenProvider tokenProvider,
        IOptions<Agent365Options> options)
    {
        _graph = new MicrosoftGraphProvisioningClient(
            httpClientFactory.CreateClient(nameof(Agent365ProvisioningClient)),
            tokenProvider);
        _options = options.Value;
    }

    public Task<IReadOnlyList<AgentIdentityBlueprintCatalogItem>> ListAsync(
        CancellationToken cancellationToken)
    {
        return _graph.ListAgentIdentityBlueprintsAsync(
            ParseManagerApplicationIds(),
            cancellationToken);
    }

    private IReadOnlyCollection<Guid> ParseManagerApplicationIds()
    {
        var configured = _options.ManagerApplicationIds ?? [];
        if (configured.Length == 0)
        {
            return [];
        }

        if (configured.Length > 10)
        {
            throw InvalidConfiguration();
        }

        var parsedIds = new HashSet<Guid>();
        foreach (var value in configured)
        {
            if (!Guid.TryParse(value, out var parsed) ||
                parsed == Guid.Empty ||
                !parsedIds.Add(parsed))
            {
                throw InvalidConfiguration();
            }
        }

        return parsedIds;
    }

    private static Agent365ProvisioningException InvalidConfiguration() => new(
        ErrorCodes.AGENT365_PLATFORM_ACCEPTANCE_UNCONFIGURED,
        "Agent 365 platform manager applications aren't configured correctly.");
}
