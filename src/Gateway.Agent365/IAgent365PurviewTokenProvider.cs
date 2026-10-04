using Azure.Core;

namespace Gateway.Agent365;

// Uses the selected child's FMI identity; never the shared blueprint or gateway as the resource caller.
public interface IAgent365PurviewTokenProvider
{
    ValueTask<AccessToken> GetPurviewTokenAsync(string agentIdentityClientId,
        string blueprintClientId, string expectedTenantId, CancellationToken cancellationToken);
}
