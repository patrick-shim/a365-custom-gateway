using Azure.Core;

namespace Gateway.ContentSafety;

internal interface IPromptShieldTokenProvider
{
    ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken);
}
