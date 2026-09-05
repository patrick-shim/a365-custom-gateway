using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class PurviewDlpProfileRepository : IPurviewDlpProfileRepository
{
    private readonly GatewayDbContext _dbContext;

    public PurviewDlpProfileRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<IReadOnlyList<PurviewDlpProfile>> ListAsync(CancellationToken ct) =>
        await _dbContext.PurviewDlpProfiles
            .AsNoTracking()
            .OrderBy(profile => profile.DisplayName)
            .ThenBy(profile => profile.BlueprintApplicationId)
            .ToArrayAsync(ct);

    public Task<PurviewDlpProfile?> GetByIdAsync(
        PurviewDlpProfileId id,
        CancellationToken ct) =>
        _dbContext.PurviewDlpProfiles.SingleOrDefaultAsync(
            profile => profile.Id == id,
            ct);

    public Task<PurviewDlpProfile?> GetByBlueprintApplicationIdAsync(
        BlueprintApplicationId blueprintApplicationId,
        CancellationToken ct) =>
        _dbContext.PurviewDlpProfiles.SingleOrDefaultAsync(
            profile => profile.BlueprintApplicationId == blueprintApplicationId,
            ct);

    public Task AddAsync(PurviewDlpProfile profile, CancellationToken ct) =>
        _dbContext.PurviewDlpProfiles.AddAsync(profile, ct).AsTask();
}
