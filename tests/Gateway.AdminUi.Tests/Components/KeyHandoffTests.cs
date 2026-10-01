using Bunit;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Microsoft.AspNetCore.Components;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.JSInterop;

namespace Gateway.AdminUi.Tests.Components;

public sealed class KeyHandoffTests
{
    [Fact]
    public async Task Leaving_an_unsaved_key_requires_confirmation_and_cancel_preserves_the_display()
    {
        using var fixture = CoreUiData.Create();
        var navigation = fixture.Services.GetRequiredService<NavigationManager>();
        navigation.NavigateTo("/agents/register");
        var discarded = 0;
        var handoff = fixture.Render<GatewayKeyHandoff>(parameters => parameters
            .Add(item => item.ExternalAgentId, CoreUiData.ExternalId)
            .Add(item => item.Credential, CoreUiData.Credential)
            .Add(item => item.OnDiscard, () => discarded++));
        await handoff.InvokeAsync(() => navigation.NavigateTo("/agents"));
        handoff.WaitForAssertion(() => Assert.True(handoff.FindComponent<ConfirmPanel>().Instance.Visible));
        await AdminUiFixture.ClickAsync(handoff, "Stay and save key");
        Assert.Equal(0, discarded);
        Assert.Equal(CoreUiData.Key, handoff.Find("#gateway-api-key").GetAttribute("value"));
        await handoff.InvokeAsync(() => navigation.NavigateTo("/agents"));
        await AdminUiFixture.ClickAsync(handoff, "Leave and hide key");
        Assert.Equal(1, discarded);
        Assert.EndsWith("/agents", navigation.Uri, StringComparison.Ordinal);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Copy_feedback_reports_the_actual_script_result_without_passing_the_key_as_an_argument(bool denied)
    {
        using var fixture = CoreUiData.Create();
        var script = fixture.JSInterop.SetupVoid("A365Gateway.copyTextFrom", _ => true);
        if (denied) script.SetException(new JSException("Synthetic clipboard denial."));
        else script.SetVoidResult();
        var value = fixture.Render<CopyableValue>(parameters => parameters
            .Add(item => item.Label, "One-time Gateway key")
            .Add(item => item.Value, CoreUiData.Key));
        await AdminUiFixture.ClickAsync(value, "Copy");
        Assert.Contains(denied ? "Copy is unavailable" : "Copied to clipboard.", value.Markup);
        if (denied) Assert.DoesNotContain("Copied to clipboard.", value.Markup);
        var invocation = Assert.Single(fixture.JSInterop.Invocations, item => item.Identifier == "A365Gateway.copyTextFrom");
        Assert.IsType<ElementReference>(Assert.Single(invocation.Arguments));
        fixture.AssertComplete();
    }

    [Fact]
    public void Automatic_handoff_is_bound_to_both_registration_and_operation_and_is_single_use()
    {
        var state = new RegistrationHandoffState();
        state.RecordSavedCredential(CoreUiData.OperationId, CoreUiData.AgentId);
        Assert.False(state.TryConsumeAutomaticCompletion(Guid.NewGuid(), CoreUiData.AgentId));
        Assert.False(state.TryConsumeAutomaticCompletion(CoreUiData.OperationId, Guid.NewGuid()));
        Assert.True(state.TryConsumeAutomaticCompletion(CoreUiData.OperationId, CoreUiData.AgentId));
        Assert.False(state.TryConsumeAutomaticCompletion(CoreUiData.OperationId, CoreUiData.AgentId));
        Assert.Throws<ArgumentException>(() => state.RecordSavedCredential(Guid.Empty, CoreUiData.AgentId));
        Assert.Throws<ArgumentException>(() => state.RecordSavedCredential(CoreUiData.OperationId, Guid.Empty));
    }

    [Fact]
    public void Connection_example_is_nonsecret_and_quotes_its_arguments()
    {
        var command = GatewayConnectionCommand.CreateSample(new Uri("https://gateway.example.invalid/"), "agent'example");
        Assert.Contains("'agent''example'", command);
        Assert.Contains(@".\src\ExternalAgent.Sample", command);
        Assert.DoesNotContain(CoreUiData.Key, command);
        Assert.DoesNotContain("--api-key", command, StringComparison.OrdinalIgnoreCase);
        Assert.False(GatewayConnectionCommand.IsShareableEndpoint(new Uri("https://user:password@example.invalid/")));
        Assert.False(GatewayConnectionCommand.IsShareableEndpoint(new Uri("https://gateway.example.invalid/?token=synthetic")));
        Assert.False(GatewayConnectionCommand.IsShareableEndpoint(new Uri("http://gateway.example.invalid/")));
        Assert.True(GatewayConnectionCommand.IsShareableEndpoint(new Uri("http://127.0.0.1:1234/")));
        Assert.False(GatewayConnectionCommand.SupportsSample(new Uri("http://127.0.0.1:1234/")));
        Assert.Throws<ArgumentException>(() => GatewayConnectionCommand.CreateSample(new Uri("http://127.0.0.1:1234/"), "fixture-agent"));
    }

    [Fact]
    public void Local_http_handoff_displays_the_endpoint_but_does_not_offer_an_unusable_command()
    {
        using var fixture = CoreUiData.Create();
        fixture.Services.Configure<Gateway.AdminUi.Options.GatewayApiOptions>(options =>
            options.BaseUrl = new Uri("http://127.0.0.1:1234/"));
        var handoff = fixture.Render<GatewayKeyHandoff>(parameters => parameters
            .Add(item => item.ExternalAgentId, CoreUiData.ExternalId)
            .Add(item => item.Credential, CoreUiData.Credential));
        Assert.Equal("http://127.0.0.1:1234/", handoff.Find("#handoff-api-endpoint").GetAttribute("value"));
        Assert.Contains("sample requires HTTPS", handoff.Markup);
        Assert.Empty(handoff.FindAll("textarea"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Confirmation_instances_have_distinct_accessible_identifiers()
    {
        using var fixture = CoreUiData.Create();
        var first = fixture.Render<ConfirmPanel>(parameters => parameters.Add(item => item.Visible, true).Add(item => item.Title, "First review"));
        var second = fixture.Render<ConfirmPanel>(parameters => parameters.Add(item => item.Visible, true).Add(item => item.Title, "Second review"));
        Assert.NotEqual(first.Find("h2").Id, second.Find("h2").Id);
        Assert.Equal(first.Find("h2").Id, first.Find("[role='alertdialog']").GetAttribute("aria-labelledby"));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Hidden_confirmation_rejects_a_late_button_callback()
    {
        using var fixture = CoreUiData.Create();
        var confirmed = 0;
        var panel = fixture.Render<ConfirmPanel>(parameters => parameters
            .Add(item => item.Visible, true)
            .Add(item => item.OnConfirm, () => confirmed++));
        var callback = panel.FindComponents<Microsoft.FluentUI.AspNetCore.Components.FluentButton>()
            .Single(item => item.Find("fluent-button").TextContent.Trim() == "Confirm").Instance.OnClick;
        panel.Render(parameters => parameters.Add(item => item.Visible, false));
        await panel.InvokeAsync(() => callback.InvokeAsync(new Microsoft.AspNetCore.Components.Web.MouseEventArgs()));
        Assert.Equal(0, confirmed);
        fixture.AssertComplete();
    }
}
