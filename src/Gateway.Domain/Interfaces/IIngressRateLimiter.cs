using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IIngressRateLimiter
{
    Task<IngressRateLimitDecision> TryAcquireAsync(
        Guid agentRegistrationId,
        Guid credentialId,
        CancellationToken ct);
}
