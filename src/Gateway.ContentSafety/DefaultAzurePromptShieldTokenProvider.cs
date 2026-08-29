using Azure.Core;
using Azure.Identity;
using Microsoft.Extensions.Options;

namespace Gateway.ContentSafety;

internal sealed class DefaultAzurePromptShieldTokenProvider : IPromptShieldTokenProvider
{
    private static readonly TokenRequestContext TokenContext =
        new(["https://cognitiveservices.azure.com/.default"]);
    private readonly TokenCredential _credential;

    public DefaultAzurePromptShieldTokenProvider(IOptions<PromptShieldOptions> options)
    {
        _credential = string.IsNullOrWhiteSpace(options.Value.ManagedIdentityClientId)
            ? new DefaultAzureCredential()
            : new DefaultAzureCredential(new DefaultAzureCredentialOptions
            {
                ManagedIdentityClientId = options.Value.ManagedIdentityClientId
            });
    }

    public ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken) =>
        _credential.GetTokenAsync(TokenContext, cancellationToken);
}
