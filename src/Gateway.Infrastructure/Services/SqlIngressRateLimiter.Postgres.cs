using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence.Configurations;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Services;

internal sealed partial class SqlIngressRateLimiter
{
    private async Task<IngressRateLimitDecision> TryAcquirePostgresAsync(
        Guid registrationId, Guid credentialId, Limits limits, CancellationToken ct)
    {
        if (_dbContext.Database.CurrentTransaction is not null)
            throw new InvalidOperationException("Ingress rate limiting must own its transaction.");
        await using var transaction = await _dbContext.Database.BeginTransactionAsync(ct);
        // Every request touches the global bucket. Serialize the short transaction
        // before taking its database clock reading so window boundaries agree.
        await _dbContext.Database.ExecuteSqlRawAsync("SELECT pg_advisory_xact_lock(365, 1)", ct);
        var nowUtc = await _dbContext.Database.SqlQueryRaw<DateTime>("SELECT clock_timestamp() AS \"Value\"").SingleAsync(ct);
        var window = new DateTime(nowUtc.Year, nowUtc.Month, nowUtc.Day, nowUtc.Hour, nowUtc.Minute, 0, DateTimeKind.Utc);
        var scopes = new[] {
            new Scope(GlobalScope, Guid.Empty, "global", limits.Global),
            new Scope(RegistrationScope, registrationId, "registration", limits.PerRegistration),
            new Scope(CredentialScope, credentialId, "credential", limits.PerCredential)
        };
        var buckets = new List<IngressRateLimitBucket>();
        foreach (var scope in scopes)
        {
            // Raw updates avoid persisting unrelated tracked work from the request.
            await _dbContext.Database.ExecuteSqlInterpolatedAsync($"""
                INSERT INTO "IngressRateLimitBuckets" ("ScopeType", "ScopeId", "WindowStartUtc", "RequestCount", "UpdatedAtUtc")
                VALUES ({(short)scope.Type}, {scope.Id}, {window}, 0, {nowUtc})
                ON CONFLICT ("ScopeType", "ScopeId") DO NOTHING
                """, ct);
            var bucket = await _dbContext.Set<IngressRateLimitBucket>().AsNoTracking()
                .SingleAsync(x => x.ScopeType == scope.Type && x.ScopeId == scope.Id, ct);
            if (bucket.WindowStartUtc != window) bucket.RequestCount = 0;
            if (bucket.RequestCount >= scope.Limit)
                return new(false, scope.Name, scope.Limit, 0, window.AddMinutes(1));
            buckets.Add(bucket);
        }
        IngressRateLimitDecision? decision = null;
        for (var i = 0; i < scopes.Length; i++)
        {
            var scope = scopes[i];
            var count = buckets[i].RequestCount + 1;
            await _dbContext.Database.ExecuteSqlInterpolatedAsync($"""
                UPDATE "IngressRateLimitBuckets" SET "WindowStartUtc" = {window}, "RequestCount" = {count}, "UpdatedAtUtc" = {nowUtc}
                WHERE "ScopeType" = {(short)scope.Type} AND "ScopeId" = {scope.Id}
                """, ct);
            if (decision is null || scope.Limit - count < decision.Remaining)
                decision = new(true, scope.Name, scope.Limit, scope.Limit - count, window.AddMinutes(1));
        }
        await transaction.CommitAsync(ct);
        return decision!;
    }
}
