using System.Data;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Infrastructure.Persistence;

public interface IDatabaseBootstrapAttestationService
{
    Task<bool> AttestAsync(CancellationToken cancellationToken = default);
}

internal interface IDatabaseBootstrapAttestationProbe
{
    Task<bool> AttestAsync(
        DatabaseAttestationOptions options,
        CancellationToken cancellationToken);
}

internal sealed class DatabaseBootstrapAttestationService(
    IOptions<DatabaseAttestationOptions> options,
    IDatabaseBootstrapAttestationProbe probe,
    IMemoryCache cache,
    ILogger<DatabaseBootstrapAttestationService> logger)
    : IDatabaseBootstrapAttestationService
{
    private const string CacheKey = "database-bootstrap-attestation-v1";
    private static readonly SemaphoreSlim AttestationGate = new(1, 1);

    public async Task<bool> AttestAsync(CancellationToken cancellationToken = default)
    {
        if (!options.Value.Enabled)
            return false;
        if (cache.TryGetValue(CacheKey, out bool cached))
            return cached;

        await AttestationGate.WaitAsync(cancellationToken);
        try
        {
            if (cache.TryGetValue(CacheKey, out cached))
                return cached;

            bool attested;
            try
            {
                attested = await probe.AttestAsync(options.Value, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch
            {
                logger.LogWarning("Database bootstrap attestation was unavailable.");
                attested = false;
            }

            // The anonymous surface is deliberately rate-bounded while keeping
            // successful evidence fresh enough for standalone bootstrap Verify.
            cache.Set(CacheKey, attested, TimeSpan.FromSeconds(5));
            return attested;
        }
        finally
        {
            AttestationGate.Release();
        }
    }
}

internal sealed class DatabaseBootstrapAttestationProbe(GatewayDbContext dbContext)
    : IDatabaseBootstrapAttestationProbe
{
    private const string MarkerName = "A365GatewayBootstrapInitializationIntent";
    private const string ExpectedCollation = "SQL_Latin1_General_CP1_CI_AS";
    private const string ExpectedConnectPermission = "G|0|0|0|CONNECT|dbo";
    private const string ExpectedApiDirectPermission = "G|0|0|0|VIEW DEFINITION|dbo";

    public async Task<bool> AttestAsync(
        DatabaseAttestationOptions options,
        CancellationToken cancellationToken)
    {
        var providerConnection = dbContext.Database.GetDbConnection();
        if (providerConnection is not SqlConnection connection)
            return false;

        var closeWhenComplete = connection.State != ConnectionState.Open;
        if (closeWhenComplete)
            await dbContext.Database.OpenConnectionAsync(cancellationToken);
        try
        {
            AssertConnectionTarget(connection, options);
            var identity = await ReadDatabaseIdentityAsync(connection, cancellationToken);
            var expectedMarker = JsonSerializer.Serialize(new DatabaseInitializationIntent(
                1,
                options.DeploymentOwnershipId,
                options.AcceptedSourceFingerprint,
                options.SqlServerFqdn,
                options.DatabaseName,
                identity.DatabaseCollation,
                identity.CatalogCollation,
                identity.DatabaseOwnerSidSha256));
            if (!await HasExactMarkerAsync(connection, expectedMarker, cancellationToken))
                return false;

            var schemaFingerprint = await DatabaseSchemaFingerprintReader.ReadFingerprintAsync(
                connection,
                cancellationToken);
            if (!schemaFingerprint.Equals(options.ExpectedSchemaFingerprint, StringComparison.Ordinal))
                return false;

            return await HasExactRuntimeAuthorityAsync(connection, options, cancellationToken);
        }
        finally
        {
            if (closeWhenComplete)
                await dbContext.Database.CloseConnectionAsync();
        }
    }

    private static void AssertConnectionTarget(
        SqlConnection connection,
        DatabaseAttestationOptions options)
    {
        var dataSource = connection.DataSource;
        if (dataSource.StartsWith("tcp:", StringComparison.OrdinalIgnoreCase))
            dataSource = dataSource[4..];
        var comma = dataSource.IndexOf(',');
        if (comma >= 0)
            dataSource = dataSource[..comma];
        if (!dataSource.Equals(options.SqlServerFqdn, StringComparison.OrdinalIgnoreCase) ||
            !connection.Database.Equals(options.DatabaseName, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Database attestation reached an unexpected target.");
        }
    }

    private static async Task<DatabaseIdentity> ReadDatabaseIdentityAsync(
        SqlConnection connection,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandTimeout = 30;
        command.CommandText = """
            SELECT collation_name, catalog_collation_type_desc, owner_sid
            FROM sys.databases
            WHERE name = DB_NAME();
            """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken) ||
            reader.IsDBNull(0) || reader.IsDBNull(1) || reader.IsDBNull(2))
        {
            throw new InvalidOperationException("Azure SQL returned no database identity attestation.");
        }
        var result = new DatabaseIdentity(
            reader.GetString(0),
            reader.GetString(1),
            $"sha256:{Convert.ToHexString(SHA256.HashData(reader.GetFieldValue<byte[]>(2))).ToLowerInvariant()}");
        if (await reader.ReadAsync(cancellationToken) ||
            !result.DatabaseCollation.Equals(ExpectedCollation, StringComparison.Ordinal) ||
            !result.CatalogCollation.Equals(ExpectedCollation, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Azure SQL database identity attestation was ambiguous or mismatched.");
        }
        return result;
    }

    private static async Task<bool> HasExactMarkerAsync(
        SqlConnection connection,
        string expectedMarker,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandTimeout = 30;
        command.CommandText = """
            SELECT name, CONVERT(nvarchar(max), value)
            FROM sys.extended_properties
            WHERE class = 0 AND major_id = 0 AND minor_id = 0
              AND name = @markerName
            ORDER BY name;
            """;
        command.Parameters.AddWithValue("@markerName", MarkerName);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
            return false;
        var exact = reader.GetString(0).Equals(MarkerName, StringComparison.Ordinal) &&
            reader.GetString(1).Equals(expectedMarker, StringComparison.Ordinal);
        return exact && !await reader.ReadAsync(cancellationToken);
    }

    private static async Task<bool> HasExactRuntimeAuthorityAsync(
        SqlConnection connection,
        DatabaseAttestationOptions options,
        CancellationToken cancellationToken)
    {
        var expected = new Dictionary<string, ExpectedPrincipal>(StringComparer.Ordinal)
        {
            [options.ApiPrincipalName] = new(
                Guid.ParseExact(options.ApiPrincipalClientId, "D"),
                [ExpectedConnectPermission, ExpectedApiDirectPermission]),
            [options.WorkerPrincipalName] = new(
                Guid.ParseExact(options.WorkerPrincipalClientId, "D"),
                [ExpectedConnectPermission])
        };
        var observed = new Dictionary<string, ObservedPrincipal>(StringComparer.Ordinal);
        await using (var command = connection.CreateCommand())
        {
            command.CommandTimeout = 30;
            command.CommandText = """
                SELECT principals.principal_id, principals.name, principals.type,
                       TRY_CONVERT(uniqueidentifier, principals.sid),
                       (SELECT COUNT(*) FROM sys.schemas AS schemas
                        WHERE schemas.principal_id = principals.principal_id),
                       (SELECT COUNT(*) FROM sys.database_principals AS owned
                        WHERE owned.owning_principal_id = principals.principal_id)
                FROM sys.database_principals AS principals
                WHERE principals.principal_id > 4
                  AND principals.is_fixed_role = 0
                ORDER BY principals.principal_id;
                """;
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                var name = reader.GetString(1);
                if (!observed.TryAdd(
                    name,
                    new ObservedPrincipal(
                        reader.GetInt32(0),
                        reader.IsDBNull(3) ? null : reader.GetGuid(3),
                        reader.GetString(2),
                        reader.GetInt32(4),
                        reader.GetInt32(5),
                        [],
                        [])))
                {
                    return false;
                }
            }
        }
        if (observed.Count != expected.Count ||
            observed.Keys.Except(expected.Keys, StringComparer.Ordinal).Any())
        {
            return false;
        }

        var builtInDboOwnerMembershipCount = 0;
        await using (var command = connection.CreateCommand())
        {
            command.CommandTimeout = 30;
            command.CommandText = """
                SELECT roles.name, members.name, roles.is_fixed_role,
                       members.principal_id, DATABASE_PRINCIPAL_ID(N'dbo')
                FROM sys.database_role_members AS memberships
                INNER JOIN sys.database_principals AS roles
                  ON roles.principal_id = memberships.role_principal_id
                INNER JOIN sys.database_principals AS members
                  ON members.principal_id = memberships.member_principal_id
                ORDER BY members.name, roles.name;
                """;
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                if (reader.GetString(0).Equals("db_owner", StringComparison.Ordinal) &&
                    reader.GetString(1).Equals("dbo", StringComparison.Ordinal) &&
                    reader.GetBoolean(2) &&
                    reader.GetInt32(3) == reader.GetInt32(4))
                {
                    builtInDboOwnerMembershipCount++;
                    continue;
                }
                if (!observed.TryGetValue(reader.GetString(1), out var principal))
                    return false;
                principal.Roles.Add(reader.GetString(0));
            }
        }
        if (builtInDboOwnerMembershipCount != 1)
            return false;

        await using (var command = connection.CreateCommand())
        {
            command.CommandTimeout = 30;
            command.CommandText = """
                SELECT grantees.name, permissions.state, CAST(permissions.class AS int),
                       permissions.major_id, permissions.minor_id,
                       permissions.permission_name, grantors.name
                FROM sys.database_permissions AS permissions
                INNER JOIN sys.database_principals AS grantees
                  ON grantees.principal_id = permissions.grantee_principal_id
                INNER JOIN sys.database_principals AS grantors
                  ON grantors.principal_id = permissions.grantor_principal_id
                WHERE NOT
                (
                    permissions.class = 0
                    AND permissions.major_id = 0
                    AND permissions.minor_id = 0
                    AND permissions.permission_name = N'CONNECT'
                    AND permissions.state IN (N'G', N'W')
                    AND grantees.name IN (N'public', N'guest')
                )
                AND NOT
                (
                    permissions.class = 0
                    AND permissions.major_id = 0
                    AND permissions.minor_id = 0
                    AND permissions.permission_name = N'CONNECT'
                    AND permissions.state = N'G'
                    AND grantees.name = N'dbo'
                    AND grantors.name = N'dbo'
                )
                AND NOT
                (
                    permissions.class = 1
                    AND permissions.minor_id = 0
                    AND permissions.permission_name = N'SELECT'
                    AND permissions.state = N'G'
                    AND grantees.name = N'public'
                    AND permissions.major_id < 0
                )
                AND NOT
                (
                    permissions.class = 1
                    AND permissions.minor_id = 0
                    AND permissions.permission_name = N'SELECT'
                    AND permissions.state = N'G'
                    AND grantees.name = N'public'
                    AND permissions.major_id = OBJECT_ID(N'sys.database_firewall_rules')
                    AND grantors.name = N'sys'
                    AND EXISTS
                    (
                        SELECT 1
                        FROM sys.all_objects AS allowed_shipped_objects
                        WHERE allowed_shipped_objects.object_id = permissions.major_id
                          AND allowed_shipped_objects.is_ms_shipped = 1
                          AND allowed_shipped_objects.schema_id = SCHEMA_ID(N'sys')
                          AND allowed_shipped_objects.type = N'V'
                    )
                )
                ORDER BY grantees.name, permissions.class, permissions.major_id,
                         permissions.minor_id, permissions.permission_name;
                """;
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                if (!observed.TryGetValue(reader.GetString(0), out var principal))
                    return false;
                principal.DirectPermissions.Add(
                    $"{reader.GetString(1)}|{reader.GetInt32(2)}|{reader.GetInt32(3)}|" +
                    $"{reader.GetInt32(4)}|{reader.GetString(5)}|{reader.GetString(6)}");
            }
        }

        foreach (var (name, expectedPrincipal) in expected)
        {
            var principal = observed[name];
            if (principal.ClientId != expectedPrincipal.ClientId ||
                !principal.Type.Equals("E", StringComparison.Ordinal) ||
                principal.OwnedSchemaCount != 0 || principal.OwnedPrincipalCount != 0 ||
                !principal.Roles.Order(StringComparer.Ordinal).SequenceEqual(
                    new[] { "db_datareader", "db_datawriter" },
                    StringComparer.Ordinal) ||
                !principal.DirectPermissions.Order(StringComparer.Ordinal).SequenceEqual(
                    expectedPrincipal.DirectPermissions.Order(StringComparer.Ordinal),
                    StringComparer.Ordinal))
            {
                return false;
            }
        }

        await using var current = connection.CreateCommand();
        current.CommandTimeout = 30;
        current.CommandText = """
            SELECT principals.name, TRY_CONVERT(uniqueidentifier, principals.sid)
            FROM sys.database_principals AS principals
            WHERE principals.name = USER_NAME();
            """;
        await using var currentReader = await current.ExecuteReaderAsync(cancellationToken);
        if (!await currentReader.ReadAsync(cancellationToken) || currentReader.IsDBNull(1))
            return false;
        var currentMatches = currentReader.GetString(0).Equals(options.ApiPrincipalName, StringComparison.Ordinal) &&
            currentReader.GetGuid(1) == Guid.ParseExact(options.ApiPrincipalClientId, "D");
        return currentMatches && !await currentReader.ReadAsync(cancellationToken);
    }

    private sealed record DatabaseIdentity(
        string DatabaseCollation,
        string CatalogCollation,
        string DatabaseOwnerSidSha256);

    private sealed record DatabaseInitializationIntent(
        int SchemaVersion,
        string DeploymentOwnershipId,
        string AcceptedSourceFingerprint,
        string Server,
        string Database,
        string DatabaseCollation,
        string CatalogCollation,
        string DatabaseOwnerSidSha256);

    private sealed record ExpectedPrincipal(
        Guid ClientId,
        IReadOnlyCollection<string> DirectPermissions);

    private sealed record ObservedPrincipal(
        int PrincipalId,
        Guid? ClientId,
        string Type,
        int OwnedSchemaCount,
        int OwnedPrincipalCount,
        List<string> Roles,
        List<string> DirectPermissions);
}
