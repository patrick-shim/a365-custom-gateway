using Bunit;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Time.Testing;

namespace Gateway.AdminUi.Tests.Components;

public sealed class M4ProtectionSnapshotTests
{
    [Theory]
    [InlineData("Active")]
    [InlineData("Disabled")]
    [InlineData("Provisioning")]
    public void Core_only_choices_are_off_not_missing_protection(string registration)
    {
        var shield = ProtectionStateProjection.PromptShields(CoreUiData.Features, registration);
        var purview = ProtectionStateProjection.Purview(CoreUiData.Features, registration, CoreUiData.Now.UtcDateTime);
        Assert.Equal("Off", shield.Current);
        Assert.Equal("Off", purview.Current);
        Assert.Equal("Off", shield.Requested);
        Assert.Equal("Off", purview.Requested);
    }

    [Fact]
    public void Absent_choices_are_unknown_not_off()
    {
        Assert.Equal("Unknown", ProtectionStateProjection.PromptShields(null, "Active").Current);
        Assert.Equal("Unknown", ProtectionStateProjection.Purview(null, "Active", CoreUiData.Now.UtcDateTime).Current);
    }

    [Theory]
    [InlineData("Enforce", "Ready", true, "Enforcing")]
    [InlineData("Enforce", "Ready", false, "Configured")]
    [InlineData("SimulationWithTips", "SimulationReady", false, "Simulation")]
    [InlineData("SimulationWithoutTips", "SimulationReady", false, "Simulation")]
    [InlineData("Disabled", "Disabled", false, "Off")]
    [InlineData("future-mode", "Ready", true, "Unknown")]
    public void Saved_modes_and_effective_evidence_are_distinct(string mode, string status, bool effective, string current)
    {
        var features = Features(mode, status, effective);
        Assert.Equal(current, ProtectionStateProjection.Purview(features, "Active", CoreUiData.Now.UtcDateTime).Current);
        Assert.Equal("Off", ProtectionStateProjection.PromptShields(features, "Active").Current);
    }

    [Fact]
    public void Simulation_modes_keep_distinct_saved_wording()
    {
        var withTips = ProtectionStateProjection.Purview(Features("SimulationWithTips", "SimulationReady", false),
            "Active", CoreUiData.Now.UtcDateTime);
        var withoutTips = ProtectionStateProjection.Purview(Features("SimulationWithoutTips", "SimulationReady", false),
            "Active", CoreUiData.Now.UtcDateTime);
        Assert.NotEqual(withTips.Requested, withoutTips.Requested);
        Assert.Equal("Simulation", withTips.Current);
        Assert.Equal("Simulation", withoutTips.Current);
    }

    [Fact]
    public void Missing_expiry_cannot_certify_current_enforcement()
    {
        var features = Features() with { PurviewReadiness = Ready() with { ValidUntilUtc = null } };
        Assert.Equal("Configured", ProtectionStateProjection.Purview(features, "Active", CoreUiData.Now.UtcDateTime).Current);
    }

    [Fact]
    public void Disabled_registration_cannot_claim_active_protection()
    {
        var features = Features() with { PromptShieldEnabled = true, PromptShieldEffectivelyEnabled = true,
            PromptShieldCapabilityStatus = "Installed" };
        Assert.Equal("Registration not active", ProtectionStateProjection.Purview(features, "Disabled", CoreUiData.Now.UtcDateTime).Current);
        Assert.Equal("Registration not active", ProtectionStateProjection.PromptShields(features, "Disabled").Current);
    }

    [Fact]
    public void Expiry_equality_updates_the_visible_snapshot_without_another_read()
    {
        using var fixture = CoreUiData.Create();
        var clock = (FakeTimeProvider)fixture.Services.GetRequiredService<TimeProvider>();
        var panel = fixture.Render<ProtectionSnapshot>(parameters => parameters
            .Add(item => item.Features, Features()).Add(item => item.RegistrationStatus, "Active"));
        Assert.Single(panel.FindAll("[aria-label='Status: Enforcing']"));
        clock.Advance(TimeSpan.FromMinutes(1));
        panel.WaitForAssertion(() =>
        {
            Assert.Empty(panel.FindAll("[aria-label='Status: Enforcing']"));
            Assert.Single(panel.FindAll("[aria-label='Status: Verification expired']"));
        });
        fixture.AssertComplete();
    }

    [Fact]
    public void Replacing_the_context_removes_old_green_evidence()
    {
        using var fixture = CoreUiData.Create();
        var panel = fixture.Render<ProtectionSnapshot>(parameters => parameters
            .Add(item => item.Features, Features()).Add(item => item.RegistrationStatus, "Active"));
        panel.Render(parameters => parameters.Add(item => item.Features,
            Features() with { PurviewEffectivelyEnabled = false, PurviewProfileStatus = "Pending" }));
        Assert.Empty(panel.FindAll("[aria-label='Status: Enforcing']"));
        Assert.Single(panel.FindAll("[aria-label='Status: Verifying']"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Agent_list_passes_the_actual_registration_status_to_the_shared_projection()
    {
        using var fixture = CoreUiData.Create();
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentsAsync),
            new AgentListResponse([CoreUiData.Summary() with { Features = Features() }], null, 1));
        var page = fixture.Render<Agents>();
        Assert.Single(page.FindAll("[aria-label='Status: Enforcing']"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Agent_details_pass_the_actual_registration_status_to_the_shared_projection()
    {
        const string role = "Gateway.Auditor";
        using var fixture = CoreUiData.Create(role);
        CoreUiData.ExpectDetails(fixture, role, CoreUiData.Agent() with { Features = Features() });
        var page = fixture.Render<AgentDetails>(parameters => parameters.Add(item => item.AgentId, CoreUiData.AgentId));
        Assert.NotEmpty(page.FindAll("[aria-label='Status: Enforcing']"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Off_readiness_does_not_demand_enforcement_work()
    {
        using var fixture = CoreUiData.Create();
        var panel = fixture.Render<ProtectionReadinessPanel>(parameters => parameters
            .Add(item => item.Readiness, Ready() with { IsReady = false, Capability = "NotInstalled", Blockers = ["CapabilityNotInstalled"] })
            .Add(item => item.PolicyMode, "Disabled").Add(item => item.ProfileStatus, "Disabled"));
        Assert.DoesNotContain("What still needs attention", panel.Markup);
        Assert.Empty(panel.FindAll(".readiness-blockers"));
        fixture.AssertComplete();
    }

    private static ProtectionReadinessDto Ready() => new(
        "Installed", "Ready", "Ready", "Ready", "Ready", true, [], CoreUiData.Now.UtcDateTime,
        ValidUntilUtc: CoreUiData.Now.AddMinutes(1).UtcDateTime);

    private static AgentFeaturesDto Features(string mode = "Enforce", string status = "Ready", bool effective = true) =>
        CoreUiData.Features with
        {
            PurviewEnabled = true, PurviewMode = mode == "Enforce" ? "Enforce" : "AuditOnly",
            PurviewPolicyMode = mode, PurviewProfileStatus = status,
            PurviewEffectivelyEnabled = effective, PurviewReadiness = Ready() with { IsReady = effective },
            PurviewDlpProfile = new(CoreUiData.OperationId, CoreUiData.BlueprintClientId, CoreUiData.Version)
        };
}
