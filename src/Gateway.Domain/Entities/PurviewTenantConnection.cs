using Gateway.Domain.Enums;
using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Entities;

public class PurviewTenantConnection
{
    public Guid Id { get; set; }
    public EntraTenantId TenantId { get; set; }
    public PurviewTenantConnectionStatus Status { get; set; }
    public ApplicationClientId? AuthorityApplicationId { get; set; }
    public ServicePrincipalObjectId? AuthorityServicePrincipalObjectId { get; set; }
    public string? AuthorityKind { get; set; }
    public SensitiveInformationTypeSnapshotGenerationId? ActiveInventoryGenerationId { get; set; }
    public DateTime? AuthorizedAtUtc { get; set; }
    public DateTime? ExpiresAtUtc { get; set; }
    public DateTime? LastVerifiedAtUtc { get; set; }
    public string? LastFailureCode { get; set; }
    public string CreatedByObjectId { get; set; } = string.Empty;
    public DateTime CreatedAtUtc { get; set; }
    public DateTime UpdatedAtUtc { get; set; }
    public byte[] RowVersion { get; set; } = [];

    public bool IsUsableAt(DateTime utcNow) =>
        utcNow.Kind == DateTimeKind.Utc &&
        Status == PurviewTenantConnectionStatus.Connected &&
        LastVerifiedAtUtc is not null &&
        (ExpiresAtUtc is null || utcNow < ExpiresAtUtc.Value);
}
