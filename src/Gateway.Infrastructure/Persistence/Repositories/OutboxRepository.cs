using System.Data;
using System.Data.Common;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class OutboxRepository : IOutboxRepository
{
    private const string SqlServerProviderName = "Microsoft.EntityFrameworkCore.SqlServer";

    // EF's in-memory provider cannot execute the SQL Server claim statement. This
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
        await _dbContext.OutboxMessages.AddAsync(message, ct);
    }

    public async Task<List<OutboxMessage>> GetPendingAsync(int batchSize, CancellationToken ct)
    {
        return await _dbContext.OutboxMessages
            .Where(m => m.Status == OutboxMessageStatus.Pending)
            .OrderBy(m => m.CreatedAtUtc)
            .ThenBy(m => m.Id)
            .Take(batchSize)
            .ToListAsync(ct);
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

        if (string.Equals(
                _dbContext.Database.ProviderName,
                SqlServerProviderName,
                StringComparison.Ordinal))
        {
            return await ClaimPendingSqlServerAsync(
                batchSize,
                utcNow,
                claimExpiresAtUtc,
                ct);
        }

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

    private async Task<IReadOnlyList<OutboxMessage>> ClaimPendingSqlServerAsync(
        int batchSize,
        DateTime utcNow,
        DateTime claimExpiresAtUtc,
        CancellationToken ct)
    {
        const string commandText = """
            ;WITH [Candidates] AS
            (
                SELECT TOP (@batchSize) *
                FROM [OutboxMessages] WITH (UPDLOCK, READPAST, READCOMMITTEDLOCK)
                WHERE
                    ([Status] = N'Pending' AND ([NextRetryAtUtc] IS NULL OR [NextRetryAtUtc] <= @utcNow))
                    OR
                    ([Status] = N'Processing' AND [NextRetryAtUtc] <= @utcNow)
                ORDER BY [CreatedAtUtc], [Id]
            )
            UPDATE [Candidates]
            SET
                [Status] = N'Processing',
                [NextRetryAtUtc] = @claimExpiresAtUtc
            OUTPUT
                INSERTED.[Id],
                INSERTED.[MessageType],
                INSERTED.[Payload],
                INSERTED.[Status],
                INSERTED.[RetryCount],
                INSERTED.[CreatedAtUtc],
                INSERTED.[PublishedAtUtc],
                INSERTED.[NextRetryAtUtc];
            """;

        var connection = _dbContext.Database.GetDbConnection();
        var shouldCloseConnection = connection.State != ConnectionState.Open;
        if (shouldCloseConnection)
        {
            await connection.OpenAsync(ct);
        }

        try
        {
            await using var command = connection.CreateCommand();
            command.CommandText = commandText;
            AddParameter(command, "@batchSize", DbType.Int32, batchSize);
            AddParameter(command, "@utcNow", DbType.DateTime2, utcNow);
            AddParameter(command, "@claimExpiresAtUtc", DbType.DateTime2, claimExpiresAtUtc);

            var claimed = new List<OutboxMessage>(batchSize);
            await using var reader = await command.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                claimed.Add(new OutboxMessage
                {
                    Id = reader.GetGuid(0),
                    MessageType = reader.GetString(1),
                    Payload = reader.GetString(2),
                    Status = Enum.Parse<OutboxMessageStatus>(reader.GetString(3)),
                    RetryCount = reader.GetInt32(4),
                    CreatedAtUtc = DateTime.SpecifyKind(reader.GetDateTime(5), DateTimeKind.Utc),
                    PublishedAtUtc = reader.IsDBNull(6)
                        ? null
                        : DateTime.SpecifyKind(reader.GetDateTime(6), DateTimeKind.Utc),
                    NextRetryAtUtc = reader.IsDBNull(7)
                        ? null
                        : DateTime.SpecifyKind(reader.GetDateTime(7), DateTimeKind.Utc),
                });
            }

            return claimed;
        }
        finally
        {
            if (shouldCloseConnection)
            {
                await connection.CloseAsync();
            }
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

    private static void AddParameter(
        DbCommand command,
        string name,
        DbType dbType,
        object value)
    {
        var parameter = command.CreateParameter();
        parameter.ParameterName = name;
        parameter.DbType = dbType;
        parameter.Value = value;
        command.Parameters.Add(parameter);
    }
}
