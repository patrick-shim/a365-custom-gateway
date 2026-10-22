using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using Gateway.Agent365;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;

internal static class RegistryThrottlingTests
{
    public static async Task RunAsync()
    {
        var registration = Guid.NewGuid();
        var identity = Guid.NewGuid();
        var blueprint = Guid.NewGuid();
        var owner = Guid.NewGuid();
        var request = new Agent365DelegatedRegistryRequest(
            Guid.NewGuid(), registration, "Agent", null, "external-agent", owner,
            owner, identity, blueprint, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
        var transport = new Handler(registration, identity, blueprint, owner);
        using var http = new HttpClient(transport) { BaseAddress = new Uri("https://graph.microsoft.com/") };
        var client = new DelegatedAgent365RegistryClient(
            http, new Token(), "gateway", Guid.NewGuid().ToString("D"),
            [TimeSpan.Zero, TimeSpan.Zero]);

        var elapsed = Stopwatch.StartNew();
        await client.VerifyAsync(registration.ToString("D"), request, CancellationToken.None);
        elapsed.Stop();

        if (transport.Reads != 2 || elapsed.Elapsed < TimeSpan.FromMilliseconds(35))
            throw new Exception("Registry verification did not honor Retry-After before exact-ID readback.");

        Console.WriteLine("Registry verification honors provider Retry-After guidance.");
    }

    private sealed class Token : IAgent365DelegatedTokenProvider
    {
        public Task<string> GetTokenAsync(CancellationToken cancellationToken) =>
            Task.FromResult("test-only");
    }

    private sealed class Handler(
        Guid registration,
        Guid identity,
        Guid blueprint,
        Guid owner) : HttpMessageHandler
    {
        public int Reads { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Reads++;
            if (Reads == 1)
            {
                var throttled = new HttpResponseMessage(HttpStatusCode.TooManyRequests);
                throttled.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(
                    TimeSpan.FromMilliseconds(50));
                return Task.FromResult(throttled);
            }

            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new
                {
                    id = registration,
                    sourceAgentId = "external-agent",
                    agentIdentityId = identity,
                    agentIdentityBlueprintId = blueprint,
                    ownerIds = new[] { owner },
                    createdBy = owner
                })
            });
        }
    }
}
