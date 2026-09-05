using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class ProtectionAdminOperationRepository
    : IProtectionAdminOperationRepository
{
    private readonly GatewayDbContext _dbContext;

    public ProtectionAdminOperationRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public Task<ProtectionAdminOperation?> GetByIdAsync(Guid id, CancellationToken ct) =>
        _dbContext.ProtectionAdminOperations
            .Include("_steps")
            .SingleOrDefaultAsync(operation => operation.Id == id, ct);

    public Task<ProtectionAdminOperation?> GetByIdempotencyKeyAsync(
        EntraTenantId tenantId,
        ProtectionIdempotencyKey idempotencyKey,
        CancellationToken ct) =>
        _dbContext.ProtectionAdminOperations
            .Include("_steps")
            .SingleOrDefaultAsync(
                operation =>
                    operation.TenantId == tenantId &&
                    operation.IdempotencyKey == idempotencyKey,
                ct);

    public Task AddAsync(ProtectionAdminOperation operation, CancellationToken ct) =>
        _dbContext.ProtectionAdminOperations.AddAsync(operation, ct).AsTask();
}
