namespace Gateway.Setup.Services;

internal enum BootstrapPlanPreparationStatus
{
    Started,
    Busy,
    NotConfirmed,
    StateChanged,
    ConfigurationChanged
}

internal sealed record BootstrapPlanPreparationResult(
    BootstrapPlanPreparationStatus Status,
    string? ConfigurationPath = null);

internal sealed class BootstrapPlanPreparationCoordinator(
    IBootstrapConfigWriter configWriter,
    BootstrapExecutionCoordinator execution)
{
    public async Task<BootstrapPlanPreparationResult> TryPrepareAndStartAsync(
        SetupWizardState state,
        bool explicitlyConfirmed,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(state);
        if (!explicitlyConfirmed)
        {
            return new BootstrapPlanPreparationResult(
                BootstrapPlanPreparationStatus.NotConfirmed);
        }

        using var lease = execution.TryAcquirePlanPreparation(explicitlyConfirmed);
        if (lease is null)
        {
            return new BootstrapPlanPreparationResult(
                BootstrapPlanPreparationStatus.Busy);
        }

        var planReady = state.CreatePlanReadyConfiguration();
        using var staged = await configWriter.StageAsync(planReady, cancellationToken);
        if (!state.IsPlanReadinessCurrent(planReady.Readiness))
        {
            return new BootstrapPlanPreparationResult(
                BootstrapPlanPreparationStatus.StateChanged);
        }

        var writeResult = staged.TryPublish();
        if (writeResult is null)
        {
            return new BootstrapPlanPreparationResult(
                BootstrapPlanPreparationStatus.ConfigurationChanged);
        }

        if (!lease.TryStartPlan(writeResult.ConfigurationFileFingerprint))
        {
            return new BootstrapPlanPreparationResult(
                BootstrapPlanPreparationStatus.Busy,
                writeResult.Path);
        }

        state.MarkConfigurationWritten(writeResult.Path);
        return new BootstrapPlanPreparationResult(
            BootstrapPlanPreparationStatus.Started,
            writeResult.Path);
    }
}
