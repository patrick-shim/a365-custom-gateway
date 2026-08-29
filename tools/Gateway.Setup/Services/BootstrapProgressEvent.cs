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

internal sealed record BootstrapProgressEvent(
    DateTimeOffset TimestampUtc,
    BootstrapProgressKind Kind,
    string Message,
    string? Step = null,
    int? ProgressPercent = null,
    Uri? AdminUiAddress = null,
    string? PlanFingerprint = null,
    bool? PlanApplyReady = null,
    string? DisplayLabel = null);

internal sealed record BootstrapProcessResult(int ExitCode, bool WasCancelled)
{
    public bool Succeeded => ExitCode == 0 && !WasCancelled;
}
