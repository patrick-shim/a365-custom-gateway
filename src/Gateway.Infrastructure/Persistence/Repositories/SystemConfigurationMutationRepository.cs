using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class SystemConfigurationMutationRepository
    : ISystemConfigurationMutationRepository
{
    private readonly GatewayDbContext _dbContext;

    public SystemConfigurationMutationRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public Task<SystemConfigurationMutation?> GetByIdAsync(Guid id, CancellationToken ct) =>
        _dbContext.SystemConfigurationMutations
            .SingleOrDefaultAsync(operation => operation.Id == id, ct);

    public Task<SystemConfigurationMutation?> GetByIdempotencyKeyAsync(
        EntraTenantId tenantId,
        ProtectionIdempotencyKey idempotencyKey,
        CancellationToken ct) =>
        _dbContext.SystemConfigurationMutations
            .SingleOrDefaultAsync(
                operation =>
                    operation.TenantId == tenantId &&
                    operation.IdempotencyKey == idempotencyKey,
                ct);

    public Task AddAsync(SystemConfigurationMutation operation, CancellationToken ct) =>
        _dbContext.SystemConfigurationMutations.AddAsync(operation, ct).AsTask();
}
