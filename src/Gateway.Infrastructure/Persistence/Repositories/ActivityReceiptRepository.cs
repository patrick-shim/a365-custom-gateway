using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class ActivityReceiptRepository : IActivityReceiptRepository
{
    private readonly GatewayDbContext _dbContext;

    public ActivityReceiptRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public Task<ActivityReceipt?> GetByIdAsync(Guid id, CancellationToken ct)
    {
        return _dbContext.ActivityReceipts
            .FirstOrDefaultAsync(receipt => receipt.Id == id, ct);
    }

    public async Task AddAsync(ActivityReceipt receipt, CancellationToken ct)
    {
        await _dbContext.ActivityReceipts.AddAsync(receipt, ct);
    }

    public async Task<bool> ExistsByExternalIdAsync(Guid agentRegistrationId, string externalActivityId, CancellationToken ct)
    {
        return await _dbContext.ActivityReceipts
            .AnyAsync(r => r.AgentRegistrationId == agentRegistrationId
                && r.ExternalActivityId == externalActivityId, ct);
    }
}
