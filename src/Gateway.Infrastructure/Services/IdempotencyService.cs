using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Services;

internal sealed class IdempotencyService : IIdempotencyService
{
    private readonly GatewayDbContext _dbContext;

    public IdempotencyService(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<IdempotencyRecord?> GetAsync(string key, CancellationToken ct)
    {
        return await _dbContext.IdempotencyRecords
            .FirstOrDefaultAsync(r => r.IdempotencyKey == key, ct);
    }

    public async Task SaveAsync(IdempotencyRecord record, CancellationToken ct)
    {
        await _dbContext.IdempotencyRecords.AddAsync(record, ct);
    }
}
