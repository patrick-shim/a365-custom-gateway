using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Azure.Core;
using FluentAssertions;
using Gateway.Agent365;
using Gateway.Domain.Models;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Gateway.ObservabilityRuntime.Tests.Agent365;

public sealed class ObservabilityExporterTests
{
    private static readonly Guid TenantId = Guid.Parse("11111111-1111-4111-8111-111111111111");
    private static readonly Guid AgentIdentityClientId = Guid.Parse("22222222-2222-4222-8222-222222222222");
    private static readonly Guid BlueprintClientId = Guid.Parse("66666666-6666-4666-8666-666666666666");
    private static readonly Guid UserObjectId = Guid.Parse("33333333-3333-4333-8333-333333333333");

    [Fact]
    public async Task ExportActivityAsync_Chat_EmitsCanonicalRootAndChildWithRedactedContent()
    {
        var handler = new RecordingHttpMessageHandler(_ => SuccessResponse());
        var tokenProvider = new RecordingTokenProvider();
        var exporter = CreateExporter(handler, tokenProvider);

        await exporter.ExportActivityAsync(CreateRequest("chat"), CancellationToken.None);

        handler.CallCount.Should().Be(1);
        handler.RequestUri.Should().Be(
            $"https://agent365.svc.cloud.microsoft/observabilityService/tenants/{TenantId:D}/otlp/agents/{AgentIdentityClientId:D}/traces?api-version=1");
        handler.Authorization.Should().Be(new AuthenticationHeaderValue("Bearer", "opaque-unit-test-value"));
        tokenProvider.CallCount.Should().Be(1);
        tokenProvider.AgentIdentityClientId.Should().Be(AgentIdentityClientId.ToString("D"));
        tokenProvider.BlueprintClientId.Should().Be(BlueprintClientId.ToString("D"));
        tokenProvider.TenantId.Should().Be(TenantId.ToString("D"));

        using var document = JsonDocument.Parse(handler.Body!);
        var spans = GetSpans(document).EnumerateArray().ToArray();
        spans.Should().HaveCount(2);

        var root = spans[0];
        var child = spans[1];
        root.GetProperty("name").GetString().Should().Be("invoke_agent");
        root.GetProperty("parentSpanId").GetString().Should().BeEmpty();
        child.GetProperty("name").GetString().Should().Be("chat");
        child.GetProperty("traceId").GetString().Should().Be(root.GetProperty("traceId").GetString());
        child.GetProperty("parentSpanId").GetString().Should().Be(root.GetProperty("spanId").GetString());

        var rootAttributes = GetAttributes(root);
        var childAttributes = GetAttributes(child);
        rootAttributes["gen_ai.agent.id"].Should().Be(AgentIdentityClientId.ToString("D"));
        rootAttributes["microsoft.a365.agent.blueprint.id"].Should().Be(BlueprintClientId.ToString("D"));
        childAttributes["gen_ai.agent.id"].Should().Be(AgentIdentityClientId.ToString("D"));
        childAttributes["microsoft.a365.agent.blueprint.id"].Should().Be(BlueprintClientId.ToString("D"));
        rootAttributes.Should().NotContainKey("gen_ai.agent.type");
        rootAttributes.Should().NotContainKey("microsoft.a365.agent.platform.id");
        childAttributes.Should().NotContainKey("gen_ai.agent.type");
        childAttributes.Should().NotContainKey("microsoft.a365.agent.platform.id");
        rootAttributes["user.id"].Should().Be(UserObjectId.ToString("D"));
        rootAttributes["gen_ai.input.messages"].Should().Contain("[REDACTED]");
        rootAttributes["gen_ai.output.messages"].Should().Contain("[REDACTED]");
        childAttributes["gen_ai.input.messages"].Should().Contain("[REDACTED]");
        childAttributes["gen_ai.output.messages"].Should().Contain("[REDACTED]");

        var allowedAttributeNames = new HashSet<string>(StringComparer.Ordinal)
        {
            "gen_ai.operation.name",
            "microsoft.tenant.id",
            "gen_ai.agent.id",
            "gen_ai.agent.name",
            "microsoft.a365.agent.blueprint.id",
            "gen_ai.conversation.id",
            "microsoft.channel.name",
            "correlation.id",
            "operation.source",
            "microsoft.session.id",
            "client.address",
            "server.address",
            "server.port",
            "user.id",
            "gen_ai.execution.type",
            "gen_ai.input.messages",
            "gen_ai.output.messages",
            "gen_ai.request.model",
            "gen_ai.provider.name"
        };
        rootAttributes.Keys.Concat(childAttributes.Keys)
            .Should().OnlyContain(attributeName => allowedAttributeNames.Contains(attributeName));

        handler.Body.Should().NotContain("contentBlobUri");
        handler.Body.Should().NotContain("access_token");
        handler.Body.Should().NotContain("authorization");
        handler.Body.Should().NotContain("promptText");
        handler.Body.Should().NotContain("responseText");
        handler.Body.Should().NotContain("correlation-1");
        handler.Body.Should().NotContain("session-1");
    }

