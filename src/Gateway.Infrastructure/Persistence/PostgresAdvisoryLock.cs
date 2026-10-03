using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Microsoft.EntityFrameworkCore;
using Npgsql;

namespace Gateway.Infrastructure.Persistence;

internal static class PostgresAdvisoryLock
{
    private const string NpgsqlProviderName = "Npgsql.EntityFrameworkCore.PostgreSQL";

    public static bool IsNpgsql(DbContext dbContext) =>
        string.Equals(dbContext.Database.ProviderName, NpgsqlProviderName, StringComparison.Ordinal);

    public static async Task<NpgsqlConnection> AcquireSessionLockAsync(
        DbContext dbContext,
        string resourceName,
        CancellationToken ct)
    {
        var connectionString = dbContext.Database.GetConnectionString();
        if (string.IsNullOrWhiteSpace(connectionString))
            throw new InvalidOperationException("The Gateway database connection string is unavailable.");

        var connection = new NpgsqlConnection(connectionString);
        await connection.OpenAsync(ct);
        try
        {
            var (k1, k2) = ToKeyPair(resourceName);
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT pg_advisory_lock(@k1, @k2);";
            command.Parameters.AddWithValue("k1", k1);
            command.Parameters.AddWithValue("k2", k2);
            await command.ExecuteScalarAsync(ct);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    public static async Task ReleaseSessionLockAsync(
        NpgsqlConnection connection,
        string resourceName,
        CancellationToken ct)
    {
        var (k1, k2) = ToKeyPair(resourceName);
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT pg_advisory_unlock(@k1, @k2);";
        command.Parameters.AddWithValue("k1", k1);
        command.Parameters.AddWithValue("k2", k2);
        await command.ExecuteScalarAsync(ct);
    }

    public static (int K1, int K2) ToKeyPair(string resourceName)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(resourceName));
        return (
            BitConverter.ToInt32(hash, 0),
            BitConverter.ToInt32(hash, 4));
    }
}
