using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.Models;

public static class RuntimeTestUiProtocol
{
    public const int MaximumSampleBytes = 8192;
    public const int MaximumBatchBytes = 65536;
    public const int MaximumBatchPositives = 8;
    public const int MaximumSelectedTypes = 100;
    public const int BrowserExecutionBudgetSeconds = 210;
    public const int InteropExecutionTimeoutSeconds = 225;

    public static bool IsHash(string? value) => value is { Length: 71 } && value.StartsWith("sha256:", StringComparison.Ordinal) &&
        value.AsSpan(7).IndexOfAnyExcept("0123456789abcdef") < 0;
    public static bool IsNonce(string? value) => value is { Length: 64 } && value.AsSpan().IndexOfAnyExcept("0123456789abcdef") < 0;

    public static bool ValidManifest(PurviewRuntimeTestSuiteManifestDto? suite, IReadOnlyList<Guid> selectedIds)
    {
        if (suite is null || !IsNonce(suite.SuiteNonce) || suite.NegativeSample is null ||
            suite.PositiveSamples.Count is < 1 or > MaximumSelectedTypes || suite.PositiveSamples.Count != selectedIds.Count ||
            suite.PositiveSamples.Any(sample => sample is null) || suite.NegativeSample.IntendedSensitiveInformationTypeId is not null)
            return false;
        var all = suite.PositiveSamples.Append(suite.NegativeSample).ToArray();
        return all.All(sample => sample.CaseId != Guid.Empty && IsHash(sample.ContentHash) &&
                   sample.Utf8ByteCount is > 0 and <= MaximumSampleBytes) &&
            all.Select(sample => sample.CaseId).Distinct().Count() == all.Length &&
            all.Select(sample => sample.ContentHash).Distinct(StringComparer.Ordinal).Count() == all.Length &&
            suite.PositiveSamples.All(sample => sample.IntendedSensitiveInformationTypeId is { } id && id != Guid.Empty) &&
            suite.PositiveSamples.Select(sample => sample.IntendedSensitiveInformationTypeId!.Value).ToHashSet().SetEquals(selectedIds) &&
            selectedIds.Distinct().Count() == selectedIds.Count;
    }

    public static bool ValidBatch(PurviewRuntimeTestSuiteManifestDto suite, IReadOnlyList<Guid> batch) =>
        batch.Count is > 0 and <= MaximumBatchPositives && batch.Distinct().Count() == batch.Count &&
        batch.All(id => suite.PositiveSamples.Any(sample => sample.CaseId == id)) &&
        suite.PositiveSamples.Where(sample => batch.Contains(sample.CaseId)).Sum(sample => sample.Utf8ByteCount) +
            suite.NegativeSample.Utf8ByteCount <= MaximumBatchBytes;

    public static bool SameSuite(PurviewRuntimeTestSuiteManifestDto left, PurviewRuntimeTestSuiteManifestDto right) =>
        left.SuiteNonce == right.SuiteNonce && left.NegativeSample == right.NegativeSample &&
        left.PositiveSamples.Count == right.PositiveSamples.Count && left.PositiveSamples.ToHashSet().SetEquals(right.PositiveSamples);

    public static bool Matches(ReviewPurviewDlpRuntimeTestRequest request, PurviewRuntimeTestReviewDto review) =>
        request.AcknowledgeSyntheticData && request.ProfileId == review.ProfileId && request.InventoryGenerationId == review.InventoryGenerationId &&
        review.AgentRegistrationId != Guid.Empty && review.ChildApplicationId != Guid.Empty && review.BlueprintApplicationId != Guid.Empty &&
        review.ActorObjectId != Guid.Empty && review.TenantId != Guid.Empty &&
        IsHash(review.SuiteHash) && IsHash(review.ConfigurationFingerprint) && IsHash(review.ReviewedContextFingerprint) &&
        ValidManifest(request.Suite, review.SensitiveInformationTypes.Select(item => item.SensitiveInformationTypeId).ToArray()) &&
        review.SensitiveInformationTypes.All(AgentProtectionUiMapping.HasExplicitThresholds) &&
        SameSuite(request.Suite, review.Suite) && ValidBatch(request.Suite, request.PositiveCaseIds) &&
        request.PositiveCaseIds.Count == review.PositiveCaseIds.Count && request.PositiveCaseIds.ToHashSet().SetEquals(review.PositiveCaseIds) &&
        review.Limits.MaximumPositiveSamplesPerBatch is > 0 and <= MaximumBatchPositives &&
        review.Limits.MaximumUtf8BytesPerSample is > 0 and <= MaximumSampleBytes &&
        review.Limits.MaximumUtf8BytesPerBatch is > 0 and <= MaximumBatchBytes &&
        review.Limits.ExecutionDeadlineSeconds is > 0 and <= 60 &&
        request.PositiveCaseIds.Count <= review.Limits.MaximumPositiveSamplesPerBatch &&
        request.Suite.PositiveSamples.Append(request.Suite.NegativeSample).All(sample => sample.Utf8ByteCount <= review.Limits.MaximumUtf8BytesPerSample) &&
        request.Suite.PositiveSamples.Where(sample => request.PositiveCaseIds.Contains(sample.CaseId)).Sum(sample => sample.Utf8ByteCount) +
            request.Suite.NegativeSample.Utf8ByteCount <= review.Limits.MaximumUtf8BytesPerBatch;

