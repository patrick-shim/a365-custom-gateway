using Bunit;
using FluentAssertions;
using Gateway.AdminUi.Components.Shared;
using Gateway.Contracts.Dtos;
using Microsoft.AspNetCore.Components.Web;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.FluentUI.AspNetCore.Components;

namespace Gateway.AdminUi.Tests.Components;

public sealed class SharedComponentTests : BunitContext
{
    public SharedComponentTests()
    {
        Services.AddFluentUIComponents();
        JSInterop.Mode = JSRuntimeMode.Loose;
    }

    [Fact]
    public void LoadingState_ExposesPoliteStatusAndContext()
    {
        var cut = Render<LoadingState>(parameters => parameters
            .Add(component => component.Label, "Loading agents…")
            .Add(component => component.Detail, "Checking the registry."));

        var panel = cut.Find("[role='status']");
        panel.GetAttribute("aria-live").Should().Be("polite");
        panel.TextContent.Should().Contain("Loading agents…");
        panel.TextContent.Should().Contain("Checking the registry.");
    }

    [Fact]
    public void EmptyState_RendersAccessibleCopyAndOptionalAction()
    {
        var cut = Render<EmptyState>(parameters => parameters
            .Add(component => component.Title, "No agents found")
            .Add(component => component.Description, "Change the filters and try again.")
            .AddChildContent("Register agent"));

        cut.Find("h2").TextContent.Should().Be("No agents found");
        cut.Markup.Should().Contain("Change the filters and try again.");
        cut.Find(".empty-actions").TextContent.Should().Contain("Register agent");
    }

    [Fact]
    public void ErrorState_ShowsSafeCorrelationIdAndInvokesRetry()
    {
        var retries = 0;
        var cut = Render<ErrorState>(parameters => parameters
            .Add(component => component.Message, "The API is temporarily unavailable.")
            .Add(component => component.CorrelationId, "correlation-789")
            .Add(component => component.OnRetry, () => retries++));

        cut.Find("[role='alert']").TextContent.Should()
            .Contain("The API is temporarily unavailable.");
        cut.Find("code").TextContent.Should().Be("correlation-789");

        cut.Find("fluent-button").Click();

        retries.Should().Be(1);
    }

    [Theory]
    [InlineData("Active", "status-positive", "Active")]
    [InlineData("RequiresManualIntervention", "status-negative", "Manual intervention")]
    [InlineData("AwaitingAdminApproval", "status-progress", "Awaiting approval")]
    [InlineData("Unknown", "status-neutral", "Unknown")]
    public void StatusPill_UsesTextAndClassInAdditionToColor(
        string value,
        string expectedClass,
        string expectedText)
    {
        var cut = Render<StatusPill>(parameters => parameters
            .Add(component => component.Value, value));

        var pill = cut.Find(".status-pill");
        pill.ClassList.Should().Contain(expectedClass);
        pill.GetAttribute("aria-label").Should().Be($"Status: {expectedText}");
        pill.TextContent.Trim().Should().Be(expectedText);
    }

    [Theory]
    [InlineData("NotConnected", "status-neutral", "Not connected")]
    [InlineData("AwaitingAdministrator", "status-progress", "Awaiting admin")]
    [InlineData("PendingPropagation", "status-progress", "Pending propagation")]
    [InlineData("PendingVerification", "status-progress", "Pending verification")]
    [InlineData("VerificationFailed", "status-negative", "Failed")]
    [InlineData("Installed", "status-positive", "Installed")]
    public void StatusPill_FormatsProtectionStatesWithoutRelyingOnColor(
        string value,
        string expectedClass,
        string expectedText)
    {
        var cut = Render<StatusPill>(parameters => parameters
            .Add(component => component.Value, value));

        var pill = cut.Find(".status-pill");
        pill.ClassList.Should().Contain(expectedClass);
        pill.TextContent.Trim().Should().Be(expectedText);
        pill.GetAttribute("aria-label").Should().NotBeNullOrWhiteSpace();
    }

    [Fact]
    public void ProtectionReadinessPanel_ExplainsPendingStateWithoutRawUnknownBlockers()
    {
        var cut = Render<ProtectionReadinessPanel>(parameters => parameters
            .Add(component => component.Label, "Research profile")
            .Add(component => component.Readiness, new ProtectionReadinessDto(
                "Installed",
                "Ready",
                "Pending",
                "NotChecked",
                "NotChecked",
                false,
                ["PropagationPending", "provider-secret-detail"],
                DateTime.UtcNow)));

        cut.Find("[aria-label='Research profile readiness']").Should().NotBeNull();
        cut.Markup.Should().Contain("Pending propagation");
        cut.Markup.Should().Contain("has not made the reviewed change available");
        cut.Markup.Should().Contain("needs administrator attention");
        cut.Markup.Should().NotContain("provider-secret-detail");
    }

