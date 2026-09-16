using System.Collections.Immutable;
using System.Text.Json;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;

namespace Gateway.Application.Protection;

public sealed class PurviewRuntimeTestAcceptance : IDisposable
{
    internal PurviewRuntimeTestAcceptance(Guid operationId, PurviewRuntimeTestPlan plan,
        PurviewRuntimeEphemeralBatch? samples, PurviewRuntimeTestResultResponse? replay, DateTimeOffset deadlineUtc = default)
    {
        OperationId = operationId;
        Plan = plan;
        Samples = samples;
        Replay = replay;
        DeadlineUtc = deadlineUtc;
    }
    public Guid OperationId { get; }
    internal PurviewRuntimeTestPlan Plan { get; }
    internal PurviewRuntimeEphemeralBatch? Samples { get; }
    internal DateTimeOffset DeadlineUtc { get; }
    public PurviewRuntimeTestResultResponse? Replay { get; }
    public void Dispose() => Samples?.Dispose();
    public override string ToString() => nameof(PurviewRuntimeTestAcceptance);
}

public sealed class PurviewRuntimeTestService : IPurviewRuntimeCertificationVerifier
{
    private readonly IPurviewRuntimeTestRepository _store;
    private readonly IProtectionAdminOperationRepository _operations;
    private readonly IAuditEventRepository _audit;
    private readonly IUnitOfWork _unitOfWork;
    private readonly ProtectionOperationTokenService _tokens;
    private readonly IPurviewRuntimeTestRunner _runner;
    private readonly TimeProvider _clock;
    private readonly IBootstrapPurviewRuntimeBinding? _binding;

    internal PurviewRuntimeTestService(IPurviewRuntimeTestRepository store,
        IProtectionAdminOperationRepository operations, IAuditEventRepository audit,
        IUnitOfWork unitOfWork, ProtectionOperationTokenService tokens,
        IPurviewRuntimeTestRunner runner, TimeProvider clock, IBootstrapPurviewRuntimeBinding? binding = null)
    {
        _store = store;
        _operations = operations;
        _audit = audit;
        _unitOfWork = unitOfWork;
        _tokens = tokens;
        _runner = runner;
        _clock = clock;
        _binding = binding;
    }

    public async Task<PurviewRuntimeTestReviewResponse> ReviewAsync(
        ProtectionActor actor, Guid profileId, ReviewPurviewDlpRuntimeTestRequest request, CancellationToken ct)
    {
        if (request.ProfileId != profileId || profileId == Guid.Empty)
            throw Invalid();
        var (_, context) = await CurrentAsync(actor, profileId, null, ct);
        var plan = PurviewRuntimeTestValidation.CreatePlan(context, request, _clock.GetUtcNow());
        var consentJson = PurviewRuntimeTestSerialization.WriteConsent(new(request, PurviewRuntimeContextEnvelope.From(context)));
        var now = _clock.GetUtcNow().UtcDateTime;
        var operation = new ProtectionAdminOperation
        {
            Id = Guid.NewGuid(), Type = ProtectionAdminOperationType.TestDlpRuntime,
            Status = ProtectionAdminOperationStatus.AwaitingConfirmation,
            TenantId = new(actor.TenantId), ActorObjectId = actor.ObjectId,
            TargetType = ProtectionAdminTargetType.DlpProfile, TargetIdentifier = profileId.ToString("D"),
            ExpectedRowVersion = ProtectionRowVersion.DecodeExpected(request.ExpectedRowVersion),
            IdempotencyKey = new(Guid.NewGuid()), CorrelationId = Guid.NewGuid(),
            RuntimeTestConsentJson = consentJson, RuntimeTestSuiteHash = plan.SuiteHash,
            RuntimeTestConfigurationFingerprint = plan.ConfigurationFingerprint,
            MaximumAttempts = 1, RetryDisposition = ProtectionRetryDisposition.NotApplicable,
            CreatedAtUtc = now, UpdatedAtUtc = now
        };
        var issued = _tokens.IssueReview(operation, request.ExpectedRowVersion, PurviewRuntimeTestSerialization.Reference(consentJson));
        if (issued.Token.Length > ProtectionOperationTokenService.MaximumTokenCharacters)
            throw Invalid();
        operation.ReviewedPayloadHash = issued.ReviewedPayloadHash;
        operation.ConfirmationVerifier = issued.Verifier;
        await _operations.AddAsync(operation, ct);
        await AuditAsync(operation, "PurviewRuntimeTestReviewed", ct);
        await _unitOfWork.SaveChangesAsync(ct);
        return new(operation.Id, issued.Token, issued.ReviewedPayloadHash, issued.ExpiresAtUtc,
            PurviewRuntimeTestValidation.ToReviewDto(plan));
    }

