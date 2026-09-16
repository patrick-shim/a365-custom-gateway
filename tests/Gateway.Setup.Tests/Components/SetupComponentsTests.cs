using Bunit;
using FluentAssertions;
using Gateway.Setup.Components.Pages;
using Gateway.Setup.Services;
using Gateway.Setup.Tests.Fixtures;
using Microsoft.AspNetCore.Components;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.FluentUI.AspNetCore.Components;

namespace Gateway.Setup.Tests.Components;

public sealed class SetupComponentsTests
{
    [Fact]
    public async Task Welcome_EmptyFixtureReadsNoProviderOrExistingMachineConfiguration()
    {
        await using var fixture = new OfflineSetupFixture();

        var page = fixture.Context.Render<Welcome>();

        page.Markup.Should().Contain("Nothing has been written or deployed yet.");
        page.FindComponent<FluentButton>().Instance.Disabled.Should().BeFalse();
        page.FindAll("input[type=password]").Should().BeEmpty();
        fixture.ConfigLoader.CallCount.Should().Be(1);
        fixture.Discovery.AccountCalls.Should().Be(0);
        fixture.ProcessRunner.Calls.Should().BeEmpty();
        fixture.AssertProviderIsolation();
    }

    [Fact]
    public async Task Welcome_RejectedConfigurationFixtureBlocksContinuation()
    {
        await using var fixture = new OfflineSetupFixture();
        fixture.ConfigLoader.Result = new ExistingConfigurationResult(
            ExistingConfigurationStatus.Rejected, null, "Offline fixture: unsupported public configuration.");

        var page = fixture.Context.Render<Welcome>();

        page.Find("[role=alert]").TextContent.Should().Contain("protected from overwrite");
        page.FindComponent<FluentButton>().Instance.Disabled.Should().BeTrue();
        fixture.State.WelcomeAccepted.Should().BeFalse();
        fixture.ProcessRunner.Calls.Should().BeEmpty();
        fixture.AssertProviderIsolation();
    }

    [Fact]
    public async Task Account_LoadingThenEmptyFixtureNeverEnablesContinuation()
    {
        await using var fixture = new OfflineSetupFixture();
        fixture.State.AcceptWelcome();
        var pending = new TaskCompletionSource<AzureAccountDiscoveryResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Discovery.Accounts = pending.Task;

        var page = fixture.Context.Render<AzureAccount>();

        page.Find("[role=status]").TextContent.Should().Contain("Reading the bounded Azure subscription inventory");
        page.FindComponents<FluentButton>().Should().OnlyContain(button => button.Instance.Disabled);
        pending.SetResult(new AzureAccountDiscoveryResult([], null));
        page.WaitForAssertion(() =>
        {
            page.Find("[role=alert]").TextContent.Should().Contain("No enabled Azure subscription");
            page.FindComponents<FluentButton>().Last().Instance.Disabled.Should().BeTrue();
        });
        fixture.Discovery.AccountCalls.Should().Be(1);
        fixture.State.HasEnabledSelectedSubscription.Should().BeFalse();
        fixture.ProcessRunner.Calls.Should().BeEmpty();
        fixture.AssertProviderIsolation();
    }

    [Fact]
    public async Task Account_ErrorFixtureOffersOnlyTheTerminalHandoff()
    {
        await using var fixture = new OfflineSetupFixture();
        fixture.State.AcceptWelcome();
        fixture.Discovery.Accounts = Task.FromResult(new AzureAccountDiscoveryResult(
            [], "Offline fixture: account inventory unavailable."));

        var page = fixture.Context.Render<AzureAccount>();

        page.Markup.Should().Contain("account inventory unavailable");
        page.Find("pre").TextContent.Should().Be("az login");
        page.FindAll("input").Should().BeEmpty();
        page.FindComponents<FluentButton>().Last().Instance.Disabled.Should().BeTrue();
        fixture.ProcessRunner.Calls.Should().BeEmpty();
        fixture.AssertProviderIsolation();
    }

    [Fact]
    public async Task Profile_FormValidationRejectsInvalidPublicValuesWithoutPublishingOrStartingAProcess()
    {
        await using var fixture = new OfflineSetupFixture();
        SetupFixtureValues.MakeReady(fixture.State);
        var page = fixture.Context.Render<ProfileFeatures>();
        var navigation = fixture.Context.Services.GetRequiredService<NavigationManager>();
        var initialUri = navigation.Uri;

        page.Find("#project-name").Input("INVALID PROJECT");
        page.Find("#alert-email").Input("not-an-email");
        page.Find("form").Submit();

        page.Find(".validation-errors").TextContent.Should().Contain("ProjectName").And.Contain("AlertEmail");
        navigation.Uri.Should().Be(initialUri);
        fixture.State.ConfigurationWritten.Should().BeFalse();
        fixture.Discovery.LocationCalls.Should().Be(0);
        fixture.Discovery.ManagerCalls.Should().Be(0);
        fixture.ProcessRunner.Calls.Should().BeEmpty();
        fixture.AssertProviderIsolation();
    }

