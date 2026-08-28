using System.Data;
using System.Data.Common;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Services;

internal sealed class SqlIngressRateLimiter : IIngressRateLimiter
{
    private const int DefaultPerCredentialLimit = 100;
    private const int DefaultPerRegistrationLimit = 1_000;
    private const int DefaultGlobalLimit = 10_000;

    private const byte GlobalScope = 0;
    private const byte RegistrationScope = 1;
    private const byte CredentialScope = 2;

    private const string AcquireSql = """
        SET NOCOUNT ON;

        DECLARE @NowUtc datetime2(7) = SYSUTCDATETIME();
        DECLARE @WindowStartUtc datetime2(0) = DATEADD(minute, DATEDIFF(minute, 0, @NowUtc), 0);
        DECLARE @ResetAtUtc datetime2(0) = DATEADD(minute, 1, @WindowStartUtc);
        DECLARE @GlobalId uniqueidentifier = '00000000-0000-0000-0000-000000000000';

        DECLARE @GlobalCount int = -1;
        DECLARE @GlobalWindow datetime2(0) = NULL;
        DECLARE @RegistrationCount int = -1;
        DECLARE @RegistrationWindow datetime2(0) = NULL;
        DECLARE @CredentialCount int = -1;
        DECLARE @CredentialWindow datetime2(0) = NULL;

        SELECT @GlobalCount = [RequestCount], @GlobalWindow = [WindowStartUtc]
        FROM [dbo].[IngressRateLimitBuckets] WITH (UPDLOCK, HOLDLOCK)
        WHERE [ScopeType] = 0 AND [ScopeId] = @GlobalId;

        SELECT @RegistrationCount = [RequestCount], @RegistrationWindow = [WindowStartUtc]
        FROM [dbo].[IngressRateLimitBuckets] WITH (UPDLOCK, HOLDLOCK)
        WHERE [ScopeType] = 1 AND [ScopeId] = @AgentRegistrationId;

        SELECT @CredentialCount = [RequestCount], @CredentialWindow = [WindowStartUtc]
        FROM [dbo].[IngressRateLimitBuckets] WITH (UPDLOCK, HOLDLOCK)
        WHERE [ScopeType] = 2 AND [ScopeId] = @CredentialId;

        IF @GlobalWindow IS NULL OR @GlobalWindow <> @WindowStartUtc SET @GlobalCount = 0;
        IF @RegistrationWindow IS NULL OR @RegistrationWindow <> @WindowStartUtc SET @RegistrationCount = 0;
        IF @CredentialWindow IS NULL OR @CredentialWindow <> @WindowStartUtc SET @CredentialCount = 0;

        IF @GlobalCount >= @GlobalLimit OR
           @RegistrationCount >= @RegistrationLimit OR
           @CredentialCount >= @CredentialLimit
        BEGIN
            DECLARE @RejectedScope tinyint =
                CASE
                    WHEN @GlobalCount >= @GlobalLimit THEN 0
                    WHEN @RegistrationCount >= @RegistrationLimit THEN 1
                    ELSE 2
                END;
            DECLARE @RejectedLimit int =
                CASE @RejectedScope
                    WHEN 0 THEN @GlobalLimit
                    WHEN 1 THEN @RegistrationLimit
                    ELSE @CredentialLimit
                END;

            SELECT
                CAST(0 AS bit) AS [Allowed],
                @RejectedScope AS [ScopeType],
                @RejectedLimit AS [Limit],
                CAST(0 AS int) AS [Remaining],
                @ResetAtUtc AS [ResetAtUtc];
            RETURN;
        END;

        IF EXISTS
        (
            SELECT 1 FROM [dbo].[IngressRateLimitBuckets]
            WHERE [ScopeType] = 0 AND [ScopeId] = @GlobalId
        )
            UPDATE [dbo].[IngressRateLimitBuckets]
            SET [WindowStartUtc] = @WindowStartUtc,
                [RequestCount] = @GlobalCount + 1,
                [UpdatedAtUtc] = @NowUtc
            WHERE [ScopeType] = 0 AND [ScopeId] = @GlobalId;
        ELSE
            INSERT INTO [dbo].[IngressRateLimitBuckets]
                ([ScopeType], [ScopeId], [WindowStartUtc], [RequestCount], [UpdatedAtUtc])
            VALUES (0, @GlobalId, @WindowStartUtc, 1, @NowUtc);

        IF EXISTS
        (
            SELECT 1 FROM [dbo].[IngressRateLimitBuckets]
            WHERE [ScopeType] = 1 AND [ScopeId] = @AgentRegistrationId
        )
            UPDATE [dbo].[IngressRateLimitBuckets]
            SET [WindowStartUtc] = @WindowStartUtc,
                [RequestCount] = @RegistrationCount + 1,
                [UpdatedAtUtc] = @NowUtc
            WHERE [ScopeType] = 1 AND [ScopeId] = @AgentRegistrationId;
        ELSE
            INSERT INTO [dbo].[IngressRateLimitBuckets]
                ([ScopeType], [ScopeId], [WindowStartUtc], [RequestCount], [UpdatedAtUtc])
            VALUES (1, @AgentRegistrationId, @WindowStartUtc, 1, @NowUtc);

        IF EXISTS
        (
            SELECT 1 FROM [dbo].[IngressRateLimitBuckets]
            WHERE [ScopeType] = 2 AND [ScopeId] = @CredentialId
        )
            UPDATE [dbo].[IngressRateLimitBuckets]
            SET [WindowStartUtc] = @WindowStartUtc,
                [RequestCount] = @CredentialCount + 1,
                [UpdatedAtUtc] = @NowUtc
            WHERE [ScopeType] = 2 AND [ScopeId] = @CredentialId;
        ELSE
            INSERT INTO [dbo].[IngressRateLimitBuckets]
                ([ScopeType], [ScopeId], [WindowStartUtc], [RequestCount], [UpdatedAtUtc])
            VALUES (2, @CredentialId, @WindowStartUtc, 1, @NowUtc);

        SET @GlobalCount = @GlobalCount + 1;
        SET @RegistrationCount = @RegistrationCount + 1;
        SET @CredentialCount = @CredentialCount + 1;

        DECLARE @EffectiveScope tinyint = 2;
        DECLARE @EffectiveLimit int = @CredentialLimit;
        DECLARE @EffectiveRemaining int = @CredentialLimit - @CredentialCount;

        IF @RegistrationLimit - @RegistrationCount < @EffectiveRemaining
        BEGIN
            SET @EffectiveScope = 1;
            SET @EffectiveLimit = @RegistrationLimit;
            SET @EffectiveRemaining = @RegistrationLimit - @RegistrationCount;
        END;

        IF @GlobalLimit - @GlobalCount < @EffectiveRemaining
        BEGIN
            SET @EffectiveScope = 0;
            SET @EffectiveLimit = @GlobalLimit;
            SET @EffectiveRemaining = @GlobalLimit - @GlobalCount;
        END;

        SELECT
            CAST(1 AS bit) AS [Allowed],
            @EffectiveScope AS [ScopeType],
            @EffectiveLimit AS [Limit],
            @EffectiveRemaining AS [Remaining],
            @ResetAtUtc AS [ResetAtUtc];
        """;

