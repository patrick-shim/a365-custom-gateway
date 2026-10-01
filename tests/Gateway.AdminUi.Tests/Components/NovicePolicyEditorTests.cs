using Bunit;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Components;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Time.Testing;
using Microsoft.FluentUI.AspNetCore.Components;

namespace Gateway.AdminUi.Tests.Components;

public sealed class NovicePolicyEditorTests
{
    private static readonly Guid ConnectionId = Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1");
    private static readonly Guid GenerationId = Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2");
    private static readonly Guid FirstTypeId = Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3");
    private static readonly Guid SecondTypeId = Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4");
    private static readonly Guid ProfileId = Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5");
    private static readonly Guid OperationId = Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa6");
    private static readonly Guid FreshReviewId = Guid.Parse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa7");
    private const string NewVersion = "AAAAAAAAAAI=";
    private static DateTime Now => CoreUiData.Now.UtcDateTime;
    private static string FirstId => FirstTypeId.ToString("D");
    private static string SecondId => SecondTypeId.ToString("D");

    [Fact]
    public async Task Newly_selected_type_has_visible_adjustable_starting_values_and_numbered_stages()
    {
        using var fixture = CoreUiData.Create();
        var draft = EmptySelection();
        var panel = RenderEditor(fixture, draft, value => draft = value);

        await SelectType(panel, FirstId);

        AssertThresholds(panel, FirstId, new(1, -1, 75, 100));
        Assert.Equal(new(1, -1, 75, 100), draft.ThresholdsFor(FirstId));
        Assert.Contains("not universal Microsoft recommendations", panel.Markup);
        Assert.Contains("Match ANY selected SIT (OR)", panel.Markup);
        Assert.Contains("Counts are not summed", panel.Markup);
        Assert.Contains("1. Select sensitive information types", panel.Markup);
        Assert.Contains("2. Set thresholds for selected types", panel.Markup);
        Assert.Contains("3. Choose the shared policy mode", panel.Markup);
        Assert.Contains("4. Review the shared impact", panel.Markup);
        Assert.Empty(panel.FindAll("select[id$='-blueprint']"));
        Assert.Contains(CoreUiData.BlueprintClientId.ToString("D"), panel.Find("[aria-label='Shared blueprint context']").TextContent);
        Assert.True(panel.Instance.CanContinue);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Adding_a_new_type_preserves_saved_and_edited_deselected_thresholds()
    {
        using var fixture = CoreUiData.Create();
        var original = new AgentProtectionSitThresholds(2, 8, 80, 95);
        var draft = Selected(original);
        var panel = RenderEditor(fixture, draft, value => draft = value);
        await SelectType(panel, SecondId);
        AssertThresholds(panel, FirstId, original);
        AssertThresholds(panel, SecondId, new(1, -1, 75, 100));

        await ChangeThreshold(panel, FirstId, "MinCount", "4");
        await ChangeThreshold(panel, FirstId, "MaxCount", "9");
        await ChangeThreshold(panel, FirstId, "MinConfidence", "83");
        await ChangeThreshold(panel, FirstId, "MaxConfidence", "97");
        await SelectType(panel, FirstId, false);
        Assert.Equal(new(4, 9, 83, 97), draft.ThresholdsFor(FirstId));
        await SelectType(panel, FirstId);

        AssertThresholds(panel, FirstId, new(4, 9, 83, 97));
        AssertThresholds(panel, SecondId, new(1, -1, 75, 100));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    public async Task Legacy_unknown_partial_or_invalid_thresholds_are_never_defaulted_on_reselection(int kind)
    {
        using var fixture = CoreUiData.Create();
        var unknown = kind switch
        {
            2 => new AgentProtectionSitThresholds(3, null, 80, null),
            3 => new AgentProtectionSitThresholds(0, -2, 101, 50),
            _ => new AgentProtectionSitThresholds()
        };
        var draft = Selected(unknown);
        if (kind == 0) draft = draft with { SensitiveInformationTypeThresholds = new Dictionary<string, AgentProtectionSitThresholds>() };
        var panel = RenderEditor(fixture, draft, value => draft = value);
        AssertThresholds(panel, FirstId, unknown);
        Assert.False(panel.Instance.CanContinue);

        await SelectType(panel, FirstId, false);
        await SelectType(panel, FirstId);

        AssertThresholds(panel, FirstId, unknown);
        Assert.Equal(unknown, draft.ThresholdsFor(FirstId));
        Assert.Contains("Blank means unknown, not a default", panel.Markup);
        Assert.False(panel.Instance.CanContinue);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Search_filters_choices_but_never_hides_selected_thresholds()
    {
        using var fixture = CoreUiData.Create();
        var panel = RenderEditor(fixture, Selected(new(4, 7, 82, 96)));

        await panel.Find("input[type='search']").InputAsync(new ChangeEventArgs { Value = "Second synthetic" });

        Assert.Empty(panel.FindAll($"[data-sit-id='{FirstId}']"));
        AssertThresholds(panel, FirstId, new(4, 7, 82, 96));
        await SelectType(panel, SecondId);
        Assert.Equal(2, panel.FindAll("[data-selected-sit]").Count);
        AssertThresholds(panel, FirstId, new(4, 7, 82, 96));
        AssertThresholds(panel, SecondId, new(1, -1, 75, 100));
        await panel.Find("input[type='search']").InputAsync(new ChangeEventArgs { Value = "no synthetic match" });
        Assert.Empty(panel.FindAll("[data-sit-id]"));
        Assert.Equal(8, panel.FindAll("[data-threshold-sit]").Count);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Clearing_a_starting_value_blocks_review_instead_of_requesting_an_invisible_default()
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture);
        await SelectType(panel, FirstId);
        await ChooseMode(panel, PurviewPolicyMode.Enforce);
        await ChangeThreshold(panel, FirstId, "MinConfidence", "");

        await AdminUiFixture.ClickAsync(panel, "Review protection choices");

        Assert.Null(panel.Instance.Selection.ThresholdsFor(FirstId)!.MinConfidence);
        Assert.False(panel.FindComponent<AgentProtectionEditor>().Instance.CanContinue);
        Assert.Empty(panel.FindComponents<ConfirmPanel>());
        AssertReadOnly(fixture);
    }

    [Theory]
    [InlineData(PurviewPolicyMode.Enforce, false)]
    [InlineData(PurviewPolicyMode.Enforce, true)]
    [InlineData(PurviewPolicyMode.SimulationWithPolicyTips, true)]
    [InlineData(PurviewPolicyMode.SilentSimulation, true)]
    [InlineData(PurviewPolicyMode.CreateButLeaveOff, true)]
    public async Task Prerequisite_refresh_preserves_unsaved_name_mode_selections_and_thresholds(PurviewPolicyMode mode, bool existing)
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture, existing ? Profile() : null);
        if (!existing) await SelectType(panel, FirstId);
        await ChangeName(panel, "My unsaved shared policy");
        await ChooseMode(panel, mode);
        await ChangeThreshold(panel, FirstId, "MinCount", "4");
        await SelectType(panel, SecondId);
        var before = panel.Instance.Selection;
        ExpectPrerequisites(fixture, existing ? [Profile()] : []);

        await AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");

        Assert.Equal("My unsaved shared policy", NameValue(panel));
        Assert.True(before.HasSameChoices(panel.Instance.Selection));
        AssertThresholds(panel, FirstId, new(4, -1, 75, 100));
        AssertThresholds(panel, SecondId, new(1, -1, 75, 100));
        Assert.Empty(panel.FindComponents<ConfirmPanel>());
        AssertReadOnly(fixture);
    }

