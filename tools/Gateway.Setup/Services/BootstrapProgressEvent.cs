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

internal sealed record BootstrapVerifiedEndpoints(
    BootstrapVerificationMode VerificationMode,
    Uri AdminUiBaseAddress,
    Uri ApiBaseAddress,
    Uri ApiHealthAddress)
{
    public Uri AdminSetupAddress => new(AdminUiBaseAddress, "setup");
}

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
    bool PlanResultClaimObserved = false);

internal sealed record BootstrapProcessResult(int ExitCode, bool WasCancelled)
{
    public bool Succeeded => ExitCode == 0 && !WasCancelled;
}
