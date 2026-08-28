using Bunit;
using FluentAssertions;
using Gateway.AdminUi.Components.Shared;
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
        pill.GetAttribute("aria-label").Should().Be($"Status: {value}");
        pill.TextContent.Trim().Should().Be(expectedText);
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
