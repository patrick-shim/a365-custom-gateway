using System.Net;
using System.Net.Http.Json;
using Gateway.Agent365;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;

internal static class RegistryDeletionTests
{
    public static async Task RunAsync()
    {
        var registration = Guid.NewGuid(); var identity = Guid.NewGuid(); var blueprint = Guid.NewGuid();
        foreach (var mode in new[] { "success", "absent", "mismatch", "forbidden", "transient" })
        {
            var transport = new Handler(registration, identity, blueprint, mode);
            using var http = new HttpClient(transport) { BaseAddress = new Uri("https://graph.microsoft.com/") };
            var client = new DelegatedAgent365RegistryClient(http, new Token(), "gateway", Guid.NewGuid().ToString());
            try
            {
                await client.DeleteAsync(registration, identity, blueprint, CancellationToken.None);
                if (mode is "mismatch" or "forbidden") throw new Exception("Unsafe deletion accepted.");
            }
            catch (Agent365DelegatedRegistryException) when (mode is "mismatch" or "forbidden") { }
            var expected = mode is "success" or "transient" ? 1 : 0;
            if (transport.Deletes != expected) throw new Exception($"Unexpected DELETE count for {mode}.");
            if (expected == 1 && !transport.VerifiedAbsent) throw new Exception("Deletion was not verified.");
        }
        Console.WriteLine("Registry deletion: exact-ID mapping, absence readback, transient retry and authorization boundaries passed.");
    }
    private sealed class Token : IAgent365DelegatedTokenProvider
    { public Task<string> GetTokenAsync(CancellationToken ct) => Task.FromResult("test-only"); }
    private sealed class Handler(Guid registration, Guid identity, Guid blueprint, string mode) : HttpMessageHandler
    {
        public int Deletes; public bool VerifiedAbsent; private int reads;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            if (request.RequestUri!.AbsolutePath != $"/beta/copilot/agentRegistrations/{registration:D}") throw new Exception("Wrong Registry identifier.");
            if (request.Method == HttpMethod.Delete) { Deletes++; return Task.FromResult(new HttpResponseMessage(HttpStatusCode.NoContent)); }
            reads++;
            var status = mode == "forbidden" ? HttpStatusCode.Forbidden : mode == "absent" || Deletes > 0 ? HttpStatusCode.NotFound
                : mode == "transient" && reads == 1 ? HttpStatusCode.ServiceUnavailable : HttpStatusCode.OK;
            if (status == HttpStatusCode.NotFound) VerifiedAbsent = true;
            return Task.FromResult(new HttpResponseMessage(status) { Content = JsonContent.Create(new {
                id = registration, agentIdentityId = mode == "mismatch" ? Guid.NewGuid() : identity, agentIdentityBlueprintId = blueprint
            }) });
        }
    }
}
