using System.Collections.Concurrent;
using System.Data;
using System.Globalization;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Persistence;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Services;

internal sealed class ProvisioningExecutionLockProvider : IProvisioningExecutionLockProvider
{
    private const int ApplicationLockTimeoutMilliseconds = 30_000;
    private const int ApplicationLockCommandTimeoutSeconds = 35;
    private const string SqlServerProviderName = "Microsoft.EntityFrameworkCore.SqlServer";
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
        if (string.Equals(providerName, SqlServerProviderName, StringComparison.Ordinal))
            return await AcquireSqlServerLeaseAsync(jobId, ct);

        if (string.Equals(providerName, InMemoryProviderName, StringComparison.Ordinal))
        {
            var semaphore = InMemoryLocks.GetOrAdd(jobId, static _ => new SemaphoreSlim(1, 1));
            await semaphore.WaitAsync(ct);
            return new InMemoryProvisioningExecutionLease(semaphore);
        }

        throw new NotSupportedException(
            $"Provisioning execution locking is not supported by the configured EF provider '{providerName ?? "unknown"}'.");
    }

    private async Task<IProvisioningExecutionLease> AcquireSqlServerLeaseAsync(
        Guid jobId,
        CancellationToken ct)
    {
        var connectionString = _dbContext.Database.GetConnectionString();
        if (string.IsNullOrWhiteSpace(connectionString))
            throw new InvalidOperationException("The Gateway database connection string is unavailable.");

        var connection = new SqlConnection(connectionString);
        try
        {
            await connection.OpenAsync(ct);
            await using var command = connection.CreateCommand();
            command.CommandTimeout = ApplicationLockCommandTimeoutSeconds;
            command.CommandText =
                "DECLARE @result int; " +
                "EXEC @result = sys.sp_getapplock " +
                "@Resource = @resource, " +
                "@LockMode = 'Exclusive', " +
                "@LockOwner = 'Session', " +
                "@LockTimeout = @timeout; " +
                "SELECT @result;";

            command.Parameters.Add(new SqlParameter("@resource", SqlDbType.NVarChar, 255)
            {
                Value = $"a365gw:provisioning:job:{jobId:D}"
            });
            command.Parameters.Add(new SqlParameter("@timeout", SqlDbType.Int)
            {
                Value = ApplicationLockTimeoutMilliseconds
            });

            var resultValue = await command.ExecuteScalarAsync(ct);
            var result = Convert.ToInt32(resultValue, CultureInfo.InvariantCulture);
            if (result < 0)
            {
                if (result == -2)
                    ct.ThrowIfCancellationRequested();

                throw new TimeoutException(
                    "The provisioning job is already being processed and could not be serialized within the bounded wait.");
            }

            return new SqlServerProvisioningExecutionLease(connection, jobId);
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    private sealed class SqlServerProvisioningExecutionLease : IProvisioningExecutionLease
    {
        private readonly SqlConnection _connection;
        private readonly Guid _jobId;
        private bool _disposed;

        public SqlServerProvisioningExecutionLease(SqlConnection connection, Guid jobId)
        {
            _connection = connection;
            _jobId = jobId;
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
                command.Parameters.Add(new SqlParameter("@resource", SqlDbType.NVarChar, 255)
                {
                    Value = $"a365gw:provisioning:job:{_jobId:D}"
                });

                await command.ExecuteScalarAsync(CancellationToken.None);
            }
            catch (SqlException)
            {
                // Closing the dedicated session releases the lock even when an
                // explicit release is interrupted by a transient SQL failure.
            }
            finally
            {
                await _connection.DisposeAsync();
            }
        }
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
}
