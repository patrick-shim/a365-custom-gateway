using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class OutboxRepository : IOutboxRepository
{
    private readonly GatewayDbContext _dbContext;

    public OutboxRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task AddAsync(OutboxMessage message, CancellationToken ct)
    {
        await _dbContext.OutboxMessages.AddAsync(message, ct);
    }

    public async Task<List<OutboxMessage>> GetPendingAsync(int batchSize, CancellationToken ct)
    {
        return await _dbContext.OutboxMessages
            .Where(m => m.Status == OutboxMessageStatus.Pending)
            .OrderBy(m => m.CreatedAtUtc)
            .Take(batchSize)
            .ToListAsync(ct);
    }

    public async Task MarkPublishedAsync(Guid id, CancellationToken ct)
    {
        var message = await _dbContext.OutboxMessages.FindAsync([id], ct);
        if (message is null) return;

        message.Status = OutboxMessageStatus.Published;
        message.PublishedAtUtc = DateTime.UtcNow;
    }

    public async Task MarkFailedAsync(Guid id, CancellationToken ct)
    {
        var message = await _dbContext.OutboxMessages.FindAsync([id], ct);
        if (message is null) return;

        message.Status = OutboxMessageStatus.Failed;
        message.RetryCount++;
    }
}