    internal async Task RecheckConfirmationAsync(ProtectionAdminOperation operation, ProtectionActor actor,
        string expectedRowVersion, JsonElement referencePayload, CancellationToken ct)
    {
        var plan = ReadPlan(operation);
        var reference = referencePayload.Deserialize<PurviewRuntimeConsentReference>(PurviewRuntimeTestSerialization.Options);
        if (reference != PurviewRuntimeTestSerialization.Reference(operation.RuntimeTestConsentJson!) ||
            expectedRowVersion != plan.Context.Versions.ProfileRowVersion)
            throw Invalid();
        var (_, current) = await CurrentAsync(actor, plan.Context.Identity.ProfileId, plan.Context.Identity.AgentRegistrationId, ct);
        PurviewRuntimeTestValidation.EnsureCurrent(plan, current, _clock.GetUtcNow());
    }

    // The controller owns the operation/profile locks and the short acceptance transaction.
    public async Task<PurviewRuntimeTestAcceptance> AcceptAsync(
        ProtectionActor actor, Guid profileId, ExecutePurviewDlpRuntimeTestRequest request, CancellationToken ct)
    {
        var existing = await _operations.GetByIdempotencyKeyAsync(new(actor.TenantId), new(request.IdempotencyKey), ct);
        if (existing is not null && (existing.Id != request.ConfirmationTokenId ||
            existing.Type != ProtectionAdminOperationType.TestDlpRuntime ||
            existing.ActorObjectId != actor.ObjectId || existing.TargetIdentifier != profileId.ToString("D")))
            throw ReplayConflict();
        var operation = existing ?? await _operations.GetByIdAsync(request.ConfirmationTokenId, ct);
        EnsureOwned(operation, actor);
        if (operation!.Type != ProtectionAdminOperationType.TestDlpRuntime ||
            operation.Id != request.ConfirmationTokenId || operation.TargetIdentifier != profileId.ToString("D"))
            throw Invalid();
        var plan = ReadPlan(operation);
        var acceptedHash = PurviewRuntimeTestValidation.AcceptedRequestHash(plan, request);
        if (existing is not null)
        {
            if (operation.AcceptedRequestHash != acceptedHash ||
                operation.ConfirmationVerifier?.ConsumedAtUtc is null ||
                operation.Status == ProtectionAdminOperationStatus.AwaitingConfirmation)
                throw ReplayConflict();
            return new(operation.Id, plan, null, PurviewRuntimeTestSerialization.ReadResult(operation).Report);
        }
        if (operation.Status != ProtectionAdminOperationStatus.AwaitingConfirmation)
            throw ReplayConflict();
        var authorized = _tokens.ValidateConfirmation(operation, actor, request.ConfirmationToken, request.ExpectedRowVersion);
        await RecheckConfirmationAsync(operation, actor, authorized.ExpectedRowVersion, authorized.Payload, ct);
        var samples = PurviewRuntimeTestValidation.ValidateSamples(plan, request.Samples);
        try
        {
            operation.ConfirmationVerifier!.MarkConsumed(_clock.GetUtcNow().UtcDateTime);
            operation.IdempotencyKey = new(request.IdempotencyKey);
            operation.AcceptedRequestHash = acceptedHash;
            operation.Status = ProtectionAdminOperationStatus.Running;
            operation.AttemptCount = 1;
            operation.StartedAtUtc = operation.UpdatedAtUtc = _clock.GetUtcNow().UtcDateTime;
            operation.RuntimeTestResultJson = PurviewRuntimeTestSerialization.WriteResult(new(
                Report(operation, plan, "Running", "Partial", [], plan.Context.SelectedTypes.Select(value => value.Id), false, null),
                [], null, null));
            await AuditAsync(operation, "PurviewRuntimeTestAccepted", ct);
            await _unitOfWork.SaveChangesAsync(ct);
            return new(operation.Id, plan, samples, null,
                AsUtc(operation.StartedAtUtc.Value).Add(PurviewRuntimeTestLimits.ExecutionDeadline));
        }
        catch { samples.Dispose(); throw; }
    }

