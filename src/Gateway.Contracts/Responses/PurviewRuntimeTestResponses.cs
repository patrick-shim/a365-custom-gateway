using System.Collections.Immutable;
using System.Text.Json.Serialization;
using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

public sealed record PurviewRuntimeTestReviewResponse(
    Guid ReviewTokenId,
    string ReviewToken,
    string ReviewedPayloadHash,
    DateTime ExpiresAtUtc,
    PurviewRuntimeTestReviewDto Review)
{
    public override string ToString() => $"{nameof(PurviewRuntimeTestReviewResponse)} {{ Token = [redacted] }}";
}

public sealed class PurviewRuntimeTestResultResponse
{
    [JsonConstructor]
    public PurviewRuntimeTestResultResponse(
        Guid operationId,
        string status,
        string outcome,
        string policyMode,
        string suiteHash,
        string configurationFingerprint,
        string profileRowVersion,
        DateTimeOffset? completedAtUtc,
        IReadOnlyList<PurviewRuntimeTestCaseResultDto> cases,
        IReadOnlyList<Guid> outstandingSensitiveInformationTypeIds,
        bool enforcementBehaviorVerified,
        string? failureCode)
    {
        OperationId = operationId;
        Status = status;
        Outcome = outcome;
        PolicyMode = policyMode;
        SuiteHash = suiteHash;
        ConfigurationFingerprint = configurationFingerprint;
        ProfileRowVersion = profileRowVersion;
        CompletedAtUtc = completedAtUtc;
        Cases = cases?.ToImmutableArray() ?? [];
        OutstandingSensitiveInformationTypeIds = outstandingSensitiveInformationTypeIds?.ToImmutableArray() ?? [];
        EnforcementBehaviorVerified = enforcementBehaviorVerified;
        FailureCode = failureCode;
    }

    public Guid OperationId { get; }
    public string Status { get; }
    public string Outcome { get; }
    public string PolicyMode { get; }
    public string SuiteHash { get; }
    public string ConfigurationFingerprint { get; }
    public string ProfileRowVersion { get; }
    public DateTimeOffset? CompletedAtUtc { get; }
    public IReadOnlyList<PurviewRuntimeTestCaseResultDto> Cases { get; }
    public IReadOnlyList<Guid> OutstandingSensitiveInformationTypeIds { get; }
    public bool EnforcementBehaviorVerified { get; }
    public string? FailureCode { get; }
    public string VerificationScope => "ApprovedSampleBehaviorInEffectivePolicyScope";
    public string SitMatchAttribution => "Unavailable";
    public override string ToString() => $"{nameof(PurviewRuntimeTestResultResponse)} {{ OperationId = {OperationId:D} }}";
}
