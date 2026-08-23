using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public class AgentCredentialReference
{
    public Guid Id { get; set; }
    public Guid AgentRegistrationId { get; set; }
    public CredentialType CredentialType { get; set; }
    public string KeyVaultSecretUri { get; set; } = string.Empty;
    public string? CertificateThumbprint { get; set; }
    public DateTime? ExpiresAtUtc { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public DateTime? RotatedAtUtc { get; set; }

    public AgentRegistration AgentRegistration { get; set; } = null!;
}
