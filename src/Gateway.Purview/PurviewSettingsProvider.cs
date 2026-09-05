using Gateway.Domain.Enums;
using Gateway.Domain.Models;

namespace Gateway.Purview;

public sealed class PurviewSettingsProvider : IPurviewSettingsProvider
{
    private const int MaximumProviderIdLength = 256;
    private readonly IPurviewSettingsAutomation _automation;

    internal PurviewSettingsProvider(IPurviewSettingsAutomation automation)
    {
        _automation = automation;
    }

    public async Task<PurviewSettingsOperationResult<PurviewKnowYourDataReadback>>
        EnsureKnowYourDataAsync(
            PurviewKnowYourDataIntent intent,
            CancellationToken cancellationToken)
    {
        Validate(intent);
        var discovered = await _automation.ReadKnowYourDataAsync(intent, cancellationToken);
        if (discovered.State == PurviewProviderObjectState.Exact)
        {
            return KydResult(
                intent.PriorCreateOutcomeUnknown
                    ? PurviewSettingsOperationDisposition.RecoveredAfterUnknownOutcome
                    : PurviewSettingsOperationDisposition.AlreadyExact,
                intent,
                discovered);
        }
        if (intent.PriorCreateOutcomeUnknown)
        {
            return Manual<PurviewKnowYourDataReadback>(
                "PURVIEW_KYD_PRIOR_MUTATION_UNRESOLVED");
        }
        if (discovered.State != PurviewProviderObjectState.Absent &&
            !(discovered.State == PurviewProviderObjectState.Mismatch &&
              intent.ExpectedPolicyProviderId is not null))
        {
            throw Failure(
                "PURVIEW_KYD_STATE_UNVERIFIABLE",
                "Know Your Data state is not safe for a create or update.");
        }

        try
        {
            await _automation.CreateKnowYourDataAsync(intent, cancellationToken);
        }
        catch (PurviewMutationOutcomeUnknownException exception)
        {
            var recovered = await _automation.ReadKnowYourDataAsync(intent, cancellationToken);
            return recovered.State == PurviewProviderObjectState.Exact
                ? KydResult(
                    PurviewSettingsOperationDisposition.RecoveredAfterUnknownOutcome,
                    intent,
                    recovered)
                : Manual<PurviewKnowYourDataReadback>(exception.FailureCode);
        }

        var readback = await _automation.ReadKnowYourDataAsync(intent, cancellationToken);
        return KydResult(
            PurviewSettingsOperationDisposition.MutatedAndVerified,
            intent,
            readback);
    }

    public async Task<PurviewSettingsOperationResult<PurviewKnowYourDataReadback>>
        VerifyKnowYourDataAsync(
            PurviewKnowYourDataIntent intent,
            CancellationToken cancellationToken)
    {
        Validate(intent);
        var readback = await _automation.ReadKnowYourDataAsync(intent, cancellationToken);
        return KydResult(PurviewSettingsOperationDisposition.ExactReadback, intent, readback);
    }

