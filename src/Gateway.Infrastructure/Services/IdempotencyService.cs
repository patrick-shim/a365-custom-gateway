using System.Data;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;

namespace Gateway.Infrastructure.Services;

internal sealed class IdempotencyService : IIdempotencyService
{
    private const int DefaultRetentionDays = 7;
    private const int ApplicationLockTimeoutMilliseconds = 30_000;
    private const int ApplicationLockCommandTimeoutSeconds = 35;
    private const string SqlServerProviderName = "Microsoft.EntityFrameworkCore.SqlServer";
    private const string InMemoryProviderName = "Microsoft.EntityFrameworkCore.InMemory";
    private static readonly object InMemoryScopeLocksGate = new();
    private static readonly Dictionary<string, InMemoryLockEntry> InMemoryScopeLocks =
        new(StringComparer.Ordinal);
    private readonly GatewayDbContext _dbContext;

    public IdempotencyService(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<IIdempotencyScopeLease> AcquireScopeAsync(
        Guid agentRegistrationId,
        string endpoint,
        string key,
        CancellationToken ct)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(endpoint);
        ArgumentException.ThrowIfNullOrWhiteSpace(key);

        var resourceName = CreateOpaqueResourceName(agentRegistrationId, endpoint, key);
        var providerName = _dbContext.Database.ProviderName;

        if (string.Equals(providerName, SqlServerProviderName, StringComparison.Ordinal))
            return await AcquireSqlServerScopeAsync(resourceName, ct);

        if (string.Equals(providerName, InMemoryProviderName, StringComparison.Ordinal))
        {
            var entry = AddInMemoryLockReference(resourceName);
            try
            {
                await entry.Semaphore.WaitAsync(ct);
                return new InMemoryIdempotencyScopeLease(resourceName, entry);
            }
            catch
            {
                RemoveInMemoryLockReference(resourceName, entry);
                throw;
            }
        }

        throw new NotSupportedException(
            $"Atomic idempotency scope locking is not supported by the configured EF provider '{providerName ?? "unknown"}'.");
    }

    public async Task<IdempotencyRecord?> GetAsync(
        Guid agentRegistrationId,
        string endpoint,
        string key,
        DateTime asOfUtc,
        CancellationToken ct)
    {
        var record = await _dbContext.IdempotencyRecords
            .SingleOrDefaultAsync(record =>
                record.AgentRegistrationId == agentRegistrationId &&
                record.Endpoint == endpoint &&
                record.IdempotencyKey == key,
                ct);

        if (record is not null && record.ExpiresAtUtc > asOfUtc)
            return record;

        var hasUnexpiredLegacyRecord = await _dbContext.IdempotencyRecords
            .AnyAsync(legacy =>
                legacy.AgentRegistrationId == null &&
                legacy.Endpoint == endpoint &&
                legacy.IdempotencyKey == key &&
                legacy.ExpiresAtUtc > asOfUtc,
                ct);

        if (hasUnexpiredLegacyRecord)
        {
            throw new ConflictException(
                "The idempotency key is reserved by a legacy replay record whose registration ownership cannot be verified. Retry with a new key.",
                ErrorCodes.IDEMPOTENCY_CONFLICT);
        }

        return null;
    }

    public async Task SaveAsync(IdempotencyRecord record, CancellationToken ct)
    {
        if (record.AgentRegistrationId is null)
            throw new ArgumentException("New idempotency records require registration scope.", nameof(record));

        record.ExpiresAtUtc = await ResolveExpirationUtcAsync(record.CreatedAtUtc, ct);

        var existing = _dbContext.IdempotencyRecords.Local
            .SingleOrDefault(item => HasSameScope(item, record));

        existing ??= await _dbContext.IdempotencyRecords
            .SingleOrDefaultAsync(item =>
                item.AgentRegistrationId == record.AgentRegistrationId &&
                item.Endpoint == record.Endpoint &&
                item.IdempotencyKey == record.IdempotencyKey,
                ct);

        if (existing is null)
        {
            await _dbContext.IdempotencyRecords.AddAsync(record, ct);
            return;
        }

        if (existing.ExpiresAtUtc > record.CreatedAtUtc)
        {
            throw new ConflictException(
                "The scoped idempotency key was recorded by another request. Retry with a new key if the original response is unavailable.",
                ErrorCodes.IDEMPOTENCY_CONFLICT);
        }

        existing.RequestBodyHash = record.RequestBodyHash;
        existing.ResponseStatusCode = record.ResponseStatusCode;
        existing.ResponseBody = record.ResponseBody;
        existing.CreatedAtUtc = record.CreatedAtUtc;
        existing.ExpiresAtUtc = record.ExpiresAtUtc;
    }

    private async Task<DateTime> ResolveExpirationUtcAsync(
        DateTime createdAtUtc,
        CancellationToken ct)
    {
        var configuredDays = await _dbContext.SystemConfigurations
            .AsNoTracking()
            .Select(configuration => configuration.RetentionDaysIdempotencyRecords)
            .SingleOrDefaultAsync(ct);
        var maximumSafeDays = (DateTime.MaxValue - createdAtUtc).TotalDays;
        var retentionDays = configuredDays > 0 && configuredDays <= maximumSafeDays
            ? configuredDays
            : DefaultRetentionDays;

        return createdAtUtc.AddDays(retentionDays);
    }

