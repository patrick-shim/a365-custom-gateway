using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;

namespace Gateway.Application.Protection;

internal sealed class PurviewRuntimeTestRunner(
    IPurviewRuntimeProbeClient probes,
    IPurviewRuntimeRoleVerifier roles,
    TimeProvider clock) : IPurviewRuntimeTestRunner
{
    public async Task<PurviewRuntimeTestBatchEvidence> RunAsync(
        Guid operationId, PurviewRuntimeTestPlan plan, PurviewRuntimeEphemeralBatch samples,
        DateTimeOffset deadlineUtc, CancellationToken cancellationToken)
    {
        var cases = new List<PurviewRuntimeTestCaseEvidence>();
        PurviewRuntimeRoleEvidence? roleEvidence = null;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var remaining = deadlineUtc - clock.GetUtcNow();
        if (remaining <= TimeSpan.Zero || remaining > PurviewRuntimeTestLimits.ExecutionDeadline)
            return Result(PurviewRuntimeTestFailureCodes.DeadlineExceeded);
        if (plan.Context.PolicyMode == PurviewPolicyMode.Disabled)
            return Result(PurviewRuntimeTestFailureCodes.Disabled);
        deadline.CancelAfter(remaining);
        try
        {
            roleEvidence = await roles.VerifyAsync(plan.Context.Identity.TenantId, deadline.Token);
            if (!roleEvidence.Ready || roleEvidence.ObservedAtUtc.Offset != TimeSpan.Zero ||
                roleEvidence.ObservedAtUtc > clock.GetUtcNow().AddMinutes(2) ||
                roleEvidence.ObservedAtUtc < clock.GetUtcNow().AddMinutes(-30) ||
                roleEvidence.CredentialExpiresAtUtc is null || roleEvidence.CredentialExpiresAtUtc <= clock.GetUtcNow())
                return Result(PurviewRuntimeTestFailureCodes.ProviderUnavailable);

            foreach (var caseId in plan.PositiveCaseIds.Prepend(plan.NegativeSample.CaseId))
            {
                deadline.Token.ThrowIfCancellationRequested();
                var observation = await probes.ProbeAsync(operationId, plan.Context, samples.GetSample(caseId), deadlineUtc, deadline.Token);
                var evidence = PurviewRuntimeTestEvidenceFactory.Capture(plan, operationId, caseId, observation, clock.GetUtcNow());
                cases.Add(evidence);
                if (evidence.Behavior is PurviewRuntimeBehaviorObservation.Failed or
                    PurviewRuntimeBehaviorObservation.NotVerified or PurviewRuntimeBehaviorObservation.OutcomeUnknown)
                    return Result(observation.FailureCode ?? PurviewRuntimeTestFailureCodes.UnexpectedVerdict);
            }
            return Result(null);
        }
        catch (OperationCanceledException)
        {
            return Result(cancellationToken.IsCancellationRequested
                ? PurviewRuntimeTestFailureCodes.OutcomeUnknown : PurviewRuntimeTestFailureCodes.DeadlineExceeded);
        }
        catch (Exception)
        {
            return Result(PurviewRuntimeTestFailureCodes.OutcomeUnknown);
        }

        PurviewRuntimeTestBatchEvidence Result(string? code) => new(
            operationId, plan.SuiteHash, plan.ConfigurationFingerprint, cases, clock.GetUtcNow(),
            roleEvidence?.Ready == true ? roleEvidence.ObservedAtUtc : null,
            roleEvidence?.CredentialExpiresAtUtc, code);
    }
}
