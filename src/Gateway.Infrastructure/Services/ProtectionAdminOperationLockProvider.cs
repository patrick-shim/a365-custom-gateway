using System.Collections.Concurrent;
using System.Data;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Persistence;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;

namespace Gateway.Infrastructure.Services;

public interface IProtectionAdminOperationLockProvider
{
    Task<IProtectionAdminIdempotencyLease> AcquireIdempotencyAsync(
        EntraTenantId tenantId,
        ProtectionIdempotencyKey idempotencyKey,
        CancellationToken ct);

    Task<IAsyncDisposable> AcquireExecutionAsync(
        Guid operationId,
        CancellationToken ct);
}

public interface IProtectionAdminIdempotencyLease : IAsyncDisposable
{
    Task CompleteAsync(CancellationToken ct);
}

internal sealed class ProtectionAdminOperationLockProvider
    : IProtectionAdminOperationLockProvider
{
    private const int ApplicationLockTimeoutMilliseconds = 30_000;
    private const int ApplicationLockCommandTimeoutSeconds = 35;
    private const string SqlServerProviderName = "Microsoft.EntityFrameworkCore.SqlServer";
    private const string InMemoryProviderName = "Microsoft.EntityFrameworkCore.InMemory";
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> InMemoryLocks = new();
    private readonly GatewayDbContext _dbContext;

    public ProtectionAdminOperationLockProvider(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<IProtectionAdminIdempotencyLease> AcquireIdempotencyAsync(
        EntraTenantId tenantId,
        ProtectionIdempotencyKey idempotencyKey,
        CancellationToken ct)
    {
        var resource = CreateOpaqueResourceName(
            "idempotency",
            tenantId.Value,
            idempotencyKey.Value);
        var providerName = _dbContext.Database.ProviderName;
        if (string.Equals(providerName, SqlServerProviderName, StringComparison.Ordinal))
            return await AcquireSqlIdempotencyAsync(resource, ct);
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

    public async Task<IAsyncDisposable> AcquireExecutionAsync(
        Guid operationId,
        CancellationToken ct)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(operationId, Guid.Empty);
        var resource = $"a365gw:protection-admin:operation:{operationId:D}";
        var providerName = _dbContext.Database.ProviderName;
        if (string.Equals(providerName, SqlServerProviderName, StringComparison.Ordinal))
            return await AcquireSqlExecutionAsync(resource, ct);
        if (string.Equals(providerName, InMemoryProviderName, StringComparison.Ordinal))
        {
            var semaphore = InMemoryLocks.GetOrAdd(
                resource,
                static _ => new SemaphoreSlim(1, 1));
            await semaphore.WaitAsync(ct);
            return new InMemoryExecutionLease(semaphore);
        }

        throw UnsupportedProvider(providerName);
    }

    private async Task<IProtectionAdminIdempotencyLease> AcquireSqlIdempotencyAsync(
        string resource,
        CancellationToken ct)
    {
        if (_dbContext.Database.CurrentTransaction is not null)
        {
            throw new InvalidOperationException(
                "The protection idempotency scope must own its database transaction.");
        }

        var transaction = await _dbContext.Database.BeginTransactionAsync(
            IsolationLevel.ReadCommitted,
            ct);
        try
        {
            await AcquireSqlLockAsync(
                _dbContext.Database.GetDbConnection(),
                transaction.GetDbTransaction(),
                resource,
                "Transaction",
                ct);
            return new SqlIdempotencyLease(transaction);
        }
        catch
        {
            await transaction.RollbackAsync(CancellationToken.None);
            await transaction.DisposeAsync();
            throw;
        }
    }

    private async Task<IAsyncDisposable> AcquireSqlExecutionAsync(
        string resource,
        CancellationToken ct)
    {
        var connectionString = _dbContext.Database.GetConnectionString();
        if (string.IsNullOrWhiteSpace(connectionString))
            throw new InvalidOperationException("The Gateway database connection string is unavailable.");

        var connection = new SqlConnection(connectionString);
        try
        {
            await connection.OpenAsync(ct);
            await AcquireSqlLockAsync(connection, null, resource, "Session", ct);
            return new SqlExecutionLease(connection, resource);
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    private static async Task AcquireSqlLockAsync(
        System.Data.Common.DbConnection connection,
        System.Data.Common.DbTransaction? transaction,
        string resource,
        string owner,
        CancellationToken ct)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandTimeout = ApplicationLockCommandTimeoutSeconds;
        command.CommandText =
            "DECLARE @result int; " +
            "EXEC @result = sys.sp_getapplock " +
            "@Resource = @resource, @LockMode = 'Exclusive', " +
            "@LockOwner = @owner, @LockTimeout = @timeout; " +
            "SELECT @result;";
        AddParameter(command, "@resource", DbType.String, 255, resource);
        AddParameter(command, "@owner", DbType.String, 32, owner);
        AddParameter(
            command,
            "@timeout",
            DbType.Int32,
            sizeof(int),
            ApplicationLockTimeoutMilliseconds);

        var result = Convert.ToInt32(
            await command.ExecuteScalarAsync(ct),
            CultureInfo.InvariantCulture);
        if (result < 0)
        {
            if (result == -2)
                ct.ThrowIfCancellationRequested();
            throw new TimeoutException(
                "The protection administration operation could not acquire its bounded SQL lock.");
        }
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
        return $"a365gw:protection-admin:v1:{Convert.ToHexString(digest)}";
    }

    private static void AddParameter(
        System.Data.Common.DbCommand command,
        string name,
        DbType type,
        int size,
        object value)
    {
        var parameter = command.CreateParameter();
        parameter.ParameterName = name;
        parameter.DbType = type;
        parameter.Size = size;
        parameter.Value = value;
        command.Parameters.Add(parameter);
    }

    private static NotSupportedException UnsupportedProvider(string? providerName) =>
        new(
            $"Protection administration locking is not supported by the configured EF provider '{providerName ?? "unknown"}'.");

    private sealed class SqlIdempotencyLease : IProtectionAdminIdempotencyLease
    {
        private readonly IDbContextTransaction _transaction;
        private bool _completed;
        private bool _disposed;

        public SqlIdempotencyLease(IDbContextTransaction transaction)
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
                        // A failed or cancelled commit may already have ended the transaction.
                    }
                }
            }
            finally
            {
                await _transaction.DisposeAsync();
            }
        }
    }

    private sealed class SqlExecutionLease : IAsyncDisposable
    {
        private readonly SqlConnection _connection;
        private readonly string _resource;
        private bool _disposed;

        public SqlExecutionLease(SqlConnection connection, string resource)
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
                await using var command = _connection.CreateCommand();
                command.CommandTimeout = ApplicationLockCommandTimeoutSeconds;
                command.CommandText =
                    "DECLARE @result int; " +
                    "EXEC @result = sys.sp_releaseapplock " +
                    "@Resource = @resource, @LockOwner = 'Session'; " +
                    "SELECT @result;";
                command.Parameters.Add(new SqlParameter(
                    "@resource",
                    SqlDbType.NVarChar,
                    255)
                {
                    Value = _resource,
                });
                await command.ExecuteScalarAsync(CancellationToken.None);
            }
            catch (SqlException)
            {
                // Closing the dedicated SQL session releases the session-owned lock.
            }
            finally
            {
                await _connection.DisposeAsync();
            }
        }
    }

    private sealed class InMemoryIdempotencyLease : IProtectionAdminIdempotencyLease
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

    private sealed class InMemoryExecutionLease : IAsyncDisposable
    {
        private readonly SemaphoreSlim _semaphore;
        private bool _disposed;

        public InMemoryExecutionLease(SemaphoreSlim semaphore)
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
}
