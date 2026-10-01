using Bunit;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Components;

namespace Gateway.AdminUi.Tests.Components;

public sealed partial class M4SettingsJourneyTests
{
    [Fact]
    public void Confirmation_shows_activity_only_while_the_visible_request_is_busy()
    {
        using var fixture = CoreUiData.Create();
        var panel = fixture.Render<ConfirmPanel>(parameters => parameters.Add(item => item.Visible, true));
        Assert.Empty(panel.FindAll("[role='progressbar']"));
        panel.Render(parameters => parameters.Add(item => item.Visible, true).Add(item => item.Busy, true));
        Assert.Equal("true", panel.Find("[role='alertdialog']").GetAttribute("aria-busy"));
        Assert.Equal("Waiting for the Gateway response", panel.Find("[role='progressbar']").GetAttribute("aria-label"));
        Assert.All(panel.FindAll("fluent-button"), button => Assert.True(button.HasAttribute("disabled")));
        panel.Render(parameters => parameters.Add(item => item.Visible, true).Add(item => item.Busy, false));
        Assert.Empty(panel.FindAll("[role='progressbar']"));
        Assert.Equal("false", panel.Find("[role='alertdialog']").GetAttribute("aria-busy"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Policy_setup_places_the_editor_before_the_optional_saved_details_library()
    {
        using var fixture = CoreUiData.Create();
        var page = GuidedPolicyPage(fixture, null, [GuidedProfile()]);
        var steps = page.Find("nav[aria-label='Purview setup steps']");
        Assert.Equal(["Connect tenant", "Set shared policy", "Test behavior", "Review agent choices"],
            steps.QuerySelectorAll("strong").Select(item => item.TextContent).ToArray());
        Assert.Equal("step", steps.QuerySelector("a[href='/settings/policy']")!.GetAttribute("aria-current"));
        Assert.DoesNotContain("settings/runtime", page.Find("nav[aria-label='Other protection tasks']").InnerHtml);
        Assert.True(page.Markup.IndexOf("shared-policy-editor", StringComparison.Ordinal) <
            page.Markup.IndexOf("saved-policy-library", StringComparison.Ordinal));
        Assert.False(page.Find("details.saved-policy-library").HasAttribute("open"));
        Assert.Contains("does not turn protection on", page.Find("#dlp-blueprint-help").TextContent);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Policy_prerequisite_refresh_gates_the_host_without_resetting_the_editor(bool editing)
    {
        using var fixture = CoreUiData.Create();
        var profiles = editing ? new[] { GuidedProfile() } : [];
        var page = GuidedPolicyPage(fixture, null, profiles);
        ExpectEditorPrerequisites(fixture, profiles);
        if (editing)
            await AdminUiFixture.ClickAsync(page, "Review settings");
        else
            await page.Find("#dlp-blueprint").ChangeAsync(new ChangeEventArgs { Value = "0" });
        var editor = page.FindComponent<AgentProtectionConfiguration>();
        var context = editor.Instance.ContextKey;
        var name = page.Find("input[id$='profile-name']");
        await name.InputAsync(new ChangeEventArgs { Value = "Unsaved policy name" });
        var inventory = new TaskCompletionSource<GatewayApiResource<PurviewSensitiveInformationTypeListResponse>>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        ExpectEditorPrerequisites(fixture, profiles, inventory.Task);
        var refresh = AdminUiFixture.ClickAsync(page, "Refresh prerequisites");
        page.WaitForAssertion(() =>
        {
            Assert.True(editor.Instance.IsReadingPrerequisites);
            Assert.True(page.Find("#dlp-blueprint").HasAttribute("disabled"));
            Assert.True(page.FindAll("fluent-button").Single(item => item.TextContent.Trim() == "Refresh").HasAttribute("disabled"));
            if (editing)
                Assert.True(page.FindAll("fluent-button").Single(item => item.TextContent.Trim() == "Cancel edit").HasAttribute("disabled"));
            Assert.NotEmpty(page.FindAll(".settings-header-activity [role='progressbar']"));
        });
        await AdminUiFixture.ClickAsync(page, "Refresh");
        if (editing)
            await AdminUiFixture.ClickAsync(page, "Cancel edit");
        else
            await page.Find("#dlp-blueprint").ChangeAsync(new ChangeEventArgs { Value = "" });
        Assert.Equal(context, editor.Instance.ContextKey);
        Assert.False(editor.Instance.Busy);
        inventory.SetResult(CoreUiData.Resource(Inventory()));
        await refresh;
        page.WaitForAssertion(() =>
        {
            Assert.False(editor.Instance.IsReadingPrerequisites);
            Assert.Equal(context, editor.Instance.ContextKey);
            Assert.Equal("Unsaved policy name", page.Find("input[id$='profile-name']").GetAttribute("value"));
            Assert.False(page.FindAll("fluent-button").Single(item => item.TextContent.Trim() == "Refresh").HasAttribute("disabled"));
            Assert.Empty(page.FindAll(".settings-header-activity"));
        });
        fixture.AssertComplete();
    }

    private static void ExpectEditorPrerequisites(
        AdminUiFixture fixture,
        IReadOnlyList<PurviewDlpProfileDto> profiles,
        Task<GatewayApiResource<PurviewSensitiveInformationTypeListResponse>>? inventory = null)
    {
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync),
            CoreUiData.Resource(new PurviewDlpProfileListResponse(profiles)));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection("Connected"))));
        fixture.Script.Expect(nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync),
            _ => inventory ?? Task.FromResult(CoreUiData.Resource(Inventory())));
    }

    [Theory]
    [InlineData("Completed", true)]
    [InlineData("Pending", false)]
    [InlineData("RequiresManualIntervention", false)]
    public void Earlier_connection_history_is_collapsed_only_after_completion(string status, bool collapsed)
    {
        using var fixture = CoreUiData.Create();
        var operation = status == "Completed" ? CompletedConnection() : PendingConnection() with { Status = status };
        var page = GuidedPolicyPage(fixture, null, [GuidedProfile()], operation: operation);
        if (collapsed)
        {
            var history = page.Find("details.previous-protection-operation");
            Assert.False(history.HasAttribute("open"));
            Assert.Contains("Completed earlier task: Connect tenant", history.TextContent);
            Assert.Contains("not completion of this step", history.TextContent);
        }
        else
        {
            Assert.Empty(page.FindAll("details.previous-protection-operation"));
        }
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("PURVIEW_INVENTORY_STALE", "Recheck the saved policy with current prerequisites")]
    [InlineData("PURVIEW_CONNECTION_EVIDENCE_STALE", "Recheck the saved policy with current prerequisites")]
    [InlineData("PURVIEW_SETTINGS_READ_TIMEOUT", "Microsoft policy read took too long")]
    [InlineData("PURVIEW_EXECUTOR_READ_UNAVAILABLE", "Microsoft policy state could not be confirmed")]
    public void Failed_policy_reads_explain_a_read_only_check_of_the_exact_saved_profile(string code, string title)
    {
        using var fixture = CoreUiData.Create();
        var profile = GuidedProfile() with
        {
            Status = "VerificationFailed",
            SensitiveInformationTypes = [new(OtherActor, SitId, "Synthetic classifier", 1, -1, 75, 100)]
        };
        var page = GuidedPolicyPage(fixture, GuidedProfileId.ToString("D"), [profile], operation: FailedPolicy(code));
        var outcome = page.Find("#protection-journey-outcome");
        Assert.Contains(title, outcome.TextContent);
        Assert.Contains("without creating them again", outcome.TextContent);
        Assert.Contains("does not prove that Microsoft objects are absent", outcome.TextContent);
        Assert.EndsWith($"#profile-{GuidedProfileId:D}", outcome.QuerySelector("a")!.GetAttribute("href"));
        Assert.True(page.Find("details.saved-policy-library").HasAttribute("open"));
        var check = page.FindAll("fluent-button").Single(item => item.TextContent == "Review existing policy check");
        Assert.False(check.HasAttribute("disabled"));
        Assert.All(fixture.Script.Calls, method => Assert.StartsWith("Get", method));
        fixture.AssertComplete();
    }

    [Fact]
    public void Failed_policy_read_with_expired_connection_leads_to_prerequisite_recovery_first()
    {
        using var fixture = CoreUiData.Create();
        var page = GuidedPolicyPage(fixture, GuidedProfileId.ToString("D"), [GuidedProfile()],
            Connection("Connected") with { ExpiresAtUtc = Now }, operation: FailedPolicy("PURVIEW_SETTINGS_READ_TIMEOUT"));
        var outcome = page.Find("#protection-journey-outcome");
        Assert.Contains("fresh prerequisite checks", outcome.TextContent);
        Assert.Contains("/settings/connection", outcome.QuerySelector("a")!.GetAttribute("href"));
        Assert.Contains("Refresh the tenant connection, then return here", page.Markup);
        Assert.True(page.FindAll("fluent-button").Single(item => item.TextContent == "Review existing policy check").HasAttribute("disabled"));
        fixture.AssertComplete();
    }

    [Fact]
    public void A_failed_operation_cannot_direct_reconciliation_to_a_different_requested_profile()
    {
        using var fixture = CoreUiData.Create();
        var other = GuidedProfile() with { Id = OtherActor };
        var page = GuidedPolicyPage(fixture, OtherActor.ToString("D"), [GuidedProfile(), other],
            operation: FailedPolicy("PURVIEW_INVENTORY_STALE"));
        var outcome = page.Find("#protection-journey-outcome");
        Assert.Contains("belongs to another shared policy", outcome.TextContent);
        var href = outcome.QuerySelector("a")!.GetAttribute("href");
        Assert.Contains($"profile={GuidedProfileId:D}", href);
        Assert.Contains($"operation={ReviewId:D}", href);
        Assert.DoesNotContain($"#profile-{OtherActor:D}", href);
        Assert.All(fixture.Script.Calls, method => Assert.StartsWith("Get", method));
        fixture.AssertComplete();
    }

    [Fact]
    public void Missing_legacy_thresholds_explain_why_an_existing_policy_check_is_unavailable()
    {
        using var fixture = CoreUiData.Create();
        var profile = GuidedProfile() with
        {
            SensitiveInformationTypes = [new(InventoryId, SitId, "Synthetic classifier", 1, -1, null, null)]
        };
        var page = GuidedPolicyPage(fixture, GuidedProfileId.ToString("D"), [profile]);
        Assert.Contains("explicitly complete the saved classifier thresholds", page.Markup);
        Assert.True(page.FindAll("fluent-button").Single(item => item.TextContent == "Review existing policy check").HasAttribute("disabled"));
        fixture.AssertComplete();
    }

    private static ProtectionAdminOperationDto FailedPolicy(string code) => PendingConnection() with
    {
        Type = "CreateOrUpdateDlpProfile", TargetType = "DlpProfile", TargetIdentifier = GuidedProfileId.ToString("D"),
        Status = "RequiresManualIntervention", FailureCode = code, RequiredAction = "Reconcile", ReadbackReferenceId = null
    };
}
