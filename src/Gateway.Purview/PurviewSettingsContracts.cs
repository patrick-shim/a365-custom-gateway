using Gateway.Domain.Enums;
using Gateway.Domain.Models;

namespace Gateway.Purview;

public sealed record PurviewTenantConnectionOperationBinding(
    Guid OperationId,
    Guid TenantId,
    Guid AdministratorObjectId,
    Guid InventoryGenerationId,
    DateTimeOffset ExpiresAtUtc);

public sealed record PurviewSensitiveInformationTypeEvidence(
    string Id,
    string ExactName,
    string Publisher);

public sealed record PurviewTenantConnectionCompanionEvidence(
    string OperationId,
    string TenantId,
    string AdministratorObjectId,
    string InventoryGenerationId,
    DateTimeOffset ObservedAtUtc,
    DateTimeOffset InventoryExpiresAtUtc,
    IReadOnlyList<string> AuthorizedCapabilities,
    IReadOnlyList<PurviewSensitiveInformationTypeEvidence> SensitiveInformationTypes);

public sealed record PurviewSensitiveInformationTypeProjection(
    Guid Id,
    string ExactName,
    string Publisher,
    int SortOrder);

public sealed record PurviewTenantSensitiveInformationTypeInventory(
    Guid GenerationId,
    Guid TenantId,
    DateTimeOffset RetrievedAtUtc,
    DateTimeOffset ExpiresAtUtc,
    IReadOnlyList<PurviewSensitiveInformationTypeProjection> Items);

public sealed record ValidatedPurviewTenantConnectionEvidence(
    Guid OperationId,
    Guid TenantId,
    Guid AdministratorObjectId,
    DateTimeOffset AuthorizedAtUtc,
    DateTimeOffset ExpiresAtUtc,
    IReadOnlyList<string> AuthorizedCapabilities,
    PurviewTenantSensitiveInformationTypeInventory Inventory);

public sealed record PurviewKnowYourDataIntent(
    Guid OperationId,
    Guid TenantId,
    Guid InventoryGenerationId,
    DateTimeOffset InventoryExpiresAtUtc,
    Guid SensitiveInformationTypeId,
    string SensitiveInformationTypeName,
    string SensitiveInformationTypePublisher,
    string PolicyName,
    PurviewMode Mode,
    IReadOnlyList<PurviewPolicyActivity> Activities,
    bool IngestionEnabled,
    string? ExpectedPolicyProviderId,
    bool PriorCreateOutcomeUnknown = false);

public sealed record PurviewDlpProfileIntent(
    Guid OperationId,
    Guid TenantId,
    Guid InventoryGenerationId,
    DateTimeOffset InventoryExpiresAtUtc,
    Guid SensitiveInformationTypeId,
    string SensitiveInformationTypeName,
    string SensitiveInformationTypePublisher,
    Guid BlueprintApplicationId,
    string PolicyName,
    string RuleName,
    PurviewMode Mode,
    IReadOnlyList<PurviewPolicyActivity> Activities,
    IReadOnlyList<PurviewDlpRuleAction> Actions,
    string? ExpectedPolicyProviderId,
    string? ExpectedRuleProviderId,
    PurviewDlpMutationRecoveryPoint RecoveryPoint =
        PurviewDlpMutationRecoveryPoint.None);

public enum PurviewDlpMutationRecoveryPoint
{
    None,
    PolicyCreationOutcomeUnknown,
    RuleCreationOutcomeUnknown
}

public sealed record PurviewKnowYourDataReadback(
    string PolicyProviderId,
    Guid TenantId,
    Guid GroupId,
    PurviewPolicyScopeType ScopeType,
    PurviewEnforcementPlane EnforcementPlane,
    Guid SensitiveInformationTypeId,
    string SensitiveInformationTypeName,
    string SensitiveInformationTypePublisher,
    PurviewMode Mode,
    IReadOnlyList<PurviewPolicyActivity> Activities,
    bool IngestionEnabled,
    DateTimeOffset ObservedAtUtc);

public sealed record PurviewDlpProfileReadback(
    string PolicyProviderId,
    string? RuleProviderId,
    Guid TenantId,
    IReadOnlyList<Guid> BlueprintApplicationIds,
    PurviewPolicyScopeType ScopeType,
    PurviewEnforcementPlane EnforcementPlane,
    Guid SensitiveInformationTypeId,
    string SensitiveInformationTypeName,
    string SensitiveInformationTypePublisher,
    PurviewMode Mode,
    IReadOnlyList<PurviewPolicyActivity> Activities,
    IReadOnlyList<PurviewDlpRuleAction> Actions,
    bool HasExclusions,
    bool HasBypass,
    DateTimeOffset ObservedAtUtc);

