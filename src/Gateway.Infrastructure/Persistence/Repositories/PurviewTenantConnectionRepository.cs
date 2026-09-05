using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class PurviewTenantConnectionRepository : IPurviewTenantConnectionRepository
{
    private readonly GatewayDbContext _dbContext;

    public PurviewTenantConnectionRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public Task<PurviewTenantConnection?> GetByIdAsync(Guid id, CancellationToken ct) =>
        _dbContext.PurviewTenantConnections.SingleOrDefaultAsync(
            connection => connection.Id == id,
            ct);

    public Task<PurviewTenantConnection?> GetByTenantIdAsync(
        EntraTenantId tenantId,
        CancellationToken ct) =>
        _dbContext.PurviewTenantConnections.SingleOrDefaultAsync(
            connection => connection.TenantId == tenantId,
            ct);

    public Task AddAsync(PurviewTenantConnection connection, CancellationToken ct) =>
        _dbContext.PurviewTenantConnections.AddAsync(connection, ct).AsTask();
}
