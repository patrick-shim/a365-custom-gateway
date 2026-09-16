using System.Net;
using System.Text;
using System.Text.Json;

namespace Gateway.ObservabilityRuntime.Tests.Fixtures;

internal sealed class UnexpectedFixtureCallException(string message) : InvalidOperationException(message);

internal sealed record CapturedRequest(
    HttpMethod Method,
    Uri Uri,
    string? AuthorizationScheme,
    string? AuthorizationParameter,
    string? IfNoneMatch,
    string Body)
{
    public JsonElement Json => JsonSerializer.Deserialize<JsonElement>(Body);
}

// A terminal handler, never a delegating handler: there is no socket transport to fall through to.
internal sealed class ScriptedTransport : HttpMessageHandler
{
    private readonly Queue<ExpectedRequest> expected = new();
    public List<CapturedRequest> Requests { get; } = [];

    public void Expect(
        HttpMethod method,
        string absoluteUri,
        HttpStatusCode status,
        string body = "{}",
        string? etag = null,
        Action<CapturedRequest>? inspect = null) =>
        Expect(method, absoluteUri, request =>
        {
            inspect?.Invoke(request);
            var response = new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json")
            };
            if (etag is not null)
                response.Headers.TryAddWithoutValidation("ETag", etag);
            return response;
        });

    public void Expect(HttpMethod method, string absoluteUri, Func<CapturedRequest, HttpResponseMessage> respond) =>
        expected.Enqueue(new(method, new Uri(absoluteUri), respond));

    public HttpClient CreateClient(Uri? baseAddress = null) =>
        new(this, disposeHandler: false) { BaseAddress = baseAddress };

    public void AssertComplete() => Assert.Empty(expected);

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!expected.TryPeek(out var next) || request.Method != next.Method || request.RequestUri != next.Uri)
            throw new UnexpectedFixtureCallException("Unscripted HTTP request: network access is forbidden.");

        expected.Dequeue();
        var captured = new CapturedRequest(
            request.Method,
            request.RequestUri!,
            request.Headers.Authorization?.Scheme,
            request.Headers.Authorization?.Parameter,
            request.Headers.TryGetValues("If-None-Match", out var values) ? values.Single() : null,
            request.Content is null ? string.Empty : await request.Content.ReadAsStringAsync(cancellationToken));
        Requests.Add(captured);
        return next.Respond(captured);
    }

    private sealed record ExpectedRequest(
        HttpMethod Method, Uri Uri, Func<CapturedRequest, HttpResponseMessage> Respond);
}

internal sealed class ClosedHttpClientFactory(
    string allowedName, ScriptedTransport transport, Uri? baseAddress = null) : IHttpClientFactory
{
    public HttpClient CreateClient(string name) =>
        name == allowedName
            ? transport.CreateClient(baseAddress)
            : throw new UnexpectedFixtureCallException("Unregistered HTTP client: network access is forbidden.");
}

internal sealed class FiniteCalls<TRequest, TResult>
{
    private readonly Queue<Func<TRequest, TResult>> expected = new();
    public List<TRequest> Requests { get; } = [];
    public void Expect(Func<TRequest, TResult> respond) => expected.Enqueue(respond);
    public TResult Invoke(TRequest request)
    {
        if (!expected.TryDequeue(out var respond))
            throw new UnexpectedFixtureCallException("An unscripted provider or credential call was attempted.");
        Requests.Add(request);
        return respond(request);
    }
    public void AssertComplete() => Assert.Empty(expected);
}
