using System.Data;
using System.Data.Common;
using System.Text.Json;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Outbox;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class OutboxRepository : IOutboxRepository
{
    private const string SqlServerProviderName = "Microsoft.EntityFrameworkCore.SqlServer";
    private const string ProtectionPublishFailureCode =
        "PROTECTION_ADMIN_OUTBOX_PUBLISH_FAILED";
    private const string ProtectionPublishFailureAction = "ReviewOperationFailure";

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

        if (terminal &&
            string.Equals(
                _dbContext.Database.ProviderName,
                SqlServerProviderName,
                StringComparison.Ordinal))
        {
            return await MarkTerminalFailedSqlServerAsync(
                id,
                claimExpiresAtUtc,
                ct);
        }

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

            if (terminal &&
                !await TryApplyProtectionTerminalFailureAsync(message!, ct))
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

    private async Task<bool> MarkTerminalFailedSqlServerAsync(
                Guid id,
                DateTime claimExpiresAtUtc,
                CancellationToken ct)
    {
        if (_dbContext.Database.CurrentTransaction is not null)
        {
            throw new InvalidOperationException(
                "Terminal outbox failure propagation must own its atomic SQL transaction.");
        }

        const string commandText = """
                    SET XACT_ABORT ON;
                    BEGIN TRANSACTION;

                    DECLARE @messageType nvarchar(256);
                    DECLARE @payload nvarchar(max);
                    DECLARE @destination nvarchar(128);

                    SELECT
                        @messageType = [MessageType],
                        @payload = [Payload],
                        @destination = [Destination]
                    FROM [dbo].[OutboxMessages] WITH (UPDLOCK, HOLDLOCK)
                    WHERE [Id] = @id
                      AND [Status] = N'Processing'
                      AND [NextRetryAtUtc] = @claimExpiresAtUtc;

                    IF @messageType IS NULL
                    BEGIN
                        ROLLBACK TRANSACTION;
                        SELECT CAST(0 AS bit);
                        RETURN;
                    END;

                    IF @messageType = N'ProtectionAdminOperationMessage'
                       AND @destination = N'gateway-protection-admin-v1'
                    BEGIN
                        DECLARE @operationId uniqueidentifier =
                            TRY_CONVERT(
                                uniqueidentifier,
                                COALESCE(
                                    JSON_VALUE(@payload, N'$.OperationId'),
                                    JSON_VALUE(@payload, N'$.operationId')));
                        DECLARE @workflowVersion int =
                            TRY_CONVERT(
                                int,
                                COALESCE(
                                    JSON_VALUE(@payload, N'$.WorkflowVersion'),
                                    JSON_VALUE(@payload, N'$.workflowVersion')));
                        DECLARE @correlationId uniqueidentifier =
                            TRY_CONVERT(
                                uniqueidentifier,
                                COALESCE(
                                    JSON_VALUE(@payload, N'$.CorrelationId'),
                                    JSON_VALUE(@payload, N'$.correlationId')));

                        IF @operationId IS NULL
                           OR @workflowVersion <> 1
                           OR @correlationId IS NULL
                           OR NOT EXISTS
                           (
                               SELECT 1
                               FROM [dbo].[ProtectionAdminOperations] WITH (UPDLOCK, HOLDLOCK)
                               WHERE [Id] = @operationId
                                 AND [WorkflowVersion] = @workflowVersion
                                 AND [CorrelationId] = @correlationId
                           )
                        BEGIN
                            ROLLBACK TRANSACTION;
                            SELECT CAST(0 AS bit);
                            RETURN;
                        END;

                        UPDATE [dbo].[ProtectionAdminOperations]
                        SET [Status] = N'Failed',
                            [RetryDisposition] = N'Exhausted',
                            [LastFailureCode] = N'PROTECTION_ADMIN_OUTBOX_PUBLISH_FAILED',
                            [RequiredAction] = N'ReviewOperationFailure',
                            [NextAttemptAtUtc] = NULL,
                            [UpdatedAtUtc] = SYSUTCDATETIME()
                        WHERE [Id] = @operationId
                          AND [Status] IN (N'Pending', N'Running', N'PendingPropagation');
                    END;

                    UPDATE [dbo].[OutboxMessages]
                    SET [Status] = N'Failed',
                        [RetryCount] =
                            CASE WHEN [RetryCount] = 2147483647
                                 THEN 2147483647 ELSE [RetryCount] + 1 END,
                        [NextRetryAtUtc] = NULL
                    WHERE [Id] = @id
                      AND [Status] = N'Processing'
                      AND [NextRetryAtUtc] = @claimExpiresAtUtc;

                    IF @@ROWCOUNT <> 1
                    BEGIN
                        ROLLBACK TRANSACTION;
                        SELECT CAST(0 AS bit);
                        RETURN;
                    END;

                    COMMIT TRANSACTION;
                    SELECT CAST(1 AS bit);
                    """;

        var connection = _dbContext.Database.GetDbConnection();
        var shouldCloseConnection = connection.State != ConnectionState.Open;
        if (shouldCloseConnection)
            await connection.OpenAsync(ct);

        try
        {
            await using var command = connection.CreateCommand();
            command.CommandText = commandText;
            AddParameter(command, "@id", DbType.Guid, id);
            AddParameter(
                command,
                "@claimExpiresAtUtc",
                DbType.DateTime2,
                claimExpiresAtUtc);
            var result = await command.ExecuteScalarAsync(ct);
            return result is bool updated && updated;
        }
        finally
        {
            if (shouldCloseConnection)
                await connection.CloseAsync();
        }
    }

    private async Task<bool> TryApplyProtectionTerminalFailureAsync(
        OutboxMessage message,
        CancellationToken ct)
    {
        var destination = _dbContext.Entry(message)
            .Property<string>("Destination")
            .CurrentValue;
        if (!string.Equals(
                message.MessageType,
                OutboxRouting.ProtectionAdminMessageType,
                StringComparison.Ordinal) ||
            !string.Equals(
                destination,
                OutboxRouting.ProtectionAdminDestination,
                StringComparison.Ordinal))
        {
            return true;
        }

        if (!TryReadProtectionMessage(message.Payload, out var coordinates))
            return false;

        var operation = await _dbContext.ProtectionAdminOperations.FindAsync(
            [coordinates!.OperationId],
            ct);
        if (operation is null ||
            operation.WorkflowVersion != coordinates.WorkflowVersion ||
            operation.CorrelationId != coordinates.CorrelationId)
        {
            return false;
        }

        if (operation.Status is
            ProtectionAdminOperationStatus.Pending or
            ProtectionAdminOperationStatus.Running or
            ProtectionAdminOperationStatus.PendingPropagation)
        {
            operation.Status = ProtectionAdminOperationStatus.Failed;
            operation.RetryDisposition = ProtectionRetryDisposition.Exhausted;
            operation.LastFailureCode = ProtectionPublishFailureCode;
            operation.RequiredAction = ProtectionPublishFailureAction;
            operation.NextAttemptAtUtc = null;
            operation.UpdatedAtUtc = DateTime.UtcNow;
        }

        return true;
    }

    private static bool TryReadProtectionMessage(
        string payload,
        out ProtectionAdminOperationMessage? message)
    {
        try
        {
            message = JsonSerializer.Deserialize<ProtectionAdminOperationMessage>(
                payload,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            return message is not null &&
                message.OperationId != Guid.Empty &&
                message.CorrelationId != Guid.Empty &&
                message.WorkflowVersion == ProtectionAdminQueueContract.WorkflowVersion;
        }
        catch (JsonException)
        {
            message = null;
            return false;
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
                    (
                        ([Status] = N'Pending' AND ([NextRetryAtUtc] IS NULL OR [NextRetryAtUtc] <= @utcNow))
                        OR
                        ([Status] = N'Processing' AND [NextRetryAtUtc] <= @utcNow)
                    )
                    AND
                    (
                        (
                            [MessageType] = N'ProtectionAdminOperationMessage'
                            AND [Destination] = N'gateway-protection-admin-v1'
                        )
                        OR
                        (
                            [MessageType] NOT LIKE N'%ProtectionAdmin%'
                            AND [Destination] = N'gateway-provisioning-v3'
                        )
                    )
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
