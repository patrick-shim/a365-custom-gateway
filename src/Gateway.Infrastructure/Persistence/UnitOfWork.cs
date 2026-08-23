using Gateway.Domain.Interfaces;

namespace Gateway.Infrastructure.Persistence;

internal sealed class UnitOfWork : IUnitOfWork
{
    private readonly GatewayDbContext _dbContext;

    public UnitOfWork(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<int> SaveChangesAsync(CancellationToken ct)
    {
        return await _dbContext.SaveChangesAsync(ct);
    }
}
