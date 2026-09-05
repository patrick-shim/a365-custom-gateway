using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Entities;

public class PurviewKnowYourDataConfiguration
{
    public Guid Id { get; set; }
    public Guid PurviewTenantConnectionId { get; set; }
    public PurviewPolicyScopeType ScopeType => PurviewPolicyScopeType.Group;
    public Guid GroupId => PurviewPolicyLocationContract.EnterpriseAiAppsGroupId;
    public PurviewEnforcementPlane EnforcementPlane => PurviewEnforcementPlane.Application;
    public SensitiveInformationTypeSnapshotGenerationId InventoryGenerationId { get; set; }
    public SensitiveInformationTypeId SensitiveInformationTypeId { get; set; }
    public string SensitiveInformationTypeName { get; set; } = string.Empty;
    public PurviewMode Mode { get; set; }
    public ICollection<PurviewPolicyActivity> Activities { get; set; } =
        new List<PurviewPolicyActivity>();
    public bool IngestionEnabled { get; set; }
    public PurviewKnowYourDataStatus Status { get; set; }
    public ProtectionReadbackStatus ReadbackStatus { get; set; }
    public string? CollectionPolicyProviderId { get; set; }
    public DateTime? LastReadbackAtUtc { get; set; }
    public string? LastFailureCode { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public DateTime UpdatedAtUtc { get; set; }
    public byte[] RowVersion { get; set; } = [];

    public bool HasExactReadyReadback =>
        Status == PurviewKnowYourDataStatus.Ready &&
        ReadbackStatus == ProtectionReadbackStatus.Ready &&
        !string.IsNullOrWhiteSpace(CollectionPolicyProviderId) &&
        LastReadbackAtUtc is not null;
}
