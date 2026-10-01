namespace Gateway.Setup.Services;

internal enum BootstrapProgressKind
{
    Information,
    Step,
    Success,
    Warning,
    Error,
    Withheld
}

internal enum BootstrapVerificationMode
{
    Apply,
    Verify
}

// Presentational completion facts. Every member is a primitive so two identical
// completion events compare equal and never look like a conflicting second claim.
internal sealed record BootstrapCompletionSummary(
    DateTimeOffset CompletedAtUtc,
    string Elapsed,
    int StepsCompleted,
    int StepsTotal,
    string DeploymentId,
    string Environment,
    string ResourceGroup,
    string Region,
    string SubscriptionId,
    string Readiness,
    string ProvisioningAdmission);

internal sealed record BootstrapVerifiedEndpoints(
    BootstrapVerificationMode VerificationMode,
    Uri AdminUiBaseAddress,
    Uri ApiBaseAddress,
    Uri ApiHealthAddress,
    BootstrapCompletionSummary? CompletionSummary = null)
{
    public Uri AdminSetupAddress => new(AdminUiBaseAddress, "setup");
}

internal sealed record BootstrapResumeAuthorization(
    string AcceptedPlanFingerprint,
    string CheckpointFingerprint,
    string ResumeAuthorizationFingerprint);

internal sealed record BootstrapProgressEvent(
    DateTimeOffset TimestampUtc,
    BootstrapProgressKind Kind,
    string Message,
    string? Step = null,
    int? ProgressPercent = null,
    string? PlanFingerprint = null,
    bool? PlanApplyReady = null,
    string? DisplayLabel = null,
    BootstrapVerifiedEndpoints? VerifiedEndpoints = null,
    bool DeploymentVerificationClaimObserved = false,
    bool PlanResultClaimObserved = false,
    BootstrapResumeAuthorization? ResumeAuthorization = null,
    bool ResumeReviewClaimObserved = false);

internal sealed record BootstrapProcessResult(int ExitCode, bool WasCancelled)
{
    public bool Succeeded => ExitCode == 0 && !WasCancelled;
}
