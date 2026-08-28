using Gateway.AdminUi.Options;
using Gateway.AdminUi.Services;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Components.Authorization;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Client;
using Microsoft.Identity.Web;

namespace Gateway.AdminUi.Authentication;

public sealed class GatewayAccessTokenProvider : IGatewayAccessTokenProvider
{
    private readonly AuthenticationStateProvider _authenticationStateProvider;
    private readonly ITokenAcquisition _tokenAcquisition;
    private readonly string[] _scopes;

    public GatewayAccessTokenProvider(
        AuthenticationStateProvider authenticationStateProvider,
        ITokenAcquisition tokenAcquisition,
        IOptions<GatewayApiOptions> options)
    {
        _authenticationStateProvider = authenticationStateProvider;
        _tokenAcquisition = tokenAcquisition;
        _scopes = options.Value.Scopes;
    }

    public async Task<string> GetAccessTokenAsync(CancellationToken cancellationToken = default)
    {
        var authenticationState = await _authenticationStateProvider
            .GetAuthenticationStateAsync()
            .WaitAsync(cancellationToken);

        if (authenticationState.User.Identity?.IsAuthenticated is not true)
        {
            throw new GatewayAuthenticationRequiredException();
        }

        try
        {
            return await _tokenAcquisition
                .GetAccessTokenForUserAsync(
                    _scopes,
                    authenticationScheme: OpenIdConnectDefaults.AuthenticationScheme,
                    user: authenticationState.User)
                .WaitAsync(cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is MsalUiRequiredException or MicrosoftIdentityWebChallengeUserException)
        {
            throw new GatewayAuthenticationRequiredException(exception);
        }
    }
}
