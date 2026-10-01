using Bunit;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Time.Testing;
using Microsoft.JSInterop;

namespace Gateway.AdminUi.Tests.Components;

public sealed class M4PolicyConfigurationTests
{
    private static readonly Guid ConnectionId = Guid.Parse("88888888-8888-4888-8888-888888888881");
    private static readonly Guid InventoryId = Guid.Parse("88888888-8888-4888-8888-888888888882");
    private static readonly Guid SitId = Guid.Parse("88888888-8888-4888-8888-888888888883");
    private static readonly Guid ProfileId = Guid.Parse("88888888-8888-4888-8888-888888888884");
    private static readonly Guid OperationId = Guid.Parse("88888888-8888-4888-8888-888888888885");
    private static DateTime Now => CoreUiData.Now.UtcDateTime;

    [Fact]
    public async Task Review_normalizes_explicit_thresholds_and_cancel_sends_no_mutation()
    {
        using var fixture = CoreUiData.Create();
        var panel = await OpenDraft(fixture);
        var ticket = ExpectReview(fixture);
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");
        Assert.Contains("min count: 1; max count: -1", panel.Markup);
        Assert.Contains("ANY selected SIT (OR)", panel.Markup);
        var callback = panel.FindComponent<ConfirmPanel>().Instance.OnConfirm;
        await AdminUiFixture.ClickAsync(panel, "Cancel");
        await panel.InvokeAsync(() => callback.InvokeAsync());
        Assert.False(ticket.IsAvailable);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Expired_review_at_equality_does_not_exchange_authority()
    {
        using var fixture = CoreUiData.Create();
        var clock = (FakeTimeProvider)fixture.Services.GetRequiredService<TimeProvider>();
        var panel = await OpenDraft(fixture);
        ExpectReview(fixture);
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");
        var callback = panel.FindComponent<ConfirmPanel>().Instance.OnConfirm;
        clock.Advance(TimeSpan.FromMinutes(1));
        await panel.InvokeAsync(() => callback.InvokeAsync());
        Assert.Contains("review/connection authority expired", panel.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Policy_dispatch_waits_for_the_actual_browser_recovery_acknowledgment()
    {
        using var fixture = CoreUiData.Create();
        var retention = fixture.JSInterop.Setup<bool>("A365Gateway.retainProtectionRecovery", _ => true);
        var panel = await OpenDraft(fixture);
        var ticket = ExpectReview(fixture);
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");
        ExpectConfirmation(fixture, ticket);
        fixture.Script.Return(nameof(IGatewayApiClient.StartPurviewDlpProfileOperationAsync),
            CoreUiData.Resource(new ProtectionOperationAcceptedResponse(OperationId, "Pending", OperationId)));
        ExpectRefresh(fixture);
        var confirm = AdminUiFixture.ClickAsync(panel, "Confirm and queue shared policy");
        panel.WaitForAssertion(() => Assert.Contains(fixture.JSInterop.Invocations,
            invocation => invocation.Identifier == "A365Gateway.retainProtectionRecovery"));
        Assert.DoesNotContain(nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync), fixture.Script.Calls);
        retention.SetResult(true);
        await confirm;
        Assert.Equal(1, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.StartPurviewDlpProfileOperationAsync)));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    public async Task Failed_retention_does_not_confirm_or_queue_a_policy(int failure)
    {
        using var fixture = CoreUiData.Create();
        var retention = fixture.JSInterop.Setup<bool>("A365Gateway.retainProtectionRecovery", _ => true);
        if (failure == 0)
            retention.SetResult(false);
        else
            retention.SetException<Exception>(failure switch
            {
                1 => new JSDisconnectedException("Synthetic private diagnostic."),
                2 => new JSException("Synthetic private diagnostic."),
                _ => new TaskCanceledException("Synthetic private diagnostic.")
            });
        var panel = await OpenDraft(fixture);
        ExpectReview(fixture);
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");
        await AdminUiFixture.ClickAsync(panel, "Confirm and queue shared policy");
        Assert.Contains("No confirmation or protection change was sent", panel.Markup);
        Assert.Contains("Reload this page", panel.Markup);
        Assert.DoesNotContain("Synthetic private diagnostic", panel.Markup);
        Assert.DoesNotContain("The gateway could not complete the request", panel.Markup);
        Assert.DoesNotContain(nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Unknown_policy_result_is_read_back_without_a_second_start()
    {
        using var fixture = CoreUiData.Create();
        var panel = await OpenDraft(fixture);
        var ticket = ExpectReview(fixture);
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");
        ExpectConfirmation(fixture, ticket);
        fixture.Script.Expect<GatewayApiResource<ProtectionOperationAcceptedResponse>>(
            nameof(IGatewayApiClient.StartPurviewDlpProfileOperationAsync),
            _ => Task.FromException<GatewayApiResource<ProtectionOperationAcceptedResponse>>(
                new GatewayApiTransportException("Synthetic response loss.", "fixture", new HttpRequestException("Synthetic transport."))));
        await AdminUiFixture.ClickAsync(panel, "Confirm and queue shared policy");
        Assert.Contains("The shared policy result is not confirmed", panel.Markup);
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(Operation())),
            arguments => Assert.Equal(OperationId, Assert.IsType<Guid>(arguments[0])));
        ExpectRefresh(fixture);
        await AdminUiFixture.ClickAsync(panel, "Check existing operation");
        Assert.DoesNotContain("The shared policy result is not confirmed", panel.Markup);
        Assert.Equal(1, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.StartPurviewDlpProfileOperationAsync)));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Wrong_returned_blueprint_cannot_reach_confirmation()
    {
        using var fixture = CoreUiData.Create();
        var panel = await OpenDraft(fixture);
        var ticket = ExpectReview(fixture, blueprint: Guid.NewGuid());
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");
        Assert.False(ticket.IsAvailable);
        Assert.Empty(panel.FindComponents<ConfirmPanel>());
        Assert.Contains("does not match the exact blueprint", panel.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Changed_draft_discards_the_review_without_mutation()
    {
        using var fixture = CoreUiData.Create();
        var panel = await OpenDraft(fixture);
        var ticket = ExpectReview(fixture);
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");
        await panel.InvokeAsync(() => panel.Find("input[value='CreateButLeaveOff']")
            .ChangeAsync(new Microsoft.AspNetCore.Components.ChangeEventArgs { Value = true }));
        Assert.False(ticket.IsAvailable);
        Assert.Empty(panel.FindComponents<ConfirmPanel>());
        fixture.AssertComplete();
    }

    private static async Task<IRenderedComponent<AgentProtectionConfiguration>> OpenDraft(AdminUiFixture fixture)
    {
        ExpectRefresh(fixture);
        var panel = fixture.Render<AgentProtectionConfiguration>(parameters => parameters
            .Add(item => item.BlueprintApplicationId, CoreUiData.BlueprintClientId)
            .Add(item => item.BlueprintDisplayName, "Fixture blueprint")
            .Add(item => item.ContextKey, "policy-fixture")
            .Add(item => item.PolicyOnly, true).Add(item => item.StartOnConfirm, true)
            .Add(item => item.IsAdministrator, true));
        await panel.InvokeAsync(() => panel.Find($"[data-sit-id='{SitId:D}']")
            .ChangeAsync(new Microsoft.AspNetCore.Components.ChangeEventArgs { Value = true }));
        await panel.InvokeAsync(() => panel.Find("input[value='Enforce']")
            .ChangeAsync(new Microsoft.AspNetCore.Components.ChangeEventArgs { Value = true }));
        Assert.True(panel.FindComponent<AgentProtectionEditor>().Instance.CanContinue);
        return panel;
    }

    private static void ExpectRefresh(AdminUiFixture fixture)
    {
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionCapabilitiesAsync),
            CoreUiData.Resource(new ProtectionCapabilitiesResponse([
                new(ConnectionId, "Purview", "Installed", new(null, null, null, null, null, null, null, null, null), Now, null, CoreUiData.Version)
            ])));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync),
            CoreUiData.Resource(new PurviewDlpProfileListResponse([])));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(new(
                ConnectionId, AdminUiFixture.Tenant, "Connected", "InteractiveDelegatedAdministrator",
                null, null, InventoryId, Now, Now.AddMinutes(10), Now, null, CoreUiData.Version))));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync),
            CoreUiData.Resource(new PurviewSensitiveInformationTypeListResponse(InventoryId,
                AdminUiFixture.Tenant, Now, Now.AddMinutes(10), false, [new(SitId, "Synthetic classifier", "Fixture")])));
    }

    private static ProtectionOperationReviewTicket ExpectReview(AdminUiFixture fixture, Guid? blueprint = null)
    {
        var summary = new ProtectionOperationReviewSummaryDto(AdminUiFixture.Tenant, "CreateOrUpdateDlpProfile",
            "DlpProfile", ProfileId.ToString("D"), blueprint ?? CoreUiData.BlueprintClientId,
            SitId, "Synthetic classifier", "Enforce", ["UploadText", "DownloadText"], [new("UploadText", "Block")],
            "Individual", "Application", "Configuration does not prove enforcement.", PolicyMode: "Enforce",
            SensitiveInformationTypes: [new(InventoryId, SitId, "Synthetic classifier", 1, -1, 75, 100)]);
        var ticket = new ProtectionOperationReviewTicket(new(OperationId, "synthetic-policy-review",
            "sha256:" + new string('a', 64), Now.AddMinutes(1), summary), "*");
        fixture.Script.Return(nameof(IGatewayApiClient.ReviewPurviewDlpProfileOperationAsync), CoreUiData.Resource(ticket),
            arguments =>
            {
                var request = Assert.IsType<ReviewPurviewDlpProfileOperationRequest>(arguments[0]);
                Assert.Equal(CoreUiData.BlueprintClientId, request.BlueprintApplicationId);
                Assert.Single(request.SensitiveInformationTypes!);
                Assert.Equal("Enforce", request.PolicyMode);
            });
        return ticket;
    }

    private static void ExpectConfirmation(AdminUiFixture fixture, ProtectionOperationReviewTicket review) =>
        fixture.Script.Return(nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync),
            CoreUiData.Resource(new ProtectionOperationConfirmationTicket(
                new(OperationId, OperationId, "synthetic-policy-confirmation", Now.AddMinutes(1)), review.Review, "*")));

    private static ProtectionAdminOperationDto Operation() => new(OperationId, 1, "CreateOrUpdateDlpProfile",
        "Pending", AdminUiFixture.Tenant, AdminUiFixture.Actor.ToString("D"), "DlpProfile", ProfileId.ToString("D"),
        "sha256:" + new string('a', 64), OperationId, "*", "Retryable", 0, 3, null, false, false,
        OperationId, null, null, null, [], Now, null, null, Now, [], CoreUiData.Version);
}
