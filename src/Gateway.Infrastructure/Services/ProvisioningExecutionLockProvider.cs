using System.Collections.Concurrent;
using System.Data;
using System.Globalization;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Npgsql;

namespace Gateway.Infrastructure.Services;

internal sealed class ProvisioningExecutionLockProvider : IProvisioningExecutionLockProvider
{
    private const string InMemoryProviderName = "Microsoft.EntityFrameworkCore.InMemory";
    private static readonly ConcurrentDictionary<Guid, SemaphoreSlim> InMemoryLocks = new();
    private readonly GatewayDbContext _dbContext;

    public ProvisioningExecutionLockProvider(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<IProvisioningExecutionLease> AcquireAsync(
        Guid jobId,
        CancellationToken ct)
    {
        if (jobId == Guid.Empty)
            throw new ArgumentException("A provisioning job ID is required.", nameof(jobId));

        var providerName = _dbContext.Database.ProviderName;

        if (PostgresAdvisoryLock.IsNpgsql(_dbContext))
            return await AcquirePostgresLeaseAsync(jobId, ct);

        if (string.Equals(providerName, InMemoryProviderName, StringComparison.Ordinal))
        {
            var semaphore = InMemoryLocks.GetOrAdd(jobId, static _ => new SemaphoreSlim(1, 1));
            await semaphore.WaitAsync(ct);
            return new InMemoryProvisioningExecutionLease(semaphore);
        }

        throw new NotSupportedException(
            $"Provisioning execution locking is not supported by the configured EF provider '{providerName ?? "unknown"}'.");
    }

    private async Task<IProvisioningExecutionLease> AcquirePostgresLeaseAsync(
        Guid jobId,
        CancellationToken ct)
    {
        var resource = $"a365gw:provisioning:job:{jobId:D}";
        var connection = await PostgresAdvisoryLock.AcquireSessionLockAsync(_dbContext, resource, ct);
        return new PostgresProvisioningExecutionLease(connection, resource);
    }

    private sealed class InMemoryProvisioningExecutionLease : IProvisioningExecutionLease
    {
        private readonly SemaphoreSlim _semaphore;
        private bool _disposed;

        public InMemoryProvisioningExecutionLease(SemaphoreSlim semaphore)
        {
            _semaphore = semaphore;
        }

        public ValueTask DisposeAsync()
        {
            if (_disposed)
                return ValueTask.CompletedTask;

            _disposed = true;
            _semaphore.Release();
            return ValueTask.CompletedTask;
        }
    }

    private sealed class PostgresProvisioningExecutionLease : IProvisioningExecutionLease
    {
        private readonly NpgsqlConnection _connection;
        private readonly string _resource;
        private bool _disposed;

        public PostgresProvisioningExecutionLease(NpgsqlConnection connection, string resource)
        {
            _connection = connection;
            _resource = resource;
        }

        public async ValueTask DisposeAsync()
        {
            if (_disposed)
                return;

            _disposed = true;
            try
            {
                await PostgresAdvisoryLock.ReleaseSessionLockAsync(
                    _connection,
                    _resource,
                    CancellationToken.None);
            }
            catch (NpgsqlException)
            {
                // Closing the session releases the advisory lock.
            }
            finally
            {
                await _connection.DisposeAsync();
            }
        }
    }
}
