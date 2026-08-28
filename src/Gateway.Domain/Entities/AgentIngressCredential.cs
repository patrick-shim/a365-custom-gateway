namespace Gateway.Domain.Entities;

public class AgentIngressCredential
{
    public Guid Id { get; set; }
    public Guid AgentRegistrationId { get; set; }
    public int FormatVersion { get; set; }
    public string HashAlgorithm { get; set; } = string.Empty;
    public byte[] SecretSalt { get; set; } = [];
    public byte[] SecretHash { get; set; } = [];
    public DateTime CreatedAtUtc { get; set; }
    public string CreatedByObjectId { get; set; } = string.Empty;
    public DateTime ExpiresAtUtc { get; set; }
    public DateTime? RevokedAtUtc { get; set; }

    public AgentRegistration AgentRegistration { get; set; } = null!;
}
