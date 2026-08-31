using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IAgent365ProvisioningClient
{
    Task<Agent365ProvisioningStepResult> ExecuteStepAsync(
        Agent365ProvisioningStepRequest request,
        CancellationToken ct);
}
