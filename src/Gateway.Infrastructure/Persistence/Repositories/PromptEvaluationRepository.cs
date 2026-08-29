using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class PromptEvaluationRepository : IPromptEvaluationRepository
{
    private readonly GatewayDbContext _dbContext;

    public PromptEvaluationRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public Task<PromptEvaluationRecord?> GetByIdAsync(Guid id, CancellationToken cancellationToken) =>
        _dbContext.PromptEvaluationRecords.SingleOrDefaultAsync(record => record.Id == id, cancellationToken);

    public async Task<bool> TryConsumeAsync(
        Guid id,
        DateTime consumedAtUtc,
        CancellationToken cancellationToken)
    {
        if (string.Equals(
                _dbContext.Database.ProviderName,
                "Microsoft.EntityFrameworkCore.InMemory",
                StringComparison.Ordinal))
        {
            var record = await _dbContext.PromptEvaluationRecords
                .SingleOrDefaultAsync(item => item.Id == id, cancellationToken);
            if (record is null || record.ConsumedAtUtc is not null || record.ExpiresAtUtc <= consumedAtUtc)
                return false;

            record.ConsumedAtUtc = consumedAtUtc;
            return true;
        }

        var affected = await _dbContext.PromptEvaluationRecords
            .Where(record =>
                record.Id == id
                && record.ConsumedAtUtc == null
                && record.ExpiresAtUtc > consumedAtUtc)
            .ExecuteUpdateAsync(
                setters => setters.SetProperty(record => record.ConsumedAtUtc, consumedAtUtc),
                cancellationToken);
        return affected == 1;
    }

    public async Task AddAsync(PromptEvaluationRecord record, CancellationToken cancellationToken) =>
        await _dbContext.PromptEvaluationRecords.AddAsync(record, cancellationToken);
}