    // Called ONLY after the controller commits and disposes its acceptance transaction.
    public async Task<PurviewRuntimeTestResultResponse> ExecuteAcceptedAsync(
        ProtectionActor actor, PurviewRuntimeTestAcceptance accepted, CancellationToken ct)
    {
        if (accepted.Replay is not null)
            return accepted.Replay;
        _store.EnsureNoActiveTransaction();
        PurviewRuntimeTestBatchEvidence evidence;
        try
        {
            evidence = await _runner.RunAsync(accepted.OperationId, accepted.Plan, accepted.Samples!,
                accepted.DeadlineUtc, ct);
        }
        catch (Exception)
        {
            evidence = Unknown(accepted.OperationId, accepted.Plan);
        }
        finally { accepted.Dispose(); }

        // A disconnected caller cannot roll back durable acceptance or prevent bounded cleanup.
        using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        return await FinishAsync(actor, accepted.OperationId, accepted.Plan, evidence, cleanup.Token);
    }

    public async Task<PurviewRuntimeTestResultResponse> GetAsync(ProtectionActor actor, Guid operationId, CancellationToken ct)
    {
        var operation = await _operations.GetByIdAsync(operationId, ct);
        EnsureOwned(operation, actor);
        if (operation!.Type != ProtectionAdminOperationType.TestDlpRuntime || operation.RuntimeTestResultJson is null)
            throw new NotFoundException("ProtectionAdminOperation", operationId);
        return PurviewRuntimeTestSerialization.ReadResult(operation).Report;
    }

    public async Task<bool> IsCurrentAsync(PurviewDlpProfile profile, CancellationToken cancellationToken) =>
        await GetCurrentBindingAsync(profile, cancellationToken) is not null;

    public async Task<PurviewRuntimeCertificationBinding?> GetCurrentBindingAsync(
        PurviewDlpProfile profile, CancellationToken cancellationToken)
    {
        if (!profile.HasRuntimeEvidenceFor(profile.BlueprintApplicationId, _clock.GetUtcNow().UtcDateTime) ||
            profile.RuntimeBehaviorCertificationOperationId is not { } operationId)
            return null;
        try
        {
            var operation = await _store.GetFreshCertificationOperationAsync(operationId, cancellationToken);
            if (operation is null || operation.Type != ProtectionAdminOperationType.TestDlpRuntime ||
                operation.Status != ProtectionAdminOperationStatus.Completed ||
                operation.TargetType != ProtectionAdminTargetType.DlpProfile ||
                operation.TargetIdentifier != profile.Id.Value.ToString("D") ||
                operation.ConfirmationVerifier?.ConsumedAtUtc is null || operation.AcceptedRequestHash is not { Length: 71 })
                return null;
            var plan = ReadPlan(operation);
            var certification = PurviewRuntimeTestSerialization.ReadResult(operation);
            if (!MatchesCertifiedDefinition(profile, plan) ||
                profile.RuntimeBehaviorSuiteHash != plan.SuiteHash ||
                !certification.Report.EnforcementBehaviorVerified || certification.Report.FailureCode is not null ||
                certification.Report.OperationId != operation.Id ||
                certification.Report.SuiteHash != plan.SuiteHash ||
                certification.Report.ConfigurationFingerprint != plan.ConfigurationFingerprint ||
                certification.CertifiedUntilUtc is not { } until || until.Offset != TimeSpan.Zero ||
                until <= _clock.GetUtcNow() ||
                profile.RuntimeBehaviorVerifiedUntilUtc is not { } profileUntil ||
                until != AsUtc(profileUntil))
                return null;
            var (snapshot, current) = await CurrentAsync(
                new ProtectionActor(operation.TenantId.Value, operation.ActorObjectId),
                profile.Id.Value, plan.Context.Identity.AgentRegistrationId, cancellationToken);
            var currentBinding = snapshot.Profile.HasRuntimeEvidenceFor(profile.BlueprintApplicationId, _clock.GetUtcNow().UtcDateTime) &&
                snapshot.Profile.RuntimeBehaviorCertificationOperationId == operationId &&
                snapshot.Profile.RuntimeBehaviorSuiteHash == plan.SuiteHash &&
                snapshot.Profile.RuntimeBehaviorVerifiedUntilUtc == until.UtcDateTime &&
                PurviewRuntimeTestValidation.MatchesCertifiedConfiguration(plan, current, _clock.GetUtcNow());
            return currentBinding ? new(operationId, plan.ConfigurationFingerprint,
                current.Identity.AgentRegistrationId, current.Versions.AgentProtectionRevision,
                current.Identity.RuntimePrincipalObjectId, until) : null;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception) { return null; }
    }

