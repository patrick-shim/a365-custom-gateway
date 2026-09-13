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
    public PurviewPolicyMode? PolicyMode { get; set; }
    public PurviewPolicyMode EffectivePolicyMode =>
        PolicyMode ?? PurviewPolicyModeCompatibility.FromLegacy(Mode);
    public ICollection<PurviewSelectedSensitiveInformationType> SensitiveInformationTypes { get; set; } =
        new List<PurviewSelectedSensitiveInformationType>();
    public IReadOnlyList<PurviewSelectedSensitiveInformationType> NormalizedSensitiveInformationTypes =>
        (SensitiveInformationTypes.Count == 0
            ? [new PurviewSelectedSensitiveInformationType(SensitiveInformationTypeId.Value, SensitiveInformationTypeName)]
            : SensitiveInformationTypes.ToArray()).OrderBy(value => value.Id).ToArray();
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
    public string? RuntimeBehaviorSuiteHash { get; set; }
    public DateTime? RuntimeBehaviorVerifiedUntilUtc { get; set; }
    public Guid? RuntimeBehaviorCertificationOperationId { get; set; }
    public string? LastFailureCode { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public DateTime UpdatedAtUtc { get; set; }
    public byte[] RowVersion { get; set; } = [];

    public bool HasVerifiedNonEnforcingConfiguration =>
        EffectivePolicyMode != PurviewPolicyMode.Enforce &&
        Status is PurviewDlpProfileStatus.SimulationReady or PurviewDlpProfileStatus.Disabled &&
        Readiness.Readback == ProtectionReadbackStatus.Ready &&
        LastReadbackAtUtc is not null &&
        !string.IsNullOrWhiteSpace(DlpPolicyProviderId) && !string.IsNullOrWhiteSpace(DlpRuleProviderId);

    public bool IsExactlyReadyFor(
        BlueprintApplicationId blueprintApplicationId,
        DateTime utcNow,
        bool runtimeCertificationCurrent = false) =>
        runtimeCertificationCurrent && HasRuntimeEvidenceFor(blueprintApplicationId, utcNow);

    // Historical evidence must also be checked against the current certified deployment context.
    public bool HasRuntimeEvidenceFor(
        BlueprintApplicationId blueprintApplicationId,
        DateTime utcNow) =>
        utcNow.Kind == DateTimeKind.Utc &&
        EffectivePolicyMode == PurviewPolicyMode.Enforce &&
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
        RuntimeBlockVerifiedAtUtc is not null &&
        RuntimeBehaviorCertificationOperationId is { } certificationId && certificationId != Guid.Empty &&
        RuntimeBehaviorSuiteHash is { Length: 71 } &&
        RuntimeBehaviorVerifiedUntilUtc is { } until &&
        until.Kind == DateTimeKind.Utc && until > utcNow;
}
