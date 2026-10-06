using System.Net;
using System.Text;
using System.Text.Json;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Gateway.Agent365;
using Gateway.Domain.Models;
using Gateway.Purview;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
await IndividualAssignmentChecks.RunAsync();
await IndividualBindingChecks.RunAsync();
await SiblingGatewayCheck.RunAsync();
// Missing identity must fail before a token request or Graph HTTP call.
using (var forbiddenTransport = new TokenEndpoint(Guid.NewGuid()))
{
    var graph = new PurviewGraphClient(forbiddenTransport);
    try
    {
        await graph.PostAsync("processContent", "users/test/dataSecurityAndGovernance/processContent",
            new System.Text.Json.Nodes.JsonObject(), null, default);
        throw new Exception("Purview accepted evaluation without an individual identity.");
    }
    catch (PurviewPolicyException failure) when (failure.FailureCode == "PURVIEW_AGENT_IDENTITY_REQUIRED") { }
    Check(forbiddenTransport.ResourceRequests.Count == 0, "Missing identity attempted fallback authentication.");
}
var tenant = Guid.NewGuid();
var blueprint = Guid.NewGuid();
var first = Guid.NewGuid();
var sibling = Guid.NewGuid();
var good = new PurviewExistingPolicy(Guid.NewGuid(), "Existing policy", "Enable", ["Application"], [first], true, new string('a', 64));
var snapshot = new PurviewPolicyCatalog(tenant, DateTimeOffset.UtcNow, [good]);
using var signingKey = RSA.Create(2048);
using var signingCertificate = new CertificateRequest("CN=catalog-test", signingKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)
    .CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddDays(1));
var signedCatalog = PurviewCatalogSignature.Sign(snapshot, signingCertificate);
Check(PurviewCatalogSignature.Verify(signedCatalog, signingCertificate, tenant).Items[0].Id == good.Id, "Signed catalog rejected.");
try { PurviewCatalogSignature.Verify(signedCatalog with { Payload = Convert.ToBase64String(Encoding.UTF8.GetBytes("{}")) }, signingCertificate, tenant); throw new Exception("Tampered catalog accepted."); }
catch (CryptographicException) { }
try { PurviewCatalogSignature.Verify(signedCatalog, signingCertificate, Guid.NewGuid()); throw new Exception("Wrong tenant signature accepted."); }
catch (PurviewPolicyException failure) when (failure.FailureCode == "PURVIEW_POLICY_CATALOG_INVALID") { }
using var otherKey = RSA.Create(2048);
using var otherCertificate = new CertificateRequest("CN=untrusted", otherKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)
    .CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddDays(1));
try { PurviewCatalogSignature.Verify(signedCatalog, otherCertificate, tenant); throw new Exception("Untrusted publisher accepted."); }
catch (CryptographicException) { }
PurviewPolicyCatalogValidation.Validate(snapshot, tenant);
Check(PurviewPolicyCatalogValidation.Incompatibility(good) is null, "Compatible existing policy rejected.");
foreach (var policy in new[] { good with { Mode = "Disable" }, good with { Mode = "TestWithoutNotifications" }, good with { EnforcementPlanes = ["CopilotExperiences"] }, good with { HasUploadTextBlock = false } })
    Check(PurviewPolicyCatalogValidation.Incompatibility(policy) is not null, "Unsupported policy accepted for blocking.");
foreach (var invalid in new[] { snapshot with { TenantId = Guid.NewGuid() }, snapshot with { RetrievedAtUtc = DateTimeOffset.UtcNow.Subtract(PurviewPolicyCatalogValidation.MaximumAge).AddSeconds(-1) }, snapshot with { Items = [good, good] }, snapshot with { Items = [null!] }, snapshot with { Items = [good with { Revision = "unversioned" }] } })
{
    try { PurviewPolicyCatalogValidation.Validate(invalid, tenant); throw new Exception("Untrusted catalog accepted."); }
    catch (PurviewPolicyException failure) when (failure.FailureCode == "PURVIEW_POLICY_CATALOG_INVALID") { }
}
var unconfigured = new RuntimePurviewCatalogClient(Options.Create(new RuntimePurviewCatalogOptions()));
try { await unconfigured.ReadAsync(tenant, default); throw new Exception("Unconfigured catalog accepted."); }
catch (PurviewPolicyException failure) when (failure.FailureCode == "PURVIEW_POLICY_CATALOG_SETUP_REQUIRED") { }

