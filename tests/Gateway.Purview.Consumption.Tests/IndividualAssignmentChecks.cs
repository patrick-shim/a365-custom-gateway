using System.Net;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Purview;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

static class IndividualAssignmentChecks
{
    public static async Task RunAsync()
    {
        static void Check(bool value, string message) { if (!value) throw new Exception(message); }
        var tenant = Guid.NewGuid(); var child = Guid.NewGuid(); var blueprint = Guid.NewGuid();
        var request = new PolicyAssignmentRequest(Guid.NewGuid(), tenant, Guid.NewGuid(), child, blueprint, Guid.NewGuid(), new string('a',64), DateTime.UtcNow.AddMinutes(10));
        var key = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
        var signed = PolicyAssignmentProtocol.Sign(request, key, "request");
        Check(PolicyAssignmentProtocol.Verify<PolicyAssignmentRequest>(signed, key, "request") == request, "Assignment round trip failed.");
        foreach (var domain in new[] { "result", "invalid" })
        {
            try { PolicyAssignmentProtocol.Verify<PolicyAssignmentRequest>(signed, key, domain); throw new Exception("Cross-domain replay accepted."); }
            catch (CryptographicException) { }
        }
        try { PolicyAssignmentProtocol.Verify<PolicyAssignmentRequest>(signed, Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)), "request"); throw new Exception("Wrong publisher accepted."); }
        catch (CryptographicException) { }
        foreach (var invalid in new[] { request with { TenantId=Guid.NewGuid() }, request with { AgentIdentityId=blueprint }, request with { ExpiresAtUtc=DateTime.UtcNow.AddMinutes(-1) }, request with { ReviewedRevision="invalid" } })
        {
            var rejected = false;
            try { PolicyAssignmentProtocol.Validate(invalid, tenant); } catch (InvalidOperationException) { rejected = true; }
            Check(rejected, "Invalid assignment target or review accepted.");
        }
        var graph = new ScopeGraph();
        using var cache = new MemoryCache(new MemoryCacheOptions());
        var client = new PurviewPolicyClient(NullLogger<PurviewPolicyClient>.Instance, Options.Create(new PurviewOptions { Enabled=true }), cache, graph);
        var input = new PurviewInteraction(Guid.NewGuid(), Guid.NewGuid().ToString(), "normal", "normal", "text/plain", "", "text/plain", null, null,
            child.ToString(), blueprint.ToString(), "test", DateTime.UtcNow, PurviewExecutionMode.EvaluateInline, Guid.NewGuid().ToString(), true);
        Check((await client.EvaluatePromptAsync(input, default)).Decision == PurviewDecisionType.Allowed, "Inline normal allow failed.");
        var sibling = Guid.NewGuid().ToString();
        await client.EvaluatePromptAsync(input with { AgentIdentityClientId=sibling }, default);
        Check(graph.ScopeTargets.SequenceEqual(new[] { child.ToString(), sibling }), "Sibling scope cache collided.");
        graph.Modified = true;
        Check((await client.EvaluatePromptAsync(input, default)).Decision == PurviewDecisionType.Allowed && graph.ScopeTargets.Count == 3,
            "Modified policy marker must refresh scope and enforce the returned verdict.");
        graph.RemoveInline = true;
        try { await client.EvaluatePromptAsync(input, default); throw new Exception("Removed inline scope allowed content."); }
        catch (PurviewPolicyException e) when (e.FailureCode == "PURVIEW_INLINE_SCOPE_NOT_READY") { }
        graph.RemoveInline = false;
        graph.Modified = false;
        graph.Block = true;
        Check((await client.EvaluatePromptAsync(input, default)).Decision == PurviewDecisionType.Blocked, "Sensitive block lost.");
        graph.Error = true;
        try { await client.EvaluatePromptAsync(input, default); throw new Exception("Processing errors allowed content."); }
        catch (PurviewPolicyException e) when (e.FailureCode == "PURVIEW_PROCESSING_ERROR") { }
        Console.WriteLine("Individual assignment authentication, expiry, target binding, sibling scope cache, inline allow/block, and processing-error checks passed.");
    }
    private sealed class ScopeGraph : IPurviewGraphClient
    {
        public List<string> ScopeTargets { get; } = [];
        public bool Block { get; set; }
        public bool Error { get; set; }
        public bool Modified { get; set; }
        public bool RemoveInline { get; set; }
        public Task<PurviewGraphResponse> PostAsync(string operation, string path, JsonObject body, string? etag, CancellationToken ct, PurviewInteraction? identity = null)
        {
            if (identity?.UseAgentIdentity != true) throw new Exception("Explicit child token binding missing.");
            if (operation == "computeProtectionScopes")
            {
                var target = body["locations"]![0]!["value"]!.GetValue<string>();
                if (target != identity.AgentIdentityClientId) throw new Exception("Scope used blueprint instead of child.");
                ScopeTargets.Add(target);
                return Task.FromResult(new PurviewGraphResponse(JsonNode.Parse(RemoveInline ? "{\"value\":[]}" : "{\"value\":[{\"activities\":\"uploadText\",\"executionMode\":\"evaluateInline\",\"policyActions\":[]}]}")!.AsObject(), "\"scope\"", HttpStatusCode.OK));
            }
            if (body["contentToProcess"]!["protectedAppMetadata"]!["applicationLocation"]!["value"]!.GetValue<string>() != identity.AgentIdentityClientId || etag != "\"scope\"")
                throw new Exception("Process content target/ETag not bound.");
            var result = new JsonObject { ["protectionScopeState"]=Modified ? "modified" : "notModified", ["processingErrors"]=Error ? new JsonArray(new JsonObject { ["code"]="error" }) : new JsonArray(),
                ["policyActions"]=Block ? new JsonArray(new JsonObject { ["action"]="restrictAccess", ["restrictionAction"]="block" }) : new JsonArray() };
            return Task.FromResult(new PurviewGraphResponse(result, null, HttpStatusCode.OK));
        }
    }
}
