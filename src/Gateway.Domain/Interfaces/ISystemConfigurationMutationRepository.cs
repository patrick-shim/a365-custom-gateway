using Gateway.Domain.Entities;
using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Interfaces;

public interface ISystemConfigurationMutationRepository
{
    Task<SystemConfigurationMutation?> GetByIdAsync(Guid id, CancellationToken ct);
    Task<SystemConfigurationMutation?> GetByIdempotencyKeyAsync(
        EntraTenantId tenantId,
        ProtectionIdempotencyKey idempotencyKey,
        CancellationToken ct);
    Task AddAsync(SystemConfigurationMutation operation, CancellationToken ct);
}