    [Fact]
    public async Task ExportActivityAsync_InvokeAgent_EmitsRootOnly()
    {
        var handler = new RecordingHttpMessageHandler(_ => SuccessResponse());
        var exporter = CreateExporter(handler, new RecordingTokenProvider());

        await exporter.ExportActivityAsync(CreateRequest("invoke_agent"), CancellationToken.None);

        using var document = JsonDocument.Parse(handler.Body!);
        var spans = GetSpans(document).EnumerateArray().ToArray();
        spans.Should().ContainSingle();
        spans[0].GetProperty("name").GetString().Should().Be("invoke_agent");
        spans[0].GetProperty("parentSpanId").GetString().Should().BeEmpty();
    }

    [Fact]
    public async Task ExportActivityAsync_MissingUserContext_FailsClosedBeforeTokenOrHttp()
    {
        var handler = new RecordingHttpMessageHandler(_ => SuccessResponse());
        var tokenProvider = new RecordingTokenProvider();
        var exporter = CreateExporter(handler, tokenProvider);

        var action = () => exporter.ExportActivityAsync(
            CreateRequest("output_messages") with { TenantUserObjectId = null },
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("MissingUserContext");
        tokenProvider.CallCount.Should().Be(0);
        handler.CallCount.Should().Be(0);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ExportActivityAsync_MissingProvisionedIdentity_FailsClosedBeforeTokenOrHttp(
        bool missingAgentIdentity)
    {
        var handler = new RecordingHttpMessageHandler(_ => SuccessResponse());
        var tokenProvider = new RecordingTokenProvider();
        var exporter = CreateExporter(handler, tokenProvider);
        var request = missingAgentIdentity
            ? CreateRequest("chat") with { AgentIdentityClientId = null }
            : CreateRequest("chat") with { BlueprintClientId = null };

        var action = () => exporter.ExportActivityAsync(request, CancellationToken.None);

        var exception = await action.Should()
            .ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be(
            missingAgentIdentity ? "InvalidAgentIdentityClientId" : "InvalidBlueprintClientId");
        tokenProvider.CallCount.Should().Be(0);
        handler.CallCount.Should().Be(0);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    [InlineData(HttpStatusCode.ServiceUnavailable)]
    public async Task ExportActivityAsync_TransientHttpStatus_ThrowsRetryableException(
        HttpStatusCode statusCode)
    {
        var handler = new RecordingHttpMessageHandler(_ => new HttpResponseMessage(statusCode));
        var exporter = CreateExporter(handler, new RecordingTokenProvider());

        var action = () => exporter.ExportActivityAsync(CreateRequest("chat"), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ObservabilityTransientException>();
        exception.Which.Code.Should().Be($"Http{(int)statusCode}");
    }

    [Fact]
    public async Task ExportActivityAsync_RejectedSpans_ThrowsTerminalException()
    {
        var handler = new RecordingHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new
            {
                partialSuccess = new { rejectedSpans = "1", errorMessage = "invalid attributes" }
            })
        });
        var exporter = CreateExporter(handler, new RecordingTokenProvider());

        var action = () => exporter.ExportActivityAsync(CreateRequest("execute_tool"), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("SpansRejected");
    }

    [Fact]
    public async Task ExportActivityAsync_EverySinkSent_Accepts()
    {
        var handler = new RecordingHttpMessageHandler(_ => ResultsResponse(new
        {
            flashpoint = new { status = "sent" },
            sentinel = new { status = "sent" },
            esp = new { status = "sent" }
        }));
        var exporter = CreateExporter(handler, new RecordingTokenProvider());

        var action = () => exporter.ExportActivityAsync(CreateRequest("chat"), CancellationToken.None);

        await action.Should().NotThrowAsync();
    }

    // The decisive case. Microsoft documents that an ineligible tenant answers
    // 200 OK with partialSuccess.rejectedSpans still 0 while every sink rejects
    // the span, so partialSuccess alone silently reports a successful export.
    [Fact]
    public async Task ExportActivityAsync_SinksRejectedWhilePartialSuccessIsZero_ThrowsTerminalExceptionCarryingReason()
    {
        var handler = new RecordingHttpMessageHandler(_ => ResultsResponse(new
        {
            flashpoint = new { status = "rejected", reason = "tenant_not_licensed" },
            sentinel = new { status = "rejected", reason = "tenant_not_licensed" },
            esp = new { status = "rejected", reason = "tenant_not_licensed" }
        }));
        var exporter = CreateExporter(handler, new RecordingTokenProvider());

        var action = () => exporter.ExportActivityAsync(
            CreateRequest("invoke_agent"),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("SpansRejected:tenant_not_licensed");
    }

    [Fact]
    public async Task ExportActivityAsync_AtLeastOneSinkSent_AcceptsDespiteNotRoutedSinks()
    {
        var handler = new RecordingHttpMessageHandler(_ => ResultsResponse(new
        {
            flashpoint = new { status = "sent" },
            sentinel = new { status = "not_routed", reason = "sink_not_enabled" }
        }));
        var exporter = CreateExporter(handler, new RecordingTokenProvider());

        var action = () => exporter.ExportActivityAsync(CreateRequest("chat"), CancellationToken.None);

        await action.Should().NotThrowAsync();
    }

    [Fact]
    public async Task ExportActivityAsync_EverySinkNotRouted_ThrowsTerminalExceptionCarryingReason()
    {
        var handler = new RecordingHttpMessageHandler(_ => ResultsResponse(new
        {
            flashpoint = new { status = "not_routed", reason = "sink_not_enabled" },
            sentinel = new { status = "not_routed", reason = "sink_not_enabled" }
        }));
        var exporter = CreateExporter(handler, new RecordingTokenProvider());

        var action = () => exporter.ExportActivityAsync(CreateRequest("chat"), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("SpansNotRouted:sink_not_enabled");
    }

    [Fact]
    public async Task ExportActivityAsync_ResultsReportNoSinkForASpan_ThrowsTerminalException()
    {
        var handler = new RecordingHttpMessageHandler(_ => ResultsResponse(new { }));
        var exporter = CreateExporter(handler, new RecordingTokenProvider());

        var action = () => exporter.ExportActivityAsync(CreateRequest("chat"), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("SpansNotRouted:unspecified");
    }

    // The rejection reason is a service-controlled enum rather than customer
    // content, but it reaches persisted error codes and audit rows, so it stays
    // bounded and single-line no matter what the service sends.
    [Fact]
    public async Task ExportActivityAsync_RejectionReason_IsBoundedBeforeReachingTheErrorCode()
    {
        var handler = new RecordingHttpMessageHandler(_ => ResultsResponse(new
        {
            flashpoint = new
            {
                status = "rejected",
                reason = new string('x', 200) + " drop\r\ntable"
            }
        }));
        var exporter = CreateExporter(handler, new RecordingTokenProvider());

        var action = () => exporter.ExportActivityAsync(CreateRequest("chat"), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("SpansRejected:" + new string('x', 64));
    }

    // Responses that carry results but omit partialSuccess must still be
    // inspected; the routing verdict lives only in results.
    [Fact]
    public async Task ExportActivityAsync_ResultsRejectedWithoutPartialSuccess_ThrowsTerminalException()
    {
        var handler = new RecordingHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new
            {
                results = new[]
                {
                    new
                    {
                        spanId = "0123456789abcdef",
                        sinks = new
                        {
                            flashpoint = new { status = "rejected", reason = "tenant_not_licensed" }
                        }
                    }
                }
            })
        });
        var exporter = CreateExporter(handler, new RecordingTokenProvider());

        var action = () => exporter.ExportActivityAsync(CreateRequest("chat"), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365ObservabilityConfigurationException>();
        exception.Which.Code.Should().Be("SpansRejected:tenant_not_licensed");
    }

    [Fact]
    public async Task ExportActivityAsync_ResponseOmitsResults_AcceptsOnPartialSuccessAlone()
    {
        var handler = new RecordingHttpMessageHandler(_ => SuccessResponse());
        var exporter = CreateExporter(handler, new RecordingTokenProvider());

        var action = () => exporter.ExportActivityAsync(CreateRequest("chat"), CancellationToken.None);

        await action.Should().NotThrowAsync();
    }

    private static ObservabilityExporter CreateExporter(
        RecordingHttpMessageHandler handler,
        IAgent365ObservabilityTokenProvider tokenProvider)
    {
        return new ObservabilityExporter(
            NullLogger<ObservabilityExporter>.Instance,
            Options.Create(new Agent365Options
            {
                TenantId = TenantId.ToString("D"),
                ObservabilityServerAddress = "gateway.example.test",
                ObservabilityServerPort = 443
            }),
            new StubHttpClientFactory(handler),
            tokenProvider);
    }

    private static ObservabilityExportRequest CreateRequest(string operation)
    {
        return new ObservabilityExportRequest(
            Guid.Parse("44444444-4444-4444-8444-444444444444"),
            Guid.Parse("55555555-5555-4555-8555-555555555555"),
            "external-agent-1",
            "Test agent",
            operation,
            "correlation-1",
            "session-1",
            UserObjectId.ToString("D"),
            new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Utc),
            new DateTime(2026, 1, 2, 3, 4, 6, DateTimeKind.Utc),
            "test-provider",
            "test-model",
            AgentIdentityClientId.ToString("D"),
            BlueprintClientId.ToString("D"));
    }

    private static HttpResponseMessage SuccessResponse()
    {
        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new { partialSuccess = (object?)null })
        };
    }

    // Mirrors the documented response shape: results[].sinks is an object map of
    // sink name to { status, reason }, alongside a clean partialSuccess.
    private static HttpResponseMessage ResultsResponse(object sinks)
    {
        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new
            {
                partialSuccess = new { rejectedSpans = 0, errorMessage = "" },
                results = new[] { new { spanId = "0123456789abcdef", sinks } }
            })
        };
    }

    private static JsonElement GetSpans(JsonDocument document)
    {
        return document.RootElement
            .GetProperty("resourceSpans")[0]
            .GetProperty("scopeSpans")[0]
            .GetProperty("spans");
    }

    private static Dictionary<string, string> GetAttributes(JsonElement span)
    {
        return span.GetProperty("attributes")
            .EnumerateArray()
            .ToDictionary(
                item => item.GetProperty("key").GetString()!,
                item => item.GetProperty("value").GetProperty("stringValue").GetString()!,
                StringComparer.Ordinal);
    }

    private sealed class StubHttpClientFactory(RecordingHttpMessageHandler handler) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(handler, disposeHandler: false);
    }

    private sealed class RecordingHttpMessageHandler(
        Func<HttpRequestMessage, HttpResponseMessage> responseFactory) : HttpMessageHandler
    {
        public int CallCount { get; private set; }
        public string? RequestUri { get; private set; }
        public AuthenticationHeaderValue? Authorization { get; private set; }
        public string? Body { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            CallCount++;
            RequestUri = request.RequestUri?.AbsoluteUri;
            Authorization = request.Headers.Authorization;
            Body = request.Content is null
                ? null
                : await request.Content.ReadAsStringAsync(cancellationToken);
            return responseFactory(request);
        }
    }

    private sealed class RecordingTokenProvider : IAgent365ObservabilityTokenProvider
    {
        public int CallCount { get; private set; }
        public string? AgentIdentityClientId { get; private set; }
        public string? BlueprintClientId { get; private set; }
        public string? TenantId { get; private set; }

        public ValueTask<AccessToken> GetTokenAsync(
            string agentIdentityClientId,
            string blueprintClientId,
            string expectedTenantId,
            CancellationToken cancellationToken)
        {
            CallCount++;
            AgentIdentityClientId = agentIdentityClientId;
            BlueprintClientId = blueprintClientId;
            TenantId = expectedTenantId;
            return ValueTask.FromResult(new AccessToken(
                "opaque-unit-test-value",
                DateTimeOffset.UtcNow.AddMinutes(10)));
        }
    }
}
