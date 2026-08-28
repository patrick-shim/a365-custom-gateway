using System.Net.Http.Headers;

namespace Gateway.AdminUi.Tests.Infrastructure;

internal sealed record RecordedRequest(
    HttpMethod Method,
    Uri Uri,
    IReadOnlyDictionary<string, string[]> Headers,
    string? Body)
{
    public string? Header(string name) =>
        Headers.TryGetValue(name, out var values) ? values.SingleOrDefault() : null;
}

internal sealed class RecordingHttpMessageHandler(
    Func<RecordedRequest, HttpResponseMessage> responder) : HttpMessageHandler
{
    private readonly Func<RecordedRequest, HttpResponseMessage> _responder = responder;

    public List<RecordedRequest> Requests { get; } = [];

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        var headers = request.Headers
            .Concat(request.Content?.Headers ?? Enumerable.Empty<KeyValuePair<string, IEnumerable<string>>>())
            .ToDictionary(
                pair => pair.Key,
                pair => pair.Value.ToArray(),
                StringComparer.OrdinalIgnoreCase);

        var body = request.Content is null
            ? null
            : await request.Content.ReadAsStringAsync(cancellationToken);

        var recorded = new RecordedRequest(
            request.Method,
            request.RequestUri ?? throw new InvalidOperationException("The request URI was not set."),
            headers,
            body);

        Requests.Add(recorded);
        return _responder(recorded);
    }

    public static HttpResponseMessage JsonResponse(
        string json,
        System.Net.HttpStatusCode statusCode = System.Net.HttpStatusCode.OK) =>
        new(statusCode)
        {
            Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json")
        };
}