    [Fact]
    public async Task Profile_ChangingSharedPromptShieldsSkuRevokesTheCostAcknowledgement()
    {
        await using var fixture = new OfflineSetupFixture();
        SetupFixtureValues.MakeReady(fixture.State);
        var page = fixture.Context.Render<ProfileFeatures>();

        page.Find("#prompt-sku").Change("S0");

        fixture.State.Form.PromptShieldEnabled.Should().BeTrue();
        fixture.State.Form.PromptShieldSkuName.Should().Be("S0");
        fixture.State.Form.PromptShieldCostAndQuotaAcknowledged.Should().BeFalse();
        page.FindComponents<FluentButton>().Last().Instance.Disabled.Should().BeTrue();
        fixture.ProcessRunner.Calls.Should().BeEmpty();
        fixture.AssertProviderIsolation();
    }

    [Fact]
    public async Task Permissions_AnUnconfirmedClickCannotStageConfigurationOrStartPlan()
    {
        await using var fixture = new OfflineSetupFixture();
        SetupFixtureValues.MakeReady(fixture.State);
        var page = fixture.Context.Render<PermissionsPlan>();
        var button = page.FindComponent<FluentButton>();

        button.Instance.Disabled.Should().BeTrue();
        await page.InvokeAsync(() => button.Instance.OnClick.InvokeAsync());

        fixture.State.ConfigurationWritten.Should().BeFalse();
        fixture.ProcessRunner.Calls.Should().BeEmpty();
        fixture.AssertProviderIsolation();
    }

    [Fact]
    public async Task Progress_EmptyFixtureDoesNotAutomaticallyStartACommand()
    {
        await using var fixture = new OfflineSetupFixture();
        fixture.State.MarkConfigurationWritten("offline-fixture-only");

        var page = fixture.Context.Render<Progress>();

        page.Markup.Should().Contain("No command is running");
        page.FindAll(".event-item").Should().BeEmpty();
        fixture.ProcessRunner.Calls.Should().BeEmpty();
        fixture.AssertProviderIsolation();
    }

    [Fact]
    public async Task Progress_FakeProcessTransitionsFromRunningToFailureWithoutClaimingReadiness()
    {
        await using var fixture = new OfflineSetupFixture();
        fixture.State.MarkConfigurationWritten("offline-fixture-only");
        var pending = fixture.ProcessRunner.Hold("unstructured fixture secret must not render");
        using var lease = fixture.Execution.TryAcquirePlanPreparation(explicitlyConfirmed: true);
        lease!.TryStartPlan(SetupFixtureValues.Fingerprint).Should().BeTrue();
        var page = fixture.Context.Render<Progress>();

        page.Markup.Should().Contain("Running Plan").And.NotContain("unstructured fixture secret");
        page.Find(".run-spinner").GetAttribute("aria-label").Should().Be("Working");
        fixture.Execution.TryStartResumeReview().Should().BeFalse();
        pending.SetResult(new BootstrapProcessResult(1, false));

        page.WaitForAssertion(() =>
        {
            page.Markup.Should().Contain("Plan did not pass");
            page.FindAll(".run-spinner").Should().BeEmpty();
            page.FindAll("fluent-button").Should().BeEmpty();
        });
        fixture.Execution.Snapshot().PlanSucceeded.Should().BeFalse();
        fixture.Execution.Snapshot().HasVerifiedDeployment.Should().BeFalse();
        fixture.ProcessRunner.Calls.Should().ContainSingle();
        fixture.AssertProviderIsolation();
    }

    [Fact]
    public async Task Progress_ApplyReadyFixtureStillRequiresASeparateExplicitConfirmation()
    {
        await using var fixture = new OfflineSetupFixture();
        fixture.State.MarkConfigurationWritten("offline-fixture-only");
        var pending = fixture.ProcessRunner.Hold(SetupFixtureValues.PlanResult);
        using var lease = fixture.Execution.TryAcquirePlanPreparation(explicitlyConfirmed: true);
        lease!.TryStartPlan(SetupFixtureValues.Fingerprint).Should().BeTrue();
        var page = fixture.Context.Render<Progress>();
        pending.SetResult(new BootstrapProcessResult(0, false));

        page.WaitForAssertion(() =>
        {
            page.Markup.Should().Contain("The reviewed plan is ready to deploy");
            page.FindComponent<FluentButton>().Instance.Disabled.Should().BeTrue();
        });
        fixture.Execution.Snapshot().HasVerifiedDeployment.Should().BeFalse();
        fixture.ProcessRunner.Calls.Should().ContainSingle();
        fixture.AssertProviderIsolation();
    }
}
