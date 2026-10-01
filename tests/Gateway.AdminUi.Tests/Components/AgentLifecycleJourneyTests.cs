using System.Net;
using Bunit;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Components.Web;
using Microsoft.FluentUI.AspNetCore.Components;

namespace Gateway.AdminUi.Tests.Components;

public sealed class AgentLifecycleJourneyTests
{
    [Theory]
    [InlineData("Gateway.Administrator", true, true, true)]
    [InlineData("Gateway.Operator", false, true, false)]
    [InlineData("Gateway.Auditor", false, false, true)]
    [InlineData("Gateway.SupportReader", false, false, false)]
    public void Details_fetch_and_render_only_role_permitted_history_and_credentials(
        string role, bool credentials, bool operations, bool audit)
    {
        using var fixture = CoreUiData.Create(role);
        CoreUiData.ExpectDetails(fixture, role);
        var page = Render(fixture);
        page.WaitForAssertion(() => Assert.Contains("Gateway connection", page.Markup));
        Assert.Equal(credentials, page.FindAll("#gateway-credentials-heading").Count == 1);
        Assert.Equal(operations, page.FindAll("#history-heading").Count == 1);
        Assert.Equal(audit, page.FindAll("#audit-heading").Count == 1);
        Assert.Contains("PowerShell connection example", page.Markup);
        Assert.DoesNotContain(CoreUiData.Key, page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Last_usable_key_cannot_be_revoked_from_the_component()
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectDetails(fixture, "Gateway.Administrator");
        var page = Render(fixture);
        Assert.Contains("Keep one usable Gateway key", page.Markup);
        var revoke = RevokeButton(page, CoreUiData.KeyId);
        Assert.True(revoke.Instance.Disabled);
        await page.InvokeAsync(() => revoke.Instance.OnClick.InvokeAsync(new MouseEventArgs()));
        Assert.DoesNotContain(page.FindComponents<ConfirmPanel>(), item => item.Instance.Visible);
        Assert.DoesNotContain(nameof(IGatewayApiClient.RevokeAgentIngressCredentialAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Replacement_is_shown_once_then_selected_old_key_revocation_requires_explicit_acknowledgment()
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectDetails(fixture, "Gateway.Administrator");
        var page = Render(fixture);
        var replacement = CoreUiData.Credential with { KeyId = CoreUiData.ReplacementId };
        await AdminUiFixture.ClickAsync(page, "Issue replacement key");
        fixture.Script.Return(nameof(IGatewayApiClient.IssueAgentIngressCredentialAsync),
            new IssueAgentIngressCredentialResponse(CoreUiData.AgentId, CoreUiData.ExternalId, replacement));
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentIngressCredentialsAsync),
            new AgentIngressCredentialListResponse(CoreUiData.AgentId, [CoreUiData.Metadata(), CoreUiData.Metadata(CoreUiData.ReplacementId)]));
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentAuditEventsAsync), new AuditEventListResponse([], null));
        await AdminUiFixture.ClickAsync(page, "Issue replacement");
        Assert.Equal(CoreUiData.Key, page.Find("#gateway-api-key").GetAttribute("value"));
        Assert.DoesNotContain(nameof(IGatewayApiClient.RevokeAgentIngressCredentialAsync), fixture.Script.Calls);
        await AdminUiFixture.ClickAsync(page, "Return to agent");
        Assert.NotEmpty(page.FindAll("#gateway-api-key"));
        CoreUiData.ExpectProtection(fixture, details: true);
        page.Find("#saved-gateway-key").Change(true);
        await AdminUiFixture.ClickAsync(page, "Return to agent");
        Assert.Empty(page.FindAll("#gateway-api-key"));
        Assert.DoesNotContain(CoreUiData.Key, page.Markup);
        var revoke = RevokeButton(page, CoreUiData.KeyId);
        await page.InvokeAsync(() => revoke.Instance.OnClick.InvokeAsync(new MouseEventArgs()));
        await AdminUiFixture.ClickAsync(page, "Revoke key");
        Assert.DoesNotContain(nameof(IGatewayApiClient.RevokeAgentIngressCredentialAsync), fixture.Script.Calls);
        page.Find("#replacement-installed").Change(true);
        fixture.Script.Return(nameof(IGatewayApiClient.RevokeAgentIngressCredentialAsync),
            new RevokeAgentIngressCredentialResponse(CoreUiData.AgentId, CoreUiData.Metadata(revoked: CoreUiData.Now.UtcDateTime), false),
            arguments => Assert.Equal(CoreUiData.KeyId, Assert.IsType<Guid>(arguments[1])));
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentIngressCredentialsAsync),
            new AgentIngressCredentialListResponse(CoreUiData.AgentId, [
                CoreUiData.Metadata(revoked: CoreUiData.Now.UtcDateTime), CoreUiData.Metadata(CoreUiData.ReplacementId)]));
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentAuditEventsAsync), new AuditEventListResponse([], null));
        await AdminUiFixture.ClickAsync(page, "Revoke key");
        Assert.Contains("Selected Gateway key revoked", page.Markup);
        Assert.True(RevokeButton(page, CoreUiData.ReplacementId).Instance.Disabled);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Interrupted_issuance_requires_metadata_readback_before_another_mutation()
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectDetails(fixture, "Gateway.Administrator");
        var page = Render(fixture);
        await AdminUiFixture.ClickAsync(page, "Issue replacement key");
        fixture.Script.Expect<IssueAgentIngressCredentialResponse>(nameof(IGatewayApiClient.IssueAgentIngressCredentialAsync), _ =>
            Task.FromException<IssueAgentIngressCredentialResponse>(new GatewayApiTransportException(
                "Synthetic lost issuance response.", "fixture-correlation", new HttpRequestException("Synthetic interruption."))));
        await AdminUiFixture.ClickAsync(page, "Issue replacement");
        Assert.Empty(page.FindAll("#gateway-api-key"));
        Assert.Contains("Check the existing result before another action", page.Markup);
        Assert.True(page.FindComponents<FluentButton>()
            .Single(item => item.Find("fluent-button").TextContent.Trim() == "Issue replacement key").Instance.Disabled);
        CoreUiData.ExpectDetails(fixture, "Gateway.Administrator", protection: false);
        await AdminUiFixture.ClickAsync(page, "Check agent and credential status");
        Assert.DoesNotContain("Check the existing result before another action", page.Markup);
        Assert.Single(fixture.Script.Calls, item => item == nameof(IGatewayApiClient.IssueAgentIngressCredentialAsync));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Wrong_registration_credential_response_is_never_displayed()
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectDetails(fixture, "Gateway.Administrator");
        var page = Render(fixture);
        await AdminUiFixture.ClickAsync(page, "Issue replacement key");
        fixture.Script.Return(nameof(IGatewayApiClient.IssueAgentIngressCredentialAsync),
            new IssueAgentIngressCredentialResponse(Guid.NewGuid(), CoreUiData.ExternalId, CoreUiData.Credential));
        await AdminUiFixture.ClickAsync(page, "Issue replacement");
        Assert.Empty(page.FindAll("#gateway-api-key"));
        Assert.DoesNotContain(CoreUiData.Key, page.Markup);
        Assert.Contains("Check the existing result before another action", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Operator_can_disable_and_reenable_without_private_credential_or_audit_calls()
    {
        using var fixture = CoreUiData.Create("Gateway.Operator");
        CoreUiData.ExpectDetails(fixture, "Gateway.Operator");
        var page = Render(fixture);
        await AdminUiFixture.ClickAsync(page, "Disable agent");
        fixture.Script.Return(nameof(IGatewayApiClient.DisableAgentAsync),
            new AgentStateChangeResponse(CoreUiData.AgentId, "Disabled", CoreUiData.Now.UtcDateTime));
        CoreUiData.ExpectDetails(fixture, "Gateway.Operator", CoreUiData.Agent(status: "Disabled"));
        await AdminUiFixture.ClickAsync(page, "Disable");
        Assert.Contains("Disable request accepted. Current status: Disabled", page.Markup);
        await AdminUiFixture.ClickAsync(page, "Enable agent");
        fixture.Script.Return(nameof(IGatewayApiClient.EnableAgentAsync),
            new AgentStateChangeResponse(CoreUiData.AgentId, "Active", CoreUiData.Now.UtcDateTime));
        CoreUiData.ExpectDetails(fixture, "Gateway.Operator");
        await AdminUiFixture.ClickAsync(page, "Enable");
        Assert.Contains("Enable request accepted. Current status: Active", page.Markup);
        Assert.DoesNotContain(nameof(IGatewayApiClient.GetAgentIngressCredentialsAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Deletion_review_has_truthful_Gateway_only_scope_and_cancel_sends_nothing()
    {
        using var fixture = CoreUiData.Create();
        CoreUiData.ExpectDetails(fixture, "Gateway.Administrator");
        var page = Render(fixture);
        await AdminUiFixture.ClickAsync(page, "Delete Gateway registration");
        var dialog = page.FindComponents<ConfirmPanel>().Single(item => item.Instance.Visible);
        Assert.Contains("Microsoft Entra identities, Agent 365 registrations, shared Purview policies and external hosting remain", dialog.Markup);
        Assert.Contains(CoreUiData.ExternalId, dialog.Markup);
        await AdminUiFixture.ClickAsync(dialog, "Cancel");
        Assert.DoesNotContain(nameof(IGatewayApiClient.DeleteAgentAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public void Wrong_agent_metadata_fails_before_fetching_related_private_data()
    {
        using var fixture = CoreUiData.Create();
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentAsync), CoreUiData.Resource(CoreUiData.Agent(Guid.NewGuid())));
        var page = Render(fixture);
        Assert.Contains("does not match the selected registration", page.Markup);
        Assert.Single(fixture.Script.Calls);
        fixture.AssertComplete();
    }

    private static IRenderedComponent<AgentDetails> Render(AdminUiFixture fixture) =>
        fixture.Render<AgentDetails>(parameters => parameters.Add(item => item.AgentId, CoreUiData.AgentId));

    private static IRenderedComponent<FluentButton> RevokeButton(IRenderedComponent<AgentDetails> page, Guid id) =>
        page.FindComponents<FluentButton>().Single(item =>
            item.Find("fluent-button").GetAttribute("aria-label") == $"Revoke Gateway key {id:D}");
}
