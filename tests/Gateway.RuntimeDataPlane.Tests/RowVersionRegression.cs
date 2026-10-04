using Gateway.Api.Extensions;
using Gateway.Application.Agents.Commands;
using Gateway.Application.Exceptions;
using Gateway.Application.Protection;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
using Microsoft.AspNetCore.Http;
using Microsoft.EntityFrameworkCore;

internal static class RowVersionRegression
{
    private static void Check(bool valid, string message)
    {
        if (!valid) throw new Exception(message);
    }

    private static void Reject(Action action)
    {
        try { action(); }
        catch (PreconditionFailedException) { return; }
        throw new Exception("Invalid or stale version was accepted.");
    }

    public static void CheckProtocol()
    {
        foreach (var size in new[] { 16 })
        {
            var bytes = Enumerable.Range(1, size).Select(x => (byte)x).ToArray();
            var version = Convert.ToBase64String(bytes);
            var key = Guid.NewGuid();
            var request = new DefaultHttpContext().Request;
            request.Headers["If-Match"] = version;
            request.Headers["Idempotency-Key"] = key.ToString("D");
            ProtectionRequestHeaderValidation.RequireReviewHeaders(request, version);
            ProtectionRequestHeaderValidation.RequireMutationHeaders(request, key, version);
            Check(RowVersionValidation.IsCanonical(version), "Protection validator rejected a supported provider token.");
            Check(ProtectionRowVersion.DecodeExpected(version).SequenceEqual(bytes), "Version must round-trip without truncation.");
            ProtectionRowVersion.EnsureMatches(version, true, bytes, Guid.NewGuid(), DateTime.UtcNow);
            var changed = bytes.ToArray();
            changed[^1]++;
            Reject(() => ProtectionRowVersion.EnsureMatches(version, true, changed, Guid.NewGuid(), DateTime.UtcNow));
            request.Headers["If-Match"] = Convert.ToBase64String(changed);
            Reject(() => ProtectionRequestHeaderValidation.RequireMutationHeaders(request, key, version));
            request.Headers["If-Match"] = new Microsoft.Extensions.Primitives.StringValues(new[] { version, version });
            Reject(() => ProtectionRequestHeaderValidation.RequireReviewHeaders(request, version));
        }
        foreach (var value in new[]
                     {
                         "", " ", "not-base64",
                         Convert.ToBase64String(new byte[4]), Convert.ToBase64String(new byte[8]), Convert.ToBase64String(new byte[15]),
                         Convert.ToBase64String(new byte[32]), "AAAAAAAAAAB=", "AAAAAAAAAAAAAAAAAAAAAB==",
                         " AAAAAAAAAAA=", "AAAAAAAAAAA=\n", "\"AAAAAAAAAAA=\"", "W/\"AAAAAAAAAAA=\""
                     })
        {
            Check(!RowVersionValidation.IsCanonical(value), "Malformed row version accepted.");
            var request = new DefaultHttpContext().Request;
            request.Headers["If-Match"] = value;
            Reject(() => ProtectionRequestHeaderValidation.RequireReviewHeaders(request, value));
            if (!string.IsNullOrWhiteSpace(value))
                Reject(() => ProtectionRowVersion.DecodeExpected(value));
        }
        Check(ProtectionRowVersion.DecodeExpected("*").Length == 0, "Creation sentinel must remain supported.");
        Reject(() => ProtectionRowVersion.EnsureMatches("*", true, new byte[16], Guid.NewGuid(), DateTime.UtcNow));
        Console.WriteLine("PostgreSQL version headers, canonical encoding, and stale-update checks passed.");
    }

    public static async Task CheckToggleAsync(GatewayDbContext db, Guid agentId)
    {
        Check(db.Database.CurrentTransaction is not null, "Toggle regression must run in a rollback-only transaction.");
        var repository = new AgentRegistrationRepository(db);
        var agent = await repository.GetByIdAsync(agentId, default) ?? throw new Exception("Test agent missing.");
        Check(agent.FeatureConfiguration.PromptShieldEnabled && !agent.FeatureConfiguration.PurviewEnabled,
            "Use an existing test agent with Prompt Shields on and Purview off.");
        var originalVersion = Convert.ToBase64String(agent.RowVersion);
        var originalRevision = agent.ProtectionRevision;
        var evaluator = new ProtectionEffectiveFeatureEvaluator(new ReadyTestBinding());
        var handler = new UpdateFeaturesHandler(repository, new AuditEventRepository(db),
            new UnusedPurview(), new UnusedShield(), new UnitOfWork(db), evaluator);
        UpdateFeaturesCommand Command(bool enabled, string version) => new(agentId, null, null, null,
            "row-version-regression", PromptShieldEnabled: enabled, ExpectedRowVersion: version,
            IdempotencyKey: Guid.NewGuid());
        await handler.Handle(Command(false, originalVersion), default);
        Check(!await db.AgentFeatureConfigurations.AsNoTracking().Where(x => x.AgentRegistrationId == agentId)
            .Select(x => x.PromptShieldEnabled).SingleAsync(), "Off was not persisted.");
        var offVersion = Convert.ToBase64String(agent.RowVersion);
        Check(offVersion != originalVersion && agent.ProtectionRevision != originalRevision, "Off must invalidate old versions and receipts.");
        try { await handler.Handle(Command(true, originalVersion), default); throw new Exception("Stale toggle succeeded."); }
        catch (PreconditionFailedException) { }
        await handler.Handle(Command(true, offVersion), default);
        Check(await db.AgentFeatureConfigurations.AsNoTracking().Where(x => x.AgentRegistrationId == agentId)
            .Select(x => x.PromptShieldEnabled).SingleAsync(), "On was not persisted.");
        Check(Convert.ToBase64String(agent.RowVersion) != offVersion, "On must return a fresh version.");
        Console.WriteLine("PostgreSQL Prompt Shields Off/On handler round-trip and stale toggle rejection passed (transaction will roll back).");
    }

    // Readiness is fixed for this persistence regression; no product APIs are invoked.
    private sealed class ReadyTestBinding : IBootstrapPromptShieldRuntimeBinding
    {
        public bool IsRuntimeReady() => true;
    }
    private sealed class UnusedShield : IPromptShieldClient
    {
        public bool IsEnabled => true;
        public TimeSpan ReceiptLifetime => TimeSpan.FromMinutes(2);
        public Task<PromptShieldEvaluationResult> EvaluateAsync(string prompt, PromptShieldSubject subject, CancellationToken ct) => throw new NotSupportedException();
    }
    private sealed class UnusedPurview : IPurviewPolicyClient
    {
        public bool IsEnabled => false;
        public PurviewMode DefaultMode => PurviewMode.AuditOnly;
        public Task<PurviewEvaluationResult> EvaluatePromptAsync(PurviewInteraction interaction, CancellationToken ct) => throw new NotSupportedException();
        public Task<PurviewEvaluationResult> EvaluateInteractionAsync(PurviewInteraction interaction, CancellationToken ct) => throw new NotSupportedException();
    }
}
