using System.Net;
using Bunit;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Components;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Time.Testing;
using Microsoft.FluentUI.AspNetCore.Components;

namespace Gateway.AdminUi.Tests.Components;

public sealed class OperationJourneyTests
{
    [Fact]
    public async Task Cancelled_confirmation_rejects_a_queued_parent_callback()
    {
        using var fixture = CoreUiData.Create();
        ExpectRead(fixture, CoreUiData.Operation());
        var page = Render(fixture);
        await AdminUiFixture.ClickAsync(page, "Complete Agent 365 registration");
        var callback = page.FindComponent<ConfirmPanel>().Instance.OnConfirm;
        await AdminUiFixture.ClickAsync(page, "Cancel");
        await page.InvokeAsync(() => callback.InvokeAsync());
        Assert.DoesNotContain(nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Route_change_invalidates_confirmation_before_waiting_for_old_poll_cancellation()
    {
        using var fixture = CoreUiData.Create();
        ExpectRead(fixture, CoreUiData.Operation());
        var page = Render(fixture);
        await AdminUiFixture.ClickAsync(page, "Complete Agent 365 registration");
        var callback = page.FindComponent<ConfirmPanel>().Instance.OnConfirm;
        var pending = new TaskCompletionSource<OperationStatusDto>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Script.Expect(nameof(IGatewayApiClient.GetOperationStatusAsync), _ => pending.Task);
        await AdminUiFixture.ClickAsync(page, "Check status");
        var nextId = Guid.NewGuid();
        ExpectRead(fixture, CoreUiData.Operation(id: nextId, available: false));
        page.Render(parameters => parameters.Add(item => item.OperationId, nextId));
        await page.InvokeAsync(() => callback.InvokeAsync());
        Assert.DoesNotContain(nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync), fixture.Script.Calls);
        pending.SetResult(CoreUiData.Operation());
        page.WaitForAssertion(() => Assert.Contains(nextId.ToString("D"), page.Markup));
        Assert.DoesNotContain(page.FindComponents<ConfirmPanel>(), item => item.Instance.Visible);
        fixture.AssertComplete();
    }

    [Fact]
    public void Prerendered_operation_never_consumes_a_saved_handoff_or_starts_Registry_completion()
    {
        using var fixture = CoreUiData.Create();
        fixture.Rendering = new RendererInfo("Static", isInteractive: false);
        var handoff = fixture.Services.GetRequiredService<RegistrationHandoffState>();
        handoff.RecordSavedCredential(CoreUiData.OperationId, CoreUiData.AgentId);
        ExpectRead(fixture, CoreUiData.Operation());
        var page = Render(fixture);
        Assert.DoesNotContain(nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync), fixture.Script.Calls);
        Assert.True(handoff.TryConsumeAutomaticCompletion(CoreUiData.OperationId, CoreUiData.AgentId));
        Assert.Equal("true", page.Find(".page-header").GetAttribute("aria-busy"));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("Gateway.Administrator", false)]
    [InlineData("Gateway.Operator", true)]
    public void Direct_or_operator_entry_does_not_automatically_complete_Registry(string role, bool savedPermit)
    {
        using var fixture = CoreUiData.Create(role);
        if (savedPermit) fixture.Services.GetRequiredService<RegistrationHandoffState>()
            .RecordSavedCredential(CoreUiData.OperationId, CoreUiData.AgentId);
        ExpectRead(fixture, CoreUiData.Operation());
        var page = Render(fixture);
        page.WaitForAssertion(() => Assert.Contains("Core fixture agent", page.Find("h1").TextContent));
        Assert.DoesNotContain(nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync), fixture.Script.Calls);
        Assert.Equal(role == "Gateway.Administrator", page.FindComponents<FluentButton>()
            .Any(item => item.Find("fluent-button").TextContent.Trim() == "Complete Agent 365 registration"));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Manual_completion_confirms_the_exact_registration_and_reads_remaining_progress()
    {
        using var fixture = CoreUiData.Create();
        ExpectRead(fixture, CoreUiData.Operation());
        var page = Render(fixture);
        await AdminUiFixture.ClickAsync(page, "Complete Agent 365 registration");
        Assert.Contains(CoreUiData.ExternalId, page.FindComponent<ConfirmPanel>().Markup);
        Assert.DoesNotContain(nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync), fixture.Script.Calls);
        fixture.Script.Return(nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync), Completion());
        ExpectRead(fixture, CoreUiData.Operation(status: "Completed", available: false));
        await AdminUiFixture.ClickAsync(page, "Complete registration");
        page.WaitForAssertion(() => Assert.Contains("This setup operation completed.", page.Markup));
        Assert.Single(fixture.Script.Calls, item => item == nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync));
        Assert.Contains("acceptance alone does not mean", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public void Permitted_automatic_completion_consumes_the_saved_key_handoff_once()
    {
        using var fixture = CoreUiData.Create();
        fixture.Services.GetRequiredService<RegistrationHandoffState>()
            .RecordSavedCredential(CoreUiData.OperationId, CoreUiData.AgentId);
        ExpectRead(fixture, CoreUiData.Operation());
        fixture.Script.Return(nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync), Completion());
        ExpectRead(fixture, CoreUiData.Operation(status: "Completed", available: false));
        var page = Render(fixture);
        page.WaitForAssertion(() => Assert.Contains("This setup operation completed.", page.Markup));
        Assert.Single(fixture.Script.Calls, item => item == nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync));
        Assert.False(fixture.Services.GetRequiredService<RegistrationHandoffState>()
            .TryConsumeAutomaticCompletion(CoreUiData.OperationId, CoreUiData.AgentId));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, true)]
    public void Closed_admission_and_legacy_operations_never_execute_a_saved_permit(bool legacy, bool available)
    {
        using var fixture = CoreUiData.Create();
        fixture.Services.GetRequiredService<RegistrationHandoffState>()
            .RecordSavedCredential(CoreUiData.OperationId, CoreUiData.AgentId);
        ExpectRead(fixture, CoreUiData.Operation(legacy: legacy, available: available));
        var page = Render(fixture);
        page.WaitForAssertion(() => Assert.Contains("Core fixture agent", page.Markup));
        Assert.DoesNotContain(nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Consent_and_claims_challenges_keep_the_same_operation_and_do_not_retry_automatically(bool claims)
    {
        using var fixture = CoreUiData.Create();
        ExpectRead(fixture, CoreUiData.Operation());
        var page = Render(fixture);
        await AdminUiFixture.ClickAsync(page, "Complete Agent 365 registration");
        fixture.Script.Expect<CompleteAgent365RegistrationResponse>(nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync), _ =>
            Task.FromException<CompleteAgent365RegistrationResponse>(CoreUiData.Error(HttpStatusCode.Unauthorized, interaction: true, claims: claims)));
        await AdminUiFixture.ClickAsync(page, "Complete registration");
        Assert.Contains(claims ? "Conditional Access interaction required" : "Administrator consent required", page.Markup);
        Assert.Contains(Uri.EscapeDataString($"/operations/{CoreUiData.OperationId:D}"), page.Markup);
        Assert.Single(fixture.Script.Calls, item => item == nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Unknown_completion_offers_only_recorded_status_readback_not_another_action()
    {
        using var fixture = CoreUiData.Create();
        ExpectRead(fixture, CoreUiData.Operation());
        var page = Render(fixture);
        await AdminUiFixture.ClickAsync(page, "Complete Agent 365 registration");
        fixture.Script.Expect<CompleteAgent365RegistrationResponse>(nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync), _ =>
            Task.FromException<CompleteAgent365RegistrationResponse>(new GatewayApiTransportException(
                "Interrupted fixture completion.", "fixture-correlation", new HttpRequestException("Synthetic timeout."))));
        await AdminUiFixture.ClickAsync(page, "Complete registration");
        Assert.Contains("The Registry result is not confirmed", page.Markup);
        var action = page.FindComponents<FluentButton>()
            .Single(item => item.Find("fluent-button").TextContent.Trim() == "Complete Agent 365 registration");
        Assert.True(action.Instance.Disabled);
        ExpectRead(fixture, CoreUiData.Operation());
        await AdminUiFixture.ClickAsync(page, "Check existing operation");
        Assert.Contains("The Registry result is not confirmed", page.Markup);
        Assert.Single(fixture.Script.Calls, item => item == nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Wrong_completion_binding_is_unknown_not_success()
    {
        using var fixture = CoreUiData.Create();
        ExpectRead(fixture, CoreUiData.Operation());
        var page = Render(fixture);
        await AdminUiFixture.ClickAsync(page, "Complete Agent 365 registration");
        fixture.Script.Return(nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync),
            Completion() with { AgentId = Guid.NewGuid() });
        await AdminUiFixture.ClickAsync(page, "Complete registration");
        Assert.Contains("The Registry result is not confirmed", page.Markup);
        Assert.DoesNotContain("This setup operation completed.", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Polling_stops_at_the_exact_five_minute_deadline_without_claiming_the_operation_failed()
    {
        using var fixture = CoreUiData.Create();
        var clock = Assert.IsType<FakeTimeProvider>(fixture.Services.GetRequiredService<TimeProvider>());
        var running = CoreUiData.Operation(status: "Running", available: false, polling: true);
        ExpectRead(fixture, running);
        var page = Render(fixture);
        page.WaitForAssertion(() => Assert.Contains("Automatic updates are active", page.Markup));
        fixture.Script.Return(nameof(IGatewayApiClient.GetOperationStatusAsync), running);
        await page.InvokeAsync(() => clock.Advance(TimeSpan.FromSeconds(299)));
        page.WaitForAssertion(() => Assert.Equal(2,
            fixture.Script.Calls.Count(item => item == nameof(IGatewayApiClient.GetOperationStatusAsync))));
        Assert.DoesNotContain("five-minute polling limit", page.Markup);
        await page.InvokeAsync(() => clock.Advance(TimeSpan.FromSeconds(1)));
        page.WaitForAssertion(() => Assert.Contains("five-minute polling limit", page.Markup));
        Assert.Contains("may still be running", page.Markup);
        Assert.DoesNotContain(nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Failed_refresh_marks_old_progress_stale_and_disables_completion()
    {
        using var fixture = CoreUiData.Create();
        ExpectRead(fixture, CoreUiData.Operation());
        var page = Render(fixture);
        fixture.Script.Expect<OperationStatusDto>(nameof(IGatewayApiClient.GetOperationStatusAsync), _ =>
            Task.FromException<OperationStatusDto>(CoreUiData.Error(HttpStatusCode.ServiceUnavailable)));
        await AdminUiFixture.ClickAsync(page, "Check status");
        page.WaitForAssertion(() => Assert.Contains("last known operation state", page.Markup));
        Assert.True(page.FindComponents<FluentButton>()
            .Single(item => item.Find("fluent-button").TextContent.Trim() == "Complete Agent 365 registration").Instance.Disabled);
        fixture.AssertComplete();
    }

    private static CompleteAgent365RegistrationResponse Completion() =>
        new(CoreUiData.OperationId, CoreUiData.AgentId, "99999999-9999-4999-8999-999999999999", "Running");

    private static void ExpectRead(AdminUiFixture fixture, OperationStatusDto operation)
    {
        fixture.Script.Return(nameof(IGatewayApiClient.GetOperationStatusAsync), operation);
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentAsync), CoreUiData.Resource(CoreUiData.Agent()));
    }

    private static IRenderedComponent<OperationStatus> Render(AdminUiFixture fixture) =>
        fixture.Render<OperationStatus>(parameters => parameters.Add(item => item.OperationId, CoreUiData.OperationId));
}
