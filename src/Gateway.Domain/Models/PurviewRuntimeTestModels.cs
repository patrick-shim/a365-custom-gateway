using System.Collections.Immutable;
using Gateway.Domain.Enums;

namespace Gateway.Domain.Models;

public static class PurviewRuntimeTestLimits
{
    public const int MaximumSelectedTypes = 100;
    public const int MaximumPositiveSamplesPerBatch = 8;
    public const int MaximumUtf8BytesPerSample = 8 * 1024;
    public const int MaximumUtf8BytesPerBatch = 64 * 1024;
    public const int SuiteNonceBytes = 32;
    public static readonly TimeSpan ExecutionDeadline = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan MaximumEvidenceAge = TimeSpan.FromMinutes(30);
}

public static class PurviewRuntimeTestFailureCodes
{
    public const string ManifestInvalid = "PURVIEW_RUNTIME_MANIFEST_INVALID";
    public const string SampleMismatch = "PURVIEW_RUNTIME_SAMPLE_MISMATCH";
    public const string SampleBoundsExceeded = "PURVIEW_RUNTIME_SAMPLE_BOUNDS_EXCEEDED";
    public const string SampleUtf8Invalid = "PURVIEW_RUNTIME_SAMPLE_UTF8_INVALID";
    public const string SyntheticApprovalRequired = "PURVIEW_RUNTIME_SYNTHETIC_APPROVAL_REQUIRED";
    public const string ContextInvalid = "PURVIEW_RUNTIME_CONTEXT_INVALID";
    public const string ContextChanged = "PURVIEW_RUNTIME_CONTEXT_CHANGED";
    public const string InventoryExpired = "PURVIEW_RUNTIME_INVENTORY_EXPIRED";
    public const string Disabled = "PURVIEW_RUNTIME_DISABLED";
    public const string NoInlineDecision = "PURVIEW_RUNTIME_NO_INLINE_DECISION";
    public const string UnexpectedVerdict = "PURVIEW_RUNTIME_UNEXPECTED_VERDICT";
    public const string ProviderUnavailable = "PURVIEW_RUNTIME_PROVIDER_UNAVAILABLE";
    public const string DeadlineExceeded = "PURVIEW_RUNTIME_DEADLINE_EXCEEDED";
    public const string OutcomeUnknown = "PURVIEW_RUNTIME_OUTCOME_UNKNOWN";
    public const string SamplesRequired = "PURVIEW_RUNTIME_SAMPLES_REQUIRED";

    public static string Normalize(string? value) => value switch
    {
        ManifestInvalid or SampleMismatch or SampleBoundsExceeded or SampleUtf8Invalid or
        SyntheticApprovalRequired or ContextInvalid or ContextChanged or InventoryExpired or
        Disabled or NoInlineDecision or UnexpectedVerdict or ProviderUnavailable or
        DeadlineExceeded or OutcomeUnknown or SamplesRequired => value,
        _ => OutcomeUnknown
    };
}

public sealed record PurviewRuntimeTestIdentityBinding(
    Guid TenantId,
    Guid ActorObjectId,
    Guid ProfileId,
    Guid TenantConnectionId,
    Guid BlueprintApplicationId,
    Guid AgentRegistrationId,
    Guid ChildApplicationId,
    Guid RuntimePrincipalObjectId);

public sealed record PurviewRuntimeTestVersionBinding(
    string ProfileRowVersion,
    string ConnectionRowVersion,
    string CapabilityRowVersion,
    Guid InventoryGenerationId,
    string InventoryRowVersion,
    DateTimeOffset InventoryExpiresAtUtc,
    string AgentRegistrationRowVersion,
    Guid AgentProtectionRevision = default)
{
    public override string ToString() => nameof(PurviewRuntimeTestVersionBinding);
}

public sealed class PurviewRuntimeTestContext
{
    public PurviewRuntimeTestContext(
        PurviewRuntimeTestIdentityBinding identity,
        PurviewRuntimeTestVersionBinding versions,
        PurviewPolicyMode policyMode,
        string profileDisplayName,
        string policyProviderId,
        string ruleProviderId,
        IEnumerable<PurviewSelectedSensitiveInformationType> selectedTypes,
        IEnumerable<PurviewPolicyActivity> activities,
        IEnumerable<PurviewDlpRuleAction> actions)
    {
        Identity = identity;
        Versions = versions;
        PolicyMode = policyMode;
        ProfileDisplayName = profileDisplayName;
        PolicyProviderId = policyProviderId;
        RuleProviderId = ruleProviderId;
        SelectedTypes = selectedTypes.ToImmutableArray();
        Activities = activities.ToImmutableArray();
        Actions = actions.ToImmutableArray();
    }

