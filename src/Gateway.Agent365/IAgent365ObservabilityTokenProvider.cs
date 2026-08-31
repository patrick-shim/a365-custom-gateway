using Azure.Core;

namespace Gateway.Agent365;

public interface IAgent365ObservabilityTokenProvider
{
    ValueTask<AccessToken> GetTokenAsync(
        string agentIdentityClientId,
        string blueprintClientId,
        string expectedTenantId,
        CancellationToken cancellationToken);
}
