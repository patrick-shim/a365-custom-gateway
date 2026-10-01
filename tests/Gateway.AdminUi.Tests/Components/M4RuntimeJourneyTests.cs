using Bunit;
using Gateway.AdminUi.Components.Pages;
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

public sealed class M4RuntimeJourneyTests
{
    private static readonly Guid ProfileId = Guid.Parse("77777777-7777-4777-8777-777777777771");
    private static readonly Guid OperationId = Guid.Parse("77777777-7777-4777-8777-777777777772");
    private static readonly Guid InventoryId = Guid.Parse("77777777-7777-4777-8777-777777777773");
    private static readonly Guid SitId = Guid.Parse("77777777-7777-4777-8777-777777777774");
    private static readonly Guid PositiveId = Guid.Parse("77777777-7777-4777-8777-777777777775");
    private static readonly Guid NegativeId = Guid.Parse("77777777-7777-4777-8777-777777777776");
    private static string Hash(char value) => "sha256:" + new string(value, 64);

    [Fact]
    public async Task Prerender_never_collects_or_reviews_samples()
    {
        using var fixture = CoreUiData.Create();
        fixture.Rendering = new("Static", false);
        var panel = Panel(fixture);
        await AdminUiFixture.ClickAsync(panel, "Verify shared profile");
        Assert.Empty(panel.FindAll("textarea"));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Role_flag_cannot_override_the_authenticated_principal()
    {
        using var fixture = CoreUiData.Create("Gateway.Operator");
        var panel = Panel(fixture);
        await AdminUiFixture.ClickAsync(panel, "Verify shared profile");
        Assert.Empty(panel.FindAll("textarea"));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Late_browser_initialization_is_erased_after_close_or_disposal(bool dispose)
    {
        using var fixture = CoreUiData.Create();
        var module = new ScriptedJsObject();
        var browser = new ScriptedJsObject();
        var created = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);
        module.ExpectAsync("createSession", _ => created.Task);
        fixture.RoutePrivateSampleModule(module);
        ExpectOpen(fixture);
        var panel = Panel(fixture);
        var opening = AdminUiFixture.ClickAsync(panel, "Verify shared profile");
        panel.WaitForAssertion(() => Assert.Contains("createSession", module.Invocations));
        await panel.InvokeAsync(() => panel.Find("input[id$='-synthetic']").Change(true));
        Assert.Equal(1, module.Invocations.Count(value => value == "createSession"));
        Task? disposing = null;
        if (dispose)
            disposing = panel.Instance.DisposeAsync().AsTask();
        else
            await AdminUiFixture.ClickAsync(panel, "Close and erase samples");
        created.SetResult(browser);
        await opening;
        if (disposing is not null)
            await disposing;
        panel.WaitForAssertion(() => Assert.Contains("dispose", browser.Invocations));
        module.AssertComplete();
        browser.AssertComplete();
        fixture.AssertComplete();
    }

    [Fact]
    public async Task A_changed_profile_erases_its_late_sample_session_before_reopening()
    {
        using var fixture = CoreUiData.Create();
        var module = new ScriptedJsObject();
        var browser = new ScriptedJsObject();
        var created = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);
        module.ExpectAsync("createSession", _ => created.Task);
        fixture.RoutePrivateSampleModule(module);
        ExpectOpen(fixture);
        var panel = Panel(fixture);
        var opening = AdminUiFixture.ClickAsync(panel, "Verify shared profile");
        panel.WaitForAssertion(() => Assert.Contains("createSession", module.Invocations));
        var nextProfile = Profile() with { Id = Guid.NewGuid() };
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync),
            CoreUiData.Resource(new PurviewDlpProfileListResponse([nextProfile])));
        panel.Render(parameters => parameters.Add(item => item.ProfileId, nextProfile.Id)
            .Add(item => item.ContextKey, "another-profile"));
        created.SetResult(browser);
        await opening;
        panel.WaitForAssertion(() => Assert.Contains("dispose", browser.Invocations));
        Assert.Empty(panel.FindAll("textarea"));
        Assert.Equal(1, module.Invocations.Count(value => value == "createSession"));
        module.AssertComplete();
        browser.AssertComplete();
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("generation")]
    [InlineData("missing-type")]
    [InlineData("duplicate-type")]
    public async Task Stale_or_ambiguous_inventory_blocks_sample_collection(string fault)
    {
        using var fixture = CoreUiData.Create();
        var inventory = Inventory();
        inventory = fault switch
        {
            "generation" => inventory with { GenerationId = Guid.NewGuid() },
            "missing-type" => inventory with { Items = [] },
            _ => inventory with { Items = [new(SitId, "Synthetic classifier", "Fixture"), new(SitId, "Synthetic classifier", "Fixture")] }
        };
        ExpectOpen(fixture, inventory);
        var panel = Panel(fixture);
        await AdminUiFixture.ClickAsync(panel, "Verify shared profile");
        Assert.Empty(panel.FindAll("textarea"));
        Assert.Contains("refresh its inventory before testing", panel.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Expiry_equality_prevents_execution_and_erases_the_private_session()
    {
        using var fixture = CoreUiData.Create();
        var (panel, module, browser) = await Reviewed(fixture);
        var clock = Clock(fixture);
        await panel.InvokeAsync(() => panel.Find("input[id$='-target']").Change(true));
        var callback = panel.FindComponent<ConfirmPanel>().Instance.OnConfirm;
        clock.Advance(TimeSpan.FromMinutes(1));
        await panel.InvokeAsync(() => callback.InvokeAsync());
        Assert.Contains("review or inventory expired", panel.Markup);
        Assert.DoesNotContain("execute", browser.Invocations);
        Assert.Contains("clear", browser.Invocations);
        module.AssertComplete();
        browser.AssertComplete();
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Transport_loss_is_not_a_verdict_and_never_reexecutes()
    {
        using var fixture = CoreUiData.Create();
        var (panel, module, browser) = await Reviewed(fixture);
        browser.Expect("execute", new RuntimeBrowserExecutionResult(null, true, OperationId));
        await panel.InvokeAsync(() => panel.Find("input[id$='-target']").Change(true));
        await AdminUiFixture.ClickAsync(panel, "Confirm and send approved batch");
        Assert.Contains("transport outcome is unknown", panel.Markup);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewRuntimeTestAsync), Report());
        ExpectProfiles(fixture);
        await AdminUiFixture.ClickAsync(panel, "Recover safe report");
        Assert.Equal(1, browser.Invocations.Count(value => value == "execute"));
        Assert.NotEmpty(panel.FindAll("[aria-label='Saved runtime test report']"));
        Assert.Contains("Historical runtime test receipt", panel.Markup);
        module.AssertComplete();
        browser.AssertComplete();
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Resetting_in_flight_execution_preserves_unknown_outcome_and_blocks_new_review()
    {
        using var fixture = CoreUiData.Create();
        var (panel, module, browser) = await Reviewed(fixture);
        browser.ExpectAsync("execute", async cancellation =>
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellation);
            return null;
        });
        await panel.InvokeAsync(() => panel.Find("input[id$='-target']").Change(true));
        var execute = AdminUiFixture.ClickAsync(panel, "Confirm and send approved batch");
        panel.WaitForAssertion(() => Assert.Contains("execute", browser.Invocations));
        await AdminUiFixture.ClickAsync(panel, "Reset and erase samples");
        await execute;
        Assert.Contains("transport outcome is unknown", panel.Markup);
        Assert.Equal(1, browser.Invocations.Count(value => value == "execute"));
        module.AssertComplete();
        browser.AssertComplete();
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Interop_deadline_becomes_unknown_without_retrying()
    {
        using var fixture = CoreUiData.Create();
        var (panel, module, browser) = await Reviewed(fixture);
        var clock = Clock(fixture);
        browser.ExpectAsync("execute", async cancellation =>
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellation);
            return null;
        });
        await panel.InvokeAsync(() => panel.Find("input[id$='-target']").Change(true));
        var execute = AdminUiFixture.ClickAsync(panel, "Confirm and send approved batch");
        panel.WaitForAssertion(() => Assert.Contains("execute", browser.Invocations));
        clock.Advance(TimeSpan.FromSeconds(RuntimeTestUiProtocol.InteropExecutionTimeoutSeconds - 1));
        Assert.False(execute.IsCompleted);
        clock.Advance(TimeSpan.FromSeconds(1));
        await execute;
        Assert.Contains("transport outcome is unknown", panel.Markup);
        Assert.Equal(1, browser.Invocations.Count(value => value == "execute"));
        module.AssertComplete();
        browser.AssertComplete();
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Stale_status_route_response_cannot_replace_the_new_report()
    {
        using var fixture = CoreUiData.Create();
        var oldId = Guid.NewGuid();
        var pending = new TaskCompletionSource<PurviewRuntimeTestResultResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Script.Expect<PurviewRuntimeTestResultResponse>(nameof(IGatewayApiClient.GetPurviewRuntimeTestAsync), _ => pending.Task);
        var page = fixture.Render<PurviewRuntimeTestStatus>(parameters => parameters.Add(item => item.OperationId, oldId));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewRuntimeTestAsync), Report());
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync), CoreUiData.Resource(new ProtectionAdminOperationResponse(Operation())));
        ExpectProfiles(fixture);
        page.Render(parameters => parameters.Add(item => item.OperationId, OperationId));
        pending.SetResult(Report(oldId));
        page.WaitForAssertion(() =>
        {
            Assert.Contains(OperationId.ToString("D"), page.Markup);
            Assert.DoesNotContain(oldId.ToString("D"), page.Markup);
        });
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("flag")]
    [InlineData("status")]
    [InlineData("negative")]
    [InlineData("scope")]
    [InlineData("metadata")]
    public void Inconsistent_reports_cannot_claim_verified_behavior(string fault)
    {
        using var fixture = CoreUiData.Create();
        var cases = Cases();
        cases = fault switch
        {
            "negative" => [cases[0]],
            "scope" => [cases[0] with { ActionSource = "ProtectionScope" }, cases[1]],
            "metadata" => [cases[0] with { ContentProcessing = "MetadataOnly" }, cases[1]],
            _ => cases
        };
        var report = new PurviewRuntimeTestResultResponse(OperationId, fault == "status" ? "Running" : "Completed",
            "EnforcementBehaviorVerified", "Enforce", Hash('a'), Hash('b'), CoreUiData.Version,
            CoreUiData.Now, cases, [], fault != "flag", null);
        Assert.False(RuntimeTestUiProtocol.IsSafeReport(report, OperationId));
        var panel = fixture.Render<PurviewRuntimeTestReport>(parameters => parameters.Add(item => item.Report, report));
        Assert.Contains("could not be verified", panel.Markup);
        Assert.Empty(panel.FindAll("[aria-label='Saved runtime test report']"));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Saved_runtime_result_explains_verified_scope_and_keeps_exact_profile_context_at_expiry()
    {
        using var fixture = CoreUiData.Create();
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewRuntimeTestAsync), Report());
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(Operation())));
        ExpectProfiles(fixture);
        var page = fixture.Render<PurviewRuntimeTestStatus>(parameters => parameters.Add(item => item.OperationId, OperationId));
        var outcome = page.Find($".journey-outcome");
        Assert.Contains("Approved behavior is currently verified", outcome.TextContent);
        Assert.Contains("does not identify which classifier matched", outcome.TextContent);
        Assert.Equal("/agents", outcome.QuerySelector("a")!.GetAttribute("href"));
        Assert.NotEmpty(page.FindAll($"a[href='/settings/runtime?profile={ProfileId:D}']"));
        await page.InvokeAsync(() => Clock(fixture).Advance(TimeSpan.FromMinutes(10)));
        page.WaitForAssertion(() => Assert.Contains("Earlier verification has expired", page.Find(".journey-outcome").TextContent));
        Assert.NotEmpty(page.FindAll($"a[href='/settings/connection?profile={ProfileId:D}']"));
        Assert.Contains("Historical runtime test receipt", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public void Saved_runtime_result_does_not_claim_readiness_from_another_tenant()
    {
        using var fixture = CoreUiData.Create();
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewRuntimeTestAsync), Report());
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(Operation() with { TenantId = ProfileId })));
        var page = fixture.Render<PurviewRuntimeTestStatus>(parameters => parameters.Add(item => item.OperationId, OperationId));
        Assert.Contains("current readiness is unavailable", page.Find(".journey-outcome").TextContent);
        Assert.DoesNotContain("Approved behavior is currently verified", page.Markup);
        Assert.Empty(page.FindAll("a[href='/agents']"));
        fixture.AssertComplete();
    }

    [Fact]
    public void A_changed_profile_is_not_certified_by_the_old_runtime_receipt()
    {
        using var fixture = CoreUiData.Create();
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewRuntimeTestAsync), Report());
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(Operation())));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync),
            CoreUiData.Resource(new PurviewDlpProfileListResponse([Profile() with { RowVersion = "AAAAAAAAAAI=" }])));
        var page = fixture.Render<PurviewRuntimeTestStatus>(parameters => parameters.Add(item => item.OperationId, OperationId));
        Assert.Contains("Earlier results are not applied to a changed or expired binding", page.Find(".journey-outcome").TextContent);
        Assert.DoesNotContain("Approved behavior is currently verified", page.Markup);
        Assert.NotEmpty(page.FindAll($"a[href='/settings/policy?profile={ProfileId:D}']"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Runtime_outcome_rejects_an_inconsistent_receipt_even_when_the_profile_is_ready()
    {
        using var fixture = CoreUiData.Create();
        var report = new PurviewRuntimeTestResultResponse(OperationId, "Running", "EnforcementBehaviorVerified",
            "Enforce", Hash('a'), Hash('b'), CoreUiData.Version, CoreUiData.Now, Cases(), [], true, null);
        var panel = fixture.Render<ProtectionRuntimeOutcome>(parameters => parameters
            .Add(item => item.Report, report).Add(item => item.CurrentProfile, Profile()));
        Assert.Contains("could not be verified", panel.Markup);
        Assert.Empty(panel.FindAll(".journey-outcome"));
        fixture.AssertComplete();
    }

    private static FakeTimeProvider Clock(AdminUiFixture fixture) => (FakeTimeProvider)fixture.Services.GetRequiredService<TimeProvider>();
    private static IRenderedComponent<PurviewRuntimeTestPanel> Panel(AdminUiFixture fixture) => fixture.Render<PurviewRuntimeTestPanel>(
        parameters => parameters.Add(item => item.ProfileId, ProfileId).Add(item => item.IsAdministrator, true)
            .Add(item => item.ContextKey, "runtime-fixture").Add(item => item.ExpectedProfileRowVersion, CoreUiData.Version));
    private static PurviewSensitiveInformationTypeSelectionDto[] Types() => [new(InventoryId, SitId, "Synthetic classifier", 1, -1, 75, 100)];
    private static PurviewRuntimeTestSuiteManifestDto Suite() => new(new string('a', 64), [new(PositiveId, SitId, Hash('1'), 32)], new(NegativeId, null, Hash('2'), 20));
    private static PurviewDlpProfileDto Profile() => new(ProfileId, CoreUiData.BlueprintClientId, "Synthetic shared policy",
        SitId, "Synthetic classifier", "Enforce", ["UploadText"], [new("UploadText", "Block")], "Ready",
        new("Installed", "Ready", "Ready", "Ready", "Ready", true, [], CoreUiData.Now.UtcDateTime,
            ValidUntilUtc: CoreUiData.Now.AddMinutes(10).UtcDateTime),
        "synthetic-policy", "synthetic-rule", CoreUiData.Now.UtcDateTime, CoreUiData.Version, "Enforce", Types(),
        Hash('a'), CoreUiData.Now.AddMinutes(10).UtcDateTime);
    private static PurviewSensitiveInformationTypeListResponse Inventory() => new(InventoryId, AdminUiFixture.Tenant,
        CoreUiData.Now.UtcDateTime, CoreUiData.Now.AddMinutes(10).UtcDateTime, false, [new(SitId, "Synthetic classifier", "Fixture")]);
    private static void ExpectProfiles(AdminUiFixture fixture) => fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync),
        CoreUiData.Resource(new PurviewDlpProfileListResponse([Profile()])));
    private static void ExpectOpen(AdminUiFixture fixture, PurviewSensitiveInformationTypeListResponse? inventory = null)
    {
        ExpectProfiles(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync), CoreUiData.Resource(inventory ?? Inventory()));
    }
    private static async Task<(IRenderedComponent<PurviewRuntimeTestPanel> Panel, ScriptedJsObject Module, ScriptedJsObject Browser)> Reviewed(AdminUiFixture fixture)
    {
        var module = new ScriptedJsObject();
        var browser = new ScriptedJsObject();
        module.Expect("createSession", browser);
        browser.Expect("prepare", new RuntimePreparedManifest(Suite(), [new[] { PositiveId }]));
        fixture.RoutePrivateSampleModule(module);
        ExpectOpen(fixture);
        var request = new ReviewPurviewDlpRuntimeTestRequest(ProfileId, CoreUiData.Version, InventoryId, Suite(), [PositiveId], true);
        var metadata = new PurviewRuntimeTestReviewDto(AdminUiFixture.Tenant, ProfileId, CoreUiData.AgentId, CoreUiData.BlueprintId,
            CoreUiData.BlueprintClientId, AdminUiFixture.Actor, InventoryId, "Enforce", Hash('a'), Hash('b'), Hash('c'),
            Types(), request.Suite, request.PositiveCaseIds, new(8, 8192, 65536, 60));
        fixture.Script.Return(nameof(IGatewayApiClient.ReviewPurviewRuntimeTestAsync),
            new PurviewRuntimeReviewTicket(new(OperationId, "synthetic-runtime-review", Hash('d'), CoreUiData.Now.AddMinutes(1).UtcDateTime, metadata), request));
        var panel = Panel(fixture);
        await AdminUiFixture.ClickAsync(panel, "Verify shared profile");
        await panel.InvokeAsync(() => panel.Find("input[id$='-synthetic']").Change(true));
        await AdminUiFixture.ClickAsync(panel, "Review test batch");
        Assert.Single(panel.FindComponents<ConfirmPanel>());
        return (panel, module, browser);
    }
    private static PurviewRuntimeTestCaseResultDto[] Cases() =>
        [new(PositiveId, SitId, Hash('1'), "Blocked", "Processed", "Content", CoreUiData.Now, null),
         new(NegativeId, null, Hash('2'), "Allowed", "Processed", "None", CoreUiData.Now, null)];
    private static PurviewRuntimeTestResultResponse Report(Guid? operation = null) => new(operation ?? OperationId,
        "Completed", "EnforcementBehaviorVerified", "Enforce", Hash('a'), Hash('b'), CoreUiData.Version,
        CoreUiData.Now, Cases(), [], true, null);
    private static ProtectionAdminOperationDto Operation() => new(OperationId, 1, "TestDlpRuntime", "Completed",
        AdminUiFixture.Tenant, AdminUiFixture.Actor.ToString("D"), "DlpProfile", ProfileId.ToString("D"),
        Hash('a'), OperationId, CoreUiData.Version, "NotApplicable", 1, 1, null, false, false, OperationId, null, null,
        null, [], CoreUiData.Now.UtcDateTime, CoreUiData.Now.UtcDateTime, CoreUiData.Now.UtcDateTime, CoreUiData.Now.UtcDateTime,
        [], CoreUiData.Version);
}
