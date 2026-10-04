using System.Net;
using System.Net.Http.Json;
using Azure.Core;
using Gateway.Agent365;

internal static class RuntimeBlueprintCredentialTests
{
    internal static async Task RunAsync()
    {
        foreach (var (code, fresh, expected) in new[] { (7000215, true, true), (7000215, false, false), (700226, true, false), (70021, false, true) })
        {
            using var response = new HttpResponseMessage(HttpStatusCode.Unauthorized) {
                Content = JsonContent.Create(new { error = "invalid_client", error_codes = new[] { code } }) };
            if (await AgentIdentityTokenProvider.IsCredentialPropagationErrorAsync(response, fresh, default) != expected)
                throw new Exception("Fresh-secret propagation classification widened to a permanent credential failure.");
        }
        var tenant = Guid.NewGuid();
        var blueprint = Guid.NewGuid();
        var directory = Path.Combine(Path.GetTempPath(), "gateway-credential-test-" + Guid.NewGuid().ToString("N"));
        var handler = new CredentialGraphHandler(blueprint);
        var graph = new MicrosoftGraphProvisioningClient(new HttpClient(handler)
            { BaseAddress = MicrosoftGraphProvisioningClient.OfficialBaseAddress }, new FakeGraphToken());
        try
        {
            await RuntimeBlueprintCredentialStore.EnsureAsync(directory, tenant, blueprint, blueprint, true, graph, default);
            var stored = RuntimeBlueprintCredentialStore.Read(directory, tenant, blueprint);
            if (stored?.KeyId != handler.KeyId || stored.Secret != "synthetic-blueprint-secret" || handler.Creates != 1)
                throw new Exception("Exact blueprint credential was not persisted.");
            await RuntimeBlueprintCredentialStore.EnsureAsync(directory, tenant, blueprint, blueprint, false, graph, default);
            if (handler.Creates != 1) throw new Exception("Credential reconciliation rotated the secret.");
            if (RuntimeBlueprintCredentialStore.Read(directory, tenant, Guid.NewGuid()) is not null)
                throw new Exception("A sibling blueprint inherited another credential.");
            handler.KeyId = Guid.NewGuid();
            await MustReject(() => RuntimeBlueprintCredentialStore.EnsureAsync(directory, tenant, blueprint, blueprint, true, graph, default));
            if (handler.Creates != 1) throw new Exception("Mismatched credential was overwritten.");
            // Missing local secret after a previous server write must require repair.
            var missingDirectory = Path.Combine(directory, "missing");
            await MustReject(() => RuntimeBlueprintCredentialStore.EnsureAsync(missingDirectory, tenant, blueprint, blueprint, true, graph, default));
            if (handler.Creates != 1) throw new Exception("Lost one-time secret was silently rotated.");
            handler.Exists = false;
            await MustReject(() => RuntimeBlueprintCredentialStore.EnsureAsync(missingDirectory, tenant, blueprint, blueprint, false, graph, default));
            if (handler.Creates != 1) throw new Exception("Selected external blueprint received an unapproved credential.");
        }
        finally
        {
            foreach (var child in Directory.GetDirectories(directory))
            {
                foreach (var file in Directory.GetFiles(child)) File.Delete(file);
                Directory.Delete(child);
            }
            foreach (var file in Directory.GetFiles(directory)) File.Delete(file);
            Directory.Delete(directory);
        }
        Console.WriteLine("Runtime blueprint credential creation, exact readback, sibling isolation, no-rotation and selected-blueprint boundaries passed.");
    }

    private static async Task MustReject(Func<Task> action)
    {
        try { await action(); }
        catch (Agent365ObservabilityConfigurationException) { return; }
        throw new Exception("An unsafe credential state was accepted.");
    }

    private sealed class FakeGraphToken : IAgent365ProvisioningTokenProvider
    {
        public ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken) =>
            ValueTask.FromResult(new AccessToken("synthetic-token", DateTimeOffset.UtcNow.AddHours(1)));
    }
    private sealed class CredentialGraphHandler(Guid blueprint) : HttpMessageHandler
    {
        internal Guid KeyId = Guid.NewGuid();
        internal bool Exists;
        internal int Creates;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var credential = new GraphPasswordCredential { KeyId = KeyId, DisplayName = "a365gw-runtime-runtime",
                EndDateTime = DateTimeOffset.UtcNow.AddYears(1), SecretText = "synthetic-blueprint-secret" };
            if (request.Method == HttpMethod.Post)
            {
                if (request.RequestUri!.AbsolutePath != $"/v1.0/applications/{blueprint:D}/addPassword")
                    throw new Exception("Unexpected credential endpoint.");
                Creates++; Exists = true;
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(credential) });
            }
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new GraphApplication {
                Id = blueprint.ToString("D"), AppId = blueprint.ToString("D"),
                PasswordCredentials = Exists ? [credential with { SecretText = null }] : [] }) });
        }
    }
}
