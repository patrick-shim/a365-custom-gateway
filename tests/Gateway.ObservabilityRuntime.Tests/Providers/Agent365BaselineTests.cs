using System.Net;
using System.Text.Json;
using Gateway.Agent365;
using Gateway.Domain.Models;
using Gateway.ObservabilityRuntime.Tests.Fixtures;

namespace Gateway.ObservabilityRuntime.Tests.Providers;

public sealed class Agent365BaselineTests
{
    internal static ObservabilityExportRequest Request => new(
        FixtureIds.Agent, FixtureIds.Registry, "external-agent", "Offline agent", "chat",
        "synthetic-correlation-content", "synthetic-session-content", FixtureIds.Actor.ToString("D"),
        FixtureIds.Timestamp, FixtureIds.Timestamp.AddSeconds(1), "fixture-provider", "fixture-model",
        FixtureIds.Child.ToString("D"), FixtureIds.Blueprint.ToString("D"));

    private const string Accepted = """
        {"partialSuccess":{"rejectedSpans":0},"results":[
        {"sinks":{"m365":{"status":"sent"}}},{"sinks":{"m365":{"status":"sent"}}}]}
        """;

    [Fact]
    public async Task Export_binds_official_route_and_child_token_with_redacted_deterministic_spans()
    {
        using var fixture = new Agent365Fixture();
        for (var attempt = 0; attempt < 2; attempt++)
        {
            fixture.ExpectToken();
            fixture.Transport.Expect(HttpMethod.Post, Agent365Fixture.ExportUri, HttpStatusCode.OK, Accepted);
        }

        await fixture.Client.ExportActivityAsync(Request, CancellationToken.None);
        await fixture.Client.ExportActivityAsync(Request, CancellationToken.None);

        Assert.Equal(fixture.Transport.Requests[0].Body, fixture.Transport.Requests[1].Body);
        var request = fixture.Transport.Requests[0];
        Assert.Equal("Bearer", request.AuthorizationScheme);
        Assert.Equal(FixtureIds.Token.Token, request.AuthorizationParameter);
        Assert.DoesNotContain(Request.CorrelationId, request.Body);
        Assert.DoesNotContain(Request.SessionId!, request.Body);
        var spans = request.Json.GetProperty("resourceSpans")[0].GetProperty("scopeSpans")[0].GetProperty("spans");
        Assert.Equal(2, spans.GetArrayLength());
        var root = spans[0];
        var child = spans[1];
        Assert.Equal("invoke_agent", root.GetProperty("name").GetString());
        Assert.Equal("chat", child.GetProperty("name").GetString());
        Assert.Equal(root.GetProperty("traceId").GetString(), child.GetProperty("traceId").GetString());
        Assert.Equal(root.GetProperty("spanId").GetString(), child.GetProperty("parentSpanId").GetString());
        var attributes = Attributes(child);
        Assert.Equal(FixtureIds.Child.ToString("D"), attributes["gen_ai.agent.id"]);
        Assert.Equal(FixtureIds.Blueprint.ToString("D"), attributes["microsoft.a365.agent.blueprint.id"]);
        Assert.Contains("[REDACTED]", attributes["gen_ai.input.messages"]);
        Assert.Contains("[REDACTED]", attributes["gen_ai.output.messages"]);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("""{"partialSuccess":{"rejectedSpans":1}}""", "SpansRejected")]
    [InlineData("""{"partialSuccess":{"rejectedSpans":0},"results":[{"sinks":{"m365":{"status":"rejected","reason":"tenant_not_licensed"}}}]}""",
        "SpansRejected:tenant_not_licensed")]
    [InlineData("""{"partialSuccess":{"rejectedSpans":0},"results":[{"sinks":{"m365":{"status":"not_routed","reason":"sink_disabled"}}}]}""",
        "SpansNotRouted:sink_disabled")]
    public async Task Http_200_with_sink_rejection_is_not_reported_as_export_success(string body, string code)
    {
        using var fixture = new Agent365Fixture();
        fixture.ExpectToken();
        fixture.Transport.Expect(HttpMethod.Post, Agent365Fixture.ExportUri, HttpStatusCode.OK, body);

        var failure = await Assert.ThrowsAsync<Agent365ObservabilityConfigurationException>(() =>
            fixture.Client.ExportActivityAsync(Request, CancellationToken.None));

        Assert.Equal(code, failure.Code);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(401)]
    [InlineData(429)]
    [InlineData(503)]
    public async Task Retriable_http_response_is_returned_to_worker_without_internal_replay(int status)
    {
        using var fixture = new Agent365Fixture();
        fixture.ExpectToken();
        fixture.Transport.Expect(HttpMethod.Post, Agent365Fixture.ExportUri, (HttpStatusCode)status);

        var failure = await Assert.ThrowsAsync<Agent365ObservabilityTransientException>(() =>
            fixture.Client.ExportActivityAsync(Request, CancellationToken.None));

        Assert.Equal($"Http{status}", failure.Code);
        Assert.Single(fixture.Transport.Requests);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Missing_user_context_cannot_acquire_a_token_or_export()
    {
        using var fixture = new Agent365Fixture();

        var failure = await Assert.ThrowsAsync<Agent365ObservabilityConfigurationException>(() =>
            fixture.Client.ExportActivityAsync(Request with { TenantUserObjectId = null }, CancellationToken.None));

        Assert.Equal("MissingUserContext", failure.Code);
        Assert.Empty(fixture.Tokens.Calls.Requests);
        Assert.Empty(fixture.Transport.Requests);
        fixture.AssertComplete();
    }

    private static Dictionary<string, string?> Attributes(JsonElement span) =>
        span.GetProperty("attributes").EnumerateArray().ToDictionary(
            item => item.GetProperty("key").GetString()!,
            item => item.GetProperty("value").GetProperty("stringValue").GetString());
}