    private static bool HasSameScope(
        IdempotencyRecord first,
        IdempotencyRecord second) =>
        first.AgentRegistrationId == second.AgentRegistrationId &&
        string.Equals(first.Endpoint, second.Endpoint, StringComparison.Ordinal) &&
        string.Equals(first.IdempotencyKey, second.IdempotencyKey, StringComparison.Ordinal);

    private async Task<IIdempotencyScopeLease> AcquireSqlServerScopeAsync(
        string resourceName,
        CancellationToken ct)
    {
        if (_dbContext.Database.CurrentTransaction is not null)
        {
            throw new InvalidOperationException(
                "The idempotency scope must own the database transaction that protects its application lock.");
        }

        var transaction = await _dbContext.Database.BeginTransactionAsync(
            IsolationLevel.ReadCommitted,
            ct);

        try
        {
            await using var command = _dbContext.Database.GetDbConnection().CreateCommand();
            command.Transaction = transaction.GetDbTransaction();
            command.CommandTimeout = ApplicationLockCommandTimeoutSeconds;
            command.CommandText =
                "DECLARE @result int; " +
                "EXEC @result = sys.sp_getapplock " +
                "@Resource = @resource, " +
                "@LockMode = 'Exclusive', " +
                "@LockOwner = 'Transaction', " +
                "@LockTimeout = @timeout; " +
                "SELECT @result;";

            var resourceParameter = command.CreateParameter();
            resourceParameter.ParameterName = "@resource";
            resourceParameter.DbType = DbType.String;
            resourceParameter.Size = 255;
            resourceParameter.Value = resourceName;
            command.Parameters.Add(resourceParameter);

            var timeoutParameter = command.CreateParameter();
            timeoutParameter.ParameterName = "@timeout";
            timeoutParameter.DbType = DbType.Int32;
            timeoutParameter.Value = ApplicationLockTimeoutMilliseconds;
            command.Parameters.Add(timeoutParameter);

            var resultValue = await command.ExecuteScalarAsync(ct);
            var result = Convert.ToInt32(resultValue, CultureInfo.InvariantCulture);
            if (result < 0)
            {
                if (result == -2)
                    ct.ThrowIfCancellationRequested();

                throw new ConflictException(
                    "The idempotency key is already being processed and could not be serialized within the bounded wait. Retry the same request.",
                    ErrorCodes.IDEMPOTENCY_CONFLICT);
            }

            return new SqlServerIdempotencyScopeLease(transaction);
        }
        catch
        {
            try
            {
                await transaction.RollbackAsync(CancellationToken.None);
            }
            catch (InvalidOperationException)
            {
                // The transaction may already have completed while cancellation was observed.
            }

            await transaction.DisposeAsync();
            throw;
        }
    }

    private static string CreateOpaqueResourceName(
        Guid agentRegistrationId,
        string endpoint,
        string key)
    {
        var scope = string.Create(
            CultureInfo.InvariantCulture,
            $"{agentRegistrationId:D}\n{endpoint}\n{key}");
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(scope));
        return $"a365gw:idempotency:v1:{Convert.ToHexString(digest)}";
    }

    private static InMemoryLockEntry AddInMemoryLockReference(string resourceName)
    {
        lock (InMemoryScopeLocksGate)
        {
            if (!InMemoryScopeLocks.TryGetValue(resourceName, out var entry))
            {
                entry = new InMemoryLockEntry();
                InMemoryScopeLocks.Add(resourceName, entry);
            }

            entry.ReferenceCount++;
            return entry;
        }
    }

    private static void RemoveInMemoryLockReference(
        string resourceName,
        InMemoryLockEntry entry)
    {
        lock (InMemoryScopeLocksGate)
        {
            entry.ReferenceCount--;
            if (entry.ReferenceCount != 0)
                return;

            InMemoryScopeLocks.Remove(resourceName);
            entry.Semaphore.Dispose();
        }
    }

    private sealed class SqlServerIdempotencyScopeLease : IIdempotencyScopeLease
    {
        private readonly IDbContextTransaction _transaction;
        private bool _completed;
        private bool _disposed;

        public SqlServerIdempotencyScopeLease(IDbContextTransaction transaction)
        {
            _transaction = transaction;
        }

        public async Task CompleteAsync(CancellationToken ct)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_completed)
                return;

            await _transaction.CommitAsync(ct);
            _completed = true;
        }

        public async ValueTask DisposeAsync()
        {
            if (_disposed)
                return;

            _disposed = true;
            try
            {
                if (!_completed)
                {
                    try
                    {
                        await _transaction.RollbackAsync(CancellationToken.None);
                    }
                    catch (InvalidOperationException)
                    {
                        // A failed/cancelled commit may already have completed the transaction.
                    }
                }
            }
            finally
            {
                await _transaction.DisposeAsync();
            }
        }
    }

    private sealed class InMemoryIdempotencyScopeLease : IIdempotencyScopeLease
    {
        private readonly string _resourceName;
        private readonly InMemoryLockEntry _entry;
        private bool _disposed;

        public InMemoryIdempotencyScopeLease(
            string resourceName,
            InMemoryLockEntry entry)
        {
            _resourceName = resourceName;
            _entry = entry;
        }

        public Task CompleteAsync(CancellationToken ct)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            ct.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync()
        {
            if (_disposed)
                return ValueTask.CompletedTask;

            _disposed = true;
            _entry.Semaphore.Release();
            RemoveInMemoryLockReference(_resourceName, _entry);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class InMemoryLockEntry
    {
        public SemaphoreSlim Semaphore { get; } = new(1, 1);
        public int ReferenceCount { get; set; }
    }
}