    [Fact]
    public async Task Removing_all_types_is_not_undone_by_refreshing_the_saved_profile()
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture, Profile());
        await ChangeName(panel, "Keep this empty draft");
        await SelectType(panel, FirstId, false);
        ExpectPrerequisites(fixture, [Profile()]);

        await AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");

        Assert.Empty(panel.Instance.Selection.SensitiveInformationTypeIds);
        Assert.Equal("Keep this empty draft", NameValue(panel));
        Assert.False(panel.FindComponent<AgentProtectionEditor>().Instance.CanContinue);
        AssertReadOnly(fixture);
    }

    [Fact]
    public async Task Refresh_invalidates_review_and_shared_acknowledgment_and_uses_the_fresh_profile_version()
    {
        using var fixture = CoreUiData.Create();
        var original = Profile();
        var panel = OpenConfiguration(fixture, original);
        await ChangeName(panel, "Reviewed unsaved name");
        await ChangeThreshold(panel, FirstId, "MinCount", "4");
        panel.Find("input[id$='impact-acknowledgment']").Change(true);
        var oldReview = ExpectReview(fixture, panel.Instance.Selection, original);
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");
        var oldConfirm = panel.FindComponent<ConfirmPanel>().Instance.OnConfirm;
        var readsStart = fixture.Script.Calls.Count;
        var refreshed = original with { RowVersion = NewVersion, DisplayName = "A concurrently saved name" };
        ExpectPrerequisites(fixture, [refreshed]);

        await AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");

        Assert.False(oldReview.IsAvailable);
        Assert.Empty(panel.FindComponents<ConfirmPanel>());
        Assert.False(panel.FindComponent<AgentProtectionEditor>().Instance.SharedPolicyImpactAcknowledged);
        Assert.Equal("Reviewed unsaved name", NameValue(panel));
        AssertThresholds(panel, FirstId, new(4, -1, 75, 100));
        Assert.All(fixture.Script.Calls.Skip(readsStart), call => Assert.StartsWith("Get", call));
        await panel.InvokeAsync(() => oldConfirm.InvokeAsync());
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");
        Assert.Equal(1, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.ReviewPurviewDlpProfileOperationAsync)));

        panel.Find("input[id$='impact-acknowledgment']").Change(true);
        ExpectReview(fixture, panel.Instance.Selection, refreshed, inspect: request =>
        {
            Assert.Equal(NewVersion, request.ExpectedRowVersion);
            Assert.Equal("Reviewed unsaved name", request.DisplayName);
            Assert.Equal(ProfileId, request.ProfileId);
            Assert.Equal(4, Assert.Single(request.SensitiveInformationTypes!).MinCount);
        }, reviewId: FreshReviewId);
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");
        Assert.Single(panel.FindComponents<ConfirmPanel>());
        Assert.DoesNotContain(nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync), fixture.Script.Calls);
        Assert.DoesNotContain(nameof(IGatewayApiClient.StartPurviewDlpProfileOperationAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task New_policy_readback_keeps_the_exact_authorized_profile_and_original_operation()
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture);
        await SelectType(panel, FirstId);
        await ChooseMode(panel, PurviewPolicyMode.Enforce);
        await ChangeName(panel, "New synthetic policy");
        var ticket = ExpectReview(fixture, panel.Instance.Selection, Profile() with { RowVersion = "*" });
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");
        fixture.Script.Return(nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync),
            CoreUiData.Resource(new ProtectionOperationConfirmationTicket(
                new(OperationId, OperationId, "synthetic-confirmation-not-valid-for-any-service", Now.AddMinutes(1)), ticket.Review, "*")));
        fixture.Script.Return(nameof(IGatewayApiClient.StartPurviewDlpProfileOperationAsync),
            CoreUiData.Resource(new ProtectionOperationAcceptedResponse(OperationId, "Pending", OperationId)));
        ExpectPrerequisites(fixture, [Profile() with { DisplayName = "New synthetic policy" }]);

        await AdminUiFixture.ClickAsync(panel, "Confirm and queue shared policy");

        Assert.DoesNotContain("exact shared profile target changed or disappeared", panel.Markup);
        Assert.Equal("New synthetic policy", NameValue(panel));
        Assert.Equal([FirstId], panel.Instance.Selection.SensitiveInformationTypeIds);
        Assert.Contains($"operation={OperationId:D}", panel.Markup);
        Assert.Equal(1, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.StartPurviewDlpProfileOperationAsync)));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Unknown_saved_thresholds_and_explicit_edits_survive_profile_refresh_without_repair_claims()
    {
        using var fixture = CoreUiData.Create();
        var legacy = Profile() with { SensitiveInformationTypes = [new(GenerationId, FirstTypeId, TypeName(FirstTypeId), null, -2, null, 101)] };
        var panel = OpenConfiguration(fixture, legacy);
        await ChangeThreshold(panel, FirstId, "MinCount", "3");
        ExpectPrerequisites(fixture, [legacy]);

        await AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");

        AssertThresholds(panel, FirstId, new(3, -2, null, 101));
        Assert.Contains("Existing threshold evidence is unknown or invalid", panel.Markup);
        Assert.False(panel.FindComponent<AgentProtectionEditor>().Instance.CanContinue);
        AssertReadOnly(fixture);
    }

    [Fact]
    public async Task Missing_selected_identity_remains_visible_and_blocks_review_after_refresh()
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture, Profile());
        await ChangeThreshold(panel, FirstId, "MinCount", "4");
        ExpectPrerequisites(fixture, [Profile()], inventory: Inventory() with { Items = [new(SecondTypeId, TypeName(SecondTypeId), "Fixture")] });

        await AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");

        Assert.Equal([FirstId], panel.Instance.Selection.SensitiveInformationTypeIds);
        AssertThresholds(panel, FirstId, new(4, -1, 75, 100));
        Assert.Single(panel.FindAll($"[data-selected-sit='{FirstId}']"));
        Assert.Contains("Removed or unavailable selected SIT IDs", panel.Markup);
        Assert.False(panel.FindComponent<AgentProtectionEditor>().Instance.CanContinue);
        AssertReadOnly(fixture);
    }

    [Fact]
    public async Task A_read_failure_before_expiry_preserves_the_draft_without_reclassifying_its_selections_as_missing()
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture, Profile());
        await ChangeName(panel, "Retain this draft after a failed read");
        await ChangeThreshold(panel, FirstId, "MinCount", "4");
        await ChooseMode(panel, PurviewPolicyMode.SilentSimulation);
        var before = panel.Instance.Selection;
        ExpectPrerequisites(fixture, [Profile()], includeInventory: false);
        fixture.Script.Expect<GatewayApiResource<PurviewSensitiveInformationTypeListResponse>>(
            nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync),
            _ => Task.FromException<GatewayApiResource<PurviewSensitiveInformationTypeListResponse>>(
                new GatewayApiTransportException("Synthetic read failure; cause not established.", "fixture",
                    new HttpRequestException("Synthetic transport."))));

        await AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");

        Assert.Equal("Retain this draft after a failed read", NameValue(panel));
        Assert.True(before.HasSameChoices(panel.Instance.Selection));
        AssertThresholds(panel, FirstId, new(4, -1, 75, 100));
        Assert.Contains("Unverified selected SIT IDs", panel.Markup);
        Assert.DoesNotContain("Removed or unavailable selected SIT IDs", panel.Markup);
        Assert.DoesNotContain("Connection verified earlier; refresh required", panel.Markup);
        Assert.False(panel.FindComponent<AgentProtectionEditor>().Instance.CanContinue);
        Assert.False(RefreshButton(panel).Instance.Disabled);
        AssertReadOnly(fixture);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task A_missing_saved_profile_cannot_become_a_create_or_rebind_to_another_profile(bool replacement)
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture, Profile());
        await ChangeName(panel, "Do not rebind my draft");
        ExpectPrerequisites(fixture, replacement ? [Profile() with { Id = SecondTypeId }] : []);

        await AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");

        Assert.Equal("Do not rebind my draft", NameValue(panel));
        Assert.Equal([FirstId], panel.Instance.Selection.SensitiveInformationTypeIds);
        Assert.Contains("exact shared profile target changed or disappeared", panel.Markup);
        Assert.False(panel.Instance.CanApply);
        AssertReadOnly(fixture);
    }

    [Theory]
    [InlineData("tenant")]
    [InlineData("generation")]
    [InlineData("empty-generation")]
    [InlineData("duplicate-id")]
    [InlineData("duplicate-name")]
    [InlineData("empty-id")]
    public async Task Mismatched_or_ambiguous_inventory_cannot_authorize_a_draft(string mismatch)
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture, Profile());
        var inventory = mismatch switch
        {
            "tenant" => Inventory() with { TenantId = SecondTypeId },
            "generation" => Inventory() with { GenerationId = SecondTypeId },
            "empty-generation" => Inventory() with { GenerationId = Guid.Empty },
            "duplicate-id" => Inventory() with { Items = [new(FirstTypeId, "First", "Fixture"), new(FirstTypeId, "Second", "Fixture")] },
            "duplicate-name" => Inventory() with { Items = [new(FirstTypeId, "Same", "Fixture"), new(SecondTypeId, "Same", "Fixture")] },
            _ => Inventory() with { Items = [new(Guid.Empty, "Invalid identity", "Fixture")] }
        };
        ExpectPrerequisites(fixture, [Profile()], inventory: inventory);

        await AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");

        Assert.Equal([FirstId], panel.Instance.Selection.SensitiveInformationTypeIds);
        Assert.False(panel.FindComponent<AgentProtectionEditor>().Instance.CanContinue);
        Assert.Empty(panel.FindAll("[data-sit-id]"));
        AssertReadOnly(fixture);
    }

    [Fact]
    public async Task Another_tenants_connection_is_not_used_even_if_its_status_says_connected()
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture, Profile());
        ExpectPrerequisites(fixture, [Profile()], Connection() with { TenantId = SecondTypeId }, includeInventory: false);

        await AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");

        Assert.Contains("does not match the signed-in tenant", panel.Markup);
        Assert.Equal([FirstId], panel.Instance.Selection.SensitiveInformationTypeIds);
        Assert.False(panel.Instance.CanApply);
        Assert.Equal(1, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync)));
        AssertReadOnly(fixture);
    }

    [Theory]
    [InlineData(PurviewPolicyMode.Enforce)]
    [InlineData(PurviewPolicyMode.SilentSimulation)]
    [InlineData(PurviewPolicyMode.CreateButLeaveOff)]
    public async Task Connection_expiry_at_equality_preserves_the_draft_and_offers_separate_tab_recovery(PurviewPolicyMode mode)
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture, Profile());
        await ChangeName(panel, "Draft survives expiry");
        await ChooseMode(panel, mode);
        var before = panel.Instance.Selection;
        var clock = (FakeTimeProvider)fixture.Services.GetRequiredService<TimeProvider>();
        clock.Advance(TimeSpan.FromMinutes(10));
        ExpectPrerequisites(fixture, [Profile()], includeInventory: false);

        await AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");

        var recovery = panel.Find("a[href='/settings/connection']");
        Assert.Equal("_blank", recovery.GetAttribute("target"));
        Assert.Contains("noopener", recovery.GetAttribute("rel"));
        Assert.Equal("Refresh tenant connection (opens new tab)", recovery.TextContent);
        Assert.Contains("cannot renew", panel.Markup);
        Assert.Contains("Connection verified earlier; refresh required", panel.Markup);
        Assert.Equal("Draft survives expiry", NameValue(panel));
        Assert.True(before.HasSameChoices(panel.Instance.Selection));
        Assert.False(panel.Instance.CanApply);
        Assert.Equal(1, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync)));
        AssertReadOnly(fixture);
    }

    [Fact]
    public async Task A_genuinely_refreshed_connection_requires_a_new_review_of_the_exact_connection_and_generation()
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture, Profile());
        await ChangeName(panel, "Keep my recovered draft");
        await ChangeThreshold(panel, FirstId, "MinCount", "4");
        var before = panel.Instance.Selection;
        var clock = (FakeTimeProvider)fixture.Services.GetRequiredService<TimeProvider>();
        clock.Advance(TimeSpan.FromMinutes(10));
        var refreshedAt = clock.GetUtcNow().UtcDateTime;
        var currentConnection = Connection() with
        {
            Id = FreshReviewId, ActiveInventoryGenerationId = SecondTypeId, RowVersion = NewVersion,
            AuthorizedAtUtc = refreshedAt, LastVerifiedAtUtc = refreshedAt, ExpiresAtUtc = refreshedAt.AddMinutes(10)
        };
        var currentInventory = Inventory() with
        {
            GenerationId = SecondTypeId, RetrievedAtUtc = refreshedAt, ExpiresAtUtc = refreshedAt.AddMinutes(10)
        };
        ExpectPrerequisites(fixture, [Profile()], currentConnection, currentInventory);

        await AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");

        Assert.Equal("Keep my recovered draft", NameValue(panel));
        Assert.True(before.HasSameChoices(panel.Instance.Selection));
        Assert.Empty(panel.FindComponents<ConfirmPanel>());
        Assert.False(panel.FindComponent<AgentProtectionEditor>().Instance.SharedPolicyImpactAcknowledged);
        Assert.All(fixture.Script.Calls, call => Assert.StartsWith("Get", call));
        panel.Find("input[id$='impact-acknowledgment']").Change(true);
        ExpectReview(fixture, panel.Instance.Selection, Profile(), inspect: request =>
        {
            Assert.Equal(currentConnection.Id, request.TenantConnectionId);
            Assert.Equal(currentInventory.GenerationId, Assert.Single(request.SensitiveInformationTypes!).InventoryGenerationId);
            Assert.Equal("Keep my recovered draft", request.DisplayName);
        }, generationId: currentInventory.GenerationId);
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");
        Assert.Single(panel.FindComponents<ConfirmPanel>());
        Assert.DoesNotContain(nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync), fixture.Script.Calls);
        Assert.DoesNotContain(nameof(IGatewayApiClient.StartPurviewDlpProfileOperationAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Loading_is_visible_and_serializes_refresh_and_edit_actions()
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture, Profile());
        await ChangeName(panel, "Before the read");
        var before = panel.Instance.Selection;
        var selectionCallback = panel.FindComponent<AgentProtectionEditor>().Instance.ValueChanged;
        var pending = new TaskCompletionSource<GatewayApiResource<ProtectionCapabilitiesResponse>>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Script.Expect(nameof(IGatewayApiClient.GetProtectionCapabilitiesAsync), _ => pending.Task);
        ExpectRemainingPrerequisites(fixture, [Profile()]);
        var refresh = AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");
        panel.WaitForAssertion(() => Assert.Contains("Reading protection prerequisites", panel.Markup));
        Assert.True(panel.Instance.IsReadingPrerequisites);
        Assert.Equal("true", panel.Find(".protection-configuration").GetAttribute("aria-busy"));
        Assert.True(panel.Find("input[id$='profile-name']").HasAttribute("disabled"));
        Assert.True(RefreshButton(panel).Instance.Disabled);
        Assert.True(panel.FindComponent<AgentProtectionEditor>().Instance.Busy);
        Assert.False(panel.Instance.CanApply);
        await ChangeName(panel, "Ignore this event during the read");
        await panel.InvokeAsync(() => selectionCallback.InvokeAsync(before with { PolicyMode = PurviewPolicyMode.CreateButLeaveOff }));
        await AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");
        Assert.Equal("Before the read", NameValue(panel));
        Assert.True(before.HasSameChoices(panel.Instance.Selection));

        pending.SetResult(CoreUiData.Resource(Capabilities()));
        await refresh;

        Assert.Equal("false", panel.Find(".protection-configuration").GetAttribute("aria-busy"));
        Assert.False(panel.Instance.IsReadingPrerequisites);
        Assert.False(RefreshButton(panel).Instance.Disabled);
        await ChangeName(panel, "An edit after the read");
        await ChangeThreshold(panel, FirstId, "MinCount", "5");
        Assert.Equal("An edit after the read", NameValue(panel));
        Assert.Equal(5, panel.Instance.Selection.ThresholdsFor(FirstId)!.MinCount);
        AssertReadOnly(fixture);
    }

    [Fact]
    public async Task Prerequisites_expiring_during_the_read_are_not_extended_or_treated_as_current()
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture, Profile());
        await ChangeThreshold(panel, FirstId, "MinCount", "4");
        var pending = new TaskCompletionSource<GatewayApiResource<PurviewSensitiveInformationTypeListResponse>>(TaskCreationOptions.RunContinuationsAsynchronously);
        ExpectPrerequisites(fixture, [Profile()], includeInventory: false);
        fixture.Script.Expect(nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync), _ => pending.Task);
        var refresh = AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");
        panel.WaitForAssertion(() => Assert.Equal(2,
            fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync))));
        var clock = (FakeTimeProvider)fixture.Services.GetRequiredService<TimeProvider>();
        clock.Advance(TimeSpan.FromMinutes(10));

        pending.SetResult(CoreUiData.Resource(Inventory()));
        await refresh;
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");

        Assert.Contains("Connection verified earlier; refresh required", panel.Markup);
        AssertThresholds(panel, FirstId, new(4, -1, 75, 100));
        Assert.False(panel.Instance.CanApply);
        AssertReadOnly(fixture);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Late_read_for_another_editor_context_or_lost_role_is_discarded(bool loseRole)
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture, Profile());
        var pending = new TaskCompletionSource<GatewayApiResource<ProtectionCapabilitiesResponse>>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Script.Expect(nameof(IGatewayApiClient.GetProtectionCapabilitiesAsync), _ => pending.Task);
        var refresh = AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");
        panel.WaitForAssertion(() => Assert.True(RefreshButton(panel).Instance.Disabled));
        if (loseRole)
            panel.Render(parameters => parameters.Add(item => item.IsAdministrator, false));
        else
            panel.Render(parameters => parameters.Add(item => item.ContextKey, "different-target")
                .Add(item => item.BlueprintApplicationId, SecondTypeId).Add(item => item.ProfileId, SecondTypeId));

        pending.SetResult(CoreUiData.Resource(Capabilities()));
        await refresh;

        Assert.Contains("Those results were discarded", panel.Markup);
        Assert.False(panel.Instance.CanApply);
        Assert.Empty(panel.FindComponents<ConfirmPanel>());
        Assert.Equal(2, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.GetProtectionCapabilitiesAsync)));
        Assert.Equal(1, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync)));
        AssertReadOnly(fixture);
    }

    [Fact]
    public async Task Disposal_cancels_the_owned_read_and_ignores_a_noncooperating_late_result()
    {
        using var fixture = CoreUiData.Create();
        var panel = OpenConfiguration(fixture, Profile());
        var pending = new TaskCompletionSource<GatewayApiResource<ProtectionCapabilitiesResponse>>(TaskCreationOptions.RunContinuationsAsynchronously);
        CancellationToken readToken = default;
        fixture.Script.Expect(nameof(IGatewayApiClient.GetProtectionCapabilitiesAsync), arguments =>
        {
            readToken = Assert.IsType<CancellationToken>(arguments[0]);
            return pending.Task;
        });
        var refresh = AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");
        panel.WaitForAssertion(() => Assert.True(readToken.CanBeCanceled));

        await fixture.DisposeComponentsAsync();
        Assert.True(readToken.IsCancellationRequested);
        pending.SetResult(CoreUiData.Resource(Capabilities()));
        await refresh;

        Assert.Equal(1, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync)));
        AssertReadOnly(fixture);
    }

    [Theory]
    [InlineData(false, true)]
    [InlineData(true, false)]
    public async Task Role_and_interactivity_gates_block_prerequisite_actions(bool administrator, bool interactive)
    {
        using var fixture = CoreUiData.Create(administrator ? "Gateway.Administrator" : "Gateway.Operator");
        fixture.Rendering = new(interactive ? "Server" : "Static", interactive);
        if (administrator) ExpectPrerequisites(fixture);
        var panel = fixture.Render<AgentProtectionConfiguration>(parameters => parameters
            .Add(item => item.BlueprintApplicationId, CoreUiData.BlueprintClientId)
            .Add(item => item.PolicyOnly, true).Add(item => item.IsAdministrator, administrator));
        var calls = fixture.Script.Calls.Count;

        await AdminUiFixture.ClickAsync(panel, "Refresh prerequisites");
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");

        Assert.True(RefreshButton(panel).Instance.Disabled);
        Assert.False(panel.Instance.CanApply);
        Assert.Equal(calls, fixture.Script.Calls.Count);
        AssertReadOnly(fixture);
    }

    private static IRenderedComponent<AgentProtectionEditor> RenderEditor(AdminUiFixture fixture,
        AgentProtectionSelection value, Action<AgentProtectionSelection>? changed = null) =>
        fixture.Render<AgentProtectionEditor>(parameters => parameters
            .Add(item => item.Value, value).Add(item => item.ValueChanged, changed ?? (_ => { }))
            .Add(item => item.IsAdministrator, true).Add(item => item.PolicyOnly, true)
            .Add(item => item.LockBlueprintSelection, true).Add(item => item.AllowThresholdEditing, true)
            .Add(item => item.RequireExplicitThresholds, true)
            .Add(item => item.Blueprints, new ProtectionInventory<AgentProtectionBlueprint>
            {
                State = ProtectionInventoryState.Ready,
                Items = [new(CoreUiData.BlueprintClientId, "Shared synthetic blueprint")]
            })
            .Add(item => item.SensitiveInformationTypes, new ProtectionInventory<AgentProtectionSensitiveInformationType>
            {
                State = ProtectionInventoryState.Ready, Clock = fixture.Services.GetRequiredService<TimeProvider>(),
                ExpiresAtUtc = CoreUiData.Now.AddMinutes(10),
                Items = [new(FirstId, TypeName(FirstTypeId)), new(SecondId, TypeName(SecondTypeId))]
            }));

    private static IRenderedComponent<AgentProtectionConfiguration> OpenConfiguration(AdminUiFixture fixture, PurviewDlpProfileDto? profile = null)
    {
        ExpectPrerequisites(fixture, profile is null ? [] : [profile]);
        return fixture.Render<AgentProtectionConfiguration>(parameters => parameters
            .Add(item => item.BlueprintApplicationId, CoreUiData.BlueprintClientId)
            .Add(item => item.BlueprintDisplayName, "Shared synthetic blueprint")
            .Add(item => item.ContextKey, "synthetic-policy-draft")
            .Add(item => item.IsAdministrator, true).Add(item => item.PolicyOnly, true)
            .Add(item => item.StartOnConfirm, true));
    }

    private static Task SelectType<T>(IRenderedComponent<T> panel, string id, bool selected = true) where T : class, IComponent =>
        panel.Find($"[data-sit-id='{id}']").ChangeAsync(new ChangeEventArgs { Value = selected });
    private static Task ChangeThreshold<T>(IRenderedComponent<T> panel, string id, string field, string value) where T : class, IComponent =>
        panel.Find($"[data-threshold-sit='{id}'][data-threshold-field='{field}']").ChangeAsync(new ChangeEventArgs { Value = value });
    private static Task ChooseMode(IRenderedComponent<AgentProtectionConfiguration> panel, PurviewPolicyMode mode) =>
        panel.Find($"input[value='{mode}']").ChangeAsync(new ChangeEventArgs { Value = true });
    private static Task ChangeName(IRenderedComponent<AgentProtectionConfiguration> panel, string name) =>
        panel.Find("input[id$='profile-name']").InputAsync(new ChangeEventArgs { Value = name });
    private static string? NameValue(IRenderedComponent<AgentProtectionConfiguration> panel) =>
        panel.Find("input[id$='profile-name']").GetAttribute("value");
    private static IRenderedComponent<FluentButton> RefreshButton(IRenderedComponent<AgentProtectionConfiguration> panel) =>
        panel.FindComponents<FluentButton>().Single(button => button.Find("fluent-button").TextContent.Trim() == "Refresh prerequisites");
    private static void AssertThresholds<T>(IRenderedComponent<T> panel, string id, AgentProtectionSitThresholds expected) where T : class, IComponent
    {
        foreach (var (field, value) in new[] { ("MinCount", expected.MinCount), ("MaxCount", expected.MaxCount),
                     ("MinConfidence", expected.MinConfidence), ("MaxConfidence", expected.MaxConfidence) })
            Assert.Equal(value?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "",
                panel.Find($"[data-threshold-sit='{id}'][data-threshold-field='{field}']").GetAttribute("value") ?? "");
    }

    private static AgentProtectionSelection EmptySelection() => new()
    {
        BlueprintId = CoreUiData.BlueprintClientId, PurviewEnabled = true, PolicyMode = PurviewPolicyMode.Enforce
    };
    private static AgentProtectionSelection Selected(AgentProtectionSitThresholds thresholds) => EmptySelection() with
    {
        SensitiveInformationTypeIds = [FirstId],
        SensitiveInformationTypeThresholds = new Dictionary<string, AgentProtectionSitThresholds> { [FirstId] = thresholds }
    };
    private static string TypeName(Guid id) => id == FirstTypeId ? "First synthetic classifier" : "Second synthetic classifier";
    private static ProtectionCapabilitiesResponse Capabilities() => new([
        new(ConnectionId, "Purview", "Installed", new(null, null, null, null, null, null, null, null, null), Now, null, CoreUiData.Version)
    ]);
    private static PurviewTenantConnectionDto Connection() => new(ConnectionId, AdminUiFixture.Tenant, "Connected",
        "InteractiveDelegatedAdministrator", null, null, GenerationId, Now, Now.AddMinutes(10), Now, null, CoreUiData.Version);
    private static PurviewSensitiveInformationTypeListResponse Inventory() => new(GenerationId, AdminUiFixture.Tenant,
        Now, Now.AddMinutes(10), false, [new(FirstTypeId, TypeName(FirstTypeId), "Fixture"), new(SecondTypeId, TypeName(SecondTypeId), "Fixture")]);
    private static PurviewDlpProfileDto Profile() => new(ProfileId, CoreUiData.BlueprintClientId, "Saved synthetic policy",
        FirstTypeId, TypeName(FirstTypeId), "Enforce", ["UploadText", "DownloadText"], [new("UploadText", "Block")],
        "Pending", new("Installed", "Ready", "NotChecked", "NotChecked", "NotTested", false, [], Now),
        "synthetic-policy", "synthetic-rule", Now, CoreUiData.Version, "Enforce",
        [new(GenerationId, FirstTypeId, TypeName(FirstTypeId), 1, -1, 75, 100)]);

    private static void ExpectPrerequisites(AdminUiFixture fixture, IReadOnlyList<PurviewDlpProfileDto>? profiles = null,
        PurviewTenantConnectionDto? connection = null, PurviewSensitiveInformationTypeListResponse? inventory = null, bool includeInventory = true)
    {
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionCapabilitiesAsync), CoreUiData.Resource(Capabilities()));
        ExpectRemainingPrerequisites(fixture, profiles, connection, inventory, includeInventory);
    }
    private static void ExpectRemainingPrerequisites(AdminUiFixture fixture, IReadOnlyList<PurviewDlpProfileDto>? profiles = null,
        PurviewTenantConnectionDto? connection = null, PurviewSensitiveInformationTypeListResponse? inventory = null, bool includeInventory = true)
    {
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync),
            CoreUiData.Resource(new PurviewDlpProfileListResponse(profiles ?? [])));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(connection ?? Connection())));
        if (includeInventory)
            fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync), CoreUiData.Resource(inventory ?? Inventory()));
    }

    private static ProtectionOperationReviewTicket ExpectReview(AdminUiFixture fixture, AgentProtectionSelection selection,
        PurviewDlpProfileDto profile, Action<ReviewPurviewDlpProfileOperationRequest>? inspect = null,
        Guid? reviewId = null, Guid? generationId = null)
    {
        var types = selection.SensitiveInformationTypeIds.Select(id =>
        {
            var thresholds = selection.ThresholdsFor(id)!;
            var guid = Guid.Parse(id);
            return new PurviewSensitiveInformationTypeSelectionDto(generationId ?? GenerationId, guid, TypeName(guid),
                thresholds.MinCount, thresholds.MaxCount, thresholds.MinConfidence, thresholds.MaxConfidence);
        }).ToArray();
        var summary = new ProtectionOperationReviewSummaryDto(AdminUiFixture.Tenant, "CreateOrUpdateDlpProfile", "DlpProfile",
            profile.Id.ToString("D"), CoreUiData.BlueprintClientId, FirstTypeId, TypeName(FirstTypeId),
            AgentProtectionUiMapping.LegacyMode(selection.PolicyMode), profile.Activities, profile.Actions, "Individual", "Application",
            "Synthetic review only; no enforcement or authorization is demonstrated.",
            PolicyMode: AgentProtectionUiMapping.ServerPolicyMode(selection.PolicyMode!.Value),
            SensitiveInformationTypes: types, AffectsAllBlueprintAgents: true);
        var ticket = new ProtectionOperationReviewTicket(new(reviewId ?? OperationId, "synthetic-review-not-valid-for-any-service",
            "sha256:" + new string('a', 64), fixture.Services.GetRequiredService<TimeProvider>().GetUtcNow().UtcDateTime.AddMinutes(1), summary), profile.RowVersion);
        fixture.Script.Return(nameof(IGatewayApiClient.ReviewPurviewDlpProfileOperationAsync), CoreUiData.Resource(ticket),
            arguments => inspect?.Invoke(Assert.IsType<ReviewPurviewDlpProfileOperationRequest>(arguments[0])));
        return ticket;
    }

    private static void AssertReadOnly(AdminUiFixture fixture)
    {
        Assert.All(fixture.Script.Calls, call => Assert.StartsWith("Get", call));
        fixture.AssertComplete();
    }
}
