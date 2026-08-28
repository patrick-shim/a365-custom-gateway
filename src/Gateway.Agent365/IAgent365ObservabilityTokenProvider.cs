using Azure.Core;

namespace Gateway.Agent365;

public sealed record AgentIdentityResourceTokenRequest(
    string ResourceScope,
    IReadOnlyCollection<string> AllowedAudiences,
    IReadOnlyCollection<string>? RequiredApplicationRoles = null);

public interface IAgentIdentityTokenProvider
{
    ValueTask<AccessToken> GetResourceTokenAsync(
        string agentIdentityClientId,
        string blueprintClientId,
        string expectedTenantId,
        AgentIdentityResourceTokenRequest resource,
        CancellationToken cancellationToken);
}

public interface IAgent365ObservabilityTokenProvider
{
    ValueTask<AccessToken> GetTokenAsync(
        string agentIdentityClientId,
        string blueprintClientId,
        string expectedTenantId,
        CancellationToken cancellationToken);
}
