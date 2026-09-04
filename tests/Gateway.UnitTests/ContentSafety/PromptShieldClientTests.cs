using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using Azure.Core;
using FluentAssertions;
using Gateway.ContentSafety;
using Gateway.Domain.Models;
using Microsoft.Extensions.Options;

namespace Gateway.UnitTests.ContentSafety;

public sealed class PromptShieldClientTests
{
    private static readonly PromptShieldSubject UnattributedSubject = new(
        Guid.Parse("11111111-1111-1111-1111-111111111111"),
        null,
        null,
        "correlation-unattributed");

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task EvaluateAsync_ReturnsOnlyTheDocumentedAttackFlag(bool attackDetected)
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(new { userPromptAnalysis = new { attackDetected } }),
                Encoding.UTF8,
                "application/json")
        });
        var tokenProvider = new StubTokenProvider();
        var client = new PromptShieldClient(
            new HttpClient(handler) { BaseAddress = new Uri("https://content-safety.example/") },
            tokenProvider,
            Options.Create(new PromptShieldOptions
            {
                Enabled = true,
                Endpoint = "https://content-safety.example/"
            }));

        var result = await client.EvaluateAsync("test prompt", UnattributedSubject, CancellationToken.None);

        result.AttackDetected.Should().Be(attackDetected);
        handler.LastRequest!.RequestUri!.PathAndQuery.Should()
            .Be("/contentsafety/text:shieldPrompt?api-version=2024-09-01");
        handler.LastRequest.Headers.Authorization!.Scheme.Should().Be("Bearer");
    }

    [Fact]
    public async Task EvaluateAsync_FailsClosedWhenTheResponseShapeIsInvalid()
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{}", Encoding.UTF8, "application/json")
        });
        var tokenProvider = new StubTokenProvider();
        var client = new PromptShieldClient(
            new HttpClient(handler) { BaseAddress = new Uri("https://content-safety.example/") },
            tokenProvider,
            Options.Create(new PromptShieldOptions
            {
                Enabled = true,
                Endpoint = "https://content-safety.example/"
            }));

        var action = () => client.EvaluateAsync("test prompt", UnattributedSubject, CancellationToken.None);

        (await action.Should().ThrowAsync<PromptShieldException>())
            .Which.FailureCode.Should().Be("PROMPT_SHIELD_INVALID_RESPONSE");
    }

    [Fact]
    public async Task EvaluateAsync_TranslatesTransportFailureToSafeProviderFailure()
    {
        var handler = new StubHandler(_ => throw new HttpRequestException("sensitive transport detail"));
        var client = new PromptShieldClient(
            new HttpClient(handler) { BaseAddress = new Uri("https://content-safety.example/") },
            new StubTokenProvider(),
            Options.Create(new PromptShieldOptions
            {
                Enabled = true,
                Endpoint = "https://content-safety.example/"
            }));

        var action = () => client.EvaluateAsync("test prompt", UnattributedSubject, CancellationToken.None);

        var exception = (await action.Should().ThrowAsync<PromptShieldException>()).Which;
        exception.FailureCode.Should().Be("PROMPT_SHIELD_UNAVAILABLE");
        exception.Message.Should().NotContain("sensitive transport detail");
    }

    [Fact]
    public async Task EvaluateAsync_AttributesTheVerdictToTheCallingAgent365Identity()
    {
        var agent365AgentId = Guid.Parse("22222222-2222-2222-2222-222222222222");
        var blueprintId = Guid.Parse("33333333-3333-3333-3333-333333333333");
        var subject = new PromptShieldSubject(
            Guid.Parse("44444444-4444-4444-4444-444444444444"),
            agent365AgentId,
            blueprintId,
            "correlation-attributed");
        var handler = AllowingHandler();
        var client = CreateClient(handler);

        using var source = new ActivitySource(nameof(
            EvaluateAsync_AttributesTheVerdictToTheCallingAgent365Identity));
        using var listener = ListenTo(source);
        using var caller = source.StartActivity("prompt.evaluate");

        await client.EvaluateAsync("test prompt", subject, CancellationToken.None);

        // Prompt Shields is a per-agent control, so a verdict in the trace has to name
        // the individual Agent 365 identity that made the call.
        caller.Should().NotBeNull();
        caller!.GetTagItem("gateway.agent.registration_id").Should()
            .Be(subject.AgentRegistrationId.ToString("D"));
        caller.GetTagItem("gateway.a365.agent_id").Should().Be(agent365AgentId.ToString("D"));
        caller.GetTagItem("gateway.a365.blueprint_id").Should().Be(blueprintId.ToString("D"));
        caller.GetTagItem("gateway.correlation.id").Should().Be("correlation-attributed");

        // The identity stays inside the tenant. Prompt Shields has no field for it, so
        // adding one would ship tenant identifiers to the provider for no decision benefit.
        handler.LastRequestBody.Should().NotContain(agent365AgentId.ToString("D"));
        handler.LastRequestBody.Should().NotContain(blueprintId.ToString("D"));
        handler.LastRequestBody.Should().NotContain(subject.AgentRegistrationId.ToString("D"));
        handler.LastRequestBody.Should().NotContain("correlation-attributed");
    }

    [Fact]
    public async Task EvaluateAsync_ReportsAnAbsentAgent365IdentityAsUnknown()
    {
        var client = CreateClient(AllowingHandler());

        using var source = new ActivitySource(nameof(
            EvaluateAsync_ReportsAnAbsentAgent365IdentityAsUnknown));
        using var listener = ListenTo(source);
        using var caller = source.StartActivity("prompt.evaluate");

        await client.EvaluateAsync("test prompt", UnattributedSubject, CancellationToken.None);

        // An agent whose Agent 365 provisioning has not completed still gets a real
        // verdict. Recording the missing identity as missing keeps the trace honest;
        // a placeholder would make the evidence appear to confirm an attribution.
        caller!.GetTagItem("gateway.a365.agent_id").Should().Be("unknown");
        caller.GetTagItem("gateway.a365.blueprint_id").Should().Be("unknown");
        caller.GetTagItem("gateway.agent.registration_id").Should()
            .Be(UnattributedSubject.AgentRegistrationId.ToString("D"));
    }

    [Fact]
    public async Task EvaluateAsync_RejectsAnEvaluationThatNamesNoAgent()
    {
        var client = CreateClient(AllowingHandler());

        var action = () => client.EvaluateAsync("test prompt", null!, CancellationToken.None);

        await action.Should().ThrowAsync<ArgumentNullException>();
    }

    private static StubHandler AllowingHandler() =>
        new(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(new { userPromptAnalysis = new { attackDetected = false } }),
                Encoding.UTF8,
                "application/json")
        });

    private static PromptShieldClient CreateClient(StubHandler handler) =>
        new(
            new HttpClient(handler) { BaseAddress = new Uri("https://content-safety.example/") },
            new StubTokenProvider(),
            Options.Create(new PromptShieldOptions
            {
                Enabled = true,
                Endpoint = "https://content-safety.example/"
            }));

    // Scoped to one test-local source, because activity listeners are registered
    // process-wide and this project runs its classes in parallel.
    private static ActivityListener ListenTo(ActivitySource source)
    {
        var listener = new ActivityListener
        {
            ShouldListenTo = candidate => ReferenceEquals(candidate, source),
            Sample = (ref ActivityCreationOptions<ActivityContext> _) =>
                ActivitySamplingResult.AllDataAndRecorded
        };
        ActivitySource.AddActivityListener(listener);
        return listener;
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> responseFactory)
        : HttpMessageHandler
    {
        public HttpRequestMessage? LastRequest { get; private set; }

        // The request is disposed as soon as the client returns, so the body has to be
        // captured while it is still live rather than read back from LastRequest.
        public string? LastRequestBody { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            LastRequest = request;
            LastRequestBody = request.Content is null
                ? null
                : await request.Content.ReadAsStringAsync(cancellationToken);
            return responseFactory(request);
        }
    }

    private sealed class StubTokenProvider : IPromptShieldTokenProvider
    {
        public ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken) =>
            ValueTask.FromResult(new AccessToken("test-token", DateTimeOffset.UtcNow.AddMinutes(5)));
    }
}
