using System.Data;
using System.Data.Common;
using System.Text.Json;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Outbox;
using Gateway.Infrastructure.Services;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class OutboxRepository : IOutboxRepository
{
    private const string SqlServerProviderName = "Microsoft.EntityFrameworkCore.SqlServer";
    private const string ProtectionPublishFailureCode =
        "PROTECTION_ADMIN_OUTBOX_PUBLISH_FAILED";
    private const string ProtectionPublishFailureAction = "ReviewOperationFailure";
    private const string UnboundGenerationCode = "PROTECTION_ADMIN_PUBLICATION_GENERATION_UNBOUND";

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

            ProtectionAdminOperationMessage? coordinates = null;
            if (terminal &&
                string.Equals(message!.MessageType, OutboxRouting.ProtectionAdminMessageType, StringComparison.Ordinal) &&
                string.Equals(_dbContext.Entry(message).Property<string>("Destination").CurrentValue,
                    OutboxRouting.ProtectionAdminDestination, StringComparison.Ordinal) &&
                !TryReadProtectionMessage(message.Payload, out coordinates))
            {
                return false;
            }

            await using var executionLease = coordinates is null ? null :
                await new ProtectionAdminOperationLockProvider(_dbContext)
                    .AcquireExecutionAsync(coordinates.OperationId, ct);
            if (coordinates is not null &&
                !await TryApplyProtectionTerminalFailureAsync(coordinates, ct))
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

        var publication = await _dbContext.OutboxMessages.AsNoTracking()
            .Where(message => message.Id == id &&
                message.Status == OutboxMessageStatus.Processing &&
                message.NextRetryAtUtc == claimExpiresAtUtc)
            .Select(message => new
            {
                message.MessageType,
                message.Payload,
                Destination = EF.Property<string>(message, "Destination")
            })
            .SingleOrDefaultAsync(ct);
        if (publication is null)
            return false;

        ProtectionAdminOperationMessage? coordinates = null;
        if (string.Equals(publication.MessageType, OutboxRouting.ProtectionAdminMessageType, StringComparison.Ordinal) &&
            string.Equals(publication.Destination, OutboxRouting.ProtectionAdminDestination, StringComparison.Ordinal) &&
            !TryReadProtectionMessage(publication.Payload, out coordinates))
        {
            return false;
        }

        // Use the worker's lock before taking SQL row locks; recheck the claim and
        // payload inside the transaction after any in-flight step has committed.
        await using var executionLease = coordinates is null ? null :
            await new ProtectionAdminOperationLockProvider(_dbContext)
                .AcquireExecutionAsync(coordinates.OperationId, ct);
        await using var transaction = await _dbContext.Database.BeginTransactionAsync(ct);
        await using var command = _dbContext.Database.GetDbConnection().CreateCommand();
        command.Transaction = transaction.GetDbTransaction();
        command.CommandText = """
            SET XACT_ABORT ON;

            IF NOT EXISTS
            (
                SELECT 1
                FROM [dbo].[OutboxMessages] WITH (UPDLOCK, HOLDLOCK)
                WHERE [Id] = @id
                  AND [Status] = N'Processing'
                  AND [NextRetryAtUtc] = @claimExpiresAtUtc
                  AND [MessageType] = @messageType
                  AND [Destination] = @destination
                  AND [Payload] COLLATE Latin1_General_100_BIN2 = @payload
            )
            BEGIN
                SELECT CAST(0 AS bit);
                RETURN;
            END;

            IF @operationId IS NOT NULL
            BEGIN
                IF NOT EXISTS
                (
                    SELECT 1
                    FROM [dbo].[ProtectionAdminOperations] WITH (UPDLOCK, HOLDLOCK)
                    WHERE [Id] = @operationId
                      AND [WorkflowVersion] = @workflowVersion
                      AND [CorrelationId] = @correlationId
                )
                BEGIN
                    SELECT CAST(0 AS bit);
                    RETURN;
                END;

                DECLARE @currentStepIndex int;
                DECLARE @currentStepGeneration int;
                SELECT TOP (1)
                    @currentStepIndex = step.[OrderIndex],
                    @currentStepGeneration =
                        CASE WHEN step.[Status] = N'Running'
                             THEN step.[AttemptCount] - 1 ELSE step.[AttemptCount] END
                FROM [dbo].[ProtectionAdminOperations] operation WITH (UPDLOCK, HOLDLOCK)
                INNER JOIN [dbo].[ProtectionAdminOperationSteps] step WITH (UPDLOCK, HOLDLOCK)
                    ON step.[ProtectionAdminOperationId] = operation.[Id]
                WHERE operation.[Id] = @operationId
                  AND operation.[Status] IN (N'Pending', N'Running', N'PendingPropagation')
                  AND step.[Status] NOT IN (N'Completed', N'Skipped')
                ORDER BY step.[OrderIndex];

                IF @expectedStepIndex = @currentStepIndex AND @expectedStepAttemptCount IS NULL
                BEGIN
                    SELECT @unboundGenerationCode;
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
                  AND [Status] IN (N'Pending', N'Running', N'PendingPropagation')
                  AND @expectedStepIndex = @currentStepIndex
                  AND @expectedStepAttemptCount = @currentStepGeneration;
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

            SELECT CAST(CASE WHEN @@ROWCOUNT = 1 THEN 1 ELSE 0 END AS bit);
            """;
        AddParameter(command, "@id", DbType.Guid, id);
        AddParameter(command, "@claimExpiresAtUtc", DbType.DateTime2, claimExpiresAtUtc);
        AddParameter(command, "@messageType", DbType.String, publication.MessageType);
        AddParameter(command, "@destination", DbType.String, publication.Destination);
        AddParameter(command, "@payload", DbType.String, publication.Payload);
        AddParameter(command, "@operationId", DbType.Guid, coordinates is null ? DBNull.Value : coordinates.OperationId);
        AddParameter(command, "@workflowVersion", DbType.Int32, coordinates is null ? DBNull.Value : coordinates.WorkflowVersion);
        AddParameter(command, "@correlationId", DbType.Guid, coordinates is null ? DBNull.Value : coordinates.CorrelationId);
        AddParameter(command, "@expectedStepIndex", DbType.Int32, coordinates is null ? DBNull.Value : coordinates.ExpectedStepIndex);
        AddParameter(command, "@expectedStepAttemptCount", DbType.Int32,
            coordinates?.ExpectedStepAttemptCount is { } attemptCount ? attemptCount : DBNull.Value);
        AddParameter(command, "@unboundGenerationCode", DbType.String, UnboundGenerationCode);
        var result = await command.ExecuteScalarAsync(ct);
        if (result is string failureCode && failureCode == UnboundGenerationCode)
            throw UnboundProtectionPublication();
        if (result is not true)
        {
            return false;
        }

        await transaction.CommitAsync(ct);
        return true;
    }

    private async Task<bool> TryApplyProtectionTerminalFailureAsync(
        ProtectionAdminOperationMessage coordinates,
        CancellationToken ct)
    {
        var operation = await _dbContext.ProtectionAdminOperations
            .Include("_steps")
            .SingleOrDefaultAsync(operation => operation.Id == coordinates.OperationId, ct);
        if (operation is null)
            return false;

        // A relay scope can already track this operation from an older
        // publication. The execution lock must protect a fresh durable read.
        var operationEntry = _dbContext.Entry(operation);
        await operationEntry.ReloadAsync(ct);
        if (operationEntry.State == EntityState.Detached)
            return false;
        foreach (var step in operation.OrderedSteps)
        {
            var stepEntry = _dbContext.Entry(step);
            await stepEntry.ReloadAsync(ct);
            if (stepEntry.State == EntityState.Detached)
                return false;
        }

        if (operation.WorkflowVersion != coordinates.WorkflowVersion ||
            operation.CorrelationId != coordinates.CorrelationId)
        {
            return false;
        }

        var currentStep = operation.OrderedSteps.FirstOrDefault(step =>
            step.Status is not ProtectionAdminStepStatus.Completed and not ProtectionAdminStepStatus.Skipped);
        if (currentStep is not null && currentStep.OrderIndex == coordinates.ExpectedStepIndex &&
            operation.Status is
            ProtectionAdminOperationStatus.Pending or
            ProtectionAdminOperationStatus.Running or
            ProtectionAdminOperationStatus.PendingPropagation)
        {
            if (coordinates.ExpectedStepAttemptCount is not { } expectedAttemptCount)
                throw UnboundProtectionPublication();
            var currentGeneration = currentStep.Status == ProtectionAdminStepStatus.Running
                ? currentStep.AttemptCount - 1
                : currentStep.AttemptCount;
            if (expectedAttemptCount != currentGeneration)
                return true;

            operation.Status = ProtectionAdminOperationStatus.Failed;
            operation.RetryDisposition = ProtectionRetryDisposition.Exhausted;
            operation.LastFailureCode = ProtectionPublishFailureCode;
            operation.RequiredAction = ProtectionPublishFailureAction;
            operation.NextAttemptAtUtc = null;
            operation.UpdatedAtUtc = DateTime.UtcNow;
        }

        return true;
    }

    private static InvalidOperationException UnboundProtectionPublication() =>
        new($"{UnboundGenerationCode}: The current publication has no durable step attempt binding; its outcome requires reconciliation.");

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
                message.ExpectedStepIndex >= 0 &&
                message.ExpectedStepIndex < ProtectionAdminWorkflow.CurrentSteps.Count &&
                message.ExpectedStepAttemptCount is null or >= 0 &&
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
