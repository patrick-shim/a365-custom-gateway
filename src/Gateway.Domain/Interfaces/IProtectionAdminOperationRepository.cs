using Gateway.Domain.Entities;
using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Interfaces;

public interface IProtectionAdminOperationRepository
{
    Task<ProtectionAdminOperation?> GetByIdAsync(Guid id, CancellationToken ct);
    Task<ProtectionAdminOperation?> GetByIdempotencyKeyAsync(
        EntraTenantId tenantId,
        ProtectionIdempotencyKey idempotencyKey,
        CancellationToken ct);
    Task AddAsync(ProtectionAdminOperation operation, CancellationToken ct);
}
