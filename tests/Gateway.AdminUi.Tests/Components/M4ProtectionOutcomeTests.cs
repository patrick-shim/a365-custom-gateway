using Bunit;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Components;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.AdminUi.Tests.Components;

public sealed partial class M4SettingsJourneyTests
{
    private static readonly Guid GuidedProfileId = Guid.Parse("99999999-9999-4999-8999-999999999998");

    [Fact]
    public void In_page_continuation_keeps_the_task_and_query_instead_of_using_the_application_base()
    {
        using var fixture = CoreUiData.Create();
        var navigation = fixture.Services.GetRequiredService<NavigationManager>();
        navigation.NavigateTo($"/settings/runtime?profile={GuidedProfileId:D}#previous-section");
        var guidance = new ProtectionJourneyGuidance("Choose examples", "Configured", "Saved", "Purpose", "Limits",
            "Next", "Choose test samples", $"#profile-runtime-{GuidedProfileId:D}");
        var panel = fixture.Render<ProtectionJourneyOutcome>(parameters => parameters.Add(item => item.Guidance, guidance));
        var href = Assert.IsType<string>(panel.Find("a").GetAttribute("href"));
        Assert.Equal(new Uri(navigation.Uri).GetLeftPart(UriPartial.Query) + guidance.ActionHref, href);
        fixture.AssertComplete();
    }

