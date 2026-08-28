using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Interfaces;
using Microsoft.EntityFrameworkCore;

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
        try
        {
            return await _dbContext.SaveChangesAsync(ct);
        }
        catch (DbUpdateConcurrencyException exception)
        {
            throw new ConflictException(
                "The resource changed while this request was being processed. Refresh it and try again.",
                ErrorCodes.CONCURRENCY_CONFLICT,
                exception);
        }
    }
}
