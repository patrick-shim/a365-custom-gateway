using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IAgentIngressCredentialService
{
    IssuedAgentIngressCredential Issue(
        Guid agentRegistrationId,
        string createdByObjectId,
        DateTime issuedAtUtc);

    Task<AgentIngressCredentialIdentity?> ValidateAsync(
        string presentedApiKey,
        DateTime validatedAtUtc,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<AgentIngressCredentialMetadata>> ListAsync(
        Guid agentRegistrationId,
        CancellationToken cancellationToken);

    Task<AgentIngressCredentialRevocationResult> RevokeAsync(
        Guid agentRegistrationId,
        Guid credentialId,
        DateTime revokedAtUtc,
        CancellationToken cancellationToken);
}