    public async Task<PurviewSettingsOperationResult<PurviewDlpProfileReadback>>
        EnsureDlpProfileAsync(
            PurviewDlpProfileIntent intent,
            CancellationToken cancellationToken)
    {
        Validate(intent);
        var discovered = await _automation.ReadDlpProfileAsync(intent, cancellationToken);
        if (discovered.State == PurviewProviderObjectState.Exact)
        {
            return DlpResult(
                intent.RecoveryPoint == PurviewDlpMutationRecoveryPoint.None
                    ? PurviewSettingsOperationDisposition.AlreadyExact
                    : PurviewSettingsOperationDisposition.RecoveredAfterUnknownOutcome,
                intent,
                discovered);
        }
        if (intent.RecoveryPoint == PurviewDlpMutationRecoveryPoint.RuleCreationOutcomeUnknown)
        {
            return Manual(
                "PURVIEW_DLP_RULE_PRIOR_MUTATION_UNRESOLVED",
                discovered.Value);
        }
        if (intent.RecoveryPoint ==
                PurviewDlpMutationRecoveryPoint.PolicyCreationOutcomeUnknown &&
            discovered.State != PurviewProviderObjectState.PolicyOnlyExact)
        {
            return Manual(
                "PURVIEW_DLP_POLICY_PRIOR_MUTATION_UNRESOLVED",
                discovered.Value);
        }

        var recoveredUnknown = intent.RecoveryPoint ==
            PurviewDlpMutationRecoveryPoint.PolicyCreationOutcomeUnknown;
        var policyMutationRequired =
            discovered.State == PurviewProviderObjectState.Absent ||
            (discovered.State == PurviewProviderObjectState.Mismatch &&
             intent.ExpectedPolicyProviderId is not null);
        if (policyMutationRequired)
        {
            try
            {
                await _automation.CreateDlpPolicyAsync(intent, cancellationToken);
            }
            catch (PurviewMutationOutcomeUnknownException)
            {
                recoveredUnknown = true;
            }

            discovered = await _automation.ReadDlpProfileAsync(intent, cancellationToken);
            if (discovered.State == PurviewProviderObjectState.Exact)
            {
                return DlpResult(
                    recoveredUnknown
                        ? PurviewSettingsOperationDisposition.RecoveredAfterUnknownOutcome
                        : PurviewSettingsOperationDisposition.MutatedAndVerified,
                    intent,
                    discovered);
            }

            if (discovered.State != PurviewProviderObjectState.PolicyOnlyExact)
            {
                return recoveredUnknown
                    ? Manual<PurviewDlpProfileReadback>("PURVIEW_DLP_POLICY_MUTATION_UNKNOWN")
                    : throw Failure(
                        "PURVIEW_DLP_POLICY_READBACK_MISSING",
                        "The DLP policy was not proven exact after creation.");
            }
        }
        else if (discovered.State != PurviewProviderObjectState.PolicyOnlyExact)
        {
            throw Failure(
                "PURVIEW_DLP_STATE_UNVERIFIABLE",
                "The DLP profile state is mismatched, partial, unknown, or unsupported.");
        }

        ValidatePolicyReadbackBeforeRuleMutation(intent, discovered.Value);
        try
        {
            await _automation.CreateDlpRuleAsync(intent, cancellationToken);
        }
        catch (PurviewMutationOutcomeUnknownException exception)
        {
            var recovered = await _automation.ReadDlpProfileAsync(intent, cancellationToken);
            return recovered.State == PurviewProviderObjectState.Exact
                ? DlpResult(
                    PurviewSettingsOperationDisposition.RecoveredAfterUnknownOutcome,
                    intent,
                    recovered)
                : Manual(exception.FailureCode, recovered.Value);
        }

        var readback = await _automation.ReadDlpProfileAsync(intent, cancellationToken);
        return DlpResult(
            recoveredUnknown
                ? PurviewSettingsOperationDisposition.RecoveredAfterUnknownOutcome
                : PurviewSettingsOperationDisposition.MutatedAndVerified,
            intent,
            readback);
    }

    public async Task<PurviewSettingsOperationResult<PurviewDlpProfileReadback>>
        VerifyDlpProfileAsync(
            PurviewDlpProfileIntent intent,
            CancellationToken cancellationToken)
    {
        Validate(intent);
        var readback = await _automation.ReadDlpProfileAsync(intent, cancellationToken);
        return DlpResult(PurviewSettingsOperationDisposition.ExactReadback, intent, readback);
    }

    public Task<PurviewSettingsOperationResult<PurviewDlpProfileReadback>>
        ReconcileDlpProfileAsync(
            PurviewDlpProfileIntent intent,
            CancellationToken cancellationToken) =>
        VerifyDlpProfileAsync(intent, cancellationToken);

    private static PurviewSettingsOperationResult<PurviewKnowYourDataReadback> KydResult(
        PurviewSettingsOperationDisposition disposition,
        PurviewKnowYourDataIntent intent,
        PurviewProviderReadback<PurviewKnowYourDataReadback> readback)
    {
        RequireState(readback.State, PurviewProviderObjectState.Exact, "PURVIEW_KYD_READBACK_MISSING");
        var value = readback.Value ??
            throw Failure("PURVIEW_KYD_READBACK_MISSING", "Know Your Data readback is missing.");
        ValidateExact(intent, value);
        return new(disposition, value, null);
    }

    private static PurviewSettingsOperationResult<PurviewDlpProfileReadback> DlpResult(
        PurviewSettingsOperationDisposition disposition,
        PurviewDlpProfileIntent intent,
        PurviewProviderReadback<PurviewDlpProfileReadback> readback)
    {
        RequireState(readback.State, PurviewProviderObjectState.Exact, "PURVIEW_DLP_READBACK_MISSING");
        var value = readback.Value ??
            throw Failure("PURVIEW_DLP_READBACK_MISSING", "DLP profile readback is missing.");
        ValidateExact(intent, value);
        return new(disposition, value, null);
    }

    private static PurviewSettingsOperationResult<T> Manual<T>(
        string failureCode,
        T? readback = null)
        where T : class =>
        new(
            PurviewSettingsOperationDisposition.RequiresManualIntervention,
            readback,
            failureCode);

