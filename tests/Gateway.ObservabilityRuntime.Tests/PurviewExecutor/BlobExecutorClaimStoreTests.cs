using Gateway.Purview;
using Gateway.Purview.Executor;
using System.Net;
using System.Text;
using System.Text.Json;
using Azure.Core.Pipeline;
using Azure.Storage.Blobs;

namespace Gateway.ObservabilityRuntime.Tests.PurviewExecutor;

public sealed class BlobExecutorClaimStoreTests
{
    [Fact]
    public async Task Create_UsesAtomicIfNoneMatch()
    {
        using var handler = new FakeHandler(request =>
        {
            Assert.Equal(HttpMethod.Put, request.Method);
            Assert.Equal("*", Assert.Single(request.Headers.GetValues("If-None-Match")));
            return Response(HttpStatusCode.Created);
        });
        Assert.True(await Store(handler).TryCreateAsync("claim.json", Claim(), default));
    }

    [Fact]
    public async Task Complete_UsesObservedETag()
    {
        var claim = Claim();
        var calls = 0;
        using var handler = new FakeHandler(request =>
        {
            calls++;
            if (request.Method == HttpMethod.Get)
                return Response(HttpStatusCode.OK, JsonSerializer.Serialize(claim, new JsonSerializerOptions(JsonSerializerDefaults.Web)));
            Assert.Equal("\"claim-etag\"", Assert.Single(request.Headers.GetValues("If-Match")));
            return Response(HttpStatusCode.Created);
        });
        await Store(handler).CompleteAsync("claim.json", claim, default);
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task Complete_RejectsChangedClaimBeforeWrite()
    {
        using var handler = new FakeHandler(request =>
        {
            Assert.Equal(HttpMethod.Get, request.Method);
            return Response(HttpStatusCode.OK, JsonSerializer.Serialize(Claim() with { InputHash = new string('b', 64) },
                new JsonSerializerOptions(JsonSerializerDefaults.Web)));
        });
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            Store(handler).CompleteAsync("claim.json", Claim(), default));
    }

    [Fact]
    public async Task OversizedClaim_IsRejected()
    {
        using var handler = new FakeHandler(_ => Response(HttpStatusCode.OK, new string(' ', 5000)));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store(handler).ReadAsync("claim.json", default));
    }

    private static ExecutorClaim Claim() => new(new string('a', 64), ExecutorClaimState.Started,
        new DateTimeOffset(2026, 9, 6, 0, 0, 0, TimeSpan.Zero));

    private static BlobExecutorClaimStore Store(HttpMessageHandler handler)
    {
        var options = new BlobClientOptions { Transport = new HttpClientTransport(new HttpClient(handler)) };
        options.Retry.MaxRetries = 0;
        options.Diagnostics.IsLoggingEnabled = false;
        return new BlobExecutorClaimStore(new BlobContainerClient(
            new Uri("https://unit.invalid/executor-claims"), options));
    }

    private static HttpResponseMessage Response(HttpStatusCode code, string body = "")
    {
        var response = new HttpResponseMessage(code) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        response.Headers.TryAddWithoutValidation("ETag", "\"claim-etag\"");
        response.Headers.TryAddWithoutValidation("Last-Modified", "Sun, 06 Sep 2026 00:00:00 GMT");
        response.Headers.TryAddWithoutValidation("x-ms-request-id", Guid.NewGuid().ToString("D"));
        return response;
    }

    private sealed class FakeHandler(Func<HttpRequestMessage, HttpResponseMessage> callback) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(callback(request));
    }
}
