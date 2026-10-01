using Bunit;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Tests.Fixtures;
using Microsoft.AspNetCore.Components;
using Microsoft.FluentUI.AspNetCore.Components;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Time.Testing;

namespace Gateway.AdminUi.Tests.Components;

public sealed class M4PolicySelectionTests
{
    [Theory]
    [InlineData(0, false)]
    [InlineData(1, true)]
    [InlineData(100, true)]
    [InlineData(101, false)]
    public void Selection_requires_one_to_one_hundred_distinct_types(int count, bool valid)
    {
        var selection = Selection(count);
        Assert.Equal(valid, selection.Validate(Blueprints(), Types(101)).Count == 0);
    }

    [Fact]
    public void Duplicate_selection_and_ambiguous_inventory_cannot_authorize()
    {
        var selected = Selection(1);
        Assert.NotEmpty((selected with { SensitiveInformationTypeIds = [Id(1), Id(1)] }).Validate(Blueprints(), Types(1)));
        var duplicateTypes = Types(1) with { Items = [new(Id(1), "First"), new(Id(1), "Second")] };
        Assert.NotEmpty(selected.Validate(Blueprints(), duplicateTypes));
        var duplicateBlueprints = Blueprints() with { Items = [new(CoreUiData.BlueprintClientId, "First"), new(CoreUiData.BlueprintClientId, "Second")] };
        Assert.NotEmpty(selected.Validate(duplicateBlueprints, Types(1)));
    }

    [Theory]
    [InlineData(1, -1, 1, 100, true)]
    [InlineData(2, 2, 75, 75, true)]
    [InlineData(0, -1, 75, 100, false)]
    [InlineData(2, 1, 75, 100, false)]
    [InlineData(1, 0, 75, 100, false)]
    [InlineData(1, -2, 75, 100, false)]
    [InlineData(1, -1, 0, 100, false)]
    [InlineData(1, -1, 1, 101, false)]
    [InlineData(1, -1, 80, 79, false)]
    public void Threshold_bounds_are_explicit_and_ordered(int minCount, int maxCount, int minConfidence, int maxConfidence, bool valid) =>
        Assert.Equal(valid, AgentProtectionUiMapping.HasExplicitThresholds(
            new AgentProtectionSitThresholds(minCount, maxCount, minConfidence, maxConfidence)));

    [Theory]
    [InlineData(PurviewPolicyMode.Enforce, "Enforce", "Enable")]
    [InlineData(PurviewPolicyMode.SimulationWithPolicyTips, "SimulationWithTips", "TestWithNotifications")]
    [InlineData(PurviewPolicyMode.SilentSimulation, "SimulationWithoutTips", "TestWithoutNotifications")]
    [InlineData(PurviewPolicyMode.CreateButLeaveOff, "Disabled", "Disable")]
    public void Each_mode_has_a_distinct_round_trip(PurviewPolicyMode mode, string apiMode, string providerMode)
    {
        Assert.Equal(apiMode, AgentProtectionUiMapping.ServerPolicyMode(mode));
        Assert.Equal(mode, AgentProtectionUiMapping.PolicyMode(apiMode, null));
        Assert.Equal(providerMode, (Selection(1) with { PolicyMode = mode }).ProviderPolicyMode);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("unsupported")]
    public void Unknown_legacy_modes_never_become_silent_simulation(string? legacy) =>
        Assert.Null(AgentProtectionUiMapping.PolicyMode(null, legacy));

    [Fact]
    public void Inventory_expiry_equality_invalidates_an_unchanged_selection()
    {
        var clock = new FakeTimeProvider(CoreUiData.Now);
        var types = Types(1) with { Clock = clock, ExpiresAtUtc = CoreUiData.Now.AddMinutes(1) };
        Assert.Empty(Selection(1).Validate(Blueprints(), types));
        clock.Advance(TimeSpan.FromMinutes(1));
        Assert.NotEmpty(Selection(1).Validate(Blueprints(), types));
    }