    private static void Validate(PurviewKnowYourDataIntent intent)
    {
        ArgumentNullException.ThrowIfNull(intent);
        ValidateCommon(
            intent.OperationId,
            intent.TenantId,
            intent.InventoryGenerationId,
            intent.InventoryExpiresAtUtc,
            intent.SensitiveInformationTypeId,
            intent.SensitiveInformationTypeName,
            intent.SensitiveInformationTypePublisher,
            intent.PolicyName,
            intent.Activities);
        ValidateProviderId(intent.ExpectedPolicyProviderId);
    }

    private static void Validate(PurviewDlpProfileIntent intent)
    {
        ArgumentNullException.ThrowIfNull(intent);
        ValidateCommon(
            intent.OperationId,
            intent.TenantId,
            intent.InventoryGenerationId,
            intent.InventoryExpiresAtUtc,
            intent.SensitiveInformationTypeId,
            intent.SensitiveInformationTypeName,
            intent.SensitiveInformationTypePublisher,
            intent.PolicyName,
            intent.Activities);
        if (intent.BlueprintApplicationId == Guid.Empty ||
            !PurviewTenantConnectionEvidenceValidator.IsBoundedText(intent.RuleName, 256) ||
        intent.Actions.Count != 1 ||
        intent.Actions[0] != new PurviewDlpRuleAction(
            PurviewPolicyActivity.UploadText,
            PurviewDlpAction.Block) ||
        !intent.Activities.Contains(PurviewPolicyActivity.UploadText))
        {
            throw Failure(
                "PURVIEW_DLP_INTENT_INVALID",
                "The reviewed DLP profile intent is invalid or unsupported.");
        }

        ValidateProviderId(intent.ExpectedPolicyProviderId);
        ValidateProviderId(intent.ExpectedRuleProviderId);
    }

    private static void ValidateCommon(
        Guid operationId,
        Guid tenantId,
        Guid generationId,
        DateTimeOffset inventoryExpiresAtUtc,
        Guid sensitiveInformationTypeId,
        string sensitiveInformationTypeName,
        string sensitiveInformationTypePublisher,
        string policyName,
        IReadOnlyList<PurviewPolicyActivity> activities)
    {
        ArgumentNullException.ThrowIfNull(activities);
        var utcNow = DateTimeOffset.UtcNow;
        if (operationId == Guid.Empty ||
            tenantId == Guid.Empty ||
            generationId == Guid.Empty ||
            sensitiveInformationTypeId == Guid.Empty ||
            inventoryExpiresAtUtc.Offset != TimeSpan.Zero ||
            inventoryExpiresAtUtc <= utcNow ||
            inventoryExpiresAtUtc >
                utcNow.AddMinutes(
                    PurviewTenantConnectionEvidenceValidator.MaximumEvidenceMinutes) ||
            !PurviewTenantConnectionEvidenceValidator.IsBoundedText(
                sensitiveInformationTypeName,
                PurviewTenantConnectionEvidenceValidator.MaximumSensitiveInformationTypeNameLength) ||
            !PurviewTenantConnectionEvidenceValidator.IsBoundedText(
                sensitiveInformationTypePublisher,
                PurviewTenantConnectionEvidenceValidator.MaximumPublisherLength) ||
            !PurviewTenantConnectionEvidenceValidator.IsBoundedText(policyName, 256) ||
            activities.Count is < 1 or > 2 ||
            activities.Distinct().Count() != activities.Count)
        {
            throw Failure(
                "PURVIEW_POLICY_INTENT_INVALID",
                "The reviewed Purview policy intent is invalid, stale, or unsupported.");
        }
    }

    private static void ValidateProviderId(string? value)
    {
        if (value is not null &&
            !PurviewTenantConnectionEvidenceValidator.IsBoundedText(
                value,
                MaximumProviderIdLength))
        {
            throw Failure(
                "PURVIEW_POLICY_INTENT_INVALID",
                "A persisted Purview provider identifier is invalid.");
        }
    }