    public static bool IsSafeReport(PurviewRuntimeTestResultResponse report, Guid operationId) =>
        report.OperationId == operationId && operationId != Guid.Empty &&
        report.Status is "AwaitingConfirmation" or "Running" or "Completed" or "RequiresManualIntervention" or "Failed" &&
        report.Outcome is "Partial" or "EnforcementBehaviorVerified" or "SimulationExercised" or "SubmissionAccepted" or "Disabled" or "Failed" or "OutcomeUnknown" &&
        report.PolicyMode is "Enforce" or "SimulationWithTips" or "SimulationWithoutTips" or "Disabled" &&
        IsHash(report.SuiteHash) && IsHash(report.ConfigurationFingerprint) && IsRowVersion(report.ProfileRowVersion) &&
        report.Cases.Count <= MaximumBatchPositives + 1 && report.OutstandingSensitiveInformationTypeIds.Count <= MaximumSelectedTypes &&
        (!report.EnforcementBehaviorVerified || report.PolicyMode == "Enforce" && report.Outcome == "EnforcementBehaviorVerified" &&
            report.OutstandingSensitiveInformationTypeIds.Count == 0) &&
        (report.PolicyMode != "Disabled" || !report.EnforcementBehaviorVerified && report.Cases.All(item => item.ContentProcessing == "NotSubmitted")) &&
        report.OutstandingSensitiveInformationTypeIds.All(id => id != Guid.Empty) && SafeFailure(report.FailureCode) &&
        report.Cases.All(item => item.CaseId != Guid.Empty && IsHash(item.ContentHash) &&
            item.ObservedDecision is "Unknown" or "Allowed" or "Blocked" or "Warned" or "AuditAccepted" or "NoInlineDecision" &&
            item.ContentProcessing is "NotSubmitted" or "MetadataOnly" or "SubmittedWithoutDecision" or "Processed" &&
            item.ActionSource is "None" or "ProtectionScope" or "Content" &&
            SafeFailure(item.FailureCode) && (item.ScopeFingerprint is null || IsHash(item.ScopeFingerprint)));

    private static bool IsRowVersion(string value)
    {
        try { var bytes = Convert.FromBase64String(value); return bytes.Length == 8 && Convert.ToBase64String(bytes) == value; }
        catch (FormatException) { return false; }
    }

    private static bool SafeFailure(string? code) => code is null or
        "PURVIEW_RUNTIME_MANIFEST_INVALID" or "PURVIEW_RUNTIME_SAMPLE_MISMATCH" or "PURVIEW_RUNTIME_SAMPLE_BOUNDS_EXCEEDED" or
        "PURVIEW_RUNTIME_SAMPLE_UTF8_INVALID" or "PURVIEW_RUNTIME_SYNTHETIC_APPROVAL_REQUIRED" or "PURVIEW_RUNTIME_CONTEXT_INVALID" or
        "PURVIEW_RUNTIME_CONTEXT_CHANGED" or "PURVIEW_RUNTIME_INVENTORY_EXPIRED" or "PURVIEW_RUNTIME_DISABLED" or
        "PURVIEW_RUNTIME_NO_INLINE_DECISION" or "PURVIEW_RUNTIME_UNEXPECTED_VERDICT" or "PURVIEW_RUNTIME_PROVIDER_UNAVAILABLE" or
        "PURVIEW_RUNTIME_DEADLINE_EXCEEDED" or "PURVIEW_RUNTIME_OUTCOME_UNKNOWN" or "PURVIEW_RUNTIME_SAMPLES_REQUIRED";
}
