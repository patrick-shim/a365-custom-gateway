using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Azure.Core;
using Azure.Identity;
using Gateway.Infrastructure.Persistence;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

var options = ParseArguments(args);
var server = Required(options, "server");
var database = Required(options, "database");
var phase = Required(options, "phase").ToLowerInvariant();
var repositoryRoot = ResolveRepositoryRoot(ReadOption(options, "repository-root"));
var principalName = ReadOption(options, "principal-name");
var principalClientIdValue = ReadOption(options, "principal-client-id");
var repeat = int.TryParse(ReadOption(options, "repeat") ?? "1", out var parsedRepeat)
    ? parsedRepeat
    : 0;

if (!server.EndsWith(".database.windows.net", StringComparison.OrdinalIgnoreCase) ||
    server.Any(char.IsWhiteSpace))
{
    throw new ArgumentException("--server must be an Azure SQL logical-server FQDN.");
}

if (string.IsNullOrWhiteSpace(database) ||
    database.Equals("master", StringComparison.OrdinalIgnoreCase) ||
    database.IndexOfAny([';', '\r', '\n']) >= 0)
{
    throw new ArgumentException("--database must identify a non-system database.");
}

if (phase is not ("initialize" or "baseline" or "prepare" or "finalize" or "verify" or "principal"))
    throw new ArgumentException("--phase must be initialize, baseline, prepare, finalize, verify, or principal.");

