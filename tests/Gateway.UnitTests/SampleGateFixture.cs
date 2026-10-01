using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ExternalAgent.Sample;
using Gateway.TestSupport;

namespace Gateway.UnitTests;

internal sealed record SampleRequest(Uri Uri, JsonElement Body, string IdempotencyKey);

internal sealed class SampleGateFixture : IDisposable
{
    internal const string EvaluationPath = "api/v1/prompts:evaluate";
    internal const string ActivityPath = "api/v1/agent-activities";
    internal const string InteractionPath = "api/v1/ai-interactions";
    internal const string PrivateDetail = "SYNTHETIC-DEPENDENCY-DETAIL-NOT-FOR-OUTPUT";
    internal const string GeneratedResponse = "Synthetic response\r\nwith exact whitespace. ";
    internal static readonly string SyntheticKey = $"a365gw_v1_{new string('a', 32)}.{new string('b', 43)}";

    private readonly Queue<(Uri Uri, Func<SampleRequest, HttpResponseMessage> Respond)> expected = new();
    private readonly OfflineHttpHandler transport;
    private readonly HttpClient client;
    private Exception? fixtureFailure;

    internal SampleGateFixture()
    {
        transport = new OfflineHttpHandler { MaximumCalls = 3, Respond = RespondAsync };
        client = new HttpClient(transport, disposeHandler: false) { BaseAddress = Options.ApiBaseUrl };
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", SyntheticKey);
    }

    internal Arguments Options { get; } = new(
        new Uri("https://sample-gate.invalid/gateway/"),
        "synthetic-child-agent",
        Guid.Parse(TestData.TenantUser),
        "Synthetic café prompt\r\nwith exact whitespace. ");
    internal SampleClock Clock { get; } = new(new FixedTimeProvider(TestData.Now));
    internal Guid ProofId { get; } = Guid.NewGuid();
    internal DateTimeOffset Deadline => new DateTimeOffset(TestData.Now).AddMinutes(5);
    internal StringWriter Output { get; } = new();
    internal StringWriter Error { get; } = new();
    internal List<SampleRequest> Requests { get; } = [];
    internal List<string> Sequence { get; } = [];
    internal List<string> ModelPrompts { get; } = [];

    internal void Expect(string path, Func<SampleRequest, HttpResponseMessage> respond) =>
        expected.Enqueue((new Uri(Options.ApiBaseUrl, path), respond));

    internal void ExpectEvaluation(Action<JsonObject>? change = null) =>
        Expect(EvaluationPath, request =>
        {
            var body = EvaluationBody(request);
            change?.Invoke(body);
            return JsonResponse(body, HttpStatusCode.OK);
        });

    internal void ExpectActivity(Action<JsonObject>? change = null, Action? beforeResponse = null) =>
        Expect(ActivityPath, request =>
        {
            var body = ActivityBody(request);
            change?.Invoke(body);
            beforeResponse?.Invoke();
            return JsonResponse(body);
        });

    internal void ExpectInteraction(Action<JsonObject>? change = null) =>
        Expect(InteractionPath, request =>
        {
            var body = InteractionBody(request);
            change?.Invoke(body);
            return JsonResponse(body);
        });

    internal JsonObject EvaluationBody(SampleRequest request) => new()
    {
        ["evaluationId"] = ProofId,
        ["evaluationReceiptId"] = ProofId,
        ["interactionId"] = request.Body.GetProperty("interactionId").GetString(),
        ["allowed"] = true,
        ["decision"] = "PROMPT_ALLOWED",
        ["promptShieldProcessing"] = "Allowed",
        ["purviewProcessing"] = "PurviewDisabled",
        ["expiresAtUtc"] = Deadline.ToString("O"),
        ["userMessage"] = PrivateDetail,
        ["correlationId"] = Guid.NewGuid().ToString("D")
    };

