using System.Data;
using System.Security.Cryptography;
using System.Text;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using Npgsql;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class PurviewConnectorStore(
    GatewayDbContext db,
    ILogger<PurviewConnectorStore> logger) : IPurviewConnectorStore
{
    internal const int MaximumSubmissionAttempts = 3;

    public Task<PurviewConnectorStateRecord?> GetStateAsync(Guid tenantId, CancellationToken ct) =>
        db.PurviewConnectorStates.AsNoTracking().SingleOrDefaultAsync(x => x.TenantId == tenantId, ct);

    public Task<PurviewConnectorOperation?> GetOperationAsync(Guid operationId, CancellationToken ct) =>
        db.PurviewConnectorOperations.AsNoTracking().SingleOrDefaultAsync(x => x.Id == operationId, ct);

    public Task<PurviewCatalogSnapshot?> GetAcceptedCatalogAsync(
        Guid tenantId,
        Guid connectorInstanceId,
        CancellationToken ct) =>
        db.PurviewCatalogSnapshots.AsNoTracking()
            .Where(x => x.TenantId == tenantId && x.ConnectorInstanceId == connectorInstanceId)
            .OrderByDescending(x => x.Generation)
            .FirstOrDefaultAsync(ct);

    public async Task<PurviewConnectorSubmissionResult> SubmitAsync(
        PurviewConnectorSubmission submission,
        CancellationToken ct)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return await SubmitOnceAsync(submission, ct);
            }
            catch (Exception failure) when (
                attempt < MaximumSubmissionAttempts &&
                IsTransientTransactionConflict(failure))
            {
                db.ChangeTracker.Clear();
                var retryDelay = GetRetryDelay(attempt);
                logger.LogWarning(
                    "Purview connector submission encountered transient database contention " +
                    "(attempt {Attempt} of {MaximumAttempts}). Retrying in {DelayMilliseconds}ms.",
                    attempt,
                    MaximumSubmissionAttempts,
                    retryDelay.TotalMilliseconds);
                await Task.Delay(retryDelay, ct);
            }
        }
    }

    private async Task<PurviewConnectorSubmissionResult> SubmitOnceAsync(
        PurviewConnectorSubmission submission,
        CancellationToken ct)
    {
        await using var transaction = await db.Database.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        if (PostgresAdvisoryLock.IsNpgsql(db))
        {
            var (key1, key2) = PostgresAdvisoryLock.ToKeyPair($"a365gw:purview-connector:{submission.TenantId:D}");
            await db.Database.ExecuteSqlInterpolatedAsync($"SELECT pg_advisory_xact_lock({key1}, {key2})", ct);
        }

        var existing = await db.PurviewConnectorOperations
            .SingleOrDefaultAsync(x => x.TenantId == submission.TenantId && x.IdempotencyKey == submission.IdempotencyKey, ct);
        if (existing is not null)
        {
            if (!CryptographicOperations.FixedTimeEquals(
                    Encoding.ASCII.GetBytes(existing.RequestHash),
                    Encoding.ASCII.GetBytes(submission.RequestHash)))
                throw new ConflictException(
                    "The Idempotency-Key was already used for a different Purview connector request.",
                    ErrorCodes.IDEMPOTENCY_CONFLICT);
            var existingState = await db.PurviewConnectorStates.SingleAsync(x => x.TenantId == submission.TenantId, ct);
            await transaction.CommitAsync(ct);
            return new(existingState, existing, true);
        }

        var state = await db.PurviewConnectorStates.SingleOrDefaultAsync(x => x.TenantId == submission.TenantId, ct);
        if (state is null)
        {
            if (submission.Type != PurviewConnectorOperationType.Connect || submission.ExpectedRowVersion != "*")
                throw new ConflictException(
                    "Connect the bootstrap-owned Purview connector before requesting a policy refresh.",
                    ErrorCodes.PURVIEW_CONNECTOR_SETUP_REQUIRED);
            state = new PurviewConnectorStateRecord
            {
                Id = Guid.NewGuid(),
                TenantId = submission.TenantId,
                ConnectorInstanceId = submission.ConnectorInstanceId,
                ConnectorProfile = submission.ConnectorProfile,
                State = PurviewConnectorState.NotConfigured,
                RefreshMode = "Manual",
                CreatedAtUtc = submission.RequestedAtUtc,
                UpdatedAtUtc = submission.RequestedAtUtc,
                RowVersion = Guid.NewGuid().ToByteArray()
            };
            db.PurviewConnectorStates.Add(state);
        }
        else
        {
            if (state.ConnectorInstanceId != submission.ConnectorInstanceId ||
                !string.Equals(state.ConnectorProfile, submission.ConnectorProfile, StringComparison.Ordinal))
                throw new ConflictException(
                    "The installed Purview connector does not match the recorded deployment connector.",
                    ErrorCodes.PURVIEW_CONNECTOR_SETUP_REQUIRED);
            EnsureRowVersion(submission.ExpectedRowVersion, state.RowVersion);
        }

        var active = await db.PurviewConnectorOperations
            .Where(x => x.TenantId == submission.TenantId &&
                (x.Status == PurviewConnectorOperationStatus.Pending || x.Status == PurviewConnectorOperationStatus.Running))
            .OrderByDescending(x => x.CreatedAtUtc)
            .FirstOrDefaultAsync(ct);
        if (active is not null)
        {
            throw new ConflictException(
                "Another Purview connector operation is already in progress.",
                ErrorCodes.PURVIEW_CONNECTOR_OPERATION_CONFLICT,
                conflictingOperationId: active.Id);
        }

        if (!IsLegalSubmissionState(submission.Type, state.State))
        {
            throw new ConflictException(
                submission.Type == PurviewConnectorOperationType.RefreshCatalog
                    ? "Connect the Purview connector before requesting a policy refresh."
                    : "The Purview connector is already configured. Use Policy Refresh for an existing connection.",
                ErrorCodes.PURVIEW_CONNECTOR_OPERATION_CONFLICT);
        }

        var operation = new PurviewConnectorOperation
        {
            Id = Guid.NewGuid(),
            TenantId = submission.TenantId,
            ConnectorInstanceId = submission.ConnectorInstanceId,
            Type = submission.Type,
            Status = PurviewConnectorOperationStatus.Pending,
            CurrentStep = "Queued",
            PercentComplete = 0,
            Generation = state.NextGeneration++,
            IdempotencyKey = submission.IdempotencyKey,
            RequestHash = submission.RequestHash,
            RequestedByObjectId = submission.RequestedByObjectId,
            CorrelationId = submission.CorrelationId,
            IssuedAtUtc = submission.RequestedAtUtc,
            ExpiresAtUtc = submission.ExpiresAtUtc,
            CreatedAtUtc = submission.RequestedAtUtc,
            RowVersion = Guid.NewGuid().ToByteArray()
        };
        state.State = submission.Type == PurviewConnectorOperationType.Connect
            ? PurviewConnectorState.Connecting
            : PurviewConnectorState.Refreshing;
        state.CurrentOperationId = operation.Id;
        state.LastAttemptedRefreshAtUtc = submission.RequestedAtUtc;
        state.LastFailureCode = null;
        state.LastCorrelationId = submission.CorrelationId;
        state.UpdatedAtUtc = submission.RequestedAtUtc;
        state.RowVersion = Guid.NewGuid().ToByteArray();
        db.PurviewConnectorOperations.Add(operation);
        db.AuditEvents.Add(new AuditEvent
        {
            Id = Guid.NewGuid(),
            EventType = submission.Type == PurviewConnectorOperationType.Connect
                ? "PurviewConnectionRequested"
                : "PurviewCatalogRefreshRequested",
            PerformedByObjectId = submission.RequestedByObjectId,
            PerformedByRole = "GatewayAdministrator",
            Details = $"OperationId={operation.Id:D}; ConnectorInstanceId={operation.ConnectorInstanceId:D}; Generation={operation.Generation}",
            CorrelationId = submission.CorrelationId,
            OccurredAtUtc = submission.RequestedAtUtc
        });
        await db.SaveChangesAsync(ct);
        await transaction.CommitAsync(ct);
        return new(state, operation, false);
    }

    internal static bool IsTransientTransactionConflict(Exception failure)
    {
        for (Exception? current = failure; current is not null; current = current.InnerException)
        {
            if (current is PostgresException postgres &&
                postgres.SqlState is PostgresErrorCodes.SerializationFailure or PostgresErrorCodes.DeadlockDetected)
                return true;
        }

        return false;
    }

    internal static TimeSpan GetRetryDelay(int failedAttempt) =>
        TimeSpan.FromMilliseconds(Math.Min(100, 25 * Math.Max(1, failedAttempt)));

    internal static bool IsLegalSubmissionState(
        PurviewConnectorOperationType type,
        PurviewConnectorState state) => type switch
        {
            PurviewConnectorOperationType.Connect =>
                state is PurviewConnectorState.NotConfigured or PurviewConnectorState.Disconnected,
            PurviewConnectorOperationType.RefreshCatalog =>
                state is PurviewConnectorState.Connected or PurviewConnectorState.Degraded,
            _ => false
        };

    private static void EnsureRowVersion(string expected, byte[] actual)
    {
        if (expected == "*" || !RowVersionValidation.IsCanonical(expected) ||
            !CryptographicOperations.FixedTimeEquals(Convert.FromBase64String(expected), actual))
            throw new PreconditionFailedException(
                "The Purview connection changed. Refresh its status and review the operation again.",
                ErrorCodes.CONCURRENCY_CONFLICT);
    }
}
