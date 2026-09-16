using System.Net;
using Gateway.ObservabilityRuntime.Tests.Fixtures;
using Gateway.ObservabilityRuntime.Tests.Providers;

namespace Gateway.ObservabilityRuntime.Tests;

public sealed class ProviderIsolationGuardTests
{
    [Theory]
    [InlineData("https://graph.microsoft.com/v1.0/me")]
    [InlineData("https://agent365.svc.cloud.microsoft/")]
    [InlineData(PromptShieldFixture.EvaluationUri)]
    [InlineData("http://169.254.169.254/metadata/identity/oauth2/token")]
    public async Task Unscripted_provider_and_managed_identity_endpoints_are_denied(string uri)
    {
        using var transport = new ScriptedTransport();
        using var client = transport.CreateClient();
        await Assert.ThrowsAsync<UnexpectedFixtureCallException>(() => client.GetAsync(uri));
        Assert.Empty(transport.Requests);
        transport.AssertComplete();
    }

    [Fact]
    public async Task Allowed_fixture_request_is_finite_and_unknown_client_names_have_no_fallback()
    {
        using var transport = new ScriptedTransport();
        var factory = new ClosedHttpClientFactory("OnlyFixtureClient", transport);
        Assert.Throws<UnexpectedFixtureCallException>(() => factory.CreateClient("DefaultAzureCredential"));
        transport.Expect(HttpMethod.Get, "https://graph.microsoft.com/v1.0/me", HttpStatusCode.OK);
        using var client = factory.CreateClient("OnlyFixtureClient");
        using var response = await client.GetAsync("https://graph.microsoft.com/v1.0/me");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        await Assert.ThrowsAsync<UnexpectedFixtureCallException>(() => client.GetAsync("https://graph.microsoft.com/v1.0/me"));
        Assert.Single(transport.Requests);
        transport.AssertComplete();
    }

    [Fact]
    public async Task Actual_prompt_shield_client_cannot_escape_the_fixture_transport()
    {
        using var fixture = new PromptShieldFixture();
        fixture.ExpectToken();
        await Assert.ThrowsAsync<UnexpectedFixtureCallException>(() =>
            fixture.Client.EvaluateAsync("synthetic", PromptShieldBaselineTests.Subject, CancellationToken.None));
        Assert.Empty(fixture.Transport.Requests);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Actual_purview_client_cannot_escape_the_fixture_transport()
    {
        using var fixture = new PurviewFixture();
        fixture.ExpectToken();
        await Assert.ThrowsAsync<UnexpectedFixtureCallException>(() =>
            fixture.Client.EvaluatePromptAsync(PurviewBaselineTests.Interaction, CancellationToken.None));
        Assert.Empty(fixture.Transport.Requests);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Actual_agent365_exporter_cannot_escape_the_fixture_transport()
    {
        using var fixture = new Agent365Fixture();
        fixture.ExpectToken();
        await Assert.ThrowsAsync<UnexpectedFixtureCallException>(() =>
            fixture.Client.ExportActivityAsync(Agent365BaselineTests.Request, CancellationToken.None));
        Assert.Empty(fixture.Transport.Requests);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Actual_registry_client_cannot_escape_the_fixture_transport()
    {
        using var transport = new ScriptedTransport();
        var tokens = new DelegatedTokenFixture();
        tokens.Calls.Expect(_ => FixtureIds.Token.Token);
        using var http = transport.CreateClient(new Uri("https://graph.microsoft.com/"));
        await Assert.ThrowsAsync<UnexpectedFixtureCallException>(() =>
            DelegatedRegistryBaselineTests.CreateClient(http, tokens).CreateAsync(
                DelegatedRegistryBaselineTests.Request, CancellationToken.None));
        Assert.Empty(transport.Requests);
        transport.AssertComplete();
        tokens.Calls.AssertComplete();
    }

    [Fact]
    public async Task Credential_fixtures_have_no_ambient_or_unlimited_fallback()
    {
        var credential = new FixtureCredential();
        await Assert.ThrowsAsync<UnexpectedFixtureCallException>(async () =>
            await credential.GetTokenAsync(new Azure.Core.TokenRequestContext(["offline-scope"]), CancellationToken.None));
        Assert.Empty(credential.Calls.Requests);
        var tokens = new ObservabilityTokenFixture();
        await Assert.ThrowsAsync<UnexpectedFixtureCallException>(async () =>
            await tokens.GetTokenAsync("child", "blueprint", "tenant", CancellationToken.None));
        var purview = new PurviewTokenFixture();
        await Assert.ThrowsAsync<UnexpectedFixtureCallException>(async () =>
            await purview.GetTokenAsync(CancellationToken.None));
        var delegated = new DelegatedTokenFixture();
        await Assert.ThrowsAsync<UnexpectedFixtureCallException>(() => delegated.GetTokenAsync(CancellationToken.None));
    }
}
