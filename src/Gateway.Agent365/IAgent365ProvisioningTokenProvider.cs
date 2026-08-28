using Azure.Core;

namespace Gateway.Agent365;

internal interface IAgent365ProvisioningTokenProvider
{
    ValueTask<AccessToken> GetTokenAsync(CancellationToken cancellationToken);
}
