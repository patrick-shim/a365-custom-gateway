using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class ProtectionCapabilityRepository : IProtectionCapabilityRepository
{
    private readonly GatewayDbContext _dbContext;

    public ProtectionCapabilityRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<IReadOnlyList<ProtectionCapability>> ListAsync(CancellationToken ct) =>
        await _dbContext.ProtectionCapabilities
            .AsNoTracking()
            .OrderBy(capability => capability.Kind)
            .ToArrayAsync(ct);

    public Task<ProtectionCapability?> GetByKindAsync(
        ProtectionCapabilityKind kind,
        CancellationToken ct) =>
        _dbContext.ProtectionCapabilities.SingleOrDefaultAsync(
            capability => capability.Kind == kind,
            ct);

    public Task AddAsync(ProtectionCapability capability, CancellationToken ct) =>
        _dbContext.ProtectionCapabilities.AddAsync(capability, ct).AsTask();
}
