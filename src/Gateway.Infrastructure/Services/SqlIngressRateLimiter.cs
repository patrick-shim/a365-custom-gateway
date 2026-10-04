using System.Data;
using System.Data.Common;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Services;

internal sealed partial class SqlIngressRateLimiter : IIngressRateLimiter
{
    private const int DefaultPerCredentialLimit = 100;
    private const int DefaultPerRegistrationLimit = 1_000;
    private const int DefaultGlobalLimit = 10_000;

    private const byte GlobalScope = 0;
    private const byte RegistrationScope = 1;
    private const byte CredentialScope = 2;

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

        if (PostgresAdvisoryLock.IsNpgsql(_dbContext))
            return await TryAcquirePostgresAsync(agentRegistrationId, credentialId, limits, ct);
        if (_dbContext.Database.ProviderName != "Microsoft.EntityFrameworkCore.InMemory")
            throw new NotSupportedException("Ingress rate limiting requires PostgreSQL.");

        return await TryAcquireProcessLocalAsync(agentRegistrationId, credentialId, limits, ct);
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
