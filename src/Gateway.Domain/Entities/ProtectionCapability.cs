using Gateway.Domain.Enums;
using Gateway.Domain.Models;

namespace Gateway.Domain.Entities;

public class ProtectionCapability
{
    public Guid Id { get; set; }
    public ProtectionCapabilityKind Kind { get; set; }
    public ProtectionCapabilityStatus Status { get; set; }
    public ProtectionCapabilityResourceIdentifiers ResourceIdentifiers { get; set; } = new();
    public DateTime? LastReadbackAtUtc { get; set; }
    public string? LastFailureCode { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public DateTime UpdatedAtUtc { get; set; }
    public byte[] RowVersion { get; set; } = [];
}
