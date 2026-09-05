using Gateway.Domain.Entities;
using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Interfaces;

public interface IPurviewKnowYourDataConfigurationRepository
{
    Task<PurviewKnowYourDataConfiguration?> GetByTenantIdAsync(
        EntraTenantId tenantId,
        CancellationToken ct);
    Task AddAsync(PurviewKnowYourDataConfiguration configuration, CancellationToken ct);
}
