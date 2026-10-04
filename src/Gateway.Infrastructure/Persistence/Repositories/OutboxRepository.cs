using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Outbox;
using Gateway.Infrastructure.Services;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed partial class OutboxRepository : IOutboxRepository
{
    // EF's in-memory provider cannot execute the PostgreSQL claim statement. This
    // lock preserves the same single-process semantics for local tests only. The
    // deployed multi-instance guarantee comes from the atomic SQL UPDATE below.
    private static readonly SemaphoreSlim NonSqlClaimLock = new(1, 1);

    private readonly GatewayDbContext _dbContext;

    public OutboxRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task AddAsync(OutboxMessage message, CancellationToken ct)
    {
        _dbContext.Entry(message).Property<string>("Destination").CurrentValue =
            OutboxRouting.ResolveDestination(message.MessageType);
        await _dbContext.OutboxMessages.AddAsync(message, ct);
    }

    public async Task<IReadOnlyList<OutboxMessage>> ClaimPendingAsync(
        int batchSize,
        DateTime utcNow,
        DateTime claimExpiresAtUtc,
        CancellationToken ct)
    {
        if (batchSize <= 0)
        {
            return [];
        }


        if (PostgresAdvisoryLock.IsNpgsql(_dbContext))
            return await ClaimPendingPostgresAsync(batchSize, utcNow, claimExpiresAtUtc, ct);
        if (_dbContext.Database.ProviderName != "Microsoft.EntityFrameworkCore.InMemory")
            throw new NotSupportedException("Outbox claiming requires PostgreSQL.");

        return await ClaimPendingNonSqlAsync(
            batchSize,
            utcNow,
            claimExpiresAtUtc,
            ct);
    }

    public async Task<bool> MarkPublishedAsync(
        Guid id,
        DateTime claimExpiresAtUtc,
        DateTime publishedAtUtc,
        CancellationToken ct)
    {
        if (_dbContext.Database.IsRelational())
        {
            var affected = await _dbContext.OutboxMessages
                .Where(message =>
                    message.Id == id &&
                    message.Status == OutboxMessageStatus.Processing &&
                    message.NextRetryAtUtc == claimExpiresAtUtc)
                .ExecuteUpdateAsync(
                    setters => setters
                        .SetProperty(message => message.Status, OutboxMessageStatus.Published)
                        .SetProperty(message => message.PublishedAtUtc, publishedAtUtc)
                        .SetProperty(message => message.NextRetryAtUtc, (DateTime?)null),
                    ct);

            return affected == 1;
        }

        await NonSqlClaimLock.WaitAsync(ct);
        try
        {
            var message = await _dbContext.OutboxMessages.FindAsync([id], ct);
            if (!OwnsClaim(message, claimExpiresAtUtc))
            {
                return false;
            }

            message!.Status = OutboxMessageStatus.Published;
            message.PublishedAtUtc = publishedAtUtc;
            message.NextRetryAtUtc = null;
            await _dbContext.SaveChangesAsync(ct);
            return true;
        }
        finally
        {
            NonSqlClaimLock.Release();
        }
    }

    public async Task<bool> MarkFailedAsync(
        Guid id,
        DateTime claimExpiresAtUtc,
        DateTime? nextRetryAtUtc,
        bool terminal,
        CancellationToken ct)
    {
        var status = terminal
            ? OutboxMessageStatus.Failed
            : OutboxMessageStatus.Pending;
        var retryAtUtc = terminal ? null : nextRetryAtUtc;



        if (_dbContext.Database.IsRelational())
        {
            var affected = await _dbContext.OutboxMessages
                .Where(message =>
                    message.Id == id &&
                    message.Status == OutboxMessageStatus.Processing &&
                    message.NextRetryAtUtc == claimExpiresAtUtc)
                .ExecuteUpdateAsync(
                    setters => setters
                        .SetProperty(message => message.Status, status)
                        .SetProperty(
                            message => message.RetryCount,
                            message => message.RetryCount == int.MaxValue
                                ? int.MaxValue
                                : message.RetryCount + 1)
                        .SetProperty(message => message.NextRetryAtUtc, retryAtUtc),
                    ct);

            return affected == 1;
        }

        await NonSqlClaimLock.WaitAsync(ct);
        try
        {
            var message = await _dbContext.OutboxMessages.FindAsync([id], ct);
            if (!OwnsClaim(message, claimExpiresAtUtc))
            {
                return false;
            }

            message!.Status = status;
            if (message.RetryCount < int.MaxValue)
            {
                message.RetryCount++;
            }
            message.NextRetryAtUtc = retryAtUtc;
            await _dbContext.SaveChangesAsync(ct);
            return true;
        }
        finally
        {
            NonSqlClaimLock.Release();
        }
    }

    private async Task<IReadOnlyList<OutboxMessage>> ClaimPendingNonSqlAsync(
        int batchSize,
        DateTime utcNow,
        DateTime claimExpiresAtUtc,
        CancellationToken ct)
    {
        await NonSqlClaimLock.WaitAsync(ct);
        try
        {
            var claimed = await _dbContext.OutboxMessages
                .Where(message =>
                    (message.Status == OutboxMessageStatus.Pending &&
                     (message.NextRetryAtUtc == null || message.NextRetryAtUtc <= utcNow)) ||
                    (message.Status == OutboxMessageStatus.Processing &&
                     message.NextRetryAtUtc <= utcNow))
                .OrderBy(message => message.CreatedAtUtc)
                .ThenBy(message => message.Id)
                .Take(batchSize)
                .ToListAsync(ct);

            foreach (var message in claimed)
            {
                message.Status = OutboxMessageStatus.Processing;
                message.NextRetryAtUtc = claimExpiresAtUtc;
            }

            await _dbContext.SaveChangesAsync(ct);
            return claimed;
        }
        finally
        {
            NonSqlClaimLock.Release();
        }
    }

    private static bool OwnsClaim(OutboxMessage? message, DateTime claimExpiresAtUtc)
    {
        return message is
        {
            Status: OutboxMessageStatus.Processing,
            NextRetryAtUtc: not null,
        } && message.NextRetryAtUtc.Value == claimExpiresAtUtc;
    }

}
