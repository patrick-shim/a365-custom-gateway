using Bunit;
using FluentAssertions;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Services;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Components.Web;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.FluentUI.AspNetCore.Components;
using NSubstitute;

namespace Gateway.AdminUi.Tests.Components;

public sealed class SettingsPageTests : BunitContext
{
    private readonly IGatewayApiClient _api = Substitute.For<IGatewayApiClient>();

    public SettingsPageTests()
    {
        Services.AddFluentUIComponents();
        Services.AddSingleton(_api);
        JSInterop.Mode = JSRuntimeMode.Loose;

        var auth = AddAuthorization();
        auth.SetAuthorized("Admin user");
        auth.SetRoles(GatewayRoles.Administrator);
    }

    [Fact]
    public async Task ConfirmedSave_IsSentOnceWhileFirstUpdateIsPending()
    {
        var config = CreateConfig();
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(config);
        var completion = new TaskCompletionSource<SystemConfigDto>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        _api.UpdateSystemConfigAsync(
                Arg.Any<UpdateSystemConfigRequest>(),
                Arg.Any<string?>(),
                Arg.Any<CancellationToken>())
            .Returns(completion.Task);
        var cut = Render<Settings>();
        cut.WaitForElement("form");

        await cut.Find("form").SubmitAsync(EventArgs.Empty);
        var saveButton = cut.FindAll(".confirm-panel fluent-button").Last();

        var firstSave = saveButton.ClickAsync(new MouseEventArgs());
        cut.WaitForAssertion(() =>
        {
            _api.Received(1).UpdateSystemConfigAsync(
                Arg.Is<UpdateSystemConfigRequest>(request =>
                    request.ProvisioningMode == config.ProvisioningMode &&
                    request.RateLimitGlobal == config.RateLimitGlobal &&
                    request.DefaultObservabilityMode == "Agent365" &&
                    request.DefaultAgent365ObservabilityEnabled == true &&
                    request.DefaultAzureMonitorExportEnabled == false &&
                    request.ReconciliationEnabled == null &&
                    request.ReconciliationIntervalHours == null &&
                    request.UseGraphAgentRegistration == null &&
                    request.UseCliProvisioningFallback == null),
                Arg.Any<string?>(),
                Arg.Any<CancellationToken>());
            cut.Markup.Should().Contain("Working…");
        });

        var duplicateSave = saveButton.ClickAsync(new MouseEventArgs());
        await duplicateSave.WaitAsync(TimeSpan.FromSeconds(2));

        _ = _api.Received(1).UpdateSystemConfigAsync(
            Arg.Any<UpdateSystemConfigRequest>(),
            Arg.Any<string?>(),
            Arg.Any<CancellationToken>());

        completion.SetResult(config);
        await firstSave.WaitAsync(TimeSpan.FromSeconds(2));
        cut.WaitForAssertion(() =>
        {
            cut.Find(".success-banner").TextContent.Should().Contain("Settings saved.");
            cut.Find("fluent-dialog.confirm-dialog").HasAttribute("hidden").Should().BeTrue();
        });
    }

    [Theory]
    [InlineData("Disabled", false, false)]
    [InlineData("GatewayOnly", false, true)]
    [InlineData("Agent365", true, false)]
    [InlineData("Agent365AzureMonitor", true, true)]
    public void OmittedCanonicalDefaults_FallBackToLegacyMode(
        string legacyMode,
        bool expectedAgent365,
        bool expectedAzureMonitor)
    {
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>())
            .Returns(CreateConfig(legacyMode, agent365Enabled: null, azureMonitorEnabled: null));

        var cut = Render<Settings>();
        cut.WaitForElement("form");

