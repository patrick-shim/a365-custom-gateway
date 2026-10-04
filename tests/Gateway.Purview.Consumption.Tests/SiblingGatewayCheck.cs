using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Gateway.Domain.Entities;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Security;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

static class SiblingGatewayCheck
{
    public static async Task RunAsync()
    {
        if (Environment.GetEnvironmentVariable("GATEWAY_SIBLING_API_TEST") != "true") return;
        var id = Guid.Parse(Environment.GetEnvironmentVariable("GATEWAY_SIBLING_ID")!);
        var actor = Guid.Parse(Environment.GetEnvironmentVariable("GATEWAY_TEST_USER")!).ToString();
        var expectedBlueprint = Environment.GetEnvironmentVariable("GATEWAY_TEST_BLUEPRINT");
        var evidence = Environment.GetEnvironmentVariable("GATEWAY_SIBLING_EVIDENCE")!;
        if (File.Exists(evidence)) throw new Exception("Evidence already exists.");
        await using var db = new GatewayDbContext(new DbContextOptionsBuilder<GatewayDbContext>().UseNpgsql(Environment.GetEnvironmentVariable("GATEWAY_TEST_DB"))
            .AddInterceptors(new PostgresRowVersionInterceptor()).Options);
        var agent = await db.AgentRegistrations.Include(x => x.FeatureConfiguration).SingleAsync(x => x.Id == id);
        if (agent.IsDeleted || agent.BlueprintId != expectedBlueprint || agent.FeatureConfiguration.PurviewEnabled ||
            !await db.AgentIngressCredentials.AnyAsync(x => x.AgentRegistrationId == id && x.RevokedAtUtc == null && x.ExpiresAtUtc > DateTime.UtcNow))
            throw new Exception("Control agent or original credential precondition failed.");
        var credentials = new AgentIngressCredentialService(db, Options.Create(new AgentIngressCredentialOptions()));
        var issued = credentials.Issue(id, actor, DateTime.UtcNow);
        issued.Credential.ExpiresAtUtc = DateTime.UtcNow.AddMinutes(5);
        db.AuditEvents.Add(new AuditEvent { Id=Guid.NewGuid(), AgentRegistrationId=id, EventType="GatewayCredentialIssued", PerformedByObjectId=actor,
            OccurredAtUtc=DateTime.UtcNow, Details=JsonSerializer.Serialize(new { credentialId=issued.Credential.Id, purpose="Temporary sibling API verification", issued.Credential.ExpiresAtUtc }) });
        await db.SaveChangesAsync();
        var results = new List<object>();
        try
        {
            using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect=false }) { BaseAddress=new Uri("http://127.0.0.1:5080/"), Timeout=TimeSpan.FromSeconds(120) };
            http.DefaultRequestHeaders.Authorization=new AuthenticationHeaderValue("Bearer", issued.ApiKey);
            foreach (var sample in new[] { ("normal", "Suggest three ways to organize a project meeting."), ("synthetic-sensitive", "Test credit card number: 4532 6677 8521 3500. This is synthetic data for DLP validation.") })
            {
                using var request = new HttpRequestMessage(HttpMethod.Post,"api/v1/prompts:evaluate") { Content=JsonContent.Create(new {
                    externalAgentId=agent.ExternalAgentId.Value, interactionId="sibling-dlp-"+Guid.NewGuid(), occurredAtUtc=DateTime.UtcNow,
                    userContext=new { tenantUserObjectId=actor }, prompt=new { contentType="text/plain", content=sample.Item2 } }) };
                request.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString());
                using var response=await http.SendAsync(request);
                var body=JsonSerializer.Deserialize<JsonElement>(await response.Content.ReadAsStringAsync());
                results.Add(new { sample=sample.Item1, status=(int)response.StatusCode, body });
                Console.WriteLine($"Sibling {sample.Item1}: HTTP {(int)response.StatusCode}.");
                if (response.StatusCode != System.Net.HttpStatusCode.OK || !body.GetProperty("allowed").GetBoolean() || body.GetProperty("purviewProcessing").GetString() != "PurviewDisabled")
                    throw new Exception("Sibling API control failed.");
            }
        }
        finally
        {
            var revoked=await credentials.RevokeAsync(id,issued.Credential.Id,DateTime.UtcNow,default);
            if (revoked.Status != Gateway.Domain.Models.AgentIngressCredentialRevocationStatus.Revoked) throw new Exception("Temporary control credential revocation failed.");
            db.AuditEvents.Add(new AuditEvent { Id=Guid.NewGuid(), AgentRegistrationId=id, EventType="GatewayCredentialRevoked", PerformedByObjectId=actor,
                OccurredAtUtc=DateTime.UtcNow, Details=JsonSerializer.Serialize(new { credentialId=issued.Credential.Id, purpose="Sibling verification completed" }) });
            await db.SaveChangesAsync();
            var clean=await credentials.ValidateAsync(issued.ApiKey,DateTime.UtcNow,default) is null;
            await File.WriteAllTextAsync(evidence,JsonSerializer.Serialize(new { at=DateTime.UtcNow, agentId=id, childId=agent.Agent365AgentId, blueprint=agent.BlueprintId,
                controlPurviewEnabled=false, results, temporaryCredentialRevoked=clean, modelCalled=false },new JsonSerializerOptions { WriteIndented=true }));
            if (!clean) throw new Exception("Revoked control credential remained usable.");
        }
    }
}
