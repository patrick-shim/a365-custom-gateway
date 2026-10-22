using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Gateway.Infrastructure.Persistence;

internal sealed class RuntimeSchemaInitializer(
    IServiceScopeFactory scopeFactory,
    ILogger<RuntimeSchemaInitializer> logger) : IHostedService
{
    internal const int MaxStartupAttempts = 12;

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        await ExecuteWithRetryAsync(EnsureSchemaAsync, DelayAsync, logger, cancellationToken);
    }

    private async Task EnsureSchemaAsync(CancellationToken cancellationToken)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        const string schemaLock = "a365gw:runtime:schema";
        await using var schemaConnection = await PostgresAdvisoryLock.AcquireSessionLockAsync(db, schemaLock, cancellationToken);
        try
        {
            await db.Database.EnsureCreatedAsync(cancellationToken);
            if (PostgresAdvisoryLock.IsNpgsql(db))
                await EnsurePurviewConnectorSchemaAsync(db, cancellationToken);
            logger.LogInformation("Runtime PostgreSQL schema ensured.");
        }
        finally
        {
            await PostgresAdvisoryLock.ReleaseSessionLockAsync(schemaConnection, schemaLock, CancellationToken.None);
        }
    }

    private static async Task EnsurePurviewConnectorSchemaAsync(
        GatewayDbContext db,
        CancellationToken cancellationToken)
    {
        // Existing runtime databases predate EF migrations. This bounded,
        // idempotent upgrade runs under the same deployment-wide schema lock as
        // EnsureCreated, so an existing named volume gains the connector tables
        // without recreating or adopting any external resource.
        const string sql = """
            CREATE TABLE IF NOT EXISTS "GatewaySchemaVersions" (
                "Version" integer PRIMARY KEY,
                "AppliedAtUtc" timestamp with time zone NOT NULL
            );

            CREATE TABLE IF NOT EXISTS "PurviewConnectorStates" (
                "Id" uuid PRIMARY KEY,
                "TenantId" uuid NOT NULL,
                "ConnectorInstanceId" uuid NOT NULL,
                "ConnectorProfile" character varying(32) NOT NULL,
                "State" character varying(24) NOT NULL,
                "RefreshMode" character varying(16) NOT NULL,
                "NextGeneration" bigint NOT NULL,
                "LastHeartbeatAtUtc" timestamp with time zone NULL,
                "LastAttemptedRefreshAtUtc" timestamp with time zone NULL,
                "LastSuccessfulRefreshAtUtc" timestamp with time zone NULL,
                "CatalogRetrievedAtUtc" timestamp with time zone NULL,
                "PolicyCount" integer NOT NULL,
                "CompatiblePolicyCount" integer NOT NULL,
                "IncompatiblePolicyCount" integer NOT NULL,
                "CatalogVerificationStatus" character varying(24) NOT NULL,
                "CurrentOperationId" uuid NULL,
                "LastFailureCode" character varying(128) NULL,
                "LastCorrelationId" character varying(128) NULL,
                "CreatedAtUtc" timestamp with time zone NOT NULL,
                "UpdatedAtUtc" timestamp with time zone NOT NULL,
                "RowVersion" bytea NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS "IX_PurviewConnectorStates_TenantId"
                ON "PurviewConnectorStates" ("TenantId");

            CREATE TABLE IF NOT EXISTS "PurviewConnectorOperations" (
                "Id" uuid PRIMARY KEY,
                "TenantId" uuid NOT NULL,
                "ConnectorInstanceId" uuid NOT NULL,
                "Type" character varying(32) NOT NULL,
                "Status" character varying(24) NOT NULL,
                "CurrentStep" character varying(64) NOT NULL,
                "PercentComplete" integer NOT NULL,
                "Generation" bigint NOT NULL,
                "IdempotencyKey" character varying(36) NOT NULL,
                "RequestHash" character varying(64) NOT NULL,
                "RequestedByObjectId" character varying(36) NOT NULL,
                "CorrelationId" character varying(128) NOT NULL,
                "IssuedAtUtc" timestamp with time zone NOT NULL,
                "ExpiresAtUtc" timestamp with time zone NOT NULL,
                "LeaseExpiresAtUtc" timestamp with time zone NULL,
                "AttemptCount" integer NOT NULL,
                "StartedAtUtc" timestamp with time zone NULL,
                "CompletedAtUtc" timestamp with time zone NULL,
                "ResultHash" character varying(64) NULL,
                "CatalogHash" character varying(64) NULL,
                "FailureCode" character varying(128) NULL,
                "FailureSummary" character varying(512) NULL,
                "TransportCleanedAtUtc" timestamp with time zone NULL,
                "CreatedAtUtc" timestamp with time zone NOT NULL,
                "RowVersion" bytea NOT NULL,
                CONSTRAINT "CK_PurviewConnectorOperations_Status" CHECK
                    ("Status" IN ('Pending','Running','Succeeded','Failed','NeedsAttention','TimedOut','Cancelled'))
            );
            CREATE UNIQUE INDEX IF NOT EXISTS "IX_PurviewConnectorOperations_TenantId_IdempotencyKey"
                ON "PurviewConnectorOperations" ("TenantId", "IdempotencyKey");
            CREATE INDEX IF NOT EXISTS "IX_PurviewConnectorOperations_Status_CreatedAtUtc"
                ON "PurviewConnectorOperations" ("Status", "CreatedAtUtc");
            ALTER TABLE "PurviewConnectorOperations"
                ADD COLUMN IF NOT EXISTS "TransportCleanedAtUtc" timestamp with time zone NULL;

            CREATE TABLE IF NOT EXISTS "PurviewCatalogSnapshots" (
                "Id" uuid PRIMARY KEY,
                "TenantId" uuid NOT NULL,
                "ConnectorInstanceId" uuid NOT NULL,
                "OperationId" uuid NOT NULL,
                "Generation" bigint NOT NULL,
                "CatalogHash" character varying(64) NOT NULL,
                "CatalogJson" jsonb NOT NULL,
                "RetrievedAtUtc" timestamp with time zone NOT NULL,
                "AcceptedAtUtc" timestamp with time zone NOT NULL,
                "PolicyCount" integer NOT NULL,
                "CompatiblePolicyCount" integer NOT NULL,
                "IncompatiblePolicyCount" integer NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS "IX_PurviewCatalogSnapshots_TenantId_Generation"
                ON "PurviewCatalogSnapshots" ("TenantId", "Generation");
            CREATE UNIQUE INDEX IF NOT EXISTS "IX_PurviewCatalogSnapshots_OperationId"
                ON "PurviewCatalogSnapshots" ("OperationId");

            INSERT INTO "GatewaySchemaVersions" ("Version", "AppliedAtUtc")
            VALUES (2, CURRENT_TIMESTAMP)
            ON CONFLICT ("Version") DO NOTHING;
            """;
        await db.Database.ExecuteSqlRawAsync(sql, cancellationToken);
    }

    internal static async Task ExecuteWithRetryAsync(
        Func<CancellationToken, Task> initialize,
        Func<TimeSpan, CancellationToken, Task> delay,
        ILogger logger,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(initialize);
        ArgumentNullException.ThrowIfNull(delay);
        ArgumentNullException.ThrowIfNull(logger);

        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await initialize(cancellationToken);
                return;
            }
            catch (Exception exception) when (
                attempt < MaxStartupAttempts &&
                IsTransientPostgresStartupFailure(exception))
            {
                var retryDelay = GetRetryDelay(attempt);
                logger.LogWarning(
                    "PostgreSQL is temporarily unavailable during runtime schema initialization " +
                    "(attempt {Attempt} of {MaxAttempts}, SQL state {SqlState}). Retrying in {DelaySeconds}s.",
                    attempt,
                    MaxStartupAttempts,
                    GetSqlState(exception) ?? "unavailable",
                    retryDelay.TotalSeconds);
                await delay(retryDelay, cancellationToken);
            }
        }
    }

    internal static bool IsTransientPostgresStartupFailure(Exception exception) =>
        exception is Npgsql.NpgsqlException { IsTransient: true } ||
        exception is TimeoutException;

    internal static TimeSpan GetRetryDelay(int failedAttempt)
    {
        var exponent = Math.Clamp(failedAttempt - 1, 0, 3);
        return TimeSpan.FromSeconds(Math.Min(5, 1 << exponent));
    }

    private static string? GetSqlState(Exception exception) =>
        exception is Npgsql.PostgresException postgresException
            ? postgresException.SqlState
            : null;

    private static Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken) =>
        Task.Delay(delay, cancellationToken);

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
