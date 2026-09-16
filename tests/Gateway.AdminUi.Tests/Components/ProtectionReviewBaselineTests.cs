using Bunit;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.Tests.Components;

public sealed class ProtectionReviewBaselineTests
{
    private static readonly Guid ProfileId = Guid.Parse("33333333-3333-4333-8333-333333333333");
    private static readonly Guid BlueprintId = Guid.Parse("44444444-4444-4444-8444-444444444444");
    private static readonly Guid SitId = Guid.Parse("55555555-5555-4555-8555-555555555555");
    private static readonly Guid InventoryId = Guid.Parse("66666666-6666-4666-8666-666666666666");
    private static readonly Guid PositiveId = Guid.Parse("77777777-7777-4777-8777-777777777777");
    private static readonly Guid NegativeId = Guid.Parse("88888888-8888-4888-8888-888888888888");
    private const string Version1 = "AAAAAAAAAAE=";
    private const string Version2 = "AAAAAAAAAAI=";
    private static string Hash(char value) => "sha256:" + new string(value, 64);

    [Fact]
    public void Restricted_role_cannot_open_or_collect_runtime_samples()
    {
        using var fixture = new AdminUiFixture("Gateway.SupportReader");
        var panel = fixture.Render<PurviewRuntimeTestPanel>(parameters => parameters
            .Add(item => item.ProfileId, ProfileId).Add(item => item.IsAdministrator, false));

        Assert.Contains("Only a Gateway Administrator", panel.Markup);
        Assert.Empty(panel.FindAll("textarea"));
        Assert.DoesNotContain("Verify shared profile", panel.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Configured_off_profile_collects_no_samples_and_performs_no_sample_interop()
    {
        using var fixture = new AdminUiFixture();
        ExpectSavedProfile(fixture, Profile(mode: "Disabled"));
        var panel = RenderPanel(fixture);

        await AdminUiFixture.ClickAsync(panel, "Verify shared profile");

        Assert.Contains("configured/off. No samples are collected or sent.", panel.Markup);
        Assert.Empty(panel.FindAll("textarea"));
        Assert.DoesNotContain(fixture.JSInterop.Invocations,
            call => call.Identifier == "import" && call.Arguments.Contains("./purview-runtime-test.js"));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Stale_saved_version_fails_before_collecting_or_reviewing_samples()
    {
        using var fixture = new AdminUiFixture();
        ExpectSavedProfile(fixture, Profile(rowVersion: Version2));
        var panel = RenderPanel(fixture);

        await AdminUiFixture.ClickAsync(panel, "Verify shared profile");

        Assert.Contains("Load a current, reconciled saved profile", panel.Find("[role='alert']").TextContent);
        Assert.Empty(panel.FindAll("textarea"));
        Assert.DoesNotContain(nameof(IGatewayApiClient.ReviewPurviewRuntimeTestAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Changed_saved_binding_discards_the_review_and_refreshes_current_readiness_without_execution()
    {
        using var fixture = new AdminUiFixture();
        var (module, browser) = PrepareSampleInterop(fixture);
        ExpectSavedProfile(fixture, Profile());
        var ticket = ExpectReview(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync),
            Resource(new PurviewDlpProfileListResponse([Profile(rowVersion: Version2)])));
        var panel = RenderPanel(fixture);
        await OpenAndReview(panel);
        Assert.True(ticket.IsAvailable);
        Assert.Single(panel.FindComponents<ConfirmPanel>());

        panel.Render(parameters => parameters
            .Add(item => item.ProfileId, ProfileId)
            .Add(item => item.IsAdministrator, true)
            .Add(item => item.ContextKey, "changed-saved-binding")
            .Add(item => item.ExpectedProfileRowVersion, Version2));

        panel.WaitForAssertion(() =>
        {
            Assert.False(ticket.IsAvailable);
            Assert.Empty(panel.FindComponents<ConfirmPanel>());
            Assert.Empty(panel.FindAll("textarea"));
        });
        Assert.DoesNotContain("execute", browser.Invocations);
        Assert.Contains("dispose", browser.Invocations);
        Assert.Equal(4, fixture.Script.Calls.Count);
        module.AssertComplete();
        browser.AssertComplete();
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Changed_samples_discard_the_review_and_require_fresh_synthetic_approval()
    {
        using var fixture = new AdminUiFixture();
        var (module, browser) = PrepareSampleInterop(fixture);
        ExpectSavedProfile(fixture, Profile());
        var ticket = ExpectReview(fixture);
        var panel = RenderPanel(fixture);
        await OpenAndReview(panel);

        await panel.InvokeAsync(panel.Instance.RuntimeInputsChanged);

        Assert.False(ticket.IsAvailable);
        Assert.Empty(panel.FindComponents<ConfirmPanel>());
        Assert.False(panel.Find("input[id$='-synthetic']").HasAttribute("checked"));
        Assert.DoesNotContain("execute", browser.Invocations);
        Assert.DoesNotContain("offline-review-token", panel.Markup);
        module.AssertComplete();
        browser.AssertComplete();
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Reviewing_does_not_execute_until_actual_target_is_explicitly_approved()
    {
        using var fixture = new AdminUiFixture();
        var (module, browser) = PrepareSampleInterop(fixture);
        ExpectSavedProfile(fixture, Profile());
        var ticket = ExpectReview(fixture);
        var panel = RenderPanel(fixture);
        await OpenAndReview(panel);

        await AdminUiFixture.ClickAsync(panel, "Confirm and send approved batch");

        Assert.True(ticket.IsAvailable);
        Assert.Contains("Explicit target approval is required", panel.Markup);
        Assert.DoesNotContain("execute", browser.Invocations);
        module.AssertComplete();
        browser.AssertComplete();
        fixture.AssertComplete();
    }

    private static IRenderedComponent<PurviewRuntimeTestPanel> RenderPanel(AdminUiFixture fixture) =>
        fixture.Render<PurviewRuntimeTestPanel>(parameters => parameters
            .Add(item => item.ProfileId, ProfileId)
            .Add(item => item.IsAdministrator, true)
            .Add(item => item.ContextKey, "saved-binding")
            .Add(item => item.ExpectedProfileRowVersion, Version1));

    private static async Task OpenAndReview(IRenderedComponent<PurviewRuntimeTestPanel> panel)
    {
        await AdminUiFixture.ClickAsync(panel, "Verify shared profile");
        panel.WaitForAssertion(() => Assert.Equal(2, panel.FindAll("textarea").Count));
        panel.Find("input[id$='-synthetic']").Change(true);
        await AdminUiFixture.ClickAsync(panel, "Review test batch");
        panel.WaitForAssertion(() => Assert.Single(panel.FindComponents<ConfirmPanel>()));
    }

    private static (ScriptedJsObject Module, ScriptedJsObject Browser) PrepareSampleInterop(AdminUiFixture fixture)
    {
        var module = new ScriptedJsObject();
        var browser = new ScriptedJsObject();
        module.Expect("createSession", browser);
        browser.Expect("prepare", new RuntimePreparedManifest(Suite(), [new[] { PositiveId }]));
        fixture.RoutePrivateSampleModule(module);
        return (module, browser);
    }

    private static void ExpectSavedProfile(AdminUiFixture fixture, PurviewDlpProfileDto profile)
    {
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync),
            Resource(new PurviewDlpProfileListResponse([profile])));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync),
            Resource(new PurviewSensitiveInformationTypeListResponse(
                InventoryId, AdminUiFixture.Tenant, DateTime.UnixEpoch, DateTime.MaxValue, false,
                [new(SitId, "Synthetic classifier", "Fixture")])));
    }

    private static PurviewRuntimeReviewTicket ExpectReview(AdminUiFixture fixture)
    {
        var request = new ReviewPurviewDlpRuntimeTestRequest(ProfileId, Version1, InventoryId, Suite(), [PositiveId], true);
        var review = new PurviewRuntimeTestReviewDto(
            AdminUiFixture.Tenant, ProfileId, PositiveId, NegativeId, BlueprintId, AdminUiFixture.Actor,
            InventoryId, "Enforce", Hash('a'), Hash('b'), Hash('c'), Selections(), request.Suite, [PositiveId],
            new(8, 8192, 65536, 60));
        var ticket = new PurviewRuntimeReviewTicket(new(
            Guid.Parse("99999999-9999-4999-8999-999999999999"), "offline-review-token", Hash('d'), DateTime.MaxValue, review), request);
        fixture.Script.Return(nameof(IGatewayApiClient.ReviewPurviewRuntimeTestAsync), ticket, arguments =>
        {
            var actual = Assert.IsType<ReviewPurviewDlpRuntimeTestRequest>(arguments[0]);
            Assert.Equal(ProfileId, actual.ProfileId);
            Assert.Equal(Version1, actual.ExpectedRowVersion);
            Assert.True(actual.AcknowledgeSyntheticData);
            Assert.True(RuntimeTestUiProtocol.SameSuite(request.Suite, actual.Suite));
        });
        return ticket;
    }

    private static PurviewRuntimeTestSuiteManifestDto Suite() => new(
        new string('a', 64), [new(PositiveId, SitId, Hash('1'), 32)], new(NegativeId, null, Hash('2'), 24));

    private static PurviewSensitiveInformationTypeSelectionDto[] Selections() =>
        [new(InventoryId, SitId, "Synthetic classifier", 1, -1, 75, 100)];

    private static PurviewDlpProfileDto Profile(string mode = "Enforce", string rowVersion = Version1) => new(
        ProfileId, BlueprintId, "Offline shared policy", SitId, "Synthetic classifier", "Enforce",
        ["UploadText"], [new("UploadText", "Block")], mode == "Disabled" ? "Disabled" : "Ready",
        new("Installed", "Ready", "Ready", "Ready", "Ready", true, [], DateTime.UnixEpoch),
        "offline-policy", "offline-rule", DateTime.UnixEpoch, rowVersion, mode, Selections());

    private static GatewayApiResource<T> Resource<T>(T value) => new(value, null, "fixture-correlation");
}
