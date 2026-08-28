namespace Gateway.Contracts.Dtos;

/// <summary>
/// Administrative metadata for a Gateway ingress credential. Raw key material,
/// hashes, and salts are intentionally excluded.
/// </summary>
public sealed record AgentIngressCredentialMetadataDto(
    Guid KeyId,
    DateTime CreatedAtUtc,
    DateTime ExpiresAtUtc,
    DateTime? RevokedAtUtc);
