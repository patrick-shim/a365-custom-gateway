using System.Security.Claims;
using FluentAssertions;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Options;
using Gateway.AdminUi.Services;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Components.Authorization;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Web;
using NSubstitute;

namespace Gateway.AdminUi.Tests.Authentication;

public sealed class GatewayAccessTokenProviderTests
{
    [Fact]
    public async Task GetAccessTokenAsync_RejectsUnauthenticatedSessionBeforeTokenAcquisition()
    {
        var tokenAcquisition = Substitute.For<ITokenAcquisition>();
        var authenticationStateProvider = new StaticAuthenticationStateProvider(
            new ClaimsPrincipal(new ClaimsIdentity()));
        var sut = CreateProvider(authenticationStateProvider, tokenAcquisition);

        var action = () => sut.GetAccessTokenAsync();

        await action.Should().ThrowAsync<GatewayAuthenticationRequiredException>();
        await tokenAcquisition.DidNotReceiveWithAnyArgs()
            .GetAccessTokenForUserAsync(default!);
    }

    [Fact]
    public async Task GetAccessTokenAsync_UsesConfiguredDelegatedScopeAndCurrentPrincipal()
    {
        var principal = new ClaimsPrincipal(new ClaimsIdentity(
            [new Claim(ClaimTypes.NameIdentifier, "user-object-id")],
            "test"));
        var tokenAcquisition = Substitute.For<ITokenAcquisition>();
        tokenAcquisition.GetAccessTokenForUserAsync(
                Arg.Is<IEnumerable<string>>(scopes => scopes.SequenceEqual(new[] { "api://gateway/access_as_user" })),
                authenticationScheme: OpenIdConnectDefaults.AuthenticationScheme,
                user: principal)
            .Returns("delegated-token");
        var sut = CreateProvider(
            new StaticAuthenticationStateProvider(principal),
            tokenAcquisition);

        var token = await sut.GetAccessTokenAsync();

        token.Should().Be("delegated-token");
        await tokenAcquisition.Received(1).GetAccessTokenForUserAsync(
            Arg.Is<IEnumerable<string>>(scopes => scopes.SequenceEqual(new[] { "api://gateway/access_as_user" })),
            authenticationScheme: OpenIdConnectDefaults.AuthenticationScheme,
            user: principal);
    }

    private static GatewayAccessTokenProvider CreateProvider(
        AuthenticationStateProvider authenticationStateProvider,
        ITokenAcquisition tokenAcquisition) =>
        new(
            authenticationStateProvider,
            tokenAcquisition,
            Microsoft.Extensions.Options.Options.Create(new GatewayApiOptions
            {
                Scopes = ["api://gateway/access_as_user"]
            }));

    private sealed class StaticAuthenticationStateProvider(ClaimsPrincipal principal)
        : AuthenticationStateProvider
    {
        public override Task<AuthenticationState> GetAuthenticationStateAsync() =>
            Task.FromResult(new AuthenticationState(principal));
    }
}
