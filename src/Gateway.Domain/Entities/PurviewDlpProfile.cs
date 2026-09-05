using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Entities;

public class PurviewDlpProfile
{
    public PurviewDlpProfileId Id { get; set; }
    public Guid PurviewTenantConnectionId { get; set; }
    public BlueprintApplicationId BlueprintApplicationId { get; set; }
    public string DisplayName { get; set; } = string.Empty;
    public SensitiveInformationTypeSnapshotGenerationId InventoryGenerationId { get; set; }
    public DateTime SensitiveInformationTypeSnapshotExpiresAtUtc { get; set; }
    public SensitiveInformationTypeId SensitiveInformationTypeId { get; set; }
    public string SensitiveInformationTypeName { get; set; } = string.Empty;
    public PurviewMode Mode { get; set; }
    public ICollection<PurviewPolicyActivity> Activities { get; set; } =
        new List<PurviewPolicyActivity>();
    public ICollection<PurviewDlpRuleAction> Actions { get; set; } =
        new List<PurviewDlpRuleAction>();
    public PurviewPolicyScopeType ScopeType => PurviewPolicyScopeType.Individual;
    public PurviewEnforcementPlane EnforcementPlane => PurviewEnforcementPlane.Application;
    public PurviewDlpProfileStatus Status { get; set; }
    public ProtectionReadiness Readiness { get; set; } = ProtectionReadiness.NotEvaluated;
    public string? DlpPolicyProviderId { get; set; }
    public string? DlpRuleProviderId { get; set; }
    public DateTime? LastReadbackAtUtc { get; set; }
    public DateTime? PropagationVerifiedAtUtc { get; set; }
    public DateTime? TokenRolesVerifiedAtUtc { get; set; }
    public DateTime? RuntimeAllowVerifiedAtUtc { get; set; }
    public DateTime? RuntimeBlockVerifiedAtUtc { get; set; }
    public string? LastFailureCode { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public DateTime UpdatedAtUtc { get; set; }
    public byte[] RowVersion { get; set; } = [];

    public bool IsExactlyReadyFor(
        BlueprintApplicationId blueprintApplicationId,
        DateTime utcNow) =>
        utcNow.Kind == DateTimeKind.Utc &&
        BlueprintApplicationId == blueprintApplicationId &&
        Status == PurviewDlpProfileStatus.Ready &&
        Readiness.IsReady &&
        utcNow < SensitiveInformationTypeSnapshotExpiresAtUtc &&
        !string.IsNullOrWhiteSpace(DlpPolicyProviderId) &&
        !string.IsNullOrWhiteSpace(DlpRuleProviderId) &&
        LastReadbackAtUtc is not null &&
        PropagationVerifiedAtUtc is not null &&
        TokenRolesVerifiedAtUtc is not null &&
        RuntimeAllowVerifiedAtUtc is not null &&
        RuntimeBlockVerifiedAtUtc is not null;
}
