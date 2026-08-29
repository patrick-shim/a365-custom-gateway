using Gateway.Setup.Security;

namespace Gateway.Setup.Services;

internal enum BootstrapExecutionStatus
{
    NotStarted,
    Running,
    Succeeded,
    Failed,
    Cancelled
}

internal sealed record BootstrapExecutionSnapshot(
    BootstrapCommand? Command,
    BootstrapExecutionStatus Status,
    IReadOnlyList<BootstrapProgressEvent> Events,
    int? ExitCode,
    bool PlanSucceeded,
    Uri? AdminUiAddress)
{
    public bool IsRunning => Status == BootstrapExecutionStatus.Running;
}

internal sealed class BootstrapExecutionCoordinator(
    IBootstrapCommandFactory commandFactory,
    IBootstrapProcessRunner processRunner,
    SetupActivityTracker activity,
    IHostApplicationLifetime applicationLifetime)
{
    private const int MaximumRetainedEvents = 300;
    private readonly object sync = new();
    private readonly List<BootstrapProgressEvent> events = [];
    private BootstrapCommand? command;
    private BootstrapExecutionStatus status = BootstrapExecutionStatus.NotStarted;
    private int? exitCode;
    private bool planSucceeded;
    private Uri? adminUiAddress;
    private string? reviewedPlanFingerprint;
    private bool planResultObserved;
    private bool planApplyReady;
    private bool planFingerprintConflict;

    public event Action? Changed;

    public BootstrapExecutionSnapshot Snapshot()
    {
        lock (sync)
        {
            return new BootstrapExecutionSnapshot(
                command,
                status,
                events.ToArray(),
                exitCode,
                planSucceeded,
                adminUiAddress);
        }
    }

    public bool TryStart(BootstrapCommand requestedCommand, bool explicitlyConfirmed)
    {
        if (!explicitlyConfirmed)
        {
            return false;
        }

        lock (sync)
        {
            if (status == BootstrapExecutionStatus.Running ||
                requestedCommand is not BootstrapCommand.Plan && !planSucceeded)
            {
                return false;
            }

            command = requestedCommand;
            status = BootstrapExecutionStatus.Running;
            exitCode = null;
            adminUiAddress = null;
            if (requestedCommand == BootstrapCommand.Plan)
            {
                planSucceeded = false;
                reviewedPlanFingerprint = null;
                planResultObserved = false;
                planApplyReady = false;
                planFingerprintConflict = false;
            }

            events.Clear();
            events.Add(new BootstrapProgressEvent(
                DateTimeOffset.UtcNow,
                BootstrapProgressKind.Information,
                $"Starting the reviewed {requestedCommand} command."));
            if (requestedCommand is BootstrapCommand.Apply or BootstrapCommand.Resume)
            {
                events.Add(new BootstrapProgressEvent(
                    DateTimeOffset.UtcNow,
                    BootstrapProgressKind.Information,
                    "Watch the launch terminal and official Microsoft browser windows for required sign-in or consent handoffs. Setup never captures that input."));
            }
        }

        activity.SetOperationActive(true);
        Changed?.Invoke();
        _ = RunCoreAsync(requestedCommand);
        return true;
    }

    private async Task RunCoreAsync(BootstrapCommand requestedCommand)
    {
        BootstrapProcessResult result;
        try
        {
            string? expectedPlanFingerprint;
            lock (sync)
            {
                expectedPlanFingerprint = requestedCommand == BootstrapCommand.Plan
                    ? null
                    : reviewedPlanFingerprint;
            }

            var specification = commandFactory.Create(requestedCommand, expectedPlanFingerprint);
            result = await processRunner.RunAsync(
                specification,
                progressEvent =>
                {
                    Append(progressEvent);
                    return ValueTask.CompletedTask;
                },
                applicationLifetime.ApplicationStopping);
        }
        catch (Exception)
        {
            Append(new BootstrapProgressEvent(
                DateTimeOffset.UtcNow,
                BootstrapProgressKind.Error,
                "Setup could not start the canonical bootstrap command. No diagnostic details were rendered."));
            result = new BootstrapProcessResult(-1, false);
        }

        lock (sync)
        {
            exitCode = result.ExitCode;
            var completedSuccessfully = result.Succeeded;
            if (requestedCommand == BootstrapCommand.Plan)
            {
                planSucceeded = result.Succeeded &&
                    planResultObserved &&
                    planApplyReady &&
                    !planFingerprintConflict &&
                    PlanFingerprintPolicy.IsCanonical(reviewedPlanFingerprint);
                completedSuccessfully = planSucceeded;
            }

            status = result.WasCancelled
                ? BootstrapExecutionStatus.Cancelled
                : completedSuccessfully
                    ? BootstrapExecutionStatus.Succeeded
                    : BootstrapExecutionStatus.Failed;

            events.Add(new BootstrapProgressEvent(
                DateTimeOffset.UtcNow,
                completedSuccessfully ? BootstrapProgressKind.Success : BootstrapProgressKind.Error,
                completedSuccessfully
                    ? $"{requestedCommand} completed successfully."
                    : result.WasCancelled
                        ? $"{requestedCommand} was interrupted. The canonical bootstrap state remains the recovery authority."
                        : requestedCommand == BootstrapCommand.Plan && result.Succeeded
                            ? "Plan ended without one apply-ready canonical fingerprint. No mutation was authorized."
                        : $"{requestedCommand} stopped with exit category {NormalizeExitCategory(result.ExitCode)}."));
            TrimEvents();
        }

        activity.SetOperationActive(false);
        if (result.Succeeded && requestedCommand is BootstrapCommand.Apply or BootstrapCommand.Resume)
        {
            activity.MarkCompleted();
        }

        Changed?.Invoke();
    }

    private void Append(BootstrapProgressEvent progressEvent)
    {
        lock (sync)
        {
            if (command == BootstrapCommand.Plan &&
                status == BootstrapExecutionStatus.Running &&
                progressEvent.PlanApplyReady is { } applyReady)
            {
                planResultObserved = true;
                planApplyReady = applyReady;
                if (!applyReady || !PlanFingerprintPolicy.IsCanonical(progressEvent.PlanFingerprint))
                {
                    reviewedPlanFingerprint = null;
                }
                else if (reviewedPlanFingerprint is null)
                {
                    reviewedPlanFingerprint = progressEvent.PlanFingerprint;
                }
                else if (!string.Equals(
                    reviewedPlanFingerprint,
                    progressEvent.PlanFingerprint,
                    StringComparison.Ordinal))
                {
                    reviewedPlanFingerprint = null;
                    planFingerprintConflict = true;
                }
            }

            if (events.Count > 0 &&
                progressEvent.Kind == BootstrapProgressKind.Withheld &&
                events[^1].Kind == progressEvent.Kind &&
                string.Equals(events[^1].Message, progressEvent.Message, StringComparison.Ordinal))
            {
                return;
            }

            events.Add(progressEvent);
            adminUiAddress = progressEvent.AdminUiAddress ?? adminUiAddress;
            TrimEvents();
        }

        activity.Touch();
        Changed?.Invoke();
    }

    private void TrimEvents()
    {
        if (events.Count > MaximumRetainedEvents)
        {
            events.RemoveRange(0, events.Count - MaximumRetainedEvents);
        }
    }

    private static string NormalizeExitCategory(int exitCode) => exitCode switch
    {
        0 => "success",
        -1 => "not-started",
        _ => "nonzero"
    };
}
