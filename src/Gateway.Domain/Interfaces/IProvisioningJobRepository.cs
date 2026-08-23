using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public interface IProvisioningJobRepository
{
    Task<ProvisioningJob?> GetByIdAsync(Guid id, CancellationToken ct);
    Task<List<ProvisioningJob>> GetByAgentIdAsync(Guid agentRegistrationId, CancellationToken ct);
    Task AddAsync(ProvisioningJob job, CancellationToken ct);
}
