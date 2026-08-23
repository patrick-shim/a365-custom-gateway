using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class AiInteractionRepository : IAiInteractionRepository
{
    private readonly GatewayDbContext _dbContext;

    public AiInteractionRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task AddAsync(AiInteractionRecord record, CancellationToken ct)
    {
        await _dbContext.AiInteractionRecords.AddAsync(record, ct);
    }
}
