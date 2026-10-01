using Bunit;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Dtos;
using Microsoft.AspNetCore.Components;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Time.Testing;

namespace Gateway.AdminUi.Tests.Components;

public sealed class ProtectionActivityTests
{
    private static DateTime Now => CoreUiData.Now.UtcDateTime;

    [Fact]
    public void Indicator_has_a_named_indeterminate_progress_role_without_its_own_live_region()
    {
        using var fixture = CoreUiData.Create();
        var panel = fixture.Render<ActivityIndicator>(parameters => parameters
            .Add(item => item.Label, "Reading the saved Gateway status"));

        var progress = Assert.Single(panel.FindAll("[role='progressbar']"));
        Assert.Equal("Reading the saved Gateway status", progress.GetAttribute("aria-label"));
        Assert.Equal("true", progress.GetAttribute("aria-busy"));
        Assert.False(progress.HasAttribute("aria-valuenow"));
        Assert.False(progress.HasAttribute("aria-valuemin"));
        Assert.False(progress.HasAttribute("aria-valuemax"));
        Assert.Contains("Reading the saved Gateway status", progress.TextContent);
        Assert.Equal("true", panel.Find(".activity-ring").GetAttribute("aria-hidden"));
        Assert.Empty(panel.FindAll("[role='status'], [aria-live]"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Loading_state_reuses_the_indicator_and_preserves_its_label_detail_and_single_announcement()
    {
        using var fixture = CoreUiData.Create();
        var panel = fixture.Render<LoadingState>(parameters => parameters
            .Add(item => item.Label, "Loading protection operation...")
            .Add(item => item.Detail, "Reading saved state only."));

        Assert.Equal("Loading protection operation...", panel.Find("strong").TextContent);
        Assert.Contains("Reading saved state only.", panel.Markup);
        Assert.Equal("Loading protection operation...", panel.Find("[role='progressbar']").GetAttribute("aria-label"));
        Assert.Single(panel.FindComponents<ActivityIndicator>());
        Assert.Single(panel.FindAll("[role='status']"));
        Assert.Single(panel.FindAll("[aria-live='polite']"));
        Assert.Empty(panel.FindAll("[aria-valuenow]"));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Outcome_activity_is_opt_in_and_preserves_guidance_actions_and_one_live_region()
    {
        using var fixture = CoreUiData.Create();
        var selected = ProtectionJourneyAction.None;
        var guidance = new ProtectionJourneyGuidance(
            "Read the existing operation", "Pending", "Saved request", "Read-only observation",
            "Microsoft progress is not confirmed", "Check the saved result", "Check existing operation",
            Action: ProtectionJourneyAction.CheckOperation);
        var panel = fixture.Render<ProtectionJourneyOutcome>(parameters => parameters
            .Add(item => item.Guidance, guidance)
            .Add(item => item.OnAction, action => selected = action));

        Assert.False(panel.Instance.Busy);
        Assert.Empty(panel.FindAll("[role='progressbar']"));

        panel.Render(parameters => parameters.Add(item => item.Busy, true));
        Assert.Single(panel.FindAll("[role='progressbar']"));
        Assert.Contains("This does not confirm progress in Microsoft", panel.Find(".outcome-activity").TextContent);
        Assert.Single(panel.FindAll("[role='status']"));
        Assert.Single(panel.FindAll("[aria-live]"));
        Assert.Same(guidance, panel.Instance.Guidance);
        await AdminUiFixture.ClickAsync(panel, "Check existing operation");
        Assert.Equal(ProtectionJourneyAction.CheckOperation, selected);

        panel.Render(parameters => parameters
            .Add(item => item.Busy, false)
            .Add(item => item.ActionDisabled, true));
        Assert.Empty(panel.FindAll("[role='progressbar']"));
        Assert.True(panel.Find("fluent-button").HasAttribute("disabled"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Active_monitoring_explains_read_only_activity_and_the_friendly_saved_step()
    {
        using var fixture = CoreUiData.Create();
        var operation = SavedOperation();
        var panel = fixture.Render<ProtectionOperationMonitor>(parameters => parameters
            .Add(item => item.Operation, operation)
            .Add(item => item.HasRetainedOperation, true)
            .Add(item => item.Polling, true)
            .Add(item => item.LastCheckedAtUtc, Now));

        Assert.Equal("monitoring", panel.Find(".operation-update-controls").GetAttribute("data-observation-state"));
        Assert.Equal("Automatic read-only updates are active", panel.Find("[role='progressbar']").GetAttribute("aria-label"));
        Assert.Contains("not confirming progress in Microsoft", panel.Find(".observation-explanation").TextContent);
        Assert.Contains("No operation is being resubmitted", panel.Markup);
        Assert.Contains("Last recorded step:", panel.Find(".operation-current-step").TextContent);
        Assert.Contains("Check the Gateway's own Purview access", panel.Find(".operation-current-step").TextContent);
        Assert.DoesNotContain("DiscoverProviderState", panel.Find(".operation-current-step").TextContent);
        Assert.Contains("6 minutes", panel.Find(".operation-observation-facts").TextContent);
        Assert.Contains("UTC", panel.Find(".operation-observation-facts").TextContent);
        Assert.Empty(panel.FindAll("[aria-valuenow], [role='status'], [aria-live]"));
        Assert.Empty(panel.FindAll(".operation-stale-check, .operation-unchanged"));
        Assert.Same(operation, panel.FindComponent<ProtectionOperationTimeline>().Instance.Operation);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Loading_displays_one_indicator_for_an_actual_read_with_or_without_a_saved_operation(bool hasSnapshot)
    {
        using var fixture = CoreUiData.Create();
        var panel = fixture.Render<ProtectionOperationMonitor>(parameters => parameters
            .Add(item => item.Operation, hasSnapshot ? SavedOperation() : null)
            .Add(item => item.HasRetainedOperation, true)
            .Add(item => item.Loading, true));

        Assert.Equal("checking", panel.Find(".operation-update-controls").GetAttribute("data-observation-state"));
        var progress = Assert.Single(panel.FindAll("[role='progressbar']"));
        Assert.Equal(hasSnapshot ? "Checking saved Gateway status" : "Loading protection operation...",
            progress.GetAttribute("aria-label"));
        Assert.Empty(panel.FindAll("[aria-valuenow]"));
        Assert.All(panel.FindAll("fluent-button"), button => Assert.True(button.HasAttribute("disabled")));
        Assert.Equal(hasSnapshot ? 0 : 1, panel.FindAll("[aria-live]").Count);
        fixture.AssertComplete();
    }

    [Fact]
    public void Paused_observation_has_no_activity_and_explicitly_does_not_cancel_the_operation()
    {
        using var fixture = CoreUiData.Create();
        const string notice = "Automatic updates paused after five minutes. Do not submit it again.";
        var panel = fixture.Render<ProtectionOperationMonitor>(parameters => parameters
            .Add(item => item.Operation, SavedOperation())
            .Add(item => item.HasRetainedOperation, true)
            .Add(item => item.Notice, notice)
            .Add(item => item.LastCheckedAtUtc, Now.AddMinutes(-2)));

        Assert.Equal("paused", panel.Find(".operation-update-controls").GetAttribute("data-observation-state"));
        Assert.Contains("Automatic updates are paused", panel.Markup);
        Assert.Contains("Only observation is paused; the operation itself was not cancelled", panel.Markup);
        Assert.Contains("Saved details may be out of date", panel.Find(".operation-stale-check").TextContent);
        Assert.Equal(notice, panel.Find(".operation-notice").TextContent);
        Assert.Empty(panel.FindAll("[role='progressbar'], .activity-ring, [aria-live]"));
        Assert.Contains("Resume automatic updates", panel.Markup);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Read_failure_has_no_activity_even_with_a_retained_polling_flag_and_retry_still_refreshes(bool hasSnapshot)
    {
        using var fixture = CoreUiData.Create();
        var refreshes = 0;
        var error = new UiErrorInfo("Synthetic status read failed.", "fixture-correlation");
        var panel = fixture.Render<ProtectionOperationMonitor>(parameters => parameters
            .Add(item => item.Operation, hasSnapshot ? SavedOperation() : null)
            .Add(item => item.HasRetainedOperation, true)
            .Add(item => item.Polling, true)
            .Add(item => item.Error, error)
            .Add(item => item.LastCheckedAtUtc, Now.AddMinutes(-2))
            .Add(item => item.OnRefresh, () => refreshes++));

        Assert.Equal("read-error", panel.Find(".operation-update-controls").GetAttribute("data-observation-state"));
        Assert.Contains(error.Message, panel.Find("[role='alert']").TextContent);
        Assert.Contains("Earlier saved details may be out of date", panel.Markup);
        Assert.Empty(panel.FindAll("[role='progressbar'], .activity-ring, [role='status'], [aria-live]"));
        await AdminUiFixture.ClickAsync(panel, "Try again");
        await AdminUiFixture.ClickAsync(panel, "Refresh operation");
        Assert.Equal(2, refreshes);

        panel.Render(parameters => parameters.Add(item => item.Loading, true));
        Assert.Single(panel.FindAll("[role='alert']"));
        Assert.Empty(panel.FindAll("[role='progressbar'], .activity-ring"));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("Completed", "completed", "The saved operation is complete")]
    [InlineData("Succeeded", "completed", "The saved operation is complete")]
    [InlineData("Failed", "attention", "The saved operation needs attention")]
    [InlineData("VerificationFailed", "attention", "The saved operation needs attention")]
    [InlineData("RequiresManualIntervention", "attention", "The saved operation needs attention")]
    [InlineData("Cancelled", "cancelled", "The saved operation was cancelled")]
    [InlineData("AwaitingAdministrator", "waiting", "The operation is waiting for the next step")]
    [InlineData("AwaitingConfirmation", "waiting", "The operation is waiting for the next step")]
    [InlineData("AwaitingBlueprint", "waiting", "The operation is waiting for the next step")]
    [InlineData("OutcomeUnknown", "unconfirmed", "The saved result is not confirmed")]
    public void Terminal_attention_waiting_and_unknown_states_remove_activity_despite_old_loading_flags(
        string status, string state, string label)
    {
        using var fixture = CoreUiData.Create();
        var panel = fixture.Render<ProtectionOperationMonitor>(parameters => parameters
            .Add(item => item.Operation, SavedOperation())
            .Add(item => item.HasRetainedOperation, true)
            .Add(item => item.Polling, true));
        Assert.Single(panel.FindAll("[role='progressbar']"));

        panel.Render(parameters => parameters
            .Add(item => item.Operation, SavedOperation(status))
            .Add(item => item.Loading, true));
        Assert.Equal(state, panel.Find(".operation-update-controls").GetAttribute("data-observation-state"));
        Assert.Contains(label, panel.Find(".observation-label").TextContent);
        Assert.Empty(panel.FindAll("[role='progressbar'], .activity-ring, [aria-live]"));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Stop_resume_and_refresh_only_forward_the_existing_callbacks()
    {
        using var fixture = CoreUiData.Create();
        var stops = 0;
        var resumes = 0;
        var refreshes = 0;
        var operation = SavedOperation();
        var panel = fixture.Render<ProtectionOperationMonitor>(parameters => parameters
            .Add(item => item.Operation, operation)
            .Add(item => item.HasRetainedOperation, true)
            .Add(item => item.Polling, true)
            .Add(item => item.OnStop, () => stops++)
            .Add(item => item.OnResume, () => resumes++)
            .Add(item => item.OnRefresh, () => refreshes++));

        await AdminUiFixture.ClickAsync(panel, "Stop automatic updates");
        Assert.Equal(1, stops);
        Assert.True(panel.Instance.Polling);
        panel.Render(parameters => parameters.Add(item => item.Polling, false));
        Assert.Empty(panel.FindAll("[role='progressbar']"));
        await AdminUiFixture.ClickAsync(panel, "Resume automatic updates");
        Assert.Equal(1, resumes);
        Assert.False(panel.Instance.Polling);
        await AdminUiFixture.ClickAsync(panel, "Refresh operation");
        Assert.Equal(1, refreshes);
        Assert.Same(operation, panel.Instance.Operation);
        Assert.Empty(fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public void Prerender_keeps_observation_controls_disabled()
    {
        using var fixture = CoreUiData.Create();
        fixture.Rendering = new RendererInfo("Static", isInteractive: false);
        var panel = fixture.Render<ProtectionOperationMonitor>(parameters => parameters
            .Add(item => item.Operation, SavedOperation())
            .Add(item => item.HasRetainedOperation, true)
            .Add(item => item.Polling, true));

        Assert.All(panel.FindAll("fluent-button"), button => Assert.True(button.HasAttribute("disabled")));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Elapsed_context_uses_the_injected_clock_only_when_the_parent_updates_the_view()
    {
        using var fixture = CoreUiData.Create();
        var clock = (FakeTimeProvider)fixture.Services.GetRequiredService<TimeProvider>();
        var operation = SavedOperation();
        var panel = fixture.Render<ProtectionOperationMonitor>(parameters => parameters
            .Add(item => item.Operation, operation)
            .Add(item => item.HasRetainedOperation, true)
            .Add(item => item.Polling, true)
            .Add(item => item.LastCheckedAtUtc, Now));
        var originalMarkup = panel.Markup;
        var renders = panel.RenderCount;

        await panel.InvokeAsync(() => clock.Advance(TimeSpan.FromMinutes(2)));
        Assert.Equal(renders, panel.RenderCount);
        Assert.Equal(originalMarkup, panel.Markup);
        panel.Render(parameters => parameters.Add(item => item.Operation, operation));
        Assert.Contains("8 minutes", panel.Find(".operation-observation-facts").TextContent);
        Assert.Contains("2 minutes before this view update", panel.Find(".operation-observation-facts").TextContent);
        Assert.Single(panel.FindAll(".operation-stale-check"));
        Assert.Contains("does not tell us whether Microsoft is still working", panel.Markup);
        Assert.Empty(panel.FindAll("[aria-live]"));
        fixture.AssertComplete();
    }

    [Fact]
    public void A_long_unchanged_saved_record_is_not_a_worker_health_or_completion_claim()
    {
        using var fixture = CoreUiData.Create();
        var operation = SavedOperation() with { UpdatedAtUtc = Now.AddMinutes(-3) };
        var panel = fixture.Render<ProtectionOperationMonitor>(parameters => parameters
            .Add(item => item.Operation, operation)
            .Add(item => item.HasRetainedOperation, true)
            .Add(item => item.Polling, true)
            .Add(item => item.LastCheckedAtUtc, Now));

        var explanation = panel.Find(".operation-unchanged").TextContent;
        Assert.Contains("No newer saved update was returned by the last check", explanation);
        Assert.Contains("A long wait alone does not tell us whether Microsoft is still working", explanation);
        Assert.Contains("do not submit it again", explanation);
        Assert.Single(panel.FindAll("[role='progressbar']"));
        Assert.Empty(panel.FindAll(".operation-stale-check"));
        Assert.DoesNotContain("stuck", panel.Markup, StringComparison.OrdinalIgnoreCase);

        panel.Render(parameters => parameters.Add(item => item.Operation, operation with { UpdatedAtUtc = Now }));
        Assert.Empty(panel.FindAll(".operation-unchanged"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Pending_steps_and_unknown_results_are_not_presented_as_active_provider_work()
    {
        using var fixture = CoreUiData.Create();
        var operation = SavedOperation("Pending") with
        {
            Steps = [
                Step("DiscoverProviderState", "Pending", 1),
                Step("ValidateReviewedIntent", "Pending", 0)
            ]
        };
        var panel = fixture.Render<ProtectionOperationMonitor>(parameters => parameters
            .Add(item => item.Operation, operation)
            .Add(item => item.HasRetainedOperation, true)
            .Add(item => item.Polling, true));

        Assert.Contains("Next recorded step (not started):", panel.Find(".operation-current-step").TextContent);
        Assert.Contains("Check your approved request", panel.Find(".operation-current-step").TextContent);
        Assert.Contains("not a live view of Microsoft activity", panel.Find("details").TextContent);
        Assert.Empty(panel.FindAll("details [role='progressbar']"));

        panel.Render(parameters => parameters
            .Add(item => item.Operation, (ProtectionAdminOperationDto?)null)
            .Add(item => item.Polling, false));
        Assert.Equal("unconfirmed", panel.Find(".operation-update-controls").GetAttribute("data-observation-state"));
        Assert.Empty(panel.FindAll(".operation-current-step, [role='progressbar']"));
        Assert.Contains("No successful status check is recorded", panel.Markup);
        Assert.Contains("Do not create another operation", panel.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public void Timestamps_are_explicit_utc_and_future_clock_skew_is_not_a_negative_elapsed_time()
    {
        using var fixture = CoreUiData.Create();
        var checkedAt = DateTime.SpecifyKind(Now.AddSeconds(-10), DateTimeKind.Unspecified);
        var operation = SavedOperation() with { CreatedAtUtc = Now.AddMinutes(1) };
        var panel = fixture.Render<ProtectionOperationMonitor>(parameters => parameters
            .Add(item => item.Operation, operation)
            .Add(item => item.HasRetainedOperation, true)
            .Add(item => item.LastCheckedAtUtc, checkedAt));

        Assert.Contains("Timestamp is ahead of this view's clock", panel.Find(".operation-observation-facts").TextContent);
        Assert.Contains("Less than a minute before this view update", panel.Markup);
        Assert.DoesNotContain("-1 minute", panel.Markup);
        Assert.All(panel.FindAll("time[datetime]"), time => Assert.EndsWith("Z", time.GetAttribute("datetime")));
        fixture.AssertComplete();
    }

    private static ProtectionAdminOperationDto SavedOperation(string status = "Running") => new(
        Id: CoreUiData.OperationId,
        WorkflowVersion: 1,
        Type: "ConnectPurviewTenant",
        Status: status,
        TenantId: AdminUiFixture.Tenant,
        ActorObjectId: AdminUiFixture.Actor.ToString("D"),
        TargetType: "PurviewTenantConnection",
        TargetIdentifier: AdminUiFixture.Tenant.ToString("D"),
        ReviewedPayloadHash: "sha256:" + new string('a', 64),
        IdempotencyKey: CoreUiData.OperationId,
        ExpectedRowVersion: CoreUiData.Version,
        RetryDisposition: "NotApplicable",
        AttemptCount: 1,
        MaximumAttempts: 3,
        NextAttemptAtUtc: null,
        CanRetry: false,
        RequiresManualIntervention: status == "RequiresManualIntervention",
        CorrelationId: CoreUiData.BlueprintId,
        ReadbackReferenceId: null,
        FailureCode: null,
        RequiredAction: null,
        Blockers: [],
        CreatedAtUtc: Now.AddMinutes(-6),
        StartedAtUtc: Now.AddMinutes(-5),
        CompletedAtUtc: status is "Completed" or "Succeeded" ? Now : null,
        UpdatedAtUtc: Now.AddSeconds(-10),
        Steps: [
            Step("ValidateReviewedIntent", "Completed", 0),
            Step("DiscoverProviderState", status is "Completed" or "Succeeded" ? "Completed" : "Running", 1)
        ],
        RowVersion: CoreUiData.Version);

    private static ProtectionAdminOperationStepDto Step(string name, string status, int order) => new(
        order == 0 ? CoreUiData.AgentId : CoreUiData.BlueprintId, order, name, status,
        status == "Pending" ? 0 : 1, "NotApplicable", null, false, false, null, null,
        status == "Pending" ? null : Now.AddMinutes(-5),
        status is "Completed" or "Succeeded" ? Now.AddMinutes(-4) : null);
}
