namespace Gateway.Domain.Models;

/// <summary>
/// Safe administrative metadata for a Gateway ingress credential. This model must
/// never contain the raw API key, salt, or hash.
/// </summary>
public sealed record AgentIngressCredentialMetadata(
    Guid KeyId,
    DateTime CreatedAtUtc,
    DateTime ExpiresAtUtc,
    DateTime? RevokedAtUtc);

public enum AgentIngressCredentialRevocationStatus
{
    Revoked,
    AlreadyRevoked,
    NotFound,
    LastUsableCredential
}

public sealed record AgentIngressCredentialRevocationResult(
    AgentIngressCredentialRevocationStatus Status,
    AgentIngressCredentialMetadata? Credential);