var fake = new TokenEndpoint(tenant);
var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?> { [$"Agent365:BlueprintClientSecrets:{blueprint}"] = "test-only-secret" }).Build();
var services = new ServiceCollection().AddLogging();
services.AddAgent365Services(configuration);
services.AddSingleton<IHttpClientFactory>(fake);
using var provider = services.BuildServiceProvider();
var purview = provider.GetRequiredService<IAgent365PurviewTokenProvider>();
var otel = provider.GetRequiredService<IAgent365ObservabilityTokenProvider>();
await purview.GetPurviewTokenAsync(first.ToString(), blueprint.ToString(), tenant.ToString(), default);
await purview.GetPurviewTokenAsync(sibling.ToString(), blueprint.ToString(), tenant.ToString(), default);
await otel.GetTokenAsync(first.ToString(), blueprint.ToString(), tenant.ToString(), default);
Check(fake.ResourceRequests.Count == 3, "Resource or sibling token cache collided.");
Check(fake.ResourceRequests[0] == (first.ToString(), "https://graph.microsoft.com/.default") &&
    fake.ResourceRequests[1] == (sibling.ToString(), "https://graph.microsoft.com/.default"), "Purview token must use exact child identity.");
await purview.GetPurviewTokenAsync(first.ToString(), blueprint.ToString(), tenant.ToString(), default);
Check(fake.ResourceRequests.Count == 3, "Same valid token was not cached.");
fake.InvalidRole = true;
try { await purview.GetPurviewTokenAsync(Guid.NewGuid().ToString(), blueprint.ToString(), tenant.ToString(), default); throw new Exception("Missing roles accepted."); }
catch (Agent365ObservabilityConfigurationException failure) when (failure.Code == "MissingPurviewRoles") { }
fake.InvalidRole = false;
fake.WrongChild = true;
try { await purview.GetPurviewTokenAsync(Guid.NewGuid().ToString(), blueprint.ToString(), tenant.ToString(), default); throw new Exception("Wrong child token accepted."); }
catch (Agent365ObservabilityConfigurationException failure) when (failure.Code == "AgentIdentityMismatch") { }
Console.WriteLine("Catalog freshness/tenant/compatibility, child/resource token isolation checks passed (no network).");

if (args.Length == 1)
{
    var live = JsonSerializer.Deserialize<PurviewPolicyCatalog>(File.ReadAllText(args[0]), PurviewCatalogJson.Options)!;
    PurviewPolicyCatalogValidation.Validate(live, Guid.Parse("ff8b1e46-ff0f-4bc2-ab02-caf2b92da496"));
    Console.WriteLine($"Live provider catalog validated: {live.Items.Count} policies; {live.Items.Count(x => PurviewPolicyCatalogValidation.Incompatibility(x) is null)} compatible candidates.");
}

sealed class TokenEndpoint(Guid tenant) : HttpMessageHandler, IHttpClientFactory
{
    public List<(string Child, string Scope)> ResourceRequests { get; } = [];
    public bool InvalidRole { get; set; }
    public bool WrongChild { get; set; }
    public HttpClient CreateClient(string name) => new(this, false);
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var form = (await request.Content!.ReadAsStringAsync(ct)).Split('&').Select(x => x.Split('=', 2)).ToDictionary(x => Uri.UnescapeDataString(x[0]), x => Uri.UnescapeDataString(x[1].Replace('+',' ')));
        var token = "test-blueprint-assertion";
        if (!form.ContainsKey("fmi_path"))
        {
            ResourceRequests.Add((form["client_id"], form["scope"]));
            var graph = form["scope"] == "https://graph.microsoft.com/.default";
            var roles = graph ? new[] { "Content.Process.User", "ProtectionScopes.Compute.User" } : new[] { "Agent365.Observability.OtelWrite" };
            var payload = new { aud = graph ? "00000003-0000-0000-c000-000000000000" : "9b975845-388f-4429-889e-eab1ef63949c", tid = tenant.ToString(), appid = WrongChild ? Guid.NewGuid().ToString() : form["client_id"], roles = InvalidRole ? [] : roles, exp = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds() };
            token = "test." + Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload))).TrimEnd('=').Replace('+','-').Replace('/','_') + ".test";
        }
        return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { access_token = token, expires_in = 3600 })) };
    }
}
