using Azure.Core;

namespace Gateway.Purview;

internal interface IPurviewTokenProvider
{
    ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken);
}
