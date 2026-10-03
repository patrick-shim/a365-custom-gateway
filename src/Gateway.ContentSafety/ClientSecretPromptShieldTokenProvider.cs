using Azure.Core;
using Azure.Identity;
using Microsoft.Extensions.Options;

namespace Gateway.ContentSafety;

internal sealed class ClientSecretPromptShieldTokenProvider : IPromptShieldTokenProvider
{
    private static readonly TokenRequestContext TokenContext =
        new(["https://cognitiveservices.azure.com/.default"]);

    private readonly TokenCredential _credential;

    public ClientSecretPromptShieldTokenProvider(IOptions<PromptShieldOptions> options)
        : this(CreateCredential(options.Value))
    {
    }

    internal ClientSecretPromptShieldTokenProvider(TokenCredential credential)
    {
        _credential = credential;
    }

    public ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken) =>
        _credential.GetTokenAsync(TokenContext, cancellationToken);

    internal static TokenCredential CreateCredential(PromptShieldOptions options)
    {
        if (string.IsNullOrWhiteSpace(options.TenantId) ||
            !Guid.TryParse(options.TenantId, out var tenantId) ||
            tenantId == Guid.Empty)
        {
            throw new InvalidOperationException(
                "PromptShield:TenantId must be a non-empty GUID when AuthMode is ClientSecret.");
        }

        if (string.IsNullOrWhiteSpace(options.ClientId) ||
            !Guid.TryParse(options.ClientId, out var clientId) ||
            clientId == Guid.Empty)
        {
            throw new InvalidOperationException(
                "PromptShield:ClientId must be a non-empty GUID when AuthMode is ClientSecret.");
        }

        if (string.IsNullOrWhiteSpace(options.ClientSecret))
        {
            throw new InvalidOperationException(
                "PromptShield:ClientSecret is required when AuthMode is ClientSecret.");
        }

        return new ClientSecretCredential(
            tenantId.ToString("D"),
            clientId.ToString("D"),
            options.ClientSecret);
    }
}
