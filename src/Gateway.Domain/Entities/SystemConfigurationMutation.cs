using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Entities;

public sealed class SystemConfigurationMutation
{
    public Guid Id { get; set; }
    public EntraTenantId TenantId { get; set; }
    public Guid ConfigurationId { get; set; }
    public string ActorObjectId { get; set; } = string.Empty;
    public string AcceptedRequestHash { get; set; } = string.Empty;
    public ProtectionIdempotencyKey IdempotencyKey { get; set; }
    public string? ResultJson { get; set; }
    public Guid CorrelationId { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public DateTime UpdatedAtUtc { get; set; }
}