    public PurviewRuntimeTestIdentityBinding Identity { get; }
    public PurviewRuntimeTestVersionBinding Versions { get; }
    public PurviewPolicyMode PolicyMode { get; }
    public string ProfileDisplayName { get; }
    public string PolicyProviderId { get; }
    public string RuleProviderId { get; }
    public ImmutableArray<PurviewSelectedSensitiveInformationType> SelectedTypes { get; }
    public ImmutableArray<PurviewPolicyActivity> Activities { get; }
    public ImmutableArray<PurviewDlpRuleAction> Actions { get; }
    public override string ToString() => nameof(PurviewRuntimeTestContext);
}

// IntendedSensitiveInformationTypeId is the administrator's association, not provider attribution.
public sealed record PurviewRuntimeSampleManifest(
    Guid CaseId,
    Guid? IntendedSensitiveInformationTypeId,
    string ContentHash,
    int Utf8ByteCount)
{
    public override string ToString() => $"{nameof(PurviewRuntimeSampleManifest)} {{ CaseId = {CaseId:D} }}";
}

public sealed class PurviewRuntimeTestPlan
{
    public PurviewRuntimeTestPlan(
        PurviewRuntimeTestContext context,
        string suiteNonce,
        IEnumerable<PurviewRuntimeSampleManifest> positiveSamples,
        PurviewRuntimeSampleManifest negativeSample,
        IEnumerable<Guid> positiveCaseIds,
        string suiteHash,
        string configurationFingerprint,
        string reviewedContextFingerprint)
    {
        Context = context;
        SuiteNonce = suiteNonce;
        PositiveSamples = positiveSamples.ToImmutableArray();
        NegativeSample = negativeSample;
        PositiveCaseIds = positiveCaseIds.ToImmutableArray();
        SuiteHash = suiteHash;
        ConfigurationFingerprint = configurationFingerprint;
        ReviewedContextFingerprint = reviewedContextFingerprint;
    }

    public PurviewRuntimeTestContext Context { get; }
    public string SuiteNonce { get; }
    public ImmutableArray<PurviewRuntimeSampleManifest> PositiveSamples { get; }
    public PurviewRuntimeSampleManifest NegativeSample { get; }
    public ImmutableArray<Guid> PositiveCaseIds { get; }
    public string SuiteHash { get; }
    public string ConfigurationFingerprint { get; }
    public string ReviewedContextFingerprint { get; }
    public override string ToString() => nameof(PurviewRuntimeTestPlan);
}

public enum PurviewRuntimeProbeDecision
{
    Unknown,
    Allowed,
    Blocked,
    Warned,
    AuditAccepted,
    NoInlineDecision
}

public enum PurviewRuntimeContentProcessing
{
    NotSubmitted,
    MetadataOnly,
    SubmittedWithoutDecision,
    Processed
}

public enum PurviewRuntimeActionSource
{
    None,
    ProtectionScope,
    Content
}

public sealed class PurviewRuntimeProbeResult
{
    public PurviewRuntimeProbeResult(
        PurviewRuntimeProbeDecision decision,
        PurviewRuntimeContentProcessing contentProcessing,
        PurviewRuntimeActionSource actionSource,
        DateTimeOffset observedAtUtc,
        string? failureCode = null,
        string? scopeFingerprint = null)
    {
        if (!Enum.IsDefined(decision) || !Enum.IsDefined(contentProcessing) ||
            !Enum.IsDefined(actionSource) || observedAtUtc.Offset != TimeSpan.Zero)
            throw new ArgumentException(PurviewRuntimeTestFailureCodes.ContextInvalid);
        Decision = decision;
        ContentProcessing = contentProcessing;
        ActionSource = actionSource;
        ObservedAtUtc = observedAtUtc;
        FailureCode = failureCode is null ? null : PurviewRuntimeTestFailureCodes.Normalize(failureCode);
        if (scopeFingerprint is not null && (scopeFingerprint.Length != 71 ||
            !scopeFingerprint.StartsWith("sha256:", StringComparison.Ordinal) ||
            scopeFingerprint.Skip(7).Any(value => value is not (>= '0' and <= '9' or >= 'a' and <= 'f'))))
            throw new ArgumentException(PurviewRuntimeTestFailureCodes.ContextInvalid);
        ScopeFingerprint = scopeFingerprint;
    }

    public PurviewRuntimeProbeDecision Decision { get; }
    public PurviewRuntimeContentProcessing ContentProcessing { get; }
    public PurviewRuntimeActionSource ActionSource { get; }
    public DateTimeOffset ObservedAtUtc { get; }
    public string? FailureCode { get; }
    public string? ScopeFingerprint { get; }
    public string SitMatchAttribution => "Unavailable";
    public override string ToString() => nameof(PurviewRuntimeProbeResult);
}
