using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class PurviewPolicyProfileRepository : IPurviewPolicyProfileRepository
{
    private readonly GatewayDbContext _dbContext;

    public PurviewPolicyProfileRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<IReadOnlyList<PurviewPolicyProfile>> ListReadyAsync(CancellationToken ct) =>
        await _dbContext.PurviewPolicyProfiles
            .AsNoTracking()
            .Where(profile => profile.Status == "Ready")
            .OrderBy(profile => profile.DisplayName)
            .ToArrayAsync(ct);

    public Task<PurviewPolicyProfile?> GetByIdAsync(Guid id, CancellationToken ct) =>
        _dbContext.PurviewPolicyProfiles.SingleOrDefaultAsync(profile => profile.Id == id, ct);

    public Task<bool> DisplayNameExistsAsync(string displayName, CancellationToken ct) =>
        _dbContext.PurviewPolicyProfiles.AnyAsync(
            profile => profile.DisplayName == displayName,
            ct);

    public Task AddAsync(PurviewPolicyProfile profile, CancellationToken ct) =>
        _dbContext.PurviewPolicyProfiles.AddAsync(profile, ct).AsTask();
}
