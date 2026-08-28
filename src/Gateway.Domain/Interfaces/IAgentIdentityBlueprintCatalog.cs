using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IAgentIdentityBlueprintCatalog
{
    Task<IReadOnlyList<AgentIdentityBlueprintCatalogItem>> ListAsync(
        CancellationToken cancellationToken);
}