    private readonly GatewayDbContext _dbContext;
    private readonly IngressRateLimitProcessStore _processStore;

    public SqlIngressRateLimiter(
        GatewayDbContext dbContext,
        IngressRateLimitProcessStore processStore)
    {
        _dbContext = dbContext;
        _processStore = processStore;
    }

    public async Task<IngressRateLimitDecision> TryAcquireAsync(
        Guid agentRegistrationId,
        Guid credentialId,
        CancellationToken ct)
    {
        var limits = await GetLimitsAsync(ct);

        return string.Equals(
            _dbContext.Database.ProviderName,
            "Microsoft.EntityFrameworkCore.SqlServer",
            StringComparison.Ordinal)
            ? await TryAcquireSqlAsync(agentRegistrationId, credentialId, limits, ct)
            : await TryAcquireProcessLocalAsync(agentRegistrationId, credentialId, limits, ct);
    }

    private async Task<Limits> GetLimitsAsync(CancellationToken ct)
    {
        var configured = await _dbContext.SystemConfigurations
            .AsNoTracking()
            .Select(item => new
            {
                item.RateLimitPerClient,
                item.RateLimitPerAgent,
                item.RateLimitGlobal
            })
            .SingleOrDefaultAsync(ct);

        if (configured is null)
        {
            return new Limits(
                DefaultPerCredentialLimit,
                DefaultPerRegistrationLimit,
                DefaultGlobalLimit);
        }

        if (configured.RateLimitPerClient <= 0 ||
            configured.RateLimitPerAgent <= 0 ||
            configured.RateLimitGlobal <= 0)
        {
            throw new InvalidOperationException("Ingress rate-limit configuration is invalid.");
        }

        return new Limits(
            configured.RateLimitPerClient,
            configured.RateLimitPerAgent,
            configured.RateLimitGlobal);
    }