    internal JsonObject ActivityBody(SampleRequest request) => new()
    {
        ["receiptId"] = Guid.NewGuid(),
        ["activityId"] = request.Body.GetProperty("activityId").GetString(),
        ["status"] = "Accepted",
        ["receivedAtUtc"] = Clock.GetUtcNow().ToString("O"),
        ["correlationId"] = Guid.NewGuid().ToString("D")
    };

    internal static JsonObject InteractionBody(SampleRequest request) => new()
    {
        ["receiptId"] = Guid.NewGuid(),
        ["interactionId"] = request.Body.GetProperty("interactionId").GetString(),
        ["status"] = "Accepted",
        ["purviewProcessing"] = "PurviewDisabled",
        ["observabilityProcessing"] = "Queued",
        ["correlationId"] = Guid.NewGuid().ToString("D")
    };

    internal Task<int> RunAsync(
        Func<string, CancellationToken, Task<string>>? model = null,
        CancellationToken cancellationToken = default) =>
        SampleInteractionRunner.RunAsync(client, Options, (prompt, token) =>
        {
            Sequence.Add("model");
            ModelPrompts.Add(prompt);
            return model?.Invoke(prompt, token) ?? Task.FromResult(GeneratedResponse);
        }, Output, Error, cancellationToken, Clock);

    internal void AssertCalls(int evaluations, int activities, int models, int interactions)
    {
        Assert.Null(fixtureFailure);
        Assert.Empty(expected);
        Assert.Equal(evaluations + activities + interactions, transport.Calls);
        Assert.Equal(evaluations, Requests.Count(request => request.Uri == new Uri(Options.ApiBaseUrl, EvaluationPath)));
        Assert.Equal(activities, Requests.Count(request => request.Uri == new Uri(Options.ApiBaseUrl, ActivityPath)));
        Assert.Equal(interactions, Requests.Count(request => request.Uri == new Uri(Options.ApiBaseUrl, InteractionPath)));
        Assert.Equal(models, ModelPrompts.Count);
        Assert.Equal(Requests.Count, Requests.Select(request => request.IdempotencyKey).Distinct().Count());
        foreach (var request in Requests)
        {
            Assert.True(Guid.TryParseExact(request.IdempotencyKey, "D", out _));
            Assert.Equal('4', request.IdempotencyKey[14]);
            Assert.Contains(request.IdempotencyKey[19], "89ab");
        }
        var displayed = Output.ToString() + Error;
        Assert.DoesNotContain(PrivateDetail, displayed);
        Assert.DoesNotContain(SyntheticKey, displayed);
        Assert.DoesNotContain(Options.Message, displayed);
        Assert.DoesNotContain(GeneratedResponse, displayed);
    }

