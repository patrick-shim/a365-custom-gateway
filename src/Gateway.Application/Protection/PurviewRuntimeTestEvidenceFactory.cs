using Gateway.Domain.Enums;
using Gateway.Domain.Models;

namespace Gateway.Application.Protection;

internal static class PurviewRuntimeTestEvidenceFactory
{
    public static PurviewRuntimeTestCaseEvidence Capture(
        PurviewRuntimeTestPlan plan,
        Guid operationId,
        Guid caseId,
        PurviewRuntimeProbeResult observation,
        DateTimeOffset utcNow)
    {
        var manifest = caseId == plan.NegativeSample.CaseId
            ? plan.NegativeSample
            : plan.PositiveSamples.SingleOrDefault(sample =>
                sample.CaseId == caseId && plan.PositiveCaseIds.Contains(caseId));
        if (operationId == Guid.Empty || manifest is null || observation is null ||
            utcNow.Offset != TimeSpan.Zero ||
            observation.ObservedAtUtc > utcNow.AddMinutes(2) ||
            observation.ObservedAtUtc < utcNow.Subtract(PurviewRuntimeTestLimits.MaximumEvidenceAge))
            throw new PurviewRuntimeTestValidationException(PurviewRuntimeTestFailureCodes.ContextInvalid);

        var behavior = Evaluate(plan.Context.PolicyMode, manifest.IntendedSensitiveInformationTypeId is not null, observation);
        return new(operationId, caseId, manifest.IntendedSensitiveInformationTypeId, manifest.ContentHash,
            plan.SuiteHash, plan.ConfigurationFingerprint, behavior, observation);
    }

    private static PurviewRuntimeBehaviorObservation Evaluate(
        PurviewPolicyMode mode,
        bool positive,
        PurviewRuntimeProbeResult observation)
    {
        if (!Enum.IsDefined(mode) || mode == PurviewPolicyMode.Disabled)
            return PurviewRuntimeBehaviorObservation.NotVerified;
        if (observation.FailureCode is not null || observation.Decision == PurviewRuntimeProbeDecision.Unknown)
            return PurviewRuntimeBehaviorObservation.OutcomeUnknown;
        if (observation.ActionSource == PurviewRuntimeActionSource.ProtectionScope)
            return PurviewRuntimeBehaviorObservation.NotVerified;
        if (observation.ContentProcessing != PurviewRuntimeContentProcessing.Processed)
            return mode != PurviewPolicyMode.Enforce &&
                (observation.ContentProcessing is PurviewRuntimeContentProcessing.MetadataOnly or
                    PurviewRuntimeContentProcessing.SubmittedWithoutDecision) &&
                (observation.Decision is PurviewRuntimeProbeDecision.AuditAccepted or
                    PurviewRuntimeProbeDecision.NoInlineDecision)
                    ? PurviewRuntimeBehaviorObservation.SubmissionAccepted
                    : PurviewRuntimeBehaviorObservation.NotVerified;

        if (mode == PurviewPolicyMode.Enforce)
        {
            var expected = positive
                ? observation.Decision == PurviewRuntimeProbeDecision.Blocked &&
                    observation.ActionSource == PurviewRuntimeActionSource.Content
                : observation.Decision == PurviewRuntimeProbeDecision.Allowed;
            return expected ? PurviewRuntimeBehaviorObservation.BehaviorObserved : PurviewRuntimeBehaviorObservation.Failed;
        }

        if (!positive)
            return observation.Decision == PurviewRuntimeProbeDecision.Allowed
                ? PurviewRuntimeBehaviorObservation.BehaviorObserved
                : PurviewRuntimeBehaviorObservation.Failed;

        return observation.Decision switch
        {
            PurviewRuntimeProbeDecision.Allowed or PurviewRuntimeProbeDecision.Warned or PurviewRuntimeProbeDecision.AuditAccepted =>
                PurviewRuntimeBehaviorObservation.BehaviorObserved,
            PurviewRuntimeProbeDecision.Blocked => PurviewRuntimeBehaviorObservation.Failed,
            _ => PurviewRuntimeBehaviorObservation.NotVerified
        };
    }
}
