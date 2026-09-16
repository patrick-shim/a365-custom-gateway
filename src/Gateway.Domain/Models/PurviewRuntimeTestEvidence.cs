using System.Collections.Immutable;

namespace Gateway.Domain.Models;

public enum PurviewRuntimeBehaviorObservation
{
    NotVerified,
    BehaviorObserved,
    SubmissionAccepted,
    Failed,
    OutcomeUnknown
}

public sealed record PurviewRuntimeTestCaseEvidence(
    Guid OperationId,
    Guid CaseId,
    Guid? IntendedSensitiveInformationTypeId,
    string ContentHash,
    string SuiteHash,
    string ConfigurationFingerprint,
    PurviewRuntimeBehaviorObservation Behavior,
    PurviewRuntimeProbeResult Observation)
{
    public string SitMatchAttribution => "Unavailable";
    public override string ToString() => $"{nameof(PurviewRuntimeTestCaseEvidence)} {{ CaseId = {CaseId:D} }}";
}

public sealed class PurviewRuntimeTestBatchEvidence
{
    public PurviewRuntimeTestBatchEvidence(
        Guid operationId,
        string suiteHash,
        string configurationFingerprint,
        IEnumerable<PurviewRuntimeTestCaseEvidence> cases,
        DateTimeOffset completedAtUtc,
        DateTimeOffset? tokenRolesVerifiedAtUtc = null,
        DateTimeOffset? credentialExpiresAtUtc = null,
        string? failureCode = null)
    {
        OperationId = operationId;
        SuiteHash = suiteHash;
        ConfigurationFingerprint = configurationFingerprint;
        Cases = cases.ToImmutableArray();
        CompletedAtUtc = completedAtUtc;
        TokenRolesVerifiedAtUtc = tokenRolesVerifiedAtUtc;
        CredentialExpiresAtUtc = credentialExpiresAtUtc;
        FailureCode = failureCode is null ? null : PurviewRuntimeTestFailureCodes.Normalize(failureCode);
    }

    public Guid OperationId { get; }
    public string SuiteHash { get; }
    public string ConfigurationFingerprint { get; }
    public ImmutableArray<PurviewRuntimeTestCaseEvidence> Cases { get; }
    public DateTimeOffset CompletedAtUtc { get; }
    public DateTimeOffset? TokenRolesVerifiedAtUtc { get; }
    public DateTimeOffset? CredentialExpiresAtUtc { get; }
    public string? FailureCode { get; }
    public string SitMatchAttribution => "Unavailable";
    public override string ToString() => $"{nameof(PurviewRuntimeTestBatchEvidence)} {{ OperationId = {OperationId:D} }}";
}
