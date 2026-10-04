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
using Npgsql;

namespace Gateway.Infrastructure.Services;

internal sealed class IdempotencyService : IIdempotencyService
{
    private const int DefaultRetentionDays = 7;
    private const string InMemoryProviderName = "Microsoft.EntityFrameworkCore.InMemory";
    private static readonly object InMemoryScopeLocksGate = new();
    private static readonly Dictionary<string, InMemoryLockEntry> InMemoryScopeLocks =
        new(StringComparer.Ordinal);
    private readonly GatewayDbContext _dbContext;

    public IdempotencyService(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<IIdempotencyScopeLease> AcquireDataPlaneScopeAsync(
        Guid agentRegistrationId, string endpoint, string key, CancellationToken ct)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(endpoint);
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        if (_dbContext.Database.ProviderName == InMemoryProviderName)
            return await AcquireScopeAsync(agentRegistrationId, endpoint, key, ct);
        if (_dbContext.Database.CurrentTransaction is not null)
            throw new InvalidOperationException("Data-plane serialization requires no existing transaction.");

        if (PostgresAdvisoryLock.IsNpgsql(_dbContext))
        {
            var resource = CreateOpaqueResourceName(agentRegistrationId, endpoint, key);
            var pg = await PostgresAdvisoryLock.AcquireSessionLockAsync(_dbContext, resource, ct);
            return new PostgresDataPlaneScopeLease(_dbContext, pg, resource);
        }

        throw new NotSupportedException("Data-plane serialization requires PostgreSQL.");
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


        if (PostgresAdvisoryLock.IsNpgsql(_dbContext))
        {
            var connection = await PostgresAdvisoryLock.AcquireSessionLockAsync(
                _dbContext,
                resourceName,
                ct);
            return new PostgresIdempotencyScopeLease(connection, resourceName);
        }

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

        return null;
    }

    public async Task<IIdempotencyScopeLease> AcquireScopeInExistingTransactionAsync(
        Guid agentRegistrationId, string endpoint, string key, CancellationToken ct)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(endpoint);
        ArgumentException.ThrowIfNullOrWhiteSpace(key);
        if (_dbContext.Database.ProviderName == InMemoryProviderName)
            return await AcquireScopeAsync(agentRegistrationId, endpoint, key, ct);
        if (!PostgresAdvisoryLock.IsNpgsql(_dbContext) || _dbContext.Database.CurrentTransaction is null)
            throw new InvalidOperationException("A protection mutation transaction must already own this feature update.");
        var (k1, k2) = PostgresAdvisoryLock.ToKeyPair(CreateOpaqueResourceName(agentRegistrationId, endpoint, key));
        await _dbContext.Database.ExecuteSqlInterpolatedAsync($"SELECT pg_advisory_xact_lock({k1}, {k2})", ct);
        return new ExistingTransactionLease();
    }

    private sealed class ExistingTransactionLease : IIdempotencyScopeLease
    {
        public Task CompleteAsync(CancellationToken ct) { ct.ThrowIfCancellationRequested(); return Task.CompletedTask; }
        public Task BeginCommitAsync(CancellationToken ct) => CompleteAsync(ct);
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    public async Task SaveAsync(IdempotencyRecord record, CancellationToken ct)
    {
        if (record.AgentRegistrationId == Guid.Empty)
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

        public Task BeginCommitAsync(CancellationToken ct) => CompleteAsync(ct);

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

    private sealed class PostgresIdempotencyScopeLease(
        NpgsqlConnection connection,
        string resourceName) : IIdempotencyScopeLease
    {
        private bool _disposed;

        public Task BeginCommitAsync(CancellationToken ct)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            ct.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }

        public Task CompleteAsync(CancellationToken ct)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            ct.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }

        public async ValueTask DisposeAsync()
        {
            if (_disposed)
                return;
            _disposed = true;
            try
            {
                await PostgresAdvisoryLock.ReleaseSessionLockAsync(
                    connection,
                    resourceName,
                    CancellationToken.None);
            }
            catch (NpgsqlException)
            {
            }
            finally
            {
                await connection.DisposeAsync();
            }
        }
    }

    private sealed class PostgresDataPlaneScopeLease(
        GatewayDbContext dbContext,
        NpgsqlConnection lockConnection,
        string resourceName) : IIdempotencyScopeLease
    {
        private IDbContextTransaction? _transaction;
        private bool _completed;
        private bool _disposed;

        public async Task BeginCommitAsync(CancellationToken ct)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_transaction is null)
                // PostgreSQL row locks cannot protect missing policy rows. Serializable
                // also protects predicate reads while the evaluation/receipt commits.
                _transaction = await dbContext.Database.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        }

        public async Task CompleteAsync(CancellationToken ct)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_completed)
                return;
            if (_transaction is null)
                throw new InvalidOperationException("The data-plane commit phase has not started.");
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
                if (_transaction is not null)
                {
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
                            }
                        }
                    }
                    finally
                    {
                        await _transaction.DisposeAsync();
                    }
                }
            }
            finally
            {
                try
                {
                    await PostgresAdvisoryLock.ReleaseSessionLockAsync(
                        lockConnection,
                        resourceName,
                        CancellationToken.None);
                }
                catch (NpgsqlException)
                {
                }

                await lockConnection.DisposeAsync();
            }
        }
    }
}