    [Fact]
    public void ProtectionOperationTimeline_ShowsSafeProgressAndCorrelationOnly()
    {
        var operation = new ProtectionAdminOperationDto(
            Guid.NewGuid(),
            1,
            "ReconcileDlpProfile",
            "WaitingForPropagation",
            Guid.NewGuid(),
            "actor-object-id",
            "PurviewDlpProfile",
            "provider-target-id",
            "payload-hash",
            Guid.NewGuid(),
            "row-version",
            "Scheduled",
            1,
            5,
            DateTime.UtcNow.AddMinutes(5),
            false,
            false,
            Guid.Parse("2eeb83c2-8a23-407c-9057-c410e5514387"),
            null,
            "provider-failure-code",
            "WaitForPropagation",
            ["PropagationPending"],
            DateTime.UtcNow.AddMinutes(-2),
            DateTime.UtcNow.AddMinutes(-1),
            null,
            DateTime.UtcNow,
            [
                new ProtectionAdminOperationStepDto(
                    Guid.NewGuid(),
                    0,
                    "DiscoverProviderState",
                    "Completed",
                    1,
                    "None",
                    null,
                    false,
                    false,
                    null,
                    null,
                    DateTime.UtcNow.AddMinutes(-1),
                    DateTime.UtcNow)
            ],
            "operation-row");

        var cut = Render<ProtectionOperationTimeline>(parameters => parameters
            .Add(component => component.Operation, operation));

        cut.Find(".operation-panel").GetAttribute("aria-live").Should().Be("polite");
        cut.Markup.Should().Contain("Pending propagation");
        cut.Markup.Should().Contain("Discover Provider State");
        cut.Markup.Should().Contain(operation.CorrelationId.ToString());
        cut.Markup.Should().NotContain("provider-target-id");
        cut.Markup.Should().NotContain("payload-hash");
        cut.Markup.Should().NotContain("provider-failure-code");
        cut.Markup.Should().NotContain("actor-object-id");
    }

    [Fact]
    public async Task CopyableCommand_IsReadonlyLabelledAndReportsCopy()
    {
        const string command =
            "pwsh -NoLogo -NoProfile -File '.\\Connect-PurviewTenant.ps1' -OperationId '00000000-0000-4000-8000-000000000001'";
        var cut = Render<CopyableCommand>(parameters => parameters
            .Add(component => component.Command, command));

        var field = cut.Find("textarea");
        field.HasAttribute("readonly").Should().BeTrue();
        field.GetAttribute("aria-describedby").Should().NotBeNullOrWhiteSpace();
        field.TextContent.Should().Be(command);
        cut.Find("label").GetAttribute("for").Should().Be(field.Id);

        await cut.Find("fluent-button").ClickAsync(new MouseEventArgs());

        cut.Find("[role='status']").TextContent.Should().Contain("Command copied");
        JSInterop.Invocations.Should().ContainSingle(invocation =>
            invocation.Identifier == "A365Gateway.copyTextFrom");
    }

    [Fact]
    public void ConfirmPanel_WhenBusy_DisablesActionsAndIgnoresBackdropCancellation()
    {
        var cancellations = 0;
        var cut = Render<ConfirmPanel>(parameters => parameters
            .Add(component => component.Visible, true)
            .Add(component => component.Busy, true)
            .Add(component => component.Title, "Disable agent")
            .Add(component => component.Message, "Traffic will stop immediately.")
            .Add(component => component.OnCancel, () => cancellations++));

        var dialog = cut.Find("[role='alertdialog']");
        dialog.GetAttribute("aria-modal").Should().Be("true");
        dialog.TextContent.Should().Contain("Working…");
        cut.FindAll("fluent-button").Should().OnlyContain(button =>
            button.HasAttribute("disabled"));

        var fluentDialog = cut.FindComponent<FluentDialog>().Instance;
        fluentDialog.Modal.Should().BeTrue();
        fluentDialog.TrapFocus.Should().BeTrue();
        fluentDialog.PreventScroll.Should().BeTrue();
        cut.InvokeAsync(() => fluentDialog.HiddenChanged.InvokeAsync(true));

        cancellations.Should().Be(0);
    }
}
