using System.Data;
using System.Net;
using System.Text.Json;
using Azure.Core;
using Gateway.Agent365;
using Gateway.Application.Prompts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }

RowVersionRegression.CheckProtocol();

var dateOptions = new JsonSerializerOptions();
dateOptions.Converters.Add(new Gateway.Contracts.Serialization.UtcDateTimeJsonConverter());
foreach (var text in new[] { "2026-10-03T10:00:00Z", "2026-10-03T10:00:00+00:00", "2026-10-03T19:00:00+09:00", "2026-10-03T10:00:00" })
{
    var instant = JsonSerializer.Deserialize<DateTime>(JsonSerializer.Serialize(text), dateOptions);
    Check(instant == new DateTime(2026, 10, 3, 10, 0, 0, DateTimeKind.Utc) && instant.Kind == DateTimeKind.Utc,
        "UTC API fields must preserve the instant and normalize offset-bearing inputs before validation/persistence.");
    Check(JsonSerializer.Serialize(instant, dateOptions).Contains("Z"), "Responses must explicitly identify UTC.");
}
Console.WriteLine("UTC/offset API timestamp checks passed.");

var capture = new ExportCapture();
var exporter = new ObservabilityExporter(NullLogger<ObservabilityExporter>.Instance,
    Options.Create(new Agent365Options { TenantId = Guid.NewGuid().ToString(), ObservabilityServerAddress = "localhost", ObservabilityServerPort = 5080 }),
    capture, new FakeTokens());
var request = new ObservabilityExportRequest(Guid.NewGuid(), Guid.NewGuid(), "test-agent", "Test agent", "execute_tool",
    Guid.NewGuid().ToString(), "synthetic-run", Guid.NewGuid().ToString(), DateTime.UtcNow, DateTime.UtcNow,
    AgentIdentityClientId: Guid.NewGuid().ToString(), BlueprintClientId: Guid.NewGuid().ToString(),
    PromptShieldDecision: PromptShieldDecisionType.Blocked);
await exporter.ExportActivityAsync(request, default);
using (var payload = JsonDocument.Parse(capture.Body!))
{
    var spans = payload.RootElement.GetProperty("resourceSpans")[0].GetProperty("scopeSpans")[0].GetProperty("spans");
    Check(spans.GetArrayLength() == 2, "Blocked evaluation requires a root and its API check span.");
    Check(spans[0].GetProperty("status").GetProperty("code").GetInt32() == 2, "Blocked invocation must be an error.");
    Check(spans[1].GetProperty("status").GetProperty("code").GetInt32() == 1, "The completed API check itself succeeded.");
    var attrs = spans[1].GetProperty("attributes").EnumerateArray().ToDictionary(x => x.GetProperty("key").GetString()!, x => x.GetProperty("value").GetProperty("stringValue").GetString());
    Check(attrs["gen_ai.tool.name"] == "azure-ai-content-safety.prompt-shields" && attrs["gen_ai.tool.type"] == "API", "Use truthful standalone API attribution.");
    Check(attrs["gen_ai.tool.description"]!.Contains(request.EventId.ToString()) && attrs["gen_ai.tool.description"]!.Contains("Blocked"), "Hunting fields must identify the observed verdict and evaluation.");
    Check(attrs["gen_ai.tool.call.arguments"]!.Contains("REDACTED"), "Prompt content must remain redacted.");
}
await exporter.ExportActivityAsync(request with { PromptShieldDecision = null }, default);
using (var payload = JsonDocument.Parse(capture.Body!))
{
    var root = payload.RootElement.GetProperty("resourceSpans")[0].GetProperty("scopeSpans")[0].GetProperty("spans")[0];
    Check(root.GetProperty("status").GetProperty("code").GetInt32() == 1 && !root.GetProperty("status").TryGetProperty("message", out _), "Ordinary successful activity must keep its status.");
}
try { await exporter.ExportActivityAsync(request with { PromptShieldDecision = PromptShieldDecisionType.Allowed }, default); throw new Exception("Invalid verdict accepted."); }
catch (Agent365ObservabilityConfigurationException ex) when (ex.Code == "InvalidPromptShieldTelemetry") { }
Console.WriteLine("Standalone Prompt Shields export contract checks passed (no network).");

if (args.Length == 0) { Console.WriteLine("PostgreSQL checks skipped: pass an existing test agent ID and GATEWAY_TEST_DB."); return; }
var connection = Environment.GetEnvironmentVariable("GATEWAY_TEST_DB") ?? throw new Exception("GATEWAY_TEST_DB is required.");
await using var db = new GatewayDbContext(new DbContextOptionsBuilder<GatewayDbContext>()
    .UseNpgsql(connection).AddInterceptors(new PostgresRowVersionInterceptor()).Options);
