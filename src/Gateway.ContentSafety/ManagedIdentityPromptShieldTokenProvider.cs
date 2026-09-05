using Azure.Core;
using Azure.Identity;
using Microsoft.Extensions.Options;

namespace Gateway.ContentSafety;

internal sealed class ManagedIdentityPromptShieldTokenProvider : IPromptShieldTokenProvider
{
    private static readonly TokenRequestContext TokenContext =
        new(["https://cognitiveservices.azure.com/.default"]);
    private readonly TokenCredential _credential;

    public ManagedIdentityPromptShieldTokenProvider(IOptions<PromptShieldOptions> options)
        : this(CreateCredential(options.Value))
    {
    }

    internal ManagedIdentityPromptShieldTokenProvider(TokenCredential credential)
    {
        _credential = credential;
    }

    public ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken) =>
        _credential.GetTokenAsync(TokenContext, cancellationToken);

    internal static TokenCredential CreateCredential(PromptShieldOptions options) =>
        CreateCredential(
            options,
            static clientId => clientId is null
                ? new ManagedIdentityCredential()
                : new ManagedIdentityCredential(
                    ManagedIdentityId.FromUserAssignedClientId(clientId)));

    internal static TokenCredential CreateCredential(
        PromptShieldOptions options,
        Func<string?, TokenCredential> credentialFactory)
    {
        if (string.IsNullOrWhiteSpace(options.ManagedIdentityClientId))
            return credentialFactory(null);

        if (!Guid.TryParse(options.ManagedIdentityClientId, out var clientId) || clientId == Guid.Empty)
        {
            throw new InvalidOperationException(
                "PromptShield:ManagedIdentityClientId must be a non-empty GUID.");
        }

        return credentialFactory(clientId.ToString("D"));
    }
}
