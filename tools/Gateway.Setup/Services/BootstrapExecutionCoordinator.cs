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
    BootstrapVerifiedEndpoints? VerifiedEndpoints)
{
    public bool IsRunning => Status == BootstrapExecutionStatus.Running;

    public bool HasVerifiedDeployment =>
        Command is BootstrapCommand.Apply or BootstrapCommand.Resume &&
        Status == BootstrapExecutionStatus.Succeeded &&
        VerifiedEndpoints is { VerificationMode: BootstrapVerificationMode.Apply };
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
    private BootstrapVerifiedEndpoints? verifiedEndpoints;
    private int deploymentVerificationClaimCount;
    private bool deploymentVerificationConflict;
    private string? reviewedPlanFingerprint;
    private int planResultClaimCount;
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
                verifiedEndpoints);
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
            verifiedEndpoints = null;
            deploymentVerificationClaimCount = 0;
            deploymentVerificationConflict = false;
            if (requestedCommand == BootstrapCommand.Plan)
            {
                planSucceeded = false;
                reviewedPlanFingerprint = null;
                planResultClaimCount = 0;
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

        bool operationCompletedSuccessfully;
        lock (sync)
        {
            exitCode = result.ExitCode;
            var completedSuccessfully = result.Succeeded;
            if (requestedCommand == BootstrapCommand.Plan)
            {
                planSucceeded = result.Succeeded &&
                    planResultClaimCount == 1 &&
                    planApplyReady &&
                    !planFingerprintConflict &&
                    PlanFingerprintPolicy.IsCanonical(reviewedPlanFingerprint);
                completedSuccessfully = planSucceeded;
            }
            else if (requestedCommand is BootstrapCommand.Apply or BootstrapCommand.Resume)
            {
                completedSuccessfully = result.Succeeded &&
                    deploymentVerificationClaimCount == 1 &&
                    !deploymentVerificationConflict &&
                    verifiedEndpoints is { VerificationMode: BootstrapVerificationMode.Apply };
                if (!completedSuccessfully)
                {
                    verifiedEndpoints = null;
                }
            }

            operationCompletedSuccessfully = completedSuccessfully;

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
                        : requestedCommand is BootstrapCommand.Apply or BootstrapCommand.Resume && result.Succeeded
                            ? $"{requestedCommand} exited without exactly one nonconflicting typed deployment verification result. Setup did not mark the Gateway ready."
                        : $"{requestedCommand} stopped with exit category {NormalizeExitCategory(result.ExitCode)}."));
            TrimEvents();
        }

        activity.SetOperationActive(false);
        if (operationCompletedSuccessfully &&
            requestedCommand is BootstrapCommand.Apply or BootstrapCommand.Resume)
        {
            activity.MarkCompleted();
        }

        Changed?.Invoke();
    }

    private void Append(BootstrapProgressEvent progressEvent)
    {
        lock (sync)
        {
            if (command is BootstrapCommand.Apply or BootstrapCommand.Resume &&
                status == BootstrapExecutionStatus.Running &&
                progressEvent.DeploymentVerificationClaimObserved)
            {
                deploymentVerificationClaimCount++;
                var candidate = progressEvent.VerifiedEndpoints;
                if (candidate is not { VerificationMode: BootstrapVerificationMode.Apply })
                {
                    deploymentVerificationConflict = true;
                }
                else if (verifiedEndpoints is null)
                {
                    verifiedEndpoints = candidate;
                }
                else if (verifiedEndpoints != candidate)
                {
                    deploymentVerificationConflict = true;
                }
            }

            if (command == BootstrapCommand.Plan &&
                status == BootstrapExecutionStatus.Running &&
                progressEvent.PlanResultClaimObserved)
            {
                planResultClaimCount++;
                if (planResultClaimCount != 1 ||
                    progressEvent.PlanApplyReady is not { } applyReady)
                {
                    reviewedPlanFingerprint = null;
                    planApplyReady = false;
                    planFingerprintConflict = true;
                }
                else
                {
                    planApplyReady = applyReady;
                    reviewedPlanFingerprint = applyReady &&
                        PlanFingerprintPolicy.IsCanonical(progressEvent.PlanFingerprint)
                            ? progressEvent.PlanFingerprint
                            : null;
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
