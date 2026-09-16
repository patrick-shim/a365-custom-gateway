using Bunit;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Responses;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.AdminUi.Tests;

public sealed class UiIsolationGuardTests
{
    [Theory]
    [InlineData("https://graph.microsoft.com/v1.0/me")]
    [InlineData("https://agent365.svc.cloud.microsoft/")]
    [InlineData("http://169.254.169.254/metadata/identity/oauth2/token")]
    public async Task Default_ui_http_client_is_deny_by_default(string uri)
    {
        using var fixture = new AdminUiFixture();
        await Assert.ThrowsAsync<UnexpectedUiFixtureCallException>(() =>
            fixture.Services.GetRequiredService<HttpClient>().GetAsync(uri));
        Assert.Equal(1, fixture.Network.Attempts);
        fixture.Script.AssertComplete();
    }

    [Fact]
    public async Task No_http_client_name_or_authentication_request_can_resolve_a_live_provider()
    {
        using var fixture = new AdminUiFixture();
        Assert.Throws<UnexpectedUiFixtureCallException>(() =>
            fixture.Services.GetRequiredService<IHttpClientFactory>().CreateClient("GatewayApiClient"));
        await Assert.ThrowsAsync<UnexpectedUiFixtureCallException>(() =>
            fixture.Services.GetRequiredService<IGatewayAccessTokenProvider>().GetAccessTokenAsync());
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Gateway_api_script_is_finite_and_has_no_real_client_fallback()
    {
        using var fixture = new AdminUiFixture();
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentsAsync), new AgentListResponse([], null, 0));
        Assert.Empty((await fixture.Api.GetAgentsAsync()).Items);
        fixture.AssertComplete();

        await Assert.ThrowsAsync<UnexpectedUiFixtureCallException>(() => fixture.Api.GetAgentsAsync());
        Assert.Single(fixture.Script.UnexpectedCalls);
        Assert.Equal(0, fixture.Network.Attempts);
    }

    [Fact]
    public async Task Sample_execution_is_not_available_without_an_explicit_finite_interop_script()
    {
        var browser = new ScriptedJsObject();
        await Assert.ThrowsAsync<UnexpectedUiFixtureCallException>(async () =>
            await browser.InvokeAsync<object>("execute", []));
        Assert.Equal(["execute"], browser.UnexpectedCalls);
    }
}
