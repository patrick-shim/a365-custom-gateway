using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class AiInteractionRepository : IAiInteractionRepository
{
    private readonly GatewayDbContext _dbContext;

    public AiInteractionRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public Task<AiInteractionRecord?> GetByIdAsync(Guid id, CancellationToken ct)
    {
        return _dbContext.AiInteractionRecords
            .FirstOrDefaultAsync(record => record.Id == id, ct);
    }

    public async Task AddAsync(AiInteractionRecord record, CancellationToken ct)
    {
        await _dbContext.AiInteractionRecords.AddAsync(record, ct);
    }
}
