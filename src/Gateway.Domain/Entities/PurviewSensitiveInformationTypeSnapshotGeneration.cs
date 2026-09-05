using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Entities;

public class PurviewSensitiveInformationTypeSnapshotGeneration
{
    public SensitiveInformationTypeSnapshotGenerationId Id { get; set; }
    public Guid PurviewTenantConnectionId { get; set; }
    public EntraTenantId TenantId { get; set; }
    public DateTime RetrievedAtUtc { get; set; }
    public DateTime ExpiresAtUtc { get; set; }
    public int ItemCount { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public ICollection<PurviewSensitiveInformationTypeSnapshot> Items { get; set; } =
        new List<PurviewSensitiveInformationTypeSnapshot>();

    public bool IsExpired(DateTime utcNow) =>
        utcNow.Kind != DateTimeKind.Utc ||
        utcNow >= ExpiresAtUtc;
}
