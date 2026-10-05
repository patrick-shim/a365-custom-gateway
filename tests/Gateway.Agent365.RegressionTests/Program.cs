using System.Net;
using System.Reflection;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Gateway.Agent365;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

await RegistryDeletionTests.RunAsync();
await AgentDeletionTests.RunAsync();

const string first = "10000000-0000-0000-0000-000000000001";
const string second = "10000000-0000-0000-0000-000000000002";
const string unmapped = "10000000-0000-0000-0000-000000000003";
const string agent = "20000000-0000-0000-0000-000000000001";
const string tenant = "30000000-0000-0000-0000-000000000001";
var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> {
    [$"Agent365:BlueprintClientSecrets:{first}"] = "test-first",
    [$"Agent365:BlueprintClientSecrets:{second}"] = "test-second"
}).Build();
var capture = new CaptureFactory();
var services = new ServiceCollection();
services.AddLogging();
services.AddAgent365Services(configuration);
services.AddSingleton<IHttpClientFactory>(capture);
using var provider = services.BuildServiceProvider();
var tokens = provider.GetRequiredService<IAgent365ObservabilityTokenProvider>();
foreach (var (blueprint, expected) in new[] { (first, "test-first"), (second, "test-second") }) {
    try {
        await tokens.GetTokenAsync(agent, blueprint, tenant, CancellationToken.None);
        throw new Exception("The fake token endpoint must reject token acquisition.");
    } catch (Agent365ObservabilityConfigurationException exception) when (exception.Code == "BlueprintTokenHttp400") { }
    if (capture.Form?["client_secret"] != expected || capture.Form["client_id"] != blueprint || capture.Form["fmi_path"] != agent)
        throw new Exception("FMI must use only the credential selected for the requested blueprint.");
}
capture.Form = null;
try {
    await tokens.GetTokenAsync(agent, unmapped, tenant, CancellationToken.None);
    throw new Exception("An unmapped blueprint must fail before contacting the token endpoint.");
} catch (Agent365ObservabilityConfigurationException exception) when (exception.Code == "MissingRuntimeBlueprintCredential") { }
if (capture.Form is not null) throw new Exception("Missing blueprint credentials reached the token endpoint.");
configuration[$"Agent365:BlueprintClientSecrets:{second}"] = "";
var invalidServices = new ServiceCollection();
invalidServices.AddLogging();
invalidServices.AddAgent365Services(configuration);
using var invalidProvider = invalidServices.BuildServiceProvider();
try {
    invalidProvider.GetRequiredService<IAgent365ObservabilityTokenProvider>();
    throw new Exception("An empty scoped credential must fail configuration validation.");
} catch (Agent365ObservabilityConfigurationException exception) when (exception.Code == "EmptyBlueprintCredential") { }
Console.WriteLine("Blueprint credential selection regression checks passed (no network calls).");
await RuntimeBlueprintCredentialTests.RunAsync();

sealed class CaptureFactory : IHttpClientFactory {
    public Dictionary<string, string>? Form { get; set; }
    public HttpClient CreateClient(string name) => new(new CaptureHandler(this));
}
sealed class CaptureHandler(CaptureFactory owner) : HttpMessageHandler {
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
        var body = await request.Content!.ReadAsStringAsync(cancellationToken);
        owner.Form = body.Split('&').Select(pair => pair.Split('=', 2)).ToDictionary(
            pair => Uri.UnescapeDataString(pair[0]), pair => Uri.UnescapeDataString(pair[1].Replace('+', ' ')));
        return new HttpResponseMessage(HttpStatusCode.BadRequest) { Content = new StringContent("{\"error\":\"invalid_client\"}") };
    }
}