    [Fact]
    public void Matching_expired_inventory_offers_a_new_explicit_connection_review_without_refresh_loop()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection("Connected"), inventory: Inventory() with { ExpiresAtUtc = Now });
        var page = ConnectionPage(fixture);
        Assert.Contains("Classifier inventory expired", page.Find("#protection-journey-outcome").TextContent);
        Assert.Contains("Review connection refresh", page.Find("#protection-journey-outcome").TextContent);
        Assert.All(fixture.Script.Calls, method => Assert.StartsWith("Get", method));
        fixture.AssertComplete();
    }

    [Fact]
    public void Verified_connection_explains_outcome_purpose_limits_and_onward_action_without_an_operation()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection("Connected"), inventory: Inventory());
        var page = ConnectionPage(fixture);
        var outcome = page.Find("#protection-journey-outcome");
        Assert.Contains("Purview connection verified", outcome.TextContent);
        Assert.Contains("1 sensitive information type.", outcome.TextContent);
        Assert.Contains("What happened", outcome.TextContent);
        Assert.Contains("Why this matters", outcome.TextContent);
        Assert.Contains("What remains", outcome.TextContent);
        Assert.Contains("does not create a DLP policy", outcome.TextContent);
        Assert.NotNull(outcome.QuerySelector(".status-positive[aria-label='Status: Connection verified']"));
        Assert.Equal("/settings/policy", outcome.QuerySelector("a")!.GetAttribute("href"));
        Assert.DoesNotContain(nameof(IGatewayApiClient.StartPurviewTenantConnectionOperationAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Pending_connection_automatically_reads_completion_and_matching_inventory_without_repeating_work()
    {
        using var fixture = CoreUiData.Create();
        var page = ObservePendingConnection(fixture);
        Assert.Contains("Checking the Purview connection", page.Find("#protection-journey-outcome").TextContent);
        Assert.Single(page.FindAll(".page-header [role='progressbar']"));
        Assert.Contains("Automatic read-only updates are active", page.Markup);
        ExpectConnectionOutcome(fixture);
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromSeconds(3)));
        page.WaitForAssertion(() => Assert.Contains("Purview connection verified", page.Find("#protection-journey-outcome").TextContent));
        Assert.Contains("Automatic updates finished", page.Markup);
        Assert.Empty(page.FindAll(".page-header [role='progressbar']"));
        Assert.Empty(page.FindAll("details.protection-technical-details[open]"));
        Assert.Equal($"/settings/policy?operation={ReviewId:D}", page.Find("#protection-journey-outcome a").GetAttribute("href"));
        Assert.All(fixture.Script.Calls, method => Assert.StartsWith("Get", method));
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromSeconds(30)));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Cross_task_blueprint_failure_does_not_trap_completed_connection_recovery(bool manualRead)
    {
        using var fixture = CoreUiData.Create();
        var navigation = fixture.Services.GetRequiredService<NavigationManager>();
        navigation.NavigateTo($"/settings/policy?operation={ReviewId:D}");
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection("PendingVerification"))));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync),
            CoreUiData.Resource(new PurviewDlpProfileListResponse([])));
        fixture.Script.Expect<AgentIdentityBlueprintListResponse>(nameof(IGatewayApiClient.GetAgentIdentityBlueprintsAsync),
            _ => Task.FromException<AgentIdentityBlueprintListResponse>(new HttpRequestException("Synthetic blueprint read failure.")));
        ExpectPendingConnectionReadback(fixture);
        ExpectConfig(fixture);
        var page = fixture.Render<Settings>(parameters => parameters.Add(item => item.TaskName, "policy"));
        Assert.Contains("Resolved blueprints could not be loaded", page.Markup);

        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection("PendingVerification"))));
        ExpectPendingConnectionReadback(fixture);
        ExpectConfig(fixture);
        navigation.NavigateTo($"/settings/connection?operation={ReviewId:D}");
        page.Render(parameters => parameters.Add(item => item.TaskName, "connection"));
        page.WaitForAssertion(() =>
        {
            fixture.AssertComplete();
            Assert.Contains("Automatic read-only updates are active", page.Markup);
        });
        if (manualRead)
            await page.InvokeAsync(() => AdminUiFixture.ClickAsync(page, "Stop automatic updates"));
        ExpectConnectionOutcome(fixture);
        if (manualRead)
            await page.InvokeAsync(() => AdminUiFixture.ClickAsync(page, "Refresh operation"));
        else
            await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromSeconds(3)));
        page.WaitForAssertion(() => Assert.Contains("Purview connection verified",
            page.Find("#protection-journey-outcome").TextContent));
        Assert.False(ConnectionRefreshDisabled(page));
        Assert.Equal(1, fixture.Script.Calls.Count(method => method == nameof(IGatewayApiClient.GetAgentIdentityBlueprintsAsync)));
        Assert.All(fixture.Script.Calls, method => Assert.StartsWith("Get", method));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Failed_automatic_completion_is_not_presented_as_verified()
    {
        using var fixture = CoreUiData.Create();
        var page = ObservePendingConnection(fixture);
        ExpectConnectionOutcome(fixture, failed: true);
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromSeconds(3)));
        page.WaitForAssertion(() => Assert.Contains("needs attention", page.Find("#protection-journey-outcome").TextContent));
        Assert.DoesNotContain("Purview connection verified", page.Find("#protection-journey-outcome").TextContent);
        Assert.Contains("PURVIEW_CONNECTION_PROVIDER_UNVERIFIED", page.Markup);
        Assert.Empty(page.FindAll("#protection-journey-outcome a[href^='/settings/policy']"));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Automatic_read_error_pauses_then_recovers_the_same_operation()
    {
        using var fixture = CoreUiData.Create();
        var page = ObservePendingConnection(fixture);
        fixture.Script.Expect<GatewayApiResource<ProtectionAdminOperationResponse>>(
            nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            _ => Task.FromException<GatewayApiResource<ProtectionAdminOperationResponse>>(new HttpRequestException("Synthetic read failure.")));
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromSeconds(3)));
        page.WaitForAssertion(() => Assert.Contains("Automatic updates stopped after a read error", page.Markup));
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromSeconds(30)));
        ExpectConnectionOutcome(fixture);
        await AdminUiFixture.ClickAsync(page, "Check existing operation");
        Assert.Contains("Purview connection verified", page.Find("#protection-journey-outcome").TextContent);
        Assert.All(fixture.Script.Calls, method => Assert.StartsWith("Get", method));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Observation_deadline_bounds_noncooperating_operation_and_context_reads(bool contextRead)
    {
        using var fixture = CoreUiData.Create();
        var page = ObservePendingConnection(fixture);
        var lateOperation = new TaskCompletionSource<GatewayApiResource<ProtectionAdminOperationResponse>>(TaskCreationOptions.RunContinuationsAsynchronously);
        var lateContext = new TaskCompletionSource<GatewayApiResource<ProtectionCapabilitiesResponse>>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (contextRead)
        {
            ExpectObservedOperation(fixture, "Completed");
            fixture.Script.Expect<GatewayApiResource<ProtectionCapabilitiesResponse>>(
                nameof(IGatewayApiClient.GetProtectionCapabilitiesAsync), _ => lateContext.Task);
        }
        else
            fixture.Script.Expect<GatewayApiResource<ProtectionAdminOperationResponse>>(
                nameof(IGatewayApiClient.GetProtectionAdminOperationAsync), _ => lateOperation.Task);
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromSeconds(3)));
        page.WaitForAssertion(() => Assert.Equal(2, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.GetProtectionAdminOperationAsync))));
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromMinutes(5)));
        page.WaitForAssertion(() => Assert.Contains("Automatic updates paused after five minutes", page.Markup));
        var priorMarkup = page.Find("#protection-journey-outcome").TextContent;
        lateOperation.TrySetResult(CoreUiData.Resource(new ProtectionAdminOperationResponse(CompletedConnection())));
        lateContext.TrySetResult(CoreUiData.Resource(new ProtectionCapabilitiesResponse([])));
        await page.InvokeAsync(() => Task.CompletedTask);
        Assert.Equal(priorMarkup, page.Find("#protection-journey-outcome").TextContent);
        if (contextRead)
            Assert.Contains("current details need a refresh", priorMarkup);
        else
        {
            ExpectConnectionOutcome(fixture);
            await AdminUiFixture.ClickAsync(page, "Resume automatic updates");
            await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromSeconds(3)));
            page.WaitForAssertion(() => Assert.Contains("Purview connection verified", page.Find("#protection-journey-outcome").TextContent));
        }
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Disposed_or_replaced_route_does_not_publish_a_late_poll(bool dispose)
    {
        using var fixture = CoreUiData.Create();
        var page = ObservePendingConnection(fixture);
        var late = new TaskCompletionSource<GatewayApiResource<ProtectionAdminOperationResponse>>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Script.Expect<GatewayApiResource<ProtectionAdminOperationResponse>>(
            nameof(IGatewayApiClient.GetProtectionAdminOperationAsync), _ => late.Task);
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromSeconds(3)));
        page.WaitForAssertion(() => Assert.Equal(2, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.GetProtectionAdminOperationAsync))));
        if (dispose)
            await page.Instance.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(2));
        else
        {
            ExpectConnectionLoad(fixture);
            await page.InvokeAsync(() => fixture.Services.GetRequiredService<NavigationManager>().NavigateTo("/settings/connection"));
            page.WaitForAssertion(() => Assert.Contains("Connect Microsoft Purview", page.Find("#protection-journey-outcome").TextContent));
        }
        late.SetResult(CoreUiData.Resource(new ProtectionAdminOperationResponse(CompletedConnection())));
        await page.InvokeAsync(() => Task.CompletedTask);
        Assert.DoesNotContain("Purview connection verified", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Stop_updates_preserves_the_operation_and_resume_is_read_only()
    {
        using var fixture = CoreUiData.Create();
        var page = ObservePendingConnection(fixture);
        await AdminUiFixture.ClickAsync(page, "Stop automatic updates");
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromSeconds(30)));
        Assert.Contains("operation itself was not cancelled", page.Markup);
        ExpectConnectionOutcome(fixture);
        await AdminUiFixture.ClickAsync(page, "Resume automatic updates");
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromSeconds(3)));
        page.WaitForAssertion(() => Assert.Contains("Purview connection verified", page.Markup));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Wrong_tenant_poll_pauses_without_current_state_or_mutation_reads()
    {
        using var fixture = CoreUiData.Create();
        var page = ObservePendingConnection(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(CompletedConnection() with { TenantId = OtherActor })));
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromSeconds(3)));
        page.WaitForAssertion(() => Assert.Contains("did not match the retained operation and tenant", page.Markup));
        Assert.Contains("result is not confirmed", page.Find("#protection-journey-outcome").TextContent);
        Assert.Empty(page.FindAll("#protection-journey-outcome a[href^='/settings/policy']"));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Completed_connection_history_remains_completed_at_readiness_expiry()
    {
        using var fixture = CoreUiData.Create();
        var page = ObservePendingConnection(fixture);
        ExpectConnectionOutcome(fixture);
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromSeconds(3)));
        page.WaitForAssertion(() => Assert.Contains("Purview connection verified", page.Markup));
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromMinutes(10)));
        page.WaitForAssertion(() => Assert.Contains("Connection verified earlier; refresh required", page.Find("#protection-journey-outcome").TextContent));
        Assert.Equal("Completed", page.FindComponent<ProtectionOperationTimeline>().Instance.Operation.Status);
        Assert.Empty(page.FindAll("#protection-journey-outcome a[href^='/settings/policy']"));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("ApplyReviewedMutation", "does not create or change a DLP policy")]
    [InlineData("VerifyPropagation", "checked separately")]
    [InlineData("AttestTokenRoles", "checked separately")]
    [InlineData("ValidateRuntimeVerdict", "No runtime samples were tested")]
    public void Connection_skips_have_purpose_specific_explanations(string name, string explanation)
    {
        using var fixture = CoreUiData.Create();
        var step = new ProtectionAdminOperationStepDto(OtherActor, 1, name, "Skipped", 0, "NotApplicable",
            null, false, false, null, null, Now, Now);
        var panel = fixture.Render<ProtectionOperationTimeline>(parameters => parameters
            .Add(item => item.Operation, CompletedConnection() with { Steps = [step] }));
        Assert.Contains(explanation, panel.Markup);
        Assert.Contains("Skipped means not run", panel.Markup);
        Assert.Empty(panel.FindAll("details[open]"));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("Disabled", "Off", "Continue to agents")]
    [InlineData("SimulationWithTips", "Simulation", "Continue to agents")]
    [InlineData("SimulationWithoutTips", "Simulation", "Continue to agents")]
    [InlineData("Enforce", "Configured", "Continue to behavior tests")]
    public void Saved_modes_have_truthful_distinct_next_actions(string mode, string status, string next)
    {
        var profile = GuidedProfile(mode);
        var guidance = ProtectionJourneyGuidance.ForProfile(profile, Now, true, false,
            $"/settings/policy?profile={profile.Id:D}", $"/settings/runtime?profile={profile.Id:D}");
        Assert.Equal(status, guidance.Status);
        Assert.Equal(next, guidance.ActionLabel);
        Assert.Contains("does not change each agent", guidance.Purpose);
        if (mode == "Enforce")
            Assert.Contains(profile.Id.ToString("D"), guidance.ActionHref);
        else
            Assert.Equal("/agents", guidance.ActionHref);
    }

    [Fact]
    public async Task Runtime_readback_expiry_updates_the_parent_outcome_and_card_without_rebinding_samples()
    {
        using var fixture = CoreUiData.Create();
        var profile = GuidedProfile();
        profile = profile with { Readiness = profile.Readiness with { ValidUntilUtc = Now.AddMinutes(30) } };
        fixture.Services.GetRequiredService<NavigationManager>().NavigateTo($"/settings/runtime?profile={profile.Id:D}");
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection("Connected") with { ExpiresAtUtc = Now.AddHours(1) })));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync),
            CoreUiData.Resource(new PurviewDlpProfileListResponse([profile])));
        ExpectConfig(fixture);
        var page = fixture.Render<Settings>(parameters => parameters.Add(item => item.TaskName, "runtime"));
        var runtime = page.FindComponent<PurviewRuntimeTestPanel>();
        var readback = profile with
        {
            Readiness = profile.Readiness with { RuntimeVerdict = "Ready", IsReady = true, ValidUntilUtc = Now.AddMinutes(5) },
            RuntimeBehaviorSuiteHash = Hash, RuntimeBehaviorVerifiedUntilUtc = Now.AddMinutes(5)
        };
        await page.InvokeAsync(() => runtime.Instance.OnReadinessChanged.InvokeAsync(readback));
        Assert.Contains("Approved behavior is currently verified", page.Find("#protection-journey-outcome").TextContent);
        Assert.Single(page.FindAll(".profile-card-header [aria-label='Status: Enforcing']"));
        Assert.Equal(profile.RowVersion, runtime.Instance.ContextKey);
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromMinutes(5)));
        page.WaitForAssertion(() => Assert.Contains("Earlier verification has expired",
            page.Find("#protection-journey-outcome").TextContent));
        Assert.Empty(page.FindAll(".profile-card-header [aria-label='Status: Enforcing']"));
        Assert.Equal(profile.RowVersion, runtime.Instance.ContextKey);
        Assert.All(fixture.Script.Calls, method => Assert.StartsWith("Get", method));
        fixture.AssertComplete();
    }

    [Fact]
    public void Exact_profile_link_filters_the_page_and_keeps_the_behavior_handoff()
    {
        using var fixture = CoreUiData.Create();
        var intended = GuidedProfile();
        var unrelated = intended with { Id = OtherActor, DisplayName = "Unrelated shared policy" };
        var page = GuidedPolicyPage(fixture, GuidedProfileId.ToString("D"), [intended, unrelated]);
        Assert.Single(page.FindAll(".profile-card"));
        Assert.DoesNotContain("Unrelated shared policy", page.Markup);
        Assert.Equal($"/settings/runtime?profile={GuidedProfileId:D}", page.Find("#protection-journey-outcome a").GetAttribute("href"));
        Assert.Contains("behavior is not verified", page.Find("#protection-journey-outcome").TextContent);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Missing_or_duplicate_profile_identifiers_fail_through_the_normal_read_error(bool empty)
    {
        using var fixture = CoreUiData.Create();
        var profile = GuidedProfile();
        var page = GuidedPolicyPage(fixture, GuidedProfileId.ToString("D"),
            empty ? [profile with { Id = Guid.Empty }] : [profile, profile]);
        Assert.Contains("Shared policies could not be read", page.Find("#protection-journey-outcome").TextContent);
        Assert.Empty(page.FindAll(".profile-card"));
        Assert.Contains("Refresh current state", page.Find("#protection-journey-outcome").TextContent);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("not-a-profile", "profile link cannot be used")]
    [InlineData("00000000-0000-0000-0000-000000000000", "profile link cannot be used")]
    [InlineData("99999999-9999-4999-8999-999999999995", "selected profile is unavailable")]
    public void Invalid_or_missing_profile_never_selects_an_arbitrary_policy(string reference, string message)
    {
        using var fixture = CoreUiData.Create();
        var page = GuidedPolicyPage(fixture, reference, [GuidedProfile()]);
        Assert.Contains(message, page.Find("#protection-journey-outcome").TextContent);
        Assert.Empty(page.FindAll(".profile-card"));
        Assert.Equal("/settings/policy", page.Find("#protection-journey-outcome a").GetAttribute("href"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Off_is_complete_even_when_the_connection_has_expired()
    {
        using var fixture = CoreUiData.Create();
        var page = GuidedPolicyPage(fixture, GuidedProfileId.ToString("D"), [GuidedProfile("Disabled")],
            Connection("Connected") with { ExpiresAtUtc = Now });
        Assert.Contains("Policy saved as Off", page.Find("#protection-journey-outcome").TextContent);
        Assert.Equal("/agents", page.Find("#protection-journey-outcome a").GetAttribute("href"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Operator_can_continue_read_only_but_cannot_be_invited_to_run_samples()
    {
        using var fixture = CoreUiData.Create("Gateway.Operator");
        var page = GuidedPolicyPage(fixture, GuidedProfileId.ToString("D"), [GuidedProfile()], administrator: false);
        Assert.Contains("Administrator must", page.Find("#protection-journey-outcome").TextContent);
        Assert.Empty(page.FindAll("#protection-journey-outcome a[href^='/settings/runtime']"));
        fixture.AssertComplete();
    }

    private static IRenderedComponent<Settings> ObservePendingConnection(AdminUiFixture fixture)
    {
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection("PendingVerification"))));
        ExpectPendingConnectionReadback(fixture);
        ExpectConfig(fixture);
        return ConnectionPage(fixture, reopen: true);
    }

    private static ProtectionAdminOperationDto CompletedConnection() => PendingConnection() with
    {
        Status = "Completed", CompletedAtUtc = Now.AddSeconds(3), UpdatedAtUtc = Now.AddSeconds(3)
    };

    private static void ExpectObservedOperation(AdminUiFixture fixture, string status) =>
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(CompletedConnection() with
            {
                Status = status, FailureCode = status == "Failed" ? "PURVIEW_CONNECTION_PROVIDER_UNVERIFIED" : null
            })), arguments => Assert.Equal(ReviewId, Assert.IsType<Guid>(arguments[0])));

    private static void ExpectConnectionOutcome(AdminUiFixture fixture, bool failed = false)
    {
        var checkedAt = Clock(fixture).GetUtcNow().UtcDateTime.AddSeconds(3);
        ExpectObservedOperation(fixture, failed ? "Failed" : "Completed");
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection(failed ? "VerificationFailed" : "Connected") with
            {
                LastVerifiedAtUtc = failed ? null : checkedAt, ExpiresAtUtc = checkedAt.AddMinutes(10)
            })));
        if (!failed)
            fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync),
                CoreUiData.Resource(Inventory() with { ExpiresAtUtc = checkedAt.AddMinutes(5) }));
    }

    private static PurviewDlpProfileDto GuidedProfile(string mode = "Enforce") => new(
        GuidedProfileId, CoreUiData.BlueprintClientId, "Guided shared policy", SitId, "Synthetic classifier",
        mode == "Enforce" ? "Enforce" : "AuditOnly", ["UploadText"], [new("UploadText", "Block")],
        mode == "Enforce" ? "Ready" : mode == "Disabled" ? "Disabled" : "SimulationReady",
        new("Installed", "Ready", "Ready", "Ready", "NotChecked", false, [], Now, ValidUntilUtc: Now.AddMinutes(10)),
        "synthetic-policy", "synthetic-rule", Now, CoreUiData.Version, mode,
        [new(InventoryId, SitId, "Synthetic classifier", 1, -1, 75, 100)]);

    private static IRenderedComponent<Settings> GuidedPolicyPage(
        AdminUiFixture fixture, string? reference, IReadOnlyList<PurviewDlpProfileDto> profiles,
        PurviewTenantConnectionDto? connection = null, bool administrator = true,
        ProtectionAdminOperationDto? operation = null)
    {
        var query = reference is null ? "" : $"?profile={reference}";
        if (operation is not null)
            query += $"{(query.Length == 0 ? "?" : "&")}operation={operation.Id:D}";
        fixture.Services.GetRequiredService<NavigationManager>().NavigateTo($"/settings/policy{query}");
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(connection ?? Connection("Connected"))));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync), CoreUiData.Resource(new PurviewDlpProfileListResponse(profiles)));
        if (administrator)
            fixture.Script.Return(nameof(IGatewayApiClient.GetAgentIdentityBlueprintsAsync), CoreUiData.Blueprints);
        if (operation is not null)
            fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
                CoreUiData.Resource(new ProtectionAdminOperationResponse(operation)));
        if (operation is { Type: "ConnectPurviewTenant", Status: not "AwaitingAdministrator" })
            fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
                CoreUiData.Resource(new PurviewTenantConnectionResponse(connection ?? Connection("Connected"))));
        if (administrator)
            ExpectConfig(fixture);
        return fixture.Render<Settings>(parameters => parameters.Add(item => item.TaskName, "policy"));
    }
}
