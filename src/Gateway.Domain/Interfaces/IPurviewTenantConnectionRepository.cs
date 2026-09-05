using Gateway.Domain.Entities;
using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Interfaces;

public interface IPurviewTenantConnectionRepository
{
    Task<PurviewTenantConnection?> GetByIdAsync(Guid id, CancellationToken ct);
    Task<PurviewTenantConnection?> GetByTenantIdAsync(
        EntraTenantId tenantId,
        CancellationToken ct);
    Task AddAsync(PurviewTenantConnection connection, CancellationToken ct);
}