Guid? principalClientId = null;
if (phase == "principal")
{
    if (string.IsNullOrWhiteSpace(principalName) ||
        !Regex.IsMatch(principalName, @"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
    {
        throw new ArgumentException(
            "--principal-name is required for the principal phase and must use only letters, numbers, dots, underscores, or hyphens.");
    }

    if (!Guid.TryParse(principalClientIdValue, out var parsedPrincipalClientId))
        throw new ArgumentException("--principal-client-id must be a valid managed-identity application/client ID.");
    principalClientId = parsedPrincipalClientId;
}

if (repeat is < 1 or > 2)
    throw new ArgumentException("--repeat must be 1 or 2.");

var scripts = phase switch
{
    "prepare" => new[]
    {
        "20260824_agent_identity_workflow_v2.sql",
        "20260825_agent_ingress_credentials.sql",
        "20260825_scoped_idempotency.sql",
        "20260825_ingress_rate_limit_buckets.sql",
        "20260829_purview_policy_profiles.sql"
    },
    "finalize" => new[] { "20260825_scoped_idempotency_finalize.sql" },
    _ => Array.Empty<string>()
};

var scriptDirectory = Path.Combine(repositoryRoot, "infrastructure", "sql");
var scriptEvidence = scripts.Select(name =>
{
    var path = Path.Combine(scriptDirectory, name);
    if (!File.Exists(path))
        throw new FileNotFoundException($"Required migration script was not found: {name}");

    var bytes = File.ReadAllBytes(path);
    return new ScriptEvidence(
        name,
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
        File.ReadAllText(path));
}).ToArray();

TokenCredential credential = string.IsNullOrWhiteSpace(
    Environment.GetEnvironmentVariable("IDENTITY_ENDPOINT"))
    ? new AzureCliCredential()
    : new ManagedIdentityCredential();
var accessToken = await credential.GetTokenAsync(
    new TokenRequestContext(["https://database.windows.net/.default"]),
    CancellationToken.None);

var connectionString = new SqlConnectionStringBuilder
{
    DataSource = $"tcp:{server},1433",
    InitialCatalog = database,
    Encrypt = SqlConnectionEncryptOption.Mandatory,
    TrustServerCertificate = false,
    ConnectTimeout = 30,
    ApplicationName = "A365GatewayDatabaseMigrator"
}.ConnectionString;

await using var connection = new SqlConnection(connectionString)
{
    AccessToken = accessToken.Token
};
await connection.OpenAsync();

RuntimePrincipalEvidence? runtimePrincipalEvidence = null;
if (phase == "initialize")
{
    await EnsureEmptyDatabaseInitializedAsync(connection);
}
if (phase == "principal")
{
    runtimePrincipalEvidence = await EnsureRuntimePrincipalAsync(
        connection,
        principalName!,
        principalClientId!.Value);
}

for (var pass = 1; pass <= repeat; pass++)
{
    foreach (var script in scriptEvidence)
    {
        foreach (var batch in SplitSqlBatches(script.Sql))
        {
            await using var command = connection.CreateCommand();
            command.CommandTimeout = 300;
            command.CommandText = batch;
            await command.ExecuteNonQueryAsync();
        }
        Console.WriteLine($"Applied {script.Name} (pass {pass}/{repeat}).");
    }
}

var verification = await VerifyAsync(connection);
var verificationFailed = phase == "baseline"
    ? verification.WorkflowV2Ready || verification.LegacyGlobalIdempotencyUniqueIndexCount != 1
    : !verification.WorkflowV2Ready ||
      (phase == "finalize" && verification.LegacyGlobalIdempotencyUniqueIndexCount != 0);
if (verificationFailed)
{
    throw new InvalidOperationException("Database schema verification did not reach the required state.");
}

var evidence = new MigrationEvidence(
    DateTimeOffset.UtcNow,
    server,
    database,
    phase,
    repeat,
    scriptEvidence.Select(item => new MigrationScriptEvidence(item.Name, item.Sha256)).ToArray(),
    verification,
    runtimePrincipalEvidence);

var evidenceJson = JsonSerializer.Serialize(
    evidence,
    new JsonSerializerOptions { WriteIndented = true });
var evidencePath = ReadOption(options, "evidence");
if (!string.IsNullOrWhiteSpace(evidencePath))
{
    var absoluteEvidencePath = Path.GetFullPath(evidencePath);
    Directory.CreateDirectory(Path.GetDirectoryName(absoluteEvidencePath)!);
    await File.WriteAllTextAsync(
        absoluteEvidencePath,
        evidenceJson);
    Console.WriteLine($"Wrote non-secret migration evidence to {absoluteEvidencePath}.");
}

if (bool.TryParse(ReadOption(options, "evidence-stdout") ?? "false", out var evidenceStdout) &&
    evidenceStdout)
{
    Console.WriteLine(
        $"EVIDENCE_BASE64={Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(evidenceJson))}");
}

Console.WriteLine(
    $"Schema verification passed (workflow-v2={verification.WorkflowV2Ready}, " +
    $"legacy-global-indexes={verification.LegacyGlobalIdempotencyUniqueIndexCount}).");

if (bool.TryParse(ReadOption(options, "stay-alive") ?? "false", out var stayAlive) && stayAlive)
{
    Console.WriteLine("Migration completed; the diagnostic container will remain alive for evidence collection.");
    await Task.Delay(Timeout.InfiniteTimeSpan);
}

static async Task EnsureEmptyDatabaseInitializedAsync(SqlConnection connection)
{
    await using var tableCountCommand = connection.CreateCommand();
    tableCountCommand.CommandTimeout = 60;
    tableCountCommand.CommandText = """
        SELECT COUNT(*)
        FROM sys.tables
        WHERE is_ms_shipped = 0;
        """;
    var tableCount = Convert.ToInt32(await tableCountCommand.ExecuteScalarAsync());
    if (tableCount > 0)
    {
        Console.WriteLine("Database already contains user tables; skipped initialization and will verify the existing schema.");
        return;
    }

    var options = new DbContextOptionsBuilder<GatewayDbContext>()
        .UseSqlServer(connection)
        .Options;
    await using var context = new GatewayDbContext(options);
    if (!await context.Database.EnsureCreatedAsync())
        throw new InvalidOperationException("The empty Gateway database was not initialized.");
    Console.WriteLine("Initialized the empty Gateway database from the reviewed current EF model.");
}

static async Task<RuntimePrincipalEvidence> EnsureRuntimePrincipalAsync(
    SqlConnection connection,
    string principalName,
    Guid principalClientId)
{
    await using (var lookup = connection.CreateCommand())
    {
        lookup.CommandTimeout = 60;
        lookup.CommandText = """
            SELECT CAST(sid AS uniqueidentifier)
            FROM sys.database_principals
            WHERE name = @principalName;
            """;
        lookup.Parameters.AddWithValue("@principalName", principalName);
        var existing = await lookup.ExecuteScalarAsync();
        if (existing is Guid existingClientId && existingClientId != principalClientId)
        {
            throw new InvalidOperationException(
                $"Database principal {principalName} exists but is bound to a different Microsoft Entra application/client ID.");
        }

        if (existing is null or DBNull)
        {
            var escapedName = principalName.Replace("]", "]]", StringComparison.Ordinal);
            await using var create = connection.CreateCommand();
            create.CommandTimeout = 120;
            create.CommandText = $"""
                DECLARE @clientId uniqueidentifier = '{principalClientId:D}';
                DECLARE @sid nvarchar(34) =
                    CONVERT(varchar(34), CONVERT(varbinary(16), @clientId), 1);
                EXEC(N'CREATE USER [{escapedName}] WITH SID = ' + @sid + N', TYPE = E;');
                """;
            await create.ExecuteNonQueryAsync();
        }
    }

    var escapedPrincipalName = principalName.Replace("]", "]]", StringComparison.Ordinal);
    foreach (var roleName in new[] { "db_datareader", "db_datawriter" })
    {
        await using var membership = connection.CreateCommand();
        membership.CommandTimeout = 60;
        membership.CommandText = """
            SELECT COUNT(*)
            FROM sys.database_role_members AS drm
            INNER JOIN sys.database_principals AS roles
                ON roles.principal_id = drm.role_principal_id
            INNER JOIN sys.database_principals AS members
                ON members.principal_id = drm.member_principal_id
            WHERE roles.name = @roleName
              AND members.name = @principalName;
            """;
        membership.Parameters.AddWithValue("@roleName", roleName);
        membership.Parameters.AddWithValue("@principalName", principalName);
        var membershipCount = Convert.ToInt32(await membership.ExecuteScalarAsync());
        if (membershipCount == 0)
        {
            await using var grant = connection.CreateCommand();
            grant.CommandTimeout = 60;
            grant.CommandText = $"ALTER ROLE [{roleName}] ADD MEMBER [{escapedPrincipalName}];";
            await grant.ExecuteNonQueryAsync();
        }
    }

    return new RuntimePrincipalEvidence(
        principalName,
        principalClientId,
        ["db_datareader", "db_datawriter"]);
}

static async Task<SchemaVerification> VerifyAsync(SqlConnection connection)
{
    const string sql = """
        SELECT
          CAST(CASE WHEN COL_LENGTH(N'dbo.AgentRegistrations', N'BlueprintSelectionMode') IS NOT NULL
                     AND COL_LENGTH(N'dbo.AgentRegistrations', N'AgentIdentityObjectId') IS NOT NULL
                     AND COL_LENGTH(N'dbo.AgentRegistrations', N'BlueprintObjectId') IS NOT NULL
                     AND COL_LENGTH(N'dbo.ProvisioningJobs', N'WorkflowVersion') IS NOT NULL
                     AND OBJECT_ID(N'dbo.AgentIngressCredentials', N'U') IS NOT NULL
                     AND OBJECT_ID(N'dbo.IngressRateLimitBuckets', N'U') IS NOT NULL
                     AND EXISTS
                     (
                         SELECT 1 FROM sys.indexes
                         WHERE object_id = OBJECT_ID(N'dbo.IdempotencyRecords', N'U')
                           AND name = N'IX_IdempotencyRecords_AgentRegistrationId_Endpoint_IdempotencyKey'
                           AND is_unique = 1
                           AND has_filter = 1
                     )
                    THEN 1 ELSE 0 END AS bit) AS WorkflowV2Ready,
          CAST
          (
              (
                  SELECT COUNT(*)
                  FROM sys.indexes AS indexes
                  WHERE indexes.object_id = OBJECT_ID(N'dbo.IdempotencyRecords', N'U')
                    AND indexes.is_unique = 1
                    AND indexes.is_primary_key = 0
                    AND 1 =
                    (
                        SELECT COUNT(*)
                        FROM sys.index_columns AS key_columns
                        WHERE key_columns.object_id = indexes.object_id
                          AND key_columns.index_id = indexes.index_id
                          AND key_columns.key_ordinal > 0
                    )
                    AND EXISTS
                    (
                        SELECT 1
                        FROM sys.index_columns AS key_columns
                        INNER JOIN sys.columns AS columns
                            ON columns.object_id = key_columns.object_id
                           AND columns.column_id = key_columns.column_id
                        WHERE key_columns.object_id = indexes.object_id
                          AND key_columns.index_id = indexes.index_id
                          AND key_columns.key_ordinal = 1
                          AND columns.name = N'IdempotencyKey'
                    )
              ) AS int
          ) AS LegacyGlobalIdempotencyUniqueIndexCount;
        """;

    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = sql;
    await using var reader = await command.ExecuteReaderAsync();
    if (!await reader.ReadAsync())
        throw new InvalidOperationException("Database schema verification returned no result.");

    var workflowV2Ready = reader.GetBoolean(0);
    var legacyGlobalIndexCount = reader.GetInt32(1);
    await reader.DisposeAsync();

    var publishableOutboxMessageCount = -1;
    var activeWorkflowV2JobCount = -1;
    var activeWorkflowV3JobCount = -1;
    var awaitingAdministratorActionWorkflowV3JobCount = -1;
    var activeLegacyJobCount = -1;
    if (workflowV2Ready)
    {
        await using var stateCommand = connection.CreateCommand();
        stateCommand.CommandTimeout = 60;
        stateCommand.CommandText = """
            SELECT
              (SELECT COUNT(*)
               FROM dbo.OutboxMessages
               WHERE Status IN (N'Pending', N'Processing')) AS PublishableOutboxMessageCount,
              (SELECT COUNT(*)
               FROM dbo.ProvisioningJobs
               WHERE WorkflowVersion = 2
                 AND Status IN (N'Pending', N'Running', N'RequiresManualIntervention'))
                AS ActiveWorkflowV2JobCount,
              (SELECT COUNT(*)
               FROM dbo.ProvisioningJobs
               WHERE WorkflowVersion >= 3
                 AND Status IN
                 (
                     N'Pending',
                     N'Running',
                     N'AwaitingAdministratorAction',
                     N'RequiresManualIntervention'
                 )) AS ActiveWorkflowV3JobCount,
              (SELECT COUNT(*)
               FROM dbo.ProvisioningJobs
               WHERE WorkflowVersion >= 3
                 AND Status = N'AwaitingAdministratorAction')
                AS AwaitingAdministratorActionWorkflowV3JobCount,
              (SELECT COUNT(*)
               FROM dbo.ProvisioningJobs
               WHERE WorkflowVersion < 2
                 AND Status IN (N'Pending', N'Running', N'RequiresManualIntervention'))
                AS ActiveLegacyJobCount;
            """;
        await using var stateReader = await stateCommand.ExecuteReaderAsync();
        if (!await stateReader.ReadAsync())
            throw new InvalidOperationException("Database execution-state verification returned no result.");
        publishableOutboxMessageCount = stateReader.GetInt32(0);
        activeWorkflowV2JobCount = stateReader.GetInt32(1);
        activeWorkflowV3JobCount = stateReader.GetInt32(2);
        awaitingAdministratorActionWorkflowV3JobCount = stateReader.GetInt32(3);
        activeLegacyJobCount = stateReader.GetInt32(4);
    }

    return new SchemaVerification(
        workflowV2Ready,
        legacyGlobalIndexCount,
        publishableOutboxMessageCount,
        activeWorkflowV2JobCount,
        activeWorkflowV3JobCount,
        awaitingAdministratorActionWorkflowV3JobCount,
        activeLegacyJobCount);
}

static Dictionary<string, string> ParseArguments(string[] arguments)
{
    var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    for (var index = 0; index < arguments.Length; index += 2)
    {
        if (index + 1 >= arguments.Length || !arguments[index].StartsWith("--", StringComparison.Ordinal))
            throw new ArgumentException("Arguments must be supplied as --name value pairs.");
        result[arguments[index][2..]] = arguments[index + 1];
    }
    return result;
}

static IEnumerable<string> SplitSqlBatches(string sql)
{
    return Regex
        .Split(sql, @"^\s*GO\s*(?:--.*)?$", RegexOptions.Multiline | RegexOptions.IgnoreCase)
        .Where(batch => !string.IsNullOrWhiteSpace(batch));
}

static string Required(IReadOnlyDictionary<string, string> options, string key) =>
    ReadOption(options, key) is { Length: > 0 } value
        ? value
        : throw new ArgumentException($"--{key} is required.");

static string? ReadOption(IReadOnlyDictionary<string, string> options, string key)
{
    if (options.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
        return value;

    var environmentName = "DATABASE_MIGRATOR_" + key
        .Replace('-', '_')
        .ToUpperInvariant();
    return Environment.GetEnvironmentVariable(environmentName);
}

static string ResolveRepositoryRoot(string? explicitRoot)
{
    var current = new DirectoryInfo(
        string.IsNullOrWhiteSpace(explicitRoot) ? Directory.GetCurrentDirectory() : explicitRoot);
    while (current is not null)
    {
        if (Directory.Exists(Path.Combine(current.FullName, "infrastructure", "sql")))
            return current.FullName;
        current = current.Parent;
    }
    throw new DirectoryNotFoundException("Could not resolve the repository root containing infrastructure/sql.");
}

internal sealed record ScriptEvidence(string Name, string Sha256, string Sql);
internal sealed record MigrationScriptEvidence(string Name, string Sha256);
internal sealed record SchemaVerification(
    bool WorkflowV2Ready,
    int LegacyGlobalIdempotencyUniqueIndexCount,
    int PublishableOutboxMessageCount,
    int ActiveWorkflowV2JobCount,
    int ActiveWorkflowV3JobCount,
    int AwaitingAdministratorActionWorkflowV3JobCount,
    int ActiveLegacyJobCount);
internal sealed record MigrationEvidence(
    DateTimeOffset VerifiedAtUtc,
    string Server,
    string Database,
    string Phase,
    int Repeat,
    IReadOnlyList<MigrationScriptEvidence> Scripts,
    SchemaVerification Verification,
    RuntimePrincipalEvidence? RuntimePrincipal);
internal sealed record RuntimePrincipalEvidence(
    string Name,
    Guid ClientId,
    IReadOnlyList<string> DatabaseRoles);