var agentId = Guid.Parse(args[0]);
var repository = new PromptEvaluationRepository(db);
var context = await repository.GetProtectionContextAsync(agentId, default) ?? throw new Exception("Test agent missing.");
await using var transaction = await db.Database.BeginTransactionAsync(IsolationLevel.Serializable);
await AgentSearchRegression.CheckAsync(db, agentId);
await RowVersionRegression.CheckToggleAsync(db, agentId);
// The toggle changes the protection revision inside this rollback-only transaction.
context = await repository.GetProtectionContextAsync(agentId, default) ?? throw new Exception("Test agent missing.");
Check(await repository.IsProtectionContextCurrentAsync(context, default), "Unchanged PostgreSQL protection context must validate with row locks.");
Check(!await repository.IsProtectionContextCurrentAsync(context with { Hash = new string('0', 64) }, default), "Changed context must be rejected.");
var agent = await db.AgentRegistrations.AsNoTracking().Include(x => x.FeatureConfiguration).SingleAsync(x => x.Id == agentId);
var evaluationRecord = new PromptEvaluationRecord
{
    Id = Guid.NewGuid(), AgentRegistrationId = agentId, Agent365AgentId = Guid.Parse(agent.Agent365AgentId!), BlueprintId = Guid.Parse(agent.BlueprintId!),
    ExternalInteractionId = $"regression-{Guid.NewGuid():N}", TenantUserObjectId = Guid.NewGuid().ToString(), PromptHashSalt = new byte[32], PromptHash = new byte[32],
    Outcome = PromptEvaluationOutcome.Allowed, PromptShieldDecision = PromptShieldDecisionType.Allowed, PurviewDecision = PurviewDecisionType.PurviewDisabled,
    ProtectionRevision = context.ProtectionRevision, ProtectionContextHash = context.Hash, PromptShieldRequired = context.PromptShieldRequired,
    EvaluatedPurviewPolicyMode = context.PurviewMode, CorrelationId = Guid.NewGuid().ToString(), CreatedAtUtc = DateTime.UtcNow, ExpiresAtUtc = DateTime.UtcNow.AddMinutes(2)
};
await repository.AddAsync(evaluationRecord, default);
await db.SaveChangesAsync();
Check(await repository.TryConsumeAsync(evaluationRecord, context, default), "First receipt consumption must succeed.");
Check(!await repository.TryConsumeAsync(evaluationRecord, context, default), "Receipt must not be consumed twice.");
var telemetry = new PromptShieldTelemetry(new ActivityReceiptRepository(db), new OutboxRepository(db));
var before = await db.OutboxMessages.CountAsync();
await telemetry.EnqueueBlockedAsync(agent, evaluationRecord, default);
await db.SaveChangesAsync();
Check(await db.OutboxMessages.CountAsync() == before, "Allowed evaluations must not enqueue a block signal.");
db.Entry(evaluationRecord).State = EntityState.Detached;
evaluationRecord.Id = Guid.NewGuid(); // Separate detached fixture: do not modify the tracked consumed receipt.
evaluationRecord.Outcome = PromptEvaluationOutcome.Blocked; evaluationRecord.PromptShieldDecision = PromptShieldDecisionType.Blocked;
await telemetry.EnqueueBlockedAsync(agent, evaluationRecord, default);
await db.SaveChangesAsync();
var message = await db.OutboxMessages.SingleAsync(x => x.Payload.Contains(evaluationRecord.Id.ToString()));
using (var payload = JsonDocument.Parse(message.Payload))
    Check(payload.RootElement.GetProperty("PromptEvaluationId").GetGuid() == evaluationRecord.Id && !payload.RootElement.TryGetProperty("Prompt", out _), "Outbox must contain only the evaluation reference.");
Check(await db.ActivityReceipts.AnyAsync(x => x.Id == evaluationRecord.Id && x.ProcessingStatus == ProcessingStatus.Accepted), "Block delivery must have a durable receipt.");
await transaction.RollbackAsync();
Console.WriteLine("PostgreSQL context locks, single-use receipt, and durable block queue checks passed; every write rolled back.");

sealed class FakeTokens : IAgent365ObservabilityTokenProvider
{
    public ValueTask<AccessToken> GetTokenAsync(string agent, string blueprint, string tenant, CancellationToken ct) => ValueTask.FromResult(new AccessToken("test-token", DateTimeOffset.UtcNow.AddMinutes(5)));
}
sealed class ExportCapture : HttpMessageHandler, IHttpClientFactory
{
    public string? Body { get; private set; }
    public HttpClient CreateClient(string name) => new(this, disposeHandler: false);
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        Body = await request.Content!.ReadAsStringAsync(ct);
        return new(HttpStatusCode.OK) { Content = new StringContent("{\"results\":[{\"sinks\":{\"sentinel\":{\"status\":\"sent\"}}},{\"sinks\":{\"sentinel\":{\"status\":\"sent\"}}}]}") };
    }
}