    private static bool MatchesCertifiedDefinition(PurviewDlpProfile profile, PurviewRuntimeTestPlan plan) =>
        profile.BlueprintApplicationId.Value == plan.Context.Identity.BlueprintApplicationId &&
        profile.PurviewTenantConnectionId == plan.Context.Identity.TenantConnectionId &&
        profile.InventoryGenerationId.Value == plan.Context.Versions.InventoryGenerationId &&
        profile.SensitiveInformationTypeSnapshotExpiresAtUtc == plan.Context.Versions.InventoryExpiresAtUtc.UtcDateTime &&
        profile.EffectivePolicyMode == plan.Context.PolicyMode &&
        profile.DisplayName == plan.Context.ProfileDisplayName &&
        profile.DlpPolicyProviderId == plan.Context.PolicyProviderId &&
        profile.DlpRuleProviderId == plan.Context.RuleProviderId &&
        profile.NormalizedSensitiveInformationTypes.SequenceEqual(plan.Context.SelectedTypes.OrderBy(value => value.Id)) &&
        profile.Activities.Order().SequenceEqual(plan.Context.Activities.Order()) &&
        profile.Actions.OrderBy(value => value.Activity).ThenBy(value => value.Action).SequenceEqual(
            plan.Context.Actions.OrderBy(value => value.Activity).ThenBy(value => value.Action));

    // Caller must hold the same operation/profile locks as execution. Never invokes the runner.
    public async Task<PurviewRuntimeTestResultResponse> RecoverAsync(ProtectionActor actor, Guid operationId, CancellationToken ct)
    {
        var operation = await _operations.GetByIdAsync(operationId, ct);
        EnsureOwned(operation, actor);
        if (operation!.Type != ProtectionAdminOperationType.TestDlpRuntime)
            throw Invalid();
        if (operation.Status != ProtectionAdminOperationStatus.Running ||
            operation.StartedAtUtc is null ||
            operation.StartedAtUtc.Value.Add(PurviewRuntimeTestLimits.ExecutionDeadline) > _clock.GetUtcNow().UtcDateTime)
            return PurviewRuntimeTestSerialization.ReadResult(operation).Report;
        var plan = ReadPlan(operation);
        return await FinishAsync(actor, operation.Id, plan, Unknown(operation.Id, plan), ct);
    }

