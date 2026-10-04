using System.Collections.Concurrent;
using System.Data;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;
using Npgsql;

namespace Gateway.Infrastructure.Services;

public interface ISystemConfigurationLockProvider
{
    Task<ISystemConfigurationMutationLease> AcquireIdempotencyAsync(
        EntraTenantId tenantId,
        ProtectionIdempotencyKey idempotencyKey,
        CancellationToken ct);


}

public interface ISystemConfigurationMutationLease : IAsyncDisposable
{
    Task CompleteAsync(CancellationToken ct);
}

internal sealed class SystemConfigurationLockProvider
    : ISystemConfigurationLockProvider
{
    private const string InMemoryProviderName = "Microsoft.EntityFrameworkCore.InMemory";
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> InMemoryLocks = new();
    private readonly GatewayDbContext _dbContext;

    public SystemConfigurationLockProvider(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<ISystemConfigurationMutationLease> AcquireIdempotencyAsync(
        EntraTenantId tenantId,
        ProtectionIdempotencyKey idempotencyKey,
        CancellationToken ct)
    {
        var resource = CreateOpaqueResourceName(
            "idempotency",
            tenantId.Value,
            idempotencyKey.Value);
        var providerName = _dbContext.Database.ProviderName;
        if (PostgresAdvisoryLock.IsNpgsql(_dbContext))
            return await AcquirePostgresIdempotencyAsync(resource, ct);
        if (string.Equals(providerName, InMemoryProviderName, StringComparison.Ordinal))
        {
            var semaphore = InMemoryLocks.GetOrAdd(
                resource,
                static _ => new SemaphoreSlim(1, 1));
            await semaphore.WaitAsync(ct);
            return new InMemoryIdempotencyLease(semaphore);
        }

        throw UnsupportedProvider(providerName);
    }

    private async Task<ISystemConfigurationMutationLease> AcquirePostgresIdempotencyAsync(
        string resource,
        CancellationToken ct)
    {
        if (_dbContext.Database.CurrentTransaction is not null)
        {
            throw new InvalidOperationException(
                "The protection idempotency scope must own its database transaction.");
        }

        var connection = await PostgresAdvisoryLock.AcquireSessionLockAsync(
            _dbContext,
            resource,
            ct);
        return new PostgresIdempotencyLease(connection, resource);
    }

    private static string CreateOpaqueResourceName(
        string scope,
        Guid tenantId,
        Guid idempotencyKey)
    {
        var material = string.Create(
            CultureInfo.InvariantCulture,
            $"{scope}\n{tenantId:D}\n{idempotencyKey:D}");
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(material));
        return $"a365gw:system-config:v1:{Convert.ToHexString(digest)}";
    }

    private static NotSupportedException UnsupportedProvider(string? providerName) =>
        new(
            $"Settings mutation locking is not supported by the configured EF provider '{providerName ?? "unknown"}'.");

    private sealed class InMemoryIdempotencyLease : ISystemConfigurationMutationLease
    {
        private readonly SemaphoreSlim _semaphore;
        private bool _disposed;

        public InMemoryIdempotencyLease(SemaphoreSlim semaphore)
        {
            _semaphore = semaphore;
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
            _semaphore.Release();
            return ValueTask.CompletedTask;
        }
    }

    private sealed class PostgresIdempotencyLease : ISystemConfigurationMutationLease
    {
        private readonly NpgsqlConnection _connection;
        private readonly string _resource;
        private bool _disposed;

        public PostgresIdempotencyLease(NpgsqlConnection connection, string resource)
        {
            _connection = connection;
            _resource = resource;
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
                    _connection,
                    _resource,
                    CancellationToken.None);
            }
            catch (NpgsqlException)
            {
            }
            finally
            {
                await _connection.DisposeAsync();
            }
        }
    }

}
