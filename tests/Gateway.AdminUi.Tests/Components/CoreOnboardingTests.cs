using System.Net;
using Bunit;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Components;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.AdminUi.Tests.Components;

public sealed class CoreOnboardingTests
{
    [Fact]
    public async Task Registration_waits_for_browser_recovery_retention_before_dispatch()
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectRegistration(fixture);
        var retention = fixture.JSInterop.Setup<bool>("A365Gateway.retainRegistrationRecovery", _ => true);
        var page = fixture.Render<RegisterAgent>();
        await FillRegistration(page);
        await page.Find("#registration-form").SubmitAsync();
        var externalId = page.Find("#external-agent-id").GetAttribute("value")!;
        fixture.Script.Return(nameof(IGatewayApiClient.RegisterAgentAsync), CoreUiData.Registered(externalId));
        var submit = AdminUiFixture.ClickAsync(ActiveReview(page), "Register and show key");
        page.WaitForAssertion(() => Assert.Contains(fixture.JSInterop.Invocations,
            call => call.Identifier == "A365Gateway.retainRegistrationRecovery"));
        Assert.DoesNotContain(nameof(IGatewayApiClient.RegisterAgentAsync), fixture.Script.Calls);
        retention.SetResult(true);
        await submit;
        Assert.NotEmpty(page.FindAll("#gateway-api-key"));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Failed_or_disconnected_browser_retention_sends_no_registration(bool disconnected)
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectRegistration(fixture);
        var retention = fixture.JSInterop.Setup<bool>("A365Gateway.retainRegistrationRecovery", _ => true);
        if (disconnected) retention.SetException(new Microsoft.JSInterop.JSDisconnectedException("Synthetic disconnected circuit."));
        else retention.SetResult(false);
        var page = fixture.Render<RegisterAgent>();
        await FillRegistration(page);
        await page.Find("#registration-form").SubmitAsync();
        await AdminUiFixture.ClickAsync(ActiveReview(page), "Register and show key");
        Assert.DoesNotContain(nameof(IGatewayApiClient.RegisterAgentAsync), fixture.Script.Calls);
        Assert.Empty(page.FindAll("#gateway-api-key"));
        Assert.NotEmpty(page.FindAll("[role='alert']"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Prerendered_registration_cannot_accept_edits_before_the_interactive_instance_exists()
    {
        using var fixture = CoreUiData.Create();
        fixture.Rendering = new RendererInfo("Static", isInteractive: false);
        CoreUiData.ExpectRegistration(fixture);
        var page = fixture.Render<RegisterAgent>();
        Assert.True(page.Find(".registration-fields").HasAttribute("disabled"));
        Assert.Equal("true", page.Find("#registration-form").GetAttribute("aria-busy"));
        Assert.DoesNotContain(nameof(IGatewayApiClient.RegisterAgentAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(typeof(RegisterAgent), "Gateway Administrator")]
    [InlineData(typeof(OperationStatus), "Gateway Administrator or Gateway Operator")]
    [InlineData(typeof(AgentDetails), "an assigned Gateway control-plane role")]
    public void Restricted_route_wording_comes_from_the_actual_page_authorization(Type page, string required)
    {
        Assert.Equal(required, Gateway.AdminUi.Authentication.GatewayPolicies.DescribeRequiredAccess(page));
    }

    [Theory]
    [InlineData("Gateway.Administrator", true)]
    [InlineData("Gateway.Operator", false)]
    [InlineData("Gateway.Auditor", false)]
    [InlineData("Gateway.SupportReader", false)]
    public void Ready_getting_started_has_the_correct_handoff_order_and_role_actions(string role, bool administrator)
    {
        using var fixture = CoreUiData.Create(role);
        CoreUiData.ExpectSetup(fixture, administrator);
        var page = fixture.Render<SetupCenter>();
        page.WaitForAssertion(() => Assert.Contains("Connect your agent", page.Markup));
        var steps = page.FindAll(".first-run-list h3").Select(item => item.TextContent).ToArray();
        Assert.Equal([
            "Choose the agent and its blueprint",
            "Save the one-time Gateway key",
            "Complete Agent 365 setup",
            "Connect and send an interaction"
        ], steps);
        Assert.Equal(administrator, page.FindAll("fluent-anchor[href='/agents/register']").Count > 0);
        Assert.Contains("Both off is a complete core registration", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public void Missing_totals_remain_qualified_in_getting_started()
    {
        using var fixture = CoreUiData.Create("Gateway.SupportReader");
        CoreUiData.ExpectSetup(fixture, administrator: false, count: null);
        var page = fixture.Render<SetupCenter>();
        page.WaitForAssertion(() => Assert.Contains("total is unavailable", page.Markup));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("UseExisting")]
    [InlineData("CreateNew")]
    public async Task Registration_reviews_exact_choices_then_saves_the_key_before_allowing_operation_handoff(string mode)
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectRegistration(fixture, CoreUiData.Config(agent365: false, mirror: true));
        var navigation = fixture.Services.GetRequiredService<NavigationManager>();
        navigation.NavigateTo("/agents/register");
        var page = fixture.Render<RegisterAgent>();
        await FillRegistration(page, mode);
        Assert.Equal(["Give your agent a name", "Choose a reusable blueprint", "Choose what this agent uses"],
            page.FindAll("#identity-heading, #blueprint-heading, #features-heading").Select(item => item.TextContent).ToArray());
        var externalId = page.Find("#external-agent-id").GetAttribute("value")!;
        Assert.Null(page.Find("#agent365-observability-enabled").GetAttribute("checked"));
        Assert.NotNull(page.Find("#azure-monitor-export-enabled").GetAttribute("checked"));

        await page.Find("#registration-form").SubmitAsync();
        Assert.DoesNotContain(nameof(IGatewayApiClient.RegisterAgentAsync), fixture.Script.Calls);
        Assert.Contains("Review registration", ActiveReview(page).Markup);
        fixture.Script.Expect<RegisterAgentResponse>(nameof(IGatewayApiClient.RegisterAgentAsync), arguments =>
        {
            var request = Assert.IsType<RegisterAgentRequest>(arguments[0]);
            Assert.Equal(externalId, request.ExternalAgentId);
            Assert.Equal(mode, request.Blueprint!.Mode);
            Assert.Equal(mode == "UseExisting" ? CoreUiData.BlueprintId.ToString("D") : null, request.Blueprint.BlueprintObjectId);
            Assert.Equal(mode == "CreateNew" ? "New fixture blueprint" : null, request.Blueprint.DisplayName);
            Assert.False(request.Features!.Agent365ObservabilityEnabled);
            Assert.True(request.Features.AzureMonitorExportEnabled);
            Assert.False(request.Features.PurviewEnabled);
            Assert.Null(request.PurviewConfigurationIntent);
            return Task.FromResult(CoreUiData.Registered(externalId));
        });
        await AdminUiFixture.ClickAsync(ActiveReview(page), "Register and show key");
        page.WaitForAssertion(() => Assert.Equal(CoreUiData.Key, page.Find("#gateway-api-key").GetAttribute("value")));
        Assert.Contains("pendingExternalId=", navigation.Uri);
        Assert.DoesNotContain(CoreUiData.Key, navigation.Uri);
        Assert.DoesNotContain(CoreUiData.Key, page.Find("textarea").TextContent);
        Assert.Contains(externalId, page.Find("textarea").TextContent);
        Assert.DoesNotContain(nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync), fixture.Script.Calls);
        await AdminUiFixture.ClickAsync(page, "Continue to agent setup");
        Assert.DoesNotContain("/operations/", navigation.Uri);

        page.Find("#saved-gateway-key").Change(true);
        await AdminUiFixture.ClickAsync(page, "Continue to agent setup");
        Assert.EndsWith($"/operations/{CoreUiData.OperationId}", navigation.Uri, StringComparison.Ordinal);
        Assert.DoesNotContain(CoreUiData.Key, page.Markup);
        var handoff = fixture.Services.GetRequiredService<RegistrationHandoffState>();
        Assert.True(handoff.TryConsumeAutomaticCompletion(CoreUiData.OperationId, CoreUiData.AgentId));
        Assert.False(handoff.TryConsumeAutomaticCompletion(CoreUiData.OperationId, CoreUiData.AgentId));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Validation_and_cancel_do_not_send_registration()
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectRegistration(fixture);
        var page = fixture.Render<RegisterAgent>();
        await page.Find("#registration-form").SubmitAsync();
        Assert.DoesNotContain(page.FindComponents<ConfirmPanel>(), item => item.Instance.Visible);
        Assert.Contains("required", page.Markup, StringComparison.OrdinalIgnoreCase);
        await FillRegistration(page);
        await page.Find("#registration-form").SubmitAsync();
        await AdminUiFixture.ClickAsync(ActiveReview(page), "Cancel");
        Assert.Equal("Core fixture agent", page.Find("#agent-name").GetAttribute("value"));
        Assert.DoesNotContain(nameof(IGatewayApiClient.RegisterAgentAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Duplicate_submission_has_only_one_in_flight_create()
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectRegistration(fixture);
        var page = fixture.Render<RegisterAgent>();
        await FillRegistration(page);
        await page.Find("#registration-form").SubmitAsync();
        var externalId = page.Find("#external-agent-id").GetAttribute("value")!;
        var pending = new TaskCompletionSource<RegisterAgentResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Script.Expect(nameof(IGatewayApiClient.RegisterAgentAsync), _ => pending.Task);
        var confirmation = ActiveReview(page);
        var first = AdminUiFixture.ClickAsync(confirmation, "Register and show key");
        page.WaitForAssertion(() => Assert.Single(fixture.Script.Calls, item => item == nameof(IGatewayApiClient.RegisterAgentAsync)));
        await page.Find("#registration-form").SubmitAsync();
        await AdminUiFixture.ClickAsync(confirmation, "Working\u2026");
        pending.SetResult(CoreUiData.Registered(externalId));
        await first;
        page.WaitForAssertion(() => Assert.NotEmpty(page.FindAll("#gateway-api-key")));
        Assert.Single(fixture.Script.Calls, item => item == nameof(IGatewayApiClient.RegisterAgentAsync));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Interrupted_create_recovers_by_exact_external_id_without_repeating_creation()
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectRegistration(fixture);
        var navigation = fixture.Services.GetRequiredService<NavigationManager>();
        navigation.NavigateTo("/agents/register");
        var page = fixture.Render<RegisterAgent>();
        await FillRegistration(page);
        await page.Find("#registration-form").SubmitAsync();
        var externalId = page.Find("#external-agent-id").GetAttribute("value")!;
        fixture.Script.Expect<RegisterAgentResponse>(nameof(IGatewayApiClient.RegisterAgentAsync), _ =>
            Task.FromException<RegisterAgentResponse>(new GatewayApiTransportException("Interrupted fixture response.",
                "fixture-correlation", new HttpRequestException("No remote transport was used."))));
        await AdminUiFixture.ClickAsync(ActiveReview(page), "Register and show key");
        Assert.Empty(page.FindAll("#registration-form"));
        Assert.Contains("pendingExternalId=", navigation.Uri);
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentsAsync), new AgentListResponse([
            CoreUiData.Summary("name-only-match", Guid.NewGuid()) with { Name = externalId },
            CoreUiData.Summary(externalId)
        ], null, 2), arguments =>
        {
            var query = Assert.IsType<AgentListQuery>(arguments[0]);
            Assert.Equal(externalId, query.Search);
        });
        await AdminUiFixture.ClickAsync(page, "Check existing registration");
        Assert.Contains($"/agents/{CoreUiData.AgentId}", page.Markup);
        Assert.Single(fixture.Script.Calls, item => item == nameof(IGatewayApiClient.RegisterAgentAsync));
        Assert.Empty(page.FindAll("#gateway-api-key"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Reopening_a_pending_recovery_link_never_loads_a_create_form_or_requests_an_old_key()
    {
        using var fixture = CoreUiData.Create();
        fixture.Services.GetRequiredService<NavigationManager>().NavigateTo($"/agents/register?pendingExternalId={CoreUiData.ExternalId}");
        var page = fixture.Render<RegisterAgent>();
        Assert.Empty(page.FindAll("#registration-form"));
        Assert.Contains(CoreUiData.ExternalId, page.Markup);
        Assert.Empty(fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("missing-key")]
    [InlineData("expired-key")]
    [InlineData("wrong-external-id")]
    [InlineData("missing-agent")]
    public async Task Incomplete_or_mismatched_acceptance_never_reveals_a_key_or_allows_blind_resubmit(string failure)
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectRegistration(fixture);
        var page = fixture.Render<RegisterAgent>();
        await FillRegistration(page);
        await page.Find("#registration-form").SubmitAsync();
        var response = CoreUiData.Registered(page.Find("#external-agent-id").GetAttribute("value")!);
        response = failure switch
        {
            "missing-key" => response with { GatewayCredential = null },
            "expired-key" => response with { GatewayCredential = CoreUiData.Credential with { ExpiresAtUtc = CoreUiData.Now.UtcDateTime } },
            "wrong-external-id" => response with { ExternalAgentId = "different-agent" },
            _ => response with { AgentId = Guid.Empty }
        };
        fixture.Script.Return(nameof(IGatewayApiClient.RegisterAgentAsync), response);
        await AdminUiFixture.ClickAsync(ActiveReview(page), "Register and show key");
        Assert.Empty(page.FindAll("#gateway-api-key"));
        Assert.Empty(page.FindAll("#registration-form"));
        Assert.Contains("Registration result needs checking", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Definite_validation_rejection_preserves_fields_and_allows_a_new_review()
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectRegistration(fixture);
        var navigation = fixture.Services.GetRequiredService<NavigationManager>();
        navigation.NavigateTo("/agents/register");
        var page = fixture.Render<RegisterAgent>();
        await FillRegistration(page);
        var externalId = page.Find("#external-agent-id").GetAttribute("value")!;
        await page.Find("#registration-form").SubmitAsync();
        fixture.Script.Expect<RegisterAgentResponse>(nameof(IGatewayApiClient.RegisterAgentAsync), _ =>
            Task.FromException<RegisterAgentResponse>(CoreUiData.Error(HttpStatusCode.BadRequest, validation: true)));
        await AdminUiFixture.ClickAsync(ActiveReview(page), "Register and show key");
        Assert.Contains("Choose another agent name", page.Markup);
        Assert.DoesNotContain("pendingExternalId", navigation.Uri);
        page.Find("#agent-name").Change("Another fixture agent");
        await page.Find("#registration-form").SubmitAsync();
        Assert.NotNull(ActiveReview(page));
        Assert.Equal(externalId, page.Find("#external-agent-id").GetAttribute("value"));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public async Task Unavailable_requested_protection_defaults_require_an_explicit_off_choice(bool shields, bool purview)
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectRegistration(fixture, CoreUiData.Config() with
        {
            DefaultPromptShieldEnabled = shields,
            PromptShieldAvailable = shields,
            DefaultPurviewEnabled = purview
        });
        var page = fixture.Render<RegisterAgent>();
        await FillRegistration(page);
        var configuration = page.FindComponent<AgentProtectionConfiguration>();
        Assert.Equal(shields, configuration.Instance.Selection.PromptShieldsEnabled);
        Assert.Equal(purview, configuration.Instance.Selection.PurviewEnabled);
        Assert.False(configuration.Instance.CanApply);
        await page.Find("#registration-form").SubmitAsync();
        Assert.DoesNotContain(page.FindComponents<ConfirmPanel>(), item => item.Instance.Visible);
        var editor = configuration.FindComponent<AgentProtectionEditor>();
        await page.InvokeAsync(() => editor.Instance.ValueChanged.InvokeAsync(editor.Instance.Value with
        {
            PromptShieldsEnabled = false,
            PurviewEnabled = false
        }));
        Assert.True(configuration.Instance.CanApply);
        await page.Find("#registration-form").SubmitAsync();
        Assert.NotNull(ActiveReview(page));
        Assert.False(configuration.Instance.Selection.PromptShieldsEnabled);
        Assert.False(configuration.Instance.Selection.PurviewEnabled);
        fixture.AssertComplete();
    }

    internal static async Task FillRegistration(IRenderedComponent<RegisterAgent> page, string mode = "UseExisting")
    {
        page.WaitForAssertion(() => Assert.NotEmpty(page.FindAll("#agent-name")));
        page.Find("#agent-name").Change("Core fixture agent");
        page.Find("#blueprint-mode").Change(mode);
        if (mode == "CreateNew") page.Find("#new-blueprint-display-name").Change("New fixture blueprint");
        else page.Find("#existing-blueprint").Change(CoreUiData.BlueprintId.ToString("D"));
        await page.InvokeAsync(() => { });
    }

    private static IRenderedComponent<ConfirmPanel> ActiveReview(IRenderedComponent<RegisterAgent> page) =>
        page.FindComponents<ConfirmPanel>().Single(item => item.Instance.Visible && item.Instance.Title == "Review registration");
}
