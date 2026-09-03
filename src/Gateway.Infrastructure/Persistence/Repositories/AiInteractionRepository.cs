using System.Collections.ObjectModel;
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

    public async Task<IReadOnlyDictionary<Guid, DateTime>> GetLatestReceivedAtUtcAsync(
        IReadOnlyCollection<Guid> agentRegistrationIds,
        CancellationToken ct)
    {
        if (agentRegistrationIds.Count == 0)
        {
            return ReadOnlyDictionary<Guid, DateTime>.Empty;
        }

        var latest = await _dbContext.AiInteractionRecords
            .Where(record => agentRegistrationIds.Contains(record.AgentRegistrationId))
            .GroupBy(record => record.AgentRegistrationId)
            .Select(group => new
            {
                AgentRegistrationId = group.Key,
                ReceivedAtUtc = group.Max(record => record.ReceivedAtUtc)
            })
            .ToListAsync(ct);

        return latest.ToDictionary(entry => entry.AgentRegistrationId, entry => entry.ReceivedAtUtc);
    }
}