        cut.Find("#default-agent365-observability-enabled").HasAttribute("checked")
            .Should().Be(expectedAgent365);
        cut.Find("#default-azure-monitor-export-enabled").HasAttribute("checked")
            .Should().Be(expectedAzureMonitor);
    }

    [Theory]
    [InlineData("Agent365AzureMonitor", false, false)]
    [InlineData("GatewayOnly", true, false)]
    [InlineData("Agent365", false, true)]
    [InlineData("Disabled", true, true)]
    public void CanonicalDefaults_WinOverConflictingLegacyMode(
        string legacyMode,
        bool agent365Enabled,
        bool azureMonitorEnabled)
    {
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>())
            .Returns(CreateConfig(legacyMode, agent365Enabled, azureMonitorEnabled));

        var cut = Render<Settings>();
        cut.WaitForElement("form");

        cut.Find("#default-agent365-observability-enabled").HasAttribute("checked")
            .Should().Be(agent365Enabled);
        cut.Find("#default-azure-monitor-export-enabled").HasAttribute("checked")
            .Should().Be(azureMonitorEnabled);
    }

    [Theory]
    [InlineData(true, false, "Agent365")]
    [InlineData(false, true, "GatewayOnly")]
    [InlineData(true, true, "Agent365AzureMonitor")]
    [InlineData(false, false, "Disabled")]
    public async Task Save_MapsIndependentDefaultsToCanonicalAndLegacyRequestValues(
        bool agent365Enabled,
        bool azureMonitorEnabled,
        string expectedLegacyMode)
    {
        var config = CreateConfig();
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(config);
        _api.UpdateSystemConfigAsync(
                Arg.Any<UpdateSystemConfigRequest>(),
                Arg.Any<string?>(),
                Arg.Any<CancellationToken>())
            .Returns(CreateConfig(expectedLegacyMode, agent365Enabled, azureMonitorEnabled));
        var cut = Render<Settings>();
        cut.WaitForElement("form");
        cut.Find("#default-agent365-observability-enabled").Change(agent365Enabled);
        cut.Find("#default-azure-monitor-export-enabled").Change(azureMonitorEnabled);

        await cut.Find("form").SubmitAsync(EventArgs.Empty);
        await cut.FindAll(".confirm-panel fluent-button").Last().ClickAsync(new MouseEventArgs());

        _ = _api.Received(1).UpdateSystemConfigAsync(
            Arg.Is<UpdateSystemConfigRequest>(request =>
                request.DefaultObservabilityMode == expectedLegacyMode &&
                request.DefaultAgent365ObservabilityEnabled == agent365Enabled &&
                request.DefaultAzureMonitorExportEnabled == azureMonitorEnabled),
            Arg.Any<string?>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public void ProvisioningExecution_IsDescribedAsDeploymentGatedWithoutCliFallbackControls()
    {
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(CreateConfig());

        var cut = Render<Settings>();
        cut.WaitForElement("form");

        cut.Markup.Should().Contain("deployment-gated");
        cut.Markup.Should().Contain("There is no unattended CLI fallback");
        cut.Markup.Should().Contain("reconciliation is not implemented");
        cut.Markup.Should().NotContain("id=\"reconciliation-enabled\"");
        cut.Markup.Should().NotContain("id=\"reconciliation-hours\"");
        cut.Markup.Should().NotContain("id=\"graph-registration\"");
        cut.Markup.Should().NotContain("id=\"cli-fallback\"");
    }

    [Fact]
    public void RateLimits_AreShownAsDistributedEnforcedAndEditable()
    {
        _api.GetSystemConfigAsync(Arg.Any<CancellationToken>()).Returns(CreateConfig());

        var cut = Render<Settings>();
        cut.WaitForElement("form");

        cut.Find("#limits-heading").TextContent.Should().Contain("Requests per minute");
        cut.Markup.Should().Contain("enforces fixed one-minute limits in SQL");
        cut.Markup.Should().Contain("registration limits aggregate rotated keys");
        cut.Find("#limit-client").HasAttribute("disabled").Should().BeFalse();
        cut.Find("#limit-agent").HasAttribute("disabled").Should().BeFalse();
        cut.Find("#limit-global").HasAttribute("disabled").Should().BeFalse();
    }

    private static SystemConfigDto CreateConfig(
        string legacyMode = "Agent365",
        bool? agent365Enabled = true,
        bool? azureMonitorEnabled = false) => new(
        ProvisioningMode: "Automatic",
        DefaultObservabilityMode: legacyMode,
        DefaultPurviewEnabled: false,
        DefaultPurviewMode: "AuditOnly",
        RetentionDaysActivityReceipts: 30,
        RetentionDaysAuditEvents: 90,
        RetentionDaysIdempotencyRecords: 7,
        RetentionDaysOutboxMessages: 14,
        RateLimitPerClient: 100,
        RateLimitPerAgent: 200,
        RateLimitGlobal: 1_000,
        ReconciliationEnabled: true,
        ReconciliationIntervalHours: 24,
        StuckTransitionTimeoutDays: 7,
        UseGraphAgentRegistration: false,
        UseCliProvisioningFallback: true,
        DefaultAgent365ObservabilityEnabled: agent365Enabled,
        DefaultAzureMonitorExportEnabled: azureMonitorEnabled);
}
