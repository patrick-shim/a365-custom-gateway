using Gateway.Api.Options;
using Gateway.Contracts;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Web;

namespace Gateway.Api.Authentication;

/// <summary>
/// Acquires a Graph token through OBO for the current control-plane user. The
/// returned token is process-local and must never be logged, persisted, or queued.
/// </summary>
internal sealed class MicrosoftIdentityWebDelegatedTokenProvider :
    IAgent365DelegatedTokenProvider
{
    private readonly IHttpContextAccessor _httpContextAccessor;
    private readonly ITokenAcquisition _tokenAcquisition;
    private readonly Agent365DelegatedRegistryOptions _options;

    public MicrosoftIdentityWebDelegatedTokenProvider(
        IHttpContextAccessor httpContextAccessor,
        ITokenAcquisition tokenAcquisition,
        IOptions<Agent365DelegatedRegistryOptions> options)
    {
        _httpContextAccessor = httpContextAccessor;
        _tokenAcquisition = tokenAcquisition;
        _options = options.Value;
    }

    public async Task<string> GetTokenAsync(CancellationToken cancellationToken)
    {
        var user = _httpContextAccessor.HttpContext?.User;
        if (user?.Identity?.IsAuthenticated is not true)
        {
            throw new Agent365DelegatedRegistryException(
                ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED,
                "A signed-in administrator is required for Agent 365 registration.",
                mutationMayHaveOccurred: false);
        }

        var scopes = _options.Scopes
            .Where(scope => !string.IsNullOrWhiteSpace(scope))
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        if (!_options.Enabled || scopes.Length == 0)
        {
            throw new Agent365DelegatedRegistryException(
                ErrorCodes.PROVISIONING_DISABLED,
                "Delegated Agent 365 Registry completion is disabled for this deployment.",
                mutationMayHaveOccurred: false);
        }

        return await _tokenAcquisition
            .GetAccessTokenForUserAsync(
                scopes,
                authenticationScheme: JwtBearerDefaults.AuthenticationScheme,
                user: user)
            .WaitAsync(cancellationToken);
    }
}