    private async Task<PurviewRuntimeTestResultResponse> FinishAsync(
        ProtectionActor actor, Guid operationId, PurviewRuntimeTestPlan plan,
        PurviewRuntimeTestBatchEvidence evidence, CancellationToken ct)
    {
        await using var transaction = await _store.BeginFreshWriteAsync(ct);
        var operation = await _operations.GetByIdAsync(operationId, ct);
        EnsureOwned(operation, actor);
        if (operation!.Status != ProtectionAdminOperationStatus.Running)
            return PurviewRuntimeTestSerialization.ReadResult(operation).Report;
        _ = ReadPlan(operation);
        PurviewRuntimeTestSnapshot? snapshot = null;
        var failure = evidence.FailureCode;
        try
        {
            (snapshot, var current) = await CurrentAsync(actor, plan.Context.Identity.ProfileId, plan.Context.Identity.AgentRegistrationId, ct);
            PurviewRuntimeTestValidation.EnsureCurrent(plan, current, _clock.GetUtcNow());
        }
        catch (Exception exception) when (exception is DomainException or NotFoundException or PurviewRuntimeTestValidationException)
        {
            failure = PurviewRuntimeTestFailureCodes.ContextChanged;
            snapshot = null;
        }

        var prior = await _store.ListSuiteOperationsAsync(plan.ConfigurationFingerprint, plan.SuiteHash,
            _clock.GetUtcNow().Subtract(PurviewRuntimeTestLimits.MaximumEvidenceAge).UtcDateTime, ct);
        var collected = new List<PurviewRuntimeTestCaseEvidence>();
        var roleTimes = new List<DateTimeOffset>();
        var credentialExpiries = new List<DateTimeOffset>();
        if (prior.Count > 128)
            failure = PurviewRuntimeTestFailureCodes.ManifestInvalid;
        foreach (var item in prior.Where(value => value.Id != operation.Id))
        {
            if (item.Status != ProtectionAdminOperationStatus.Completed)
            {
                failure ??= PurviewRuntimeTestFailureCodes.OutcomeUnknown;
                continue;
            }
            var previous = PurviewRuntimeTestSerialization.ReadResult(item);
            if (previous.Report.FailureCode is not null)
                failure ??= previous.Report.FailureCode;
            collected.AddRange(previous.Evidence);
            if (previous.TokenRolesVerifiedAtUtc is { } roleTime) roleTimes.Add(roleTime);
            if (previous.CredentialExpiresAtUtc is { } expiry) credentialExpiries.Add(expiry);
        }
        collected.AddRange(evidence.Cases);
        var observedScopes = collected.Where(value => value.Behavior == PurviewRuntimeBehaviorObservation.BehaviorObserved)
            .Select(value => value.Observation.ScopeFingerprint).Distinct(StringComparer.Ordinal).ToArray();
        if (observedScopes.Contains(null) || observedScopes.Length > 1)
            failure ??= PurviewRuntimeTestFailureCodes.ContextChanged;
        if (evidence.TokenRolesVerifiedAtUtc is { } currentRoleTime) roleTimes.Add(currentRoleTime);
        if (evidence.CredentialExpiresAtUtc is { } currentExpiry) credentialExpiries.Add(currentExpiry);
        var covered = CoveredCases(plan, collected);
        var outstanding = plan.PositiveSamples.Where(value => !covered.Contains(value.CaseId))
            .Select(value => value.IntendedSensitiveInformationTypeId!.Value).ToArray();
        var complete = failure is null && outstanding.Length == 0 && roleTimes.Count > 0 &&
            credentialExpiries.Count > 0 && credentialExpiries.Min() > _clock.GetUtcNow();
        var enforce = plan.Context.PolicyMode == PurviewPolicyMode.Enforce;
        var behaviorVerified = complete && enforce;
        DateTimeOffset? certifiedUntil = null;
        var outcome = failure is not null
            ? failure is PurviewRuntimeTestFailureCodes.OutcomeUnknown or PurviewRuntimeTestFailureCodes.DeadlineExceeded or
                PurviewRuntimeTestFailureCodes.ContextChanged ? "OutcomeUnknown" : "Failed"
            : complete ? enforce ? "EnforcementBehaviorVerified" : "SimulationExercised"
            : evidence.Cases.Any(value => value.Behavior == PurviewRuntimeBehaviorObservation.SubmissionAccepted)
                ? "SubmissionAccepted" : "Partial";

        if (snapshot is not null && enforce && (behaviorVerified || failure is not null))
        {
            var profile = snapshot.Profile;
            if (behaviorVerified)
            {
                var until = collected.Min(value => value.Observation.ObservedAtUtc).Add(PurviewRuntimeTestLimits.MaximumEvidenceAge);
                until = new[] { until, roleTimes.Min().Add(PurviewRuntimeTestLimits.MaximumEvidenceAge),
                    credentialExpiries.Min(), plan.Context.Versions.InventoryExpiresAtUtc,
                    AsUtc(profile.LastReadbackAtUtc!.Value).Add(PurviewRuntimeTestLimits.MaximumEvidenceAge) }.Min();
                if (until <= _clock.GetUtcNow())
                {
                    behaviorVerified = false;
                    failure = PurviewRuntimeTestFailureCodes.ContextChanged;
                    outcome = "OutcomeUnknown";
                }
                else
                {
                    profile.RuntimeAllowVerifiedAtUtc = collected.Where(value => value.CaseId == plan.NegativeSample.CaseId)
                        .Min(value => value.Observation.ObservedAtUtc).UtcDateTime;
                    profile.RuntimeBlockVerifiedAtUtc = collected.Where(value => value.IntendedSensitiveInformationTypeId is not null)
                        .Min(value => value.Observation.ObservedAtUtc).UtcDateTime;
                    profile.TokenRolesVerifiedAtUtc = roleTimes.Min().UtcDateTime;
                    profile.PropagationVerifiedAtUtc = profile.RuntimeAllowVerifiedAtUtc;
                    profile.RuntimeBehaviorSuiteHash = plan.SuiteHash;
                    profile.RuntimeBehaviorVerifiedUntilUtc = until.UtcDateTime;
                    profile.RuntimeBehaviorCertificationOperationId = operation.Id;
                    certifiedUntil = until;
                    profile.Readiness = ProtectionReadiness.Ready;
                    profile.Status = PurviewDlpProfileStatus.Ready;
                    profile.LastFailureCode = null;
                }
            }
            if (!behaviorVerified)
            {
                profile.RuntimeAllowVerifiedAtUtc = profile.RuntimeBlockVerifiedAtUtc = null;
                profile.RuntimeBehaviorSuiteHash = null;
                profile.RuntimeBehaviorVerifiedUntilUtc = null;
                profile.RuntimeBehaviorCertificationOperationId = null;
                profile.Readiness = profile.Readiness with { RuntimeVerdict = ProtectionRuntimeVerdictStatus.Failed };
                profile.Status = PurviewDlpProfileStatus.VerificationFailed;
                profile.LastFailureCode = failure;
            }
            profile.UpdatedAtUtc = _clock.GetUtcNow().UtcDateTime;
            _store.UpdateProfile(profile);
        }

        operation.Status = failure is null ? ProtectionAdminOperationStatus.Completed : ProtectionAdminOperationStatus.RequiresManualIntervention;
        operation.RetryDisposition = failure is null ? ProtectionRetryDisposition.NotApplicable : ProtectionRetryDisposition.RequiresManualIntervention;
        operation.LastFailureCode = failure;
        operation.RequiredAction = failure is null && complete ? null : "ReviewRuntimeSamples";
        operation.CompletedAtUtc = operation.UpdatedAtUtc = _clock.GetUtcNow().UtcDateTime;
        var report = Report(operation, plan, operation.Status.ToString(), outcome, evidence.Cases, outstanding, behaviorVerified, failure);
        var stored = new PurviewRuntimeStoredResult(report, evidence.Cases, evidence.TokenRolesVerifiedAtUtc,
            evidence.CredentialExpiresAtUtc, certifiedUntil);
        operation.RuntimeTestResultJson = PurviewRuntimeTestSerialization.WriteResult(stored);
        await AuditAsync(operation, "PurviewRuntimeTestCompleted", ct);
        await _unitOfWork.SaveChangesAsync(ct);
        if (snapshot is not null && (behaviorVerified || (enforce && failure is not null)))
        {
            report = CopyRowVersion(report, ProtectionRowVersion.Encode(snapshot.Profile.RowVersion, snapshot.Profile.Id.Value, snapshot.Profile.UpdatedAtUtc));
            operation.RuntimeTestResultJson = PurviewRuntimeTestSerialization.WriteResult(stored with { Report = report });
            await _unitOfWork.SaveChangesAsync(ct);
        }
        await transaction.CompleteAsync(ct);
        return report;
    }