    [Fact]
    public async Task Prompt_Shields_and_Purview_toggles_do_not_rewrite_each_other()
    {
        using var fixture = CoreUiData.Create();
        var selected = Selection(1);
        var panel = fixture.Render<AgentProtectionEditor>(parameters => parameters
            .Add(item => item.Value, selected).Add(item => item.IsAdministrator, true)
            .Add(item => item.Blueprints, Blueprints()).Add(item => item.SensitiveInformationTypes, Types(1))
            .Add(item => item.ValueChanged, value => selected = value));
        var shields = panel.FindComponents<FluentSwitch>().Single(component => component.Instance.Id?.EndsWith("-prompt-shields", StringComparison.Ordinal) == true);
        await panel.InvokeAsync(() => shields.Instance.ValueChanged.InvokeAsync(true));
        Assert.True(selected.PromptShieldsEnabled);
        Assert.True(selected.PurviewEnabled);
        Assert.Equal(PurviewPolicyMode.Enforce, selected.PolicyMode);
        Assert.Equal([Id(1)], selected.SensitiveInformationTypeIds);
        var purview = panel.FindComponents<FluentSwitch>().Single(component => component.Instance.Id?.EndsWith("-purview", StringComparison.Ordinal) == true);
        await panel.InvokeAsync(() => purview.Instance.ValueChanged.InvokeAsync(false));
        Assert.False(selected.PurviewEnabled);
        Assert.True(selected.PromptShieldsEnabled);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Editing_a_threshold_invalidates_the_existing_shared_impact_acknowledgment()
    {
        using var fixture = CoreUiData.Create();
        var panel = fixture.Render<AgentProtectionEditor>(parameters => parameters
            .Add(item => item.Value, Selection(1)).Add(item => item.IsAdministrator, true)
            .Add(item => item.Blueprints, Blueprints()).Add(item => item.SensitiveInformationTypes, Types(1))
            .Add(item => item.AllowThresholdEditing, true).Add(item => item.RequireExplicitThresholds, true)
            .Add(item => item.RequiresSharedPolicyAcknowledgment, true).Add(item => item.SharedPolicyReviewKey, "version-1"));
        panel.Find("input[id$='impact-acknowledgment']").Change(true);
        Assert.True(panel.Instance.CanContinue);
        await panel.Find("[data-threshold-field='MinCount']").ChangeAsync(new ChangeEventArgs { Value = "2" });
        Assert.False(panel.Instance.SharedPolicyImpactAcknowledged);
        Assert.False(panel.Instance.CanContinue);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Prerendered_controls_cannot_review_policy()
    {
        using var fixture = CoreUiData.Create();
        fixture.Rendering = new("Static", false);
        var reviews = 0;
        var panel = fixture.Render<AgentProtectionEditor>(parameters => parameters
            .Add(item => item.Value, Selection(1)).Add(item => item.IsAdministrator, true)
            .Add(item => item.Blueprints, Blueprints()).Add(item => item.SensitiveInformationTypes, Types(1))
            .Add(item => item.OnReview, _ => reviews++));
        Assert.False(panel.Instance.CanContinue);
        await AdminUiFixture.ClickAsync(panel, "Review protection choices");
        Assert.Equal(0, reviews);
        fixture.AssertComplete();
    }

    private static string Id(int number) => $"00000000-0000-4000-8000-{number:D12}";
    private static ProtectionInventory<AgentProtectionBlueprint> Blueprints() => new()
    {
        State = ProtectionInventoryState.Ready, Items = [new(CoreUiData.BlueprintClientId, "Shared fixture blueprint")]
    };
    private static ProtectionInventory<AgentProtectionSensitiveInformationType> Types(int count) => new()
    {
        State = ProtectionInventoryState.Ready,
        Items = Enumerable.Range(1, count).Select(index => new AgentProtectionSensitiveInformationType(Id(index), $"Synthetic type {index}")).ToArray()
    };
    private static AgentProtectionSelection Selection(int count) => new()
    {
        BlueprintId = CoreUiData.BlueprintClientId, PurviewEnabled = true, PolicyMode = PurviewPolicyMode.Enforce,
        SensitiveInformationTypeIds = Enumerable.Range(1, count).Select(Id).ToArray(),
        SensitiveInformationTypeThresholds = Enumerable.Range(1, count).ToDictionary(Id, _ => new AgentProtectionSitThresholds(1, -1, 75, 100))
    };
}
