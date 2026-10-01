using Bunit;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Microsoft.FluentUI.AspNetCore.Components;

namespace Gateway.AdminUi.Tests.Components;

public sealed class AgentsPageBaselineTests
{
    [Fact]
    public void Administrator_sees_the_empty_registry_and_registration_entry_points()
    {
        using var fixture = new AdminUiFixture();
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentsAsync), new AgentListResponse([], null, 0),
            arguments => Assert.Equal(new AgentListQuery(Limit: 100), arguments[0]));

        var page = fixture.Render<Agents>();

        Assert.Contains("No agents registered", page.Find(".empty-state").TextContent);
        Assert.NotEmpty(page.FindAll("[href='/agents/register']"));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(GatewayRoles.Operator)]
    [InlineData(GatewayRoles.Auditor)]
    [InlineData(GatewayRoles.SupportReader)]
    public void Read_roles_see_empty_state_without_administrator_registration_actions(string role)
    {
        using var fixture = new AdminUiFixture(role);
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentsAsync), new AgentListResponse([], null, 0));

        var page = fixture.Render<Agents>();

        Assert.Contains("No agents registered", page.Find(".empty-state").TextContent);
        Assert.Empty(page.FindAll("[href='/agents/register']"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Pending_request_shows_loading_until_explicit_fixture_completion()
    {
        using var fixture = new AdminUiFixture();
        var response = new TaskCompletionSource<AgentListResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Script.Expect(nameof(IGatewayApiClient.GetAgentsAsync), _ => response.Task);

        var page = fixture.Render<Agents>();

        Assert.Contains("Loading agents", page.Find(".state-panel").TextContent);
        Assert.Equal("true", page.Find("section[aria-busy]").GetAttribute("aria-busy"));
        Assert.Empty(page.FindAll(".empty-state"));
        response.SetResult(new([], null, 0));
        page.WaitForAssertion(() =>
        {
            Assert.Empty(page.FindAll(".state-panel"));
            Assert.Contains("No agents registered", page.Find(".empty-state").TextContent);
            Assert.Equal("false", page.Find("section[aria-busy]").GetAttribute("aria-busy"));
        });
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Safe_error_can_be_retried_once_without_exposing_the_transport_exception()
    {
        using var fixture = new AdminUiFixture();
        fixture.Script.Expect<AgentListResponse>(nameof(IGatewayApiClient.GetAgentsAsync), _ =>
            Task.FromException<AgentListResponse>(new GatewayApiTransportException(
                "Gateway is temporarily unavailable.", "fixture-correlation",
                new HttpRequestException("private transport detail"))));
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentsAsync), new AgentListResponse([], null, 0));

        var page = fixture.Render<Agents>();

        Assert.Contains("Gateway is temporarily unavailable.", page.Find("[role='alert']").TextContent);
        Assert.Contains("fixture-correlation", page.Find("[role='alert']").TextContent);
        Assert.DoesNotContain("private transport detail", page.Markup);
        await AdminUiFixture.ClickAsync(page, "Try again");
        page.WaitForAssertion(() =>
        {
            Assert.Empty(page.FindAll("[role='alert']"));
            Assert.Contains("No agents registered", page.Find(".empty-state").TextContent);
        });
        Assert.Equal(2, fixture.Script.Calls.Count);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("Disabled", false, false)]
    [InlineData("GatewayOnly", false, true)]
    [InlineData("Agent365", true, false)]
    [InlineData("Agent365AzureMonitor", true, true)]
    public void Existing_destination_modes_remain_distinct_with_authoritative_totals_and_available_paging(
        string mode, bool agent365, bool mirror)
    {
        using var fixture = new AdminUiFixture(GatewayRoles.SupportReader);
        var agent = new AgentSummaryDto(
            Guid.Parse("33333333-3333-4333-8333-333333333333"), "offline-agent", "Offline agent", null,
            "Active", "Test", null, new AgentFeaturesDto(mode, false, null), null, DateTime.UnixEpoch, DateTime.UnixEpoch);
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentsAsync), new AgentListResponse([agent], "next-cursor", 125));

        var page = fixture.Render<Agents>();

        var row = page.Find("tbody").TextContent;
        Assert.Contains($"Agent 365: {(agent365 ? "Enabled" : "Disabled")}", row);
        Assert.Contains($"Azure Monitor mirror: {(mirror ? "Enabled" : "Disabled")}", row);
        Assert.Contains("Not reported", row);
        Assert.NotNull(page.Find($"a[href='/agents/{agent.AgentId}']"));
        Assert.DoesNotContain("paging is temporarily unavailable", page.Markup);
        Assert.Contains("1–1 of 125 agents", page.Markup);
        Assert.False(page.FindComponents<FluentButton>()
            .Single(button => button.Find("fluent-button").TextContent.Trim() == "Next").Instance.Disabled);
        fixture.AssertComplete();
    }
}