    private HashSet<Guid> CoveredCases(PurviewRuntimeTestPlan plan, IEnumerable<PurviewRuntimeTestCaseEvidence> evidence)
    {
        var valid = evidence.Where(value => value.SuiteHash == plan.SuiteHash &&
            value.ConfigurationFingerprint == plan.ConfigurationFingerprint &&
            value.Observation.FailureCode is null &&
            value.Observation.ObservedAtUtc.Offset == TimeSpan.Zero &&
            value.Observation.ObservedAtUtc >= _clock.GetUtcNow().Subtract(PurviewRuntimeTestLimits.MaximumEvidenceAge) &&
            value.Observation.ObservedAtUtc <= _clock.GetUtcNow().AddMinutes(2) &&
            value.Behavior == PurviewRuntimeBehaviorObservation.BehaviorObserved).ToArray();
        var cleanOperations = valid.Where(value => value.CaseId == plan.NegativeSample.CaseId &&
            value.IntendedSensitiveInformationTypeId is null && value.ContentHash == plan.NegativeSample.ContentHash &&
            value.Observation.Decision == PurviewRuntimeProbeDecision.Allowed &&
            value.Observation.ContentProcessing == PurviewRuntimeContentProcessing.Processed)
            .Select(value => value.OperationId).ToHashSet();
        return valid.Where(value => cleanOperations.Contains(value.OperationId) &&
            plan.PositiveSamples.Any(sample => sample.CaseId == value.CaseId &&
                sample.ContentHash == value.ContentHash && sample.IntendedSensitiveInformationTypeId == value.IntendedSensitiveInformationTypeId) &&
            (plan.Context.PolicyMode != PurviewPolicyMode.Enforce ||
                (value.Observation.Decision == PurviewRuntimeProbeDecision.Blocked &&
                 value.Observation.ActionSource == PurviewRuntimeActionSource.Content &&
                 value.Observation.ContentProcessing == PurviewRuntimeContentProcessing.Processed)))
            .Select(value => value.CaseId).ToHashSet();
    }

