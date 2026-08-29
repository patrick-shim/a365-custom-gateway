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

        var result = await client.EvaluateAsync("test prompt", CancellationToken.None);

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

        var action = () => client.EvaluateAsync("test prompt", CancellationToken.None);

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

        var action = () => client.EvaluateAsync("test prompt", CancellationToken.None);

        var exception = (await action.Should().ThrowAsync<PromptShieldException>()).Which;
        exception.FailureCode.Should().Be("PROMPT_SHIELD_UNAVAILABLE");
        exception.Message.Should().NotContain("sensitive transport detail");
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> responseFactory)
        : HttpMessageHandler
    {
        public HttpRequestMessage? LastRequest { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            LastRequest = request;
            return Task.FromResult(responseFactory(request));
        }
    }

    private sealed class StubTokenProvider : IPromptShieldTokenProvider
    {
        public ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken) =>
            ValueTask.FromResult(new AccessToken("test-token", DateTimeOffset.UtcNow.AddMinutes(5)));
    }
}