public enum PurviewProviderObjectState
{
    Absent,
    PolicyOnlyExact,
    Exact,
    Mismatch,
    Unknown
}

public sealed record PurviewProviderReadback<T>(
    PurviewProviderObjectState State,
    T? Value)
    where T : class
{
    public static PurviewProviderReadback<T> Absent() =>
        new(PurviewProviderObjectState.Absent, null);

    public static PurviewProviderReadback<T> PolicyOnly(T value) =>
        new(PurviewProviderObjectState.PolicyOnlyExact, value);

    public static PurviewProviderReadback<T> Mismatch() =>
        new(PurviewProviderObjectState.Mismatch, null);

    public static PurviewProviderReadback<T> Unknown() =>
        new(PurviewProviderObjectState.Unknown, null);
}

public static class PurviewProviderReadback
{
    public static PurviewProviderReadback<T> Exact<T>(T value)
        where T : class =>
        new(PurviewProviderObjectState.Exact, value);

    public static PurviewProviderReadback<T> PolicyOnly<T>(T value)
        where T : class =>
        new(PurviewProviderObjectState.PolicyOnlyExact, value);
}

public enum PurviewSettingsOperationDisposition
{
    AlreadyExact,
    ExactReadback,
    MutatedAndVerified,
    RecoveredAfterUnknownOutcome,
    RequiresManualIntervention
}

public sealed record PurviewSettingsOperationResult<T>(
    PurviewSettingsOperationDisposition Disposition,
    T? Readback,
    string? FailureCode)
    where T : class;

public sealed record PurviewReadinessEvidence(
    ProtectionCapabilityStatus Capability,
    ProtectionReadbackStatus Readback,
    ProtectionPropagationStatus Propagation,
    ProtectionTokenRoleStatus TokenRoles,
    ProtectionRuntimeVerdictStatus RuntimeVerdict,
    DateTimeOffset? ExactReadbackAtUtc = null,
    DateTimeOffset? PropagationVerifiedAtUtc = null,
    DateTimeOffset? TokenRolesVerifiedAtUtc = null,
    DateTimeOffset? RuntimeAllowVerifiedAtUtc = null,
    DateTimeOffset? RuntimeBlockVerifiedAtUtc = null);

internal enum PurviewSettingsAutomationMutation
{
    CreateKnowYourData,
    CreateDlpPolicy,
    CreateDlpRule
}

internal interface IPurviewSettingsAutomation
{
    Task<PurviewProviderReadback<PurviewKnowYourDataReadback>>
        ReadKnowYourDataAsync(
            PurviewKnowYourDataIntent intent,
            CancellationToken cancellationToken);

    Task CreateKnowYourDataAsync(
        PurviewKnowYourDataIntent intent,
        CancellationToken cancellationToken);

    Task<PurviewProviderReadback<PurviewDlpProfileReadback>>
        ReadDlpProfileAsync(
            PurviewDlpProfileIntent intent,
            CancellationToken cancellationToken);

    Task CreateDlpPolicyAsync(
        PurviewDlpProfileIntent intent,
        CancellationToken cancellationToken);

    Task CreateDlpRuleAsync(
        PurviewDlpProfileIntent intent,
        CancellationToken cancellationToken);
}

public interface IPurviewSettingsProvider
{
    Task<PurviewSettingsOperationResult<PurviewKnowYourDataReadback>>
        EnsureKnowYourDataAsync(
            PurviewKnowYourDataIntent intent,
            CancellationToken cancellationToken);

    Task<PurviewSettingsOperationResult<PurviewKnowYourDataReadback>>
        VerifyKnowYourDataAsync(
            PurviewKnowYourDataIntent intent,
            CancellationToken cancellationToken);

    Task<PurviewSettingsOperationResult<PurviewDlpProfileReadback>>
        EnsureDlpProfileAsync(
            PurviewDlpProfileIntent intent,
            CancellationToken cancellationToken);

    Task<PurviewSettingsOperationResult<PurviewDlpProfileReadback>>
        VerifyDlpProfileAsync(
            PurviewDlpProfileIntent intent,
            CancellationToken cancellationToken);

    Task<PurviewSettingsOperationResult<PurviewDlpProfileReadback>>
        ReconcileDlpProfileAsync(
            PurviewDlpProfileIntent intent,
            CancellationToken cancellationToken);
}

internal sealed class PurviewMutationOutcomeUnknownException : Exception
{
    public string FailureCode { get; }

    public PurviewMutationOutcomeUnknownException(
        string failureCode,
        Exception? innerException = null)
        : base("The Purview mutation outcome is unknown and requires exact readback.", innerException)
    {
        FailureCode = failureCode;
    }
}