    private async Task<(PurviewRuntimeTestSnapshot Snapshot, PurviewRuntimeTestContext Context)> CurrentAsync(
        ProtectionActor actor, Guid profileId, Guid? registrationId, CancellationToken ct)
    {
        var snapshot = await _store.LoadFreshSnapshotAsync(profileId, actor.TenantId, registrationId, ct)
            ?? throw new NotFoundException("PurviewDlpProfile", profileId);
        var profile = snapshot.Profile;
        var now = _clock.GetUtcNow();
        if (snapshot.Agent is null)
            throw new DomainException("Finish registration of an active blueprint child before runtime testing.",
                "PURVIEW_RUNTIME_AGENT_NOT_DISCOVERABLE");
        if (snapshot.Capability.Status != ProtectionCapabilityStatus.Installed || snapshot.Capability.LastReadbackAtUtc is null ||
            (_binding is not null && !_binding.IsExact(snapshot.Capability)) ||
            !snapshot.Connection.IsUsableAt(now.UtcDateTime) ||
            snapshot.Inventory.TenantId.Value != actor.TenantId ||
            snapshot.Inventory.PurviewTenantConnectionId != snapshot.Connection.Id ||
            snapshot.Connection.ActiveInventoryGenerationId != snapshot.Inventory.Id ||
            snapshot.Inventory.IsExpired(now.UtcDateTime) ||
            profile.SensitiveInformationTypeSnapshotExpiresAtUtc != snapshot.Inventory.ExpiresAtUtc ||
            profile.Readiness.Readback != ProtectionReadbackStatus.Ready ||
            profile.LastReadbackAtUtc is null || AsUtc(profile.LastReadbackAtUtc.Value) < now.AddMinutes(-30) ||
            AsUtc(profile.LastReadbackAtUtc.Value) > now.AddMinutes(2) ||
            !Guid.TryParse(snapshot.Agent.Agent365AgentId, out var childId) || childId == Guid.Empty ||
            snapshot.Capability.ResourceIdentifiers.PurviewRuntimeManagedIdentityPrincipalObjectId is not { } principal)
            throw new DomainException("Current runtime-test prerequisites are unavailable.", ErrorCodes.PURVIEW_DLP_PROFILE_NOT_READY);
        var selected = profile.NormalizedSensitiveInformationTypes;
        if (selected.Any(value => !PurviewSensitiveInformationTypeThresholds.AreValid(value.MinCount, value.MaxCount, value.MinConfidence, value.MaxConfidence)))
            throw new DomainException("Review explicit SIT thresholds before runtime testing.", ErrorCodes.PURVIEW_SIT_THRESHOLDS_REVIEW_REQUIRED);
        foreach (var value in selected)
            if (snapshot.Inventory.Items.Count(item => item.SensitiveInformationTypeId.Value == value.Id && item.ExactName == value.ExactName) != 1)
                throw new DomainException("The selected inventory changed.", ErrorCodes.PURVIEW_DLP_PROFILE_NOT_READY);
        var context = new PurviewRuntimeTestContext(
            new(actor.TenantId, Guid.Parse(actor.ObjectId), profile.Id.Value, snapshot.Connection.Id,
                profile.BlueprintApplicationId.Value, snapshot.Agent.Id, childId, principal.Value),
            new(Version(profile.RowVersion, profile.Id.Value, profile.UpdatedAtUtc),
                Version(snapshot.Connection.RowVersion, snapshot.Connection.Id, snapshot.Connection.UpdatedAtUtc),
                Version(snapshot.Capability.RowVersion, snapshot.Capability.Id, snapshot.Capability.UpdatedAtUtc),
                snapshot.Inventory.Id.Value, Version([], snapshot.Inventory.Id.Value, snapshot.Inventory.CreatedAtUtc),
                AsUtc(snapshot.Inventory.ExpiresAtUtc), Version(snapshot.Agent.RowVersion, snapshot.Agent.Id, snapshot.Agent.UpdatedAtUtc),
                snapshot.Agent.ProtectionRevision),
            profile.EffectivePolicyMode, profile.DisplayName, profile.DlpPolicyProviderId!, profile.DlpRuleProviderId!,
            selected, profile.Activities, profile.Actions);
        return (snapshot, context);
    }

