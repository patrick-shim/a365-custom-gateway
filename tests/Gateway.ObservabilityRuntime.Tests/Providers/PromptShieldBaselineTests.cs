using System.Net;
using System.Text.Json;
using Gateway.Domain.Models;
using Gateway.ObservabilityRuntime.Tests.Fixtures;
using Microsoft.Extensions.Options;

namespace Gateway.ObservabilityRuntime.Tests.Providers;

public sealed class PromptShieldBaselineTests
{
    internal static readonly PromptShieldSubject Subject = new(
        FixtureIds.Agent, FixtureIds.Child, FixtureIds.Blueprint, "offline-correlation");

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Trusted_boolean_decision_is_mapped_without_sending_agent_identity(bool attack)
    {
        using var fixture = new PromptShieldFixture();
        fixture.ExpectToken();
        fixture.Transport.Expect(HttpMethod.Post, PromptShieldFixture.EvaluationUri, HttpStatusCode.OK,
            JsonSerializer.Serialize(new { userPromptAnalysis = new { attackDetected = attack } }),
            inspect: request =>
            {
                Assert.Equal("Bearer", request.AuthorizationScheme);
                Assert.Equal("synthetic prompt", request.Json.GetProperty("userPrompt").GetString());
                Assert.Single(request.Json.EnumerateObject());
                Assert.DoesNotContain(FixtureIds.Agent.ToString("D"), request.Body);
                Assert.DoesNotContain(FixtureIds.Child.ToString("D"), request.Body);
                Assert.DoesNotContain(FixtureIds.Blueprint.ToString("D"), request.Body);
            });

        var result = await fixture.Client.EvaluateAsync("synthetic prompt", Subject, CancellationToken.None);

        Assert.Equal(attack, result.AttackDetected);
        Assert.Equal(TimeSpan.FromMinutes(5), fixture.Client.ReceiptLifetime);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("""{"userPromptAnalysis":{"attackDetected":"false"}}""")]
    [InlineData("{")]
    public async Task Missing_or_malformed_verdict_is_not_an_allow(string body)
    {
        using var fixture = new PromptShieldFixture();
        fixture.ExpectToken();
        fixture.Transport.Expect(HttpMethod.Post, PromptShieldFixture.EvaluationUri, HttpStatusCode.OK, body);

        var failure = await Assert.ThrowsAsync<PromptShieldException>(() =>
            fixture.Client.EvaluateAsync("synthetic prompt", Subject, CancellationToken.None));

        Assert.Equal("PROMPT_SHIELD_INVALID_RESPONSE", failure.FailureCode);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(403, "PROMPT_SHIELD_FORBIDDEN", false)]
    [InlineData(429, "PROMPT_SHIELD_THROTTLED", true)]
    [InlineData(503, "PROMPT_SHIELD_INVALID_STATUS", true)]
    public async Task Provider_failure_is_classified_without_exposing_response_content(
        int status, string code, bool transient)
    {
        using var fixture = new PromptShieldFixture();
        fixture.ExpectToken();
        fixture.Transport.Expect(HttpMethod.Post, PromptShieldFixture.EvaluationUri,
            (HttpStatusCode)status, """{"message":"provider-private-content"}""");

        var failure = await Assert.ThrowsAsync<PromptShieldException>(() =>
            fixture.Client.EvaluateAsync("synthetic prompt", Subject, CancellationToken.None));

        Assert.Equal(code, failure.FailureCode);
        Assert.Equal(transient, failure.IsTransient);
        Assert.DoesNotContain("provider-private-content", failure.Message);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Wrong_managed_identity_is_rejected_before_http()
    {
        using var fixture = new PromptShieldFixture();
        fixture.ExpectToken(FixtureIds.Actor);

        var failure = await Assert.ThrowsAsync<PromptShieldException>(() =>
            fixture.Client.EvaluateAsync("synthetic prompt", Subject, CancellationToken.None));

        Assert.Equal("PROMPT_SHIELD_CAPABILITY_BINDING_INVALID", failure.FailureCode);
        Assert.Empty(fixture.Transport.Requests);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Disabled_capability_never_acquires_credentials_or_sends_content()
    {
        using var fixture = new PromptShieldFixture(enabled: false);

        var failure = await Assert.ThrowsAsync<PromptShieldException>(() =>
            fixture.Client.EvaluateAsync("synthetic prompt", Subject, CancellationToken.None));

        Assert.Equal("PROMPT_SHIELD_NOT_CONFIGURED", failure.FailureCode);
        Assert.Empty(fixture.Credential.Calls.Requests);
        Assert.Empty(fixture.Transport.Requests);
        fixture.AssertComplete();
    }

    [Fact]
    public void Endpoint_drift_fails_options_validation_before_credentials_or_transport()
    {
        using var fixture = new PromptShieldFixture(configuredEndpoint: "https://other-fixture.cognitiveservices.azure.com/");

        Assert.Throws<OptionsValidationException>(() => fixture.Client);

        Assert.Empty(fixture.Credential.Calls.Requests);
        Assert.Empty(fixture.Transport.Requests);
        fixture.AssertComplete();
    }
}
