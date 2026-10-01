using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Models;
using Microsoft.AspNetCore.Components;
using Microsoft.JSInterop;

namespace Gateway.AdminUi.Components.Pages;

public partial class Settings
{
    private static readonly TimeSpan OperationPollInterval = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan OperationPollLimit = TimeSpan.FromMinutes(5);
    private CancellationTokenSource? operationPollCts;
    private Task operationPollTask = Task.CompletedTask;
    private Guid? observedOperationId;
    private long observedContext = -1;
    private bool operationPolling;
    private bool operationContextRefreshing;
    private bool operationContextRefreshNeeded;
    private bool changingContext;
    private DateTime? operationLastCheckedAtUtc;
    private string? operationPollingNotice;
    private ElementReference policyEditorHeading;
    private bool focusPolicyEditorRequested;
    private bool ShouldReadProtectionContext => canReadProtectionGovernance &&
        (isAdministrator || CurrentTask is not (SettingsTask.Runtime or SettingsTask.Defaults)) &&
        PurviewCapability?.Status != "NotInstalled";
    private bool ShouldReadProfiles =>
        CurrentTask is SettingsTask.Overview or SettingsTask.Policy or SettingsTask.Runtime or SettingsTask.Defaults;
    private bool ShouldReadKnowYourData => CurrentTask == SettingsTask.Collection;
    private bool ShouldReadInventory =>
        isAdministrator && ConnectionIsReady && CurrentTask is SettingsTask.Connection or SettingsTask.Collection;
    private bool ShouldReadBlueprints => isAdministrator && CurrentTask == SettingsTask.Policy;
    private bool ProtectionReadsSucceeded => capabilitiesError is null &&
        (!ShouldReadProtectionContext || connectionError is null &&
            (!ShouldReadProfiles || profilesError is null) &&
            (!ShouldReadKnowYourData || knowYourDataError is null) &&
            (!ShouldReadInventory || inventoryError is null) &&
            (!ShouldReadBlueprints || blueprintsError is null));

    protected override async Task OnAfterRenderAsync(bool firstRender)
    {
        if (!RendererInfo.IsInteractive || disposed || changingContext)
            return;
        if (focusPolicyEditorRequested && !reloading)
        {
            focusPolicyEditorRequested = false;
            if (CurrentTask == SettingsTask.Policy)
            {
                try { await policyEditorHeading.FocusAsync(); }
                catch (JSException exception)
                {
                    Logger.LogDebug(exception, "Shared policy editor focus was unavailable.");
                    protectionAnnouncement = "The selected policy is ready to review in the editor above its saved details.";
                }
            }
        }
        if (focusOutcomeRequested && outcomePanel is not null && !reloading && !operationContextRefreshing)
        {
            focusOutcomeRequested = false;
            try
            {
                await outcomePanel.FocusAsync();
            }
            catch (JSException exception)
            {
                Logger.LogDebug(exception, "Protection outcome focus was unavailable.");
                if (!disposed)
                    protectionAnnouncement = "Follow the result and next step in the protection outcome panel.";
            }
        }
        if (!reloading && !operationLoading && !protectionActionBusy &&
            !protectionOutcomeUnknown && operationError is null &&
            ProtectionOperationPresentation.IsInProgress(ActiveOperation?.Status) &&
            (observedContext != contextGeneration || observedOperationId != activeOperationId))
            await StartOperationUpdatesAsync();
    }

    private async Task StartOperationUpdatesAsync()
    {
        if (disposed || !RendererInfo.IsInteractive || activeOperationId is not { } operationId)
            return;
        var generation = contextGeneration;
        await CancelOperationUpdatesAsync();
        if (!IsCurrent(generation) || activeOperationId != operationId)
            return;
        observedContext = generation;
        observedOperationId = operationId;
        operationPollingNotice = null;
        operationPolling = true;
        operationPollCts = CancellationTokenSource.CreateLinkedTokenSource(disposeCts.Token);
        operationPollTask = ObserveOperationAsync(operationId, generation, operationPollCts.Token);
        await InvokeAsync(StateHasChanged);
    }

    private async Task StopOperationUpdatesAsync()
    {
        operationPollingNotice = "Automatic updates stopped. The operation itself was not cancelled. Check the saved result or resume updates when ready.";
        await CancelOperationUpdatesAsync();
    }

    private async Task ObserveOperationAsync(Guid operationId, long generation, CancellationToken cancellationToken)
    {
        using var deadline = new CancellationTokenSource(OperationPollLimit, Clock);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var token = linked.Token;
        try
        {
            while (!token.IsCancellationRequested && IsCurrent(generation) && activeOperationId == operationId)
            {
                await Task.Delay(OperationPollInterval, Clock, token);
                if (reloading || operationLoading || protectionActionBusy)
                    continue;
                await ReadActiveOperationAsync(refreshContext: false, token);
                token.ThrowIfCancellationRequested();
                if (!IsCurrent(generation) || activeOperationId != operationId)
                    return;
                if (operationError is not null || protectionOutcomeUnknown)
                {
                    operationPollingNotice = "Automatic updates stopped after a read error. Check this same saved operation; no request was resubmitted.";
                    return;
                }
                if (!ProtectionOperationPresentation.IsInProgress(ActiveOperation?.Status))
                {
                    await RefreshOperationContextAsync(token);
                    if (IsCurrent(generation))
                        operationPollingNotice = ProtectionReadsSucceeded
                            ? "Automatic updates finished. The saved result and current next step are shown above."
                            : "The operation finished, but some current details could not be read. Refresh current state before continuing.";
                    return;
                }
                await InvokeAsync(StateHasChanged);
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && deadline.IsCancellationRequested)
        {
            if (IsCurrent(generation))
                operationPollingNotice = "Automatic updates paused after five minutes. The operation may still be running; resume updates to continue. Do not submit it again.";
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            if (IsCurrent(generation))
            {
                operationError = UiErrorInfo.FromException(exception);
                operationPollingNotice = "Automatic updates stopped after a read error. Check the saved operation without resubmitting it.";
            }
            else
                LogSupersededRead();
        }
        finally
        {
            if (IsCurrent(generation) && activeOperationId == operationId)
            {
                operationPolling = false;
                await InvokeAsync(StateHasChanged);
            }
        }
    }

    private async Task RefreshOperationContextAsync(CancellationToken cancellationToken)
    {
        var generation = contextGeneration;
        operationContextRefreshing = true;
        operationContextRefreshNeeded = true;
        try
        {
            await InvokeAsync(StateHasChanged);
            await LoadProtectionJourneyAsync(cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            if (IsCurrent(generation) && ProtectionReadsSucceeded)
                operationContextRefreshNeeded = false;
        }
        finally
        {
            if (IsCurrent(generation))
                operationContextRefreshing = false;
        }
    }

    private async Task CancelOperationUpdatesAsync()
    {
        var cancellation = operationPollCts;
        var task = operationPollTask;
        operationPollCts = null;
        operationPollTask = Task.CompletedTask;
        if (cancellation is null)
            return;
        cancellation.Cancel();
        await task;
        cancellation.Dispose();
        operationPolling = false;
    }
}