    internal void AssertMatchingSubmission()
    {
        var evaluation = Assert.Single(Requests, request => request.Uri.AbsolutePath.EndsWith("prompts:evaluate")).Body;
        var activity = Assert.Single(Requests, request => request.Uri.AbsolutePath.EndsWith("agent-activities")).Body;
        var interaction = Assert.Single(Requests, request => request.Uri.AbsolutePath.EndsWith("ai-interactions")).Body;
        AssertProperties(evaluation, "externalAgentId", "interactionId", "occurredAtUtc", "userContext", "prompt");
        AssertProperties(activity, "externalAgentId", "activityId", "sessionId", "activityType", "occurredAtUtc",
            "actor", "tool", "attributes");
        AssertProperties(interaction, "externalAgentId", "interactionId", "sessionId", "occurredAtUtc", "userContext",
            "prompt", "response", "model", "metadata", "promptEvaluationReceiptId");
        foreach (var property in new[] { "externalAgentId", "interactionId", "occurredAtUtc", "userContext", "prompt" })
            Assert.Equal(evaluation.GetProperty(property).GetRawText(), interaction.GetProperty(property).GetRawText());
        Assert.Equal(Options.ExternalAgentId, evaluation.GetProperty("externalAgentId").GetString());
        Assert.Equal(Options.TenantUserObjectId, evaluation.GetProperty("userContext").GetProperty("tenantUserObjectId").GetGuid());
        Assert.Equal(TestData.Now, evaluation.GetProperty("occurredAtUtc").GetDateTimeOffset().UtcDateTime);
        Assert.Equal(Options.Message, evaluation.GetProperty("prompt").GetProperty("content").GetString());
        Assert.Equal("text/plain", evaluation.GetProperty("prompt").GetProperty("contentType").GetString());
        Assert.Equal(ProofId, interaction.GetProperty("promptEvaluationReceiptId").GetGuid());
        Assert.Equal(GeneratedResponse, interaction.GetProperty("response").GetProperty("content").GetString());
        Assert.Equal("text/plain", interaction.GetProperty("response").GetProperty("contentType").GetString());
        Assert.Equal(JsonValueKind.Null, interaction.GetProperty("model").ValueKind);
        Assert.Equal(Options.ExternalAgentId, activity.GetProperty("externalAgentId").GetString());
        Assert.Equal(interaction.GetProperty("sessionId").GetString(), activity.GetProperty("sessionId").GetString());
        Assert.Equal("User", activity.GetProperty("actor").GetProperty("type").GetString());
        Assert.Equal(Options.TenantUserObjectId, activity.GetProperty("actor").GetProperty("tenantUserObjectId").GetGuid());
        Assert.Equal("Chat", activity.GetProperty("activityType").GetString());
        Assert.Equal(JsonValueKind.Null, activity.GetProperty("tool").ValueKind);
        Assert.Equal(activity.GetProperty("attributes").GetRawText(), interaction.GetProperty("metadata").GetRawText());
        Assert.StartsWith("sample-interaction-", interaction.GetProperty("interactionId").GetString());
        Assert.StartsWith("sample-activity-", activity.GetProperty("activityId").GetString());
    }

    internal static HttpResponseMessage JsonResponse(JsonObject body, HttpStatusCode status = HttpStatusCode.Accepted) =>
        RawResponse(body.ToJsonString(), status);

    internal static HttpResponseMessage RawResponse(string body, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    internal static HttpResponseMessage Rejection(string errorCode) =>
        JsonResponse(new JsonObject { ["errorCode"] = errorCode, ["detail"] = PrivateDetail }, HttpStatusCode.Forbidden);

    private async Task<HttpResponseMessage> RespondAsync(HttpRequestMessage request, CancellationToken token)
    {
        if (request.Method != HttpMethod.Post || !expected.TryDequeue(out var next) || request.RequestUri != next.Uri)
        {
            fixtureFailure = new OfflineProviderException();
            throw fixtureFailure;
        }
        if (request.Headers.Authorization?.Scheme != "Bearer" ||
            request.Headers.Authorization.Parameter != SyntheticKey)
        {
            fixtureFailure = new InvalidOperationException("Synthetic authorization was not preserved.");
            throw fixtureFailure;
        }
        var captured = new SampleRequest(request.RequestUri!,
            JsonSerializer.Deserialize<JsonElement>(await request.Content!.ReadAsStringAsync(token)),
            request.Headers.GetValues("Idempotency-Key").Single());
        Requests.Add(captured);
        Sequence.Add(request.RequestUri!.Segments.Last());
        return next.Respond(captured);
    }

    private static void AssertProperties(JsonElement body, params string[] properties) =>
        Assert.Equal(properties.Order(), body.EnumerateObject().Select(property => property.Name).Order());

    public void Dispose()
    {
        client.Dispose();
        transport.Dispose();
        Output.Dispose();
        Error.Dispose();
    }
}

internal sealed class SampleClock(TimeProvider initial) : TimeProvider
{
    internal DateTimeOffset Now { get; set; } = initial.GetUtcNow();
    public override DateTimeOffset GetUtcNow() => Now;
}
