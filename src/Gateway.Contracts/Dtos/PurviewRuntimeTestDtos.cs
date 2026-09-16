using System.Collections.Immutable;
using System.Text.Json.Serialization;

namespace Gateway.Contracts.Dtos;

public sealed record PurviewRuntimeTestSampleManifestDto(
    Guid CaseId,
    Guid? IntendedSensitiveInformationTypeId,
    string ContentHash,
    int Utf8ByteCount)
{
    public override string ToString() => $"{nameof(PurviewRuntimeTestSampleManifestDto)} {{ CaseId = {CaseId:D} }}";
}

public sealed class PurviewRuntimeTestSuiteManifestDto
{
    [JsonConstructor]
    public PurviewRuntimeTestSuiteManifestDto(
        string suiteNonce,
        IReadOnlyList<PurviewRuntimeTestSampleManifestDto> positiveSamples,
        PurviewRuntimeTestSampleManifestDto negativeSample)
    {
        SuiteNonce = suiteNonce;
        PositiveSamples = positiveSamples?.ToImmutableArray() ?? [];
        NegativeSample = negativeSample;
    }

    public string SuiteNonce { get; }
    public IReadOnlyList<PurviewRuntimeTestSampleManifestDto> PositiveSamples { get; }
    public PurviewRuntimeTestSampleManifestDto NegativeSample { get; }
    public override string ToString() => nameof(PurviewRuntimeTestSuiteManifestDto);
}

// This type is exclusively an incoming/outgoing TLS request body, never persisted operation state.
public sealed record PurviewRuntimeTestSampleContentDto(Guid CaseId, string Content)
{
    public override string ToString() =>
        $"{nameof(PurviewRuntimeTestSampleContentDto)} {{ CaseId = {CaseId:D}, Content = [redacted] }}";
}

public sealed record PurviewRuntimeTestLimitsDto(
    int MaximumPositiveSamplesPerBatch,
    int MaximumUtf8BytesPerSample,
    int MaximumUtf8BytesPerBatch,
    int ExecutionDeadlineSeconds);

public sealed class PurviewRuntimeTestReviewDto
{
    [JsonConstructor]
    public PurviewRuntimeTestReviewDto(
        Guid tenantId,
        Guid profileId,
        Guid agentRegistrationId,
        Guid childApplicationId,
        Guid blueprintApplicationId,
        Guid actorObjectId,
        Guid inventoryGenerationId,
        string policyMode,
        string suiteHash,
        string configurationFingerprint,
        string reviewedContextFingerprint,
        IReadOnlyList<PurviewSensitiveInformationTypeSelectionDto> sensitiveInformationTypes,
        PurviewRuntimeTestSuiteManifestDto suite,
        IReadOnlyList<Guid> positiveCaseIds,
        PurviewRuntimeTestLimitsDto limits)
    {
        TenantId = tenantId;
        ProfileId = profileId;
        AgentRegistrationId = agentRegistrationId;
        ChildApplicationId = childApplicationId;
        BlueprintApplicationId = blueprintApplicationId;
        ActorObjectId = actorObjectId;
        InventoryGenerationId = inventoryGenerationId;
        PolicyMode = policyMode;
        SuiteHash = suiteHash;
        ConfigurationFingerprint = configurationFingerprint;
        ReviewedContextFingerprint = reviewedContextFingerprint;
        SensitiveInformationTypes = sensitiveInformationTypes?.ToImmutableArray() ?? [];
        Suite = suite;
        PositiveCaseIds = positiveCaseIds?.ToImmutableArray() ?? [];
        Limits = limits;
    }

    public Guid TenantId { get; }
    public Guid ProfileId { get; }
    public Guid AgentRegistrationId { get; }
    public Guid ChildApplicationId { get; }
    public Guid BlueprintApplicationId { get; }
    public Guid ActorObjectId { get; }
    public Guid InventoryGenerationId { get; }
    public string PolicyMode { get; }
    public string SuiteHash { get; }
    public string ConfigurationFingerprint { get; }
    public string ReviewedContextFingerprint { get; }
    public IReadOnlyList<PurviewSensitiveInformationTypeSelectionDto> SensitiveInformationTypes { get; }
    public PurviewRuntimeTestSuiteManifestDto Suite { get; }
    public IReadOnlyList<Guid> PositiveCaseIds { get; }
    public PurviewRuntimeTestLimitsDto Limits { get; }
    public string VerificationScope => "ApprovedSampleBehaviorInEffectivePolicyScope";
    public string SitMatchAttribution => "Unavailable";
    public override string ToString() => nameof(PurviewRuntimeTestReviewDto);
}

public sealed record PurviewRuntimeTestCaseResultDto(
    Guid CaseId,
    Guid? IntendedSensitiveInformationTypeId,
    string ContentHash,
    string ObservedDecision,
    string ContentProcessing,
    string ActionSource,
    DateTimeOffset ObservedAtUtc,
    string? FailureCode,
    string? ScopeFingerprint = null)
{
    public override string ToString() => $"{nameof(PurviewRuntimeTestCaseResultDto)} {{ CaseId = {CaseId:D} }}";
}