    private static PurviewRuntimeTestPlan ReadPlan(ProtectionAdminOperation operation)
    {
        var plan = PurviewRuntimeTestSerialization.Plan(PurviewRuntimeTestSerialization.ReadConsent(operation));
        if (operation.RuntimeTestSuiteHash != plan.SuiteHash ||
            operation.RuntimeTestConfigurationFingerprint != plan.ConfigurationFingerprint ||
            operation.TargetIdentifier != plan.Context.Identity.ProfileId.ToString("D") ||
            operation.TenantId.Value != plan.Context.Identity.TenantId ||
            operation.ActorObjectId != plan.Context.Identity.ActorObjectId.ToString("D"))
            throw Invalid();
        return plan;
    }

    private static PurviewRuntimeTestResultResponse Report(ProtectionAdminOperation operation, PurviewRuntimeTestPlan plan,
        string status, string outcome, IEnumerable<PurviewRuntimeTestCaseEvidence> cases, IEnumerable<Guid> outstanding, bool verified, string? code) =>
        new(operation.Id, status, outcome, plan.Context.PolicyMode.ToString(), plan.SuiteHash, plan.ConfigurationFingerprint,
            plan.Context.Versions.ProfileRowVersion, operation.CompletedAtUtc is { } completed ? AsUtc(completed) : null,
            cases.Select(value => new PurviewRuntimeTestCaseResultDto(value.CaseId, value.IntendedSensitiveInformationTypeId,
                value.ContentHash, value.Observation.Decision.ToString(), value.Observation.ContentProcessing.ToString(),
                value.Observation.ActionSource.ToString(), value.Observation.ObservedAtUtc, value.Observation.FailureCode,
                value.Observation.ScopeFingerprint)).ToArray(),
            outstanding.Order().ToArray(), verified, code);

    private static PurviewRuntimeTestResultResponse CopyRowVersion(PurviewRuntimeTestResultResponse value, string rowVersion) =>
        new(value.OperationId, value.Status, value.Outcome, value.PolicyMode, value.SuiteHash, value.ConfigurationFingerprint,
            rowVersion, value.CompletedAtUtc, value.Cases, value.OutstandingSensitiveInformationTypeIds, value.EnforcementBehaviorVerified, value.FailureCode);
    private PurviewRuntimeTestBatchEvidence Unknown(Guid operationId, PurviewRuntimeTestPlan plan) =>
        new(operationId, plan.SuiteHash, plan.ConfigurationFingerprint, [], _clock.GetUtcNow(), failureCode: PurviewRuntimeTestFailureCodes.OutcomeUnknown);
    private Task AuditAsync(ProtectionAdminOperation operation, string eventType, CancellationToken ct) =>
        _audit.AddAsync(new AuditEvent
        {
            Id = Guid.NewGuid(), EventType = eventType, PerformedByObjectId = operation.ActorObjectId,
            PerformedByRole = "Administrator", CorrelationId = operation.CorrelationId.ToString("D"),
            Details = JsonSerializer.Serialize(new { operationId = operation.Id, operation.Status, operation.ReviewedPayloadHash }),
            OccurredAtUtc = _clock.GetUtcNow().UtcDateTime
        }, ct);
    private static void EnsureOwned(ProtectionAdminOperation? operation, ProtectionActor actor)
    {
        if (operation is null || operation.TenantId.Value != actor.TenantId || operation.ActorObjectId != actor.ObjectId)
            throw new NotFoundException("ProtectionAdminOperation", operation?.Id ?? Guid.Empty);
    }
    private static DateTimeOffset AsUtc(DateTime value) => new(DateTime.SpecifyKind(value, DateTimeKind.Utc));
    private static string Version(byte[] bytes, Guid id, DateTime updated) => ProtectionRowVersion.Encode(bytes, id, DateTime.SpecifyKind(updated, DateTimeKind.Utc));
    private static DomainException Invalid() => new("The runtime-test consent is invalid.", ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
    private static ConflictException ReplayConflict() => new("The runtime-test idempotency key was already used for different consent.", ErrorCodes.IDEMPOTENCY_CONFLICT);
}