    private static void ValidateExact(
        PurviewKnowYourDataIntent intent,
        PurviewKnowYourDataReadback readback)
    {
        if (readback.TenantId != intent.TenantId ||
            readback.GroupId != PurviewPolicyLocationContract.EnterpriseAiAppsGroupId ||
            readback.ScopeType != PurviewPolicyScopeType.Group ||
            readback.EnforcementPlane != PurviewEnforcementPlane.Application ||
            readback.SensitiveInformationTypeId != intent.SensitiveInformationTypeId ||
            !string.Equals(
                readback.SensitiveInformationTypeName,
                intent.SensitiveInformationTypeName,
                StringComparison.Ordinal) ||
            !string.Equals(
                readback.SensitiveInformationTypePublisher,
                intent.SensitiveInformationTypePublisher,
                StringComparison.Ordinal) ||
            readback.Mode != intent.Mode ||
            !ExactSet(readback.Activities, intent.Activities) ||
            readback.IngestionEnabled != intent.IngestionEnabled ||
            !MatchesExpectedId(intent.ExpectedPolicyProviderId, readback.PolicyProviderId) ||
            !ValidObservedAt(readback.ObservedAtUtc))
        {
            throw Failure(
                "PURVIEW_KYD_READBACK_MISMATCH",
                "Know Your Data did not read back with the exact reviewed configuration.");
        }
    }

    private static void ValidatePolicyReadbackBeforeRuleMutation(
        PurviewDlpProfileIntent intent,
        PurviewDlpProfileReadback? readback)
    {
        if (readback is null ||
            !ExactDlpPolicy(intent, readback) ||
            (intent.ExpectedRuleProviderId is null
                ? readback.RuleProviderId is not null
                : !string.Equals(
                    intent.ExpectedRuleProviderId,
                    readback.RuleProviderId,
                    StringComparison.Ordinal)))
        {
            throw Failure(
                "PURVIEW_DLP_POLICY_READBACK_MISMATCH",
                "The DLP policy and rule identity were not independently read back before rule mutation.");
        }
    }

    private static void ValidateExact(
        PurviewDlpProfileIntent intent,
        PurviewDlpProfileReadback readback)
    {
        if (!ExactDlpPolicy(intent, readback) ||
            string.IsNullOrWhiteSpace(readback.RuleProviderId) ||
            !MatchesExpectedId(intent.ExpectedRuleProviderId, readback.RuleProviderId) ||
            readback.SensitiveInformationTypeId != intent.SensitiveInformationTypeId ||
            !string.Equals(
                readback.SensitiveInformationTypeName,
                intent.SensitiveInformationTypeName,
                StringComparison.Ordinal) ||
            !string.Equals(
                readback.SensitiveInformationTypePublisher,
                intent.SensitiveInformationTypePublisher,
                StringComparison.Ordinal) ||
            !ExactSet(readback.Activities, intent.Activities) ||
            !ExactSet(readback.Actions, intent.Actions) ||
            readback.HasExclusions ||
            readback.HasBypass)
        {
            throw Failure(
                "PURVIEW_DLP_READBACK_MISMATCH",
                "DLP did not read back with the exact reviewed one-blueprint configuration.");
        }
    }

    private static bool ExactDlpPolicy(
        PurviewDlpProfileIntent intent,
        PurviewDlpProfileReadback readback) =>
        readback.TenantId == intent.TenantId &&
        readback.BlueprintApplicationIds.Count == 1 &&
        readback.BlueprintApplicationIds[0] == intent.BlueprintApplicationId &&
        readback.ScopeType == PurviewPolicyScopeType.Individual &&
        readback.EnforcementPlane == PurviewEnforcementPlane.Application &&
        readback.Mode == intent.Mode &&
        !readback.HasExclusions &&
        !readback.HasBypass &&
        MatchesExpectedId(intent.ExpectedPolicyProviderId, readback.PolicyProviderId) &&
        ValidObservedAt(readback.ObservedAtUtc);

    private static bool ExactSet<T>(IReadOnlyList<T> actual, IReadOnlyList<T> expected)
        where T : notnull =>
        actual.Count == expected.Count &&
        actual.ToHashSet().SetEquals(expected);

    private static bool MatchesExpectedId(string? expected, string actual) =>
        PurviewTenantConnectionEvidenceValidator.IsBoundedText(
            actual,
            MaximumProviderIdLength) &&
        (expected is null || string.Equals(expected, actual, StringComparison.Ordinal));

    private static bool ValidObservedAt(DateTimeOffset value) =>
        value.Offset == TimeSpan.Zero &&
        value <= DateTimeOffset.UtcNow.AddMinutes(5) &&
        value >= DateTimeOffset.UtcNow.AddMinutes(-30);

    private static void RequireState(
        PurviewProviderObjectState actual,
        PurviewProviderObjectState expected,
        string failureCode)
    {
        if (actual != expected)
            throw Failure(failureCode, "Purview provider state could not be verified exactly.");
    }

    private static PurviewPolicyException Failure(string code, string message) =>
        new(code, message);
}
