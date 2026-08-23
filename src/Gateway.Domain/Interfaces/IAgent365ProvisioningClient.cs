using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IAgent365ProvisioningClient
{
    Task<Agent365ProvisioningResult> ProvisionAsync(AgentProvisioningRequest request, CancellationToken ct);
    Task<Agent365ReconciliationResult> ReconcileAsync(Agent365ResourceReference resource, CancellationToken ct);
    Task DeleteAsync(Agent365ResourceReference resource, CancellationToken ct);
}