    private async Task<IngressRateLimitDecision> TryAcquireSqlAsync(
        Guid agentRegistrationId,
        Guid credentialId,
        Limits limits,
        CancellationToken ct)
    {
        var connection = _dbContext.Database.GetDbConnection();
        var openedHere = connection.State != ConnectionState.Open;

        if (openedHere)
            await connection.OpenAsync(ct);

        try
        {
            await using var transaction = await connection.BeginTransactionAsync(
                IsolationLevel.Serializable,
                ct);
            await using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = AcquireSql;
            command.CommandType = CommandType.Text;
            command.CommandTimeout = 15;

            AddParameter(command, "@AgentRegistrationId", DbType.Guid, agentRegistrationId);
            AddParameter(command, "@CredentialId", DbType.Guid, credentialId);
            AddParameter(command, "@CredentialLimit", DbType.Int32, limits.PerCredential);
            AddParameter(command, "@RegistrationLimit", DbType.Int32, limits.PerRegistration);
            AddParameter(command, "@GlobalLimit", DbType.Int32, limits.Global);

            await using var reader = await command.ExecuteReaderAsync(ct);
            if (!await reader.ReadAsync(ct))
                throw new InvalidOperationException("Ingress rate limiter returned no decision.");

            var decision = new IngressRateLimitDecision(
                reader.GetBoolean(0),
                GetScopeName(reader.GetByte(1)),
                reader.GetInt32(2),
                reader.GetInt32(3),
                DateTime.SpecifyKind(reader.GetDateTime(4), DateTimeKind.Utc));

            await reader.DisposeAsync();
            await transaction.CommitAsync(ct);
            return decision;
        }
        finally
        {
            if (openedHere && connection.State == ConnectionState.Open)
                await connection.CloseAsync();
        }
    }

    private async Task<IngressRateLimitDecision> TryAcquireProcessLocalAsync(
        Guid agentRegistrationId,
        Guid credentialId,
        Limits limits,
        CancellationToken ct)
    {
        await _processStore.Gate.WaitAsync(ct);
        try
        {
            var nowUtc = DateTime.UtcNow;
            var windowStartUtc = new DateTime(
                nowUtc.Year,
                nowUtc.Month,
                nowUtc.Day,
                nowUtc.Hour,
                nowUtc.Minute,
                0,
                DateTimeKind.Utc);
            var resetAtUtc = windowStartUtc.AddMinutes(1);

            var scopes = new[]
            {
                new Scope(GlobalScope, Guid.Empty, "global", limits.Global),
                new Scope(RegistrationScope, agentRegistrationId, "registration", limits.PerRegistration),
                new Scope(CredentialScope, credentialId, "credential", limits.PerCredential)
            };

            foreach (var scope in scopes)
            {
                var bucket = GetCurrentBucket(scope, windowStartUtc);
                if (bucket.RequestCount >= scope.Limit)
                {
                    return new IngressRateLimitDecision(
                        false,
                        scope.Name,
                        scope.Limit,
                        0,
                        resetAtUtc);
                }
            }

            IngressRateLimitDecision? effective = null;
            foreach (var scope in scopes)
            {
                var bucket = GetCurrentBucket(scope, windowStartUtc);
                bucket.RequestCount++;
                var remaining = scope.Limit - bucket.RequestCount;
                if (effective is null || remaining < effective.Remaining)
                {
                    effective = new IngressRateLimitDecision(
                        true,
                        scope.Name,
                        scope.Limit,
                        remaining,
                        resetAtUtc);
                }
            }

            return effective!;
        }
        finally
        {
            _processStore.Gate.Release();
        }
    }

    private IngressRateLimitProcessStore.ProcessBucket GetCurrentBucket(
        Scope scope,
        DateTime windowStartUtc)
    {
        var key = (scope.Type, scope.Id);
        if (!_processStore.Buckets.TryGetValue(key, out var bucket))
        {
            bucket = new IngressRateLimitProcessStore.ProcessBucket
            {
                WindowStartUtc = windowStartUtc
            };
            _processStore.Buckets[key] = bucket;
        }
        else if (bucket.WindowStartUtc != windowStartUtc)
        {
            bucket.WindowStartUtc = windowStartUtc;
            bucket.RequestCount = 0;
        }

        return bucket;
    }

    private static void AddParameter(
        DbCommand command,
        string name,
        DbType type,
        object value)
    {
        var parameter = command.CreateParameter();
        parameter.ParameterName = name;
        parameter.DbType = type;
        parameter.Value = value;
        command.Parameters.Add(parameter);
    }

    private static string GetScopeName(byte scopeType) => scopeType switch
    {
        GlobalScope => "global",
        RegistrationScope => "registration",
        CredentialScope => "credential",
        _ => throw new InvalidOperationException("Ingress rate limiter returned an unknown scope.")
    };

    private sealed record Limits(int PerCredential, int PerRegistration, int Global);
    private sealed record Scope(byte Type, Guid Id, string Name, int Limit);
}
