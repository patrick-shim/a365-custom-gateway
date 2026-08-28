using Bunit;
using FluentAssertions;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.FluentUI.AspNetCore.Components;
using NSubstitute;

namespace Gateway.AdminUi.Tests.Components;

public sealed class AgentsPageTests : BunitContext
{
    private readonly IGatewayApiClient _api = Substitute.For<IGatewayApiClient>();

    public AgentsPageTests()
    {
        Services.AddFluentUIComponents();
        Services.AddSingleton(_api);
        JSInterop.Mode = JSRuntimeMode.Loose;
    }

    [Fact]
    public void Administrator_SeesReturnedAgentsAndRegistrationAction()
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Admin user");
        auth.SetRoles(GatewayRoles.Administrator);
        var agentId = Guid.NewGuid();
        _api.GetAgentsAsync(Arg.Any<AgentListQuery>(), Arg.Any<CancellationToken>())
            .Returns(new AgentListResponse(
                [CreateAgent(agentId, "Research agent", "Active")],
                "more-records",
                1));

        var cut = Render<Agents>();

        cut.WaitForAssertion(() =>
        {
            cut.Find("h1").TextContent.Should().Be("Agents");
            cut.Find("tbody").TextContent.Should().Contain("Research agent");
            cut.Find("tbody").TextContent.Should().Contain("Active");
            cut.Find($"a[href='/agents/{agentId}']").Should().NotBeNull();
            cut.Find("[href='/agents/register']").TextContent.Should().Contain("Register agent");
            cut.Markup.Should().Contain("paging is temporarily unavailable");
        });

        _api.Received(1).GetAgentsAsync(
            Arg.Is<AgentListQuery>(query => query.Limit == 100),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public void SupportReader_SeesEmptyStateWithoutRegistrationAction()
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Reader user");
        auth.SetRoles(GatewayRoles.SupportReader);
        _api.GetAgentsAsync(Arg.Any<AgentListQuery>(), Arg.Any<CancellationToken>())
            .Returns(new AgentListResponse([], null, 0));

        var cut = Render<Agents>();

        cut.WaitForAssertion(() =>
        {
            cut.Find(".empty-state").TextContent.Should().Contain("No agents registered");
            cut.FindAll("[href='/agents/register']").Should().BeEmpty();
        });
    }

    [Theory]
    [InlineData("Disabled", "Agent 365: Disabled", "Azure Monitor mirror: Disabled")]
    [InlineData("GatewayOnly", "Agent 365: Disabled", "Azure Monitor mirror: Enabled")]
    [InlineData("Agent365", "Agent 365: Enabled", "Azure Monitor mirror: Disabled")]
    [InlineData("Agent365AzureMonitor", "Agent 365: Enabled", "Azure Monitor mirror: Enabled")]
    public void LegacyModes_RenderAsIndependentTelemetryDestinations(
        string legacyMode,
        string expectedAgent365,
        string expectedAzureMonitor)
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Reader user");
        auth.SetRoles(GatewayRoles.SupportReader);
        _api.GetAgentsAsync(Arg.Any<AgentListQuery>(), Arg.Any<CancellationToken>())
            .Returns(new AgentListResponse(
                [CreateAgent(
                    Guid.NewGuid(),
                    "Legacy agent",
                    "Active",
                    new AgentFeaturesDto(legacyMode, false, null))],
                null,
                1));

        var cut = Render<Agents>();

        cut.WaitForAssertion(() =>
        {
            var telemetryCell = cut.FindAll("tbody td")[3];
            telemetryCell.TextContent.Should().Contain(expectedAgent365);
            telemetryCell.TextContent.Should().Contain(expectedAzureMonitor);
        });
    }

    [Fact]
    public void CanonicalBooleans_TakePrecedenceOverLegacyMode()
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Reader user");
        auth.SetRoles(GatewayRoles.SupportReader);
        _api.GetAgentsAsync(Arg.Any<AgentListQuery>(), Arg.Any<CancellationToken>())
            .Returns(new AgentListResponse(
                [CreateAgent(
                    Guid.NewGuid(),
                    "Canonical agent",
                    "Active",
                    new AgentFeaturesDto("GatewayOnly", false, null, true, false))],
                null,
                1));

        var cut = Render<Agents>();

        cut.WaitForAssertion(() =>
        {
            var telemetryCell = cut.FindAll("tbody td")[3];
            telemetryCell.TextContent.Should().Contain("Agent 365: Enabled");
            telemetryCell.TextContent.Should().Contain("Azure Monitor mirror: Disabled");
        });
    }

    [Fact]
    public void ApiFailure_RendersSafeMessageCorrelationAndRetry()
    {
        var auth = AddAuthorization();
        auth.SetAuthorized("Operator user");
        auth.SetRoles(GatewayRoles.Operator);
        _api.GetAgentsAsync(Arg.Any<AgentListQuery>(), Arg.Any<CancellationToken>())
            .Returns(
                _ => Task.FromException<AgentListResponse>(new GatewayApiException(
                    System.Net.HttpStatusCode.ServiceUnavailable,
                    "The Gateway API is temporarily unavailable.",
                    "Try again in a few minutes.",
                    null,
                    null,
                    "GW-UNAVAILABLE",
                    "page-correlation",
                    new Dictionary<string, string[]>(),
                    TimeSpan.FromSeconds(5))),
                _ => Task.FromResult(new AgentListResponse([], null, 0)));

        var cut = Render<Agents>();

        cut.WaitForAssertion(() =>
        {
            var alert = cut.Find("[role='alert']");
            alert.TextContent.Should().Contain("Try again in a few minutes.");
            alert.TextContent.Should().Contain("page-correlation");
        });

        cut.Find("[role='alert'] fluent-button").Click();

        cut.WaitForAssertion(() =>
        {
            cut.Find(".empty-state").TextContent.Should().Contain("No agents registered");
            _api.Received(2).GetAgentsAsync(
                Arg.Any<AgentListQuery>(),
                Arg.Any<CancellationToken>());
        });
    }

    private static AgentSummaryDto CreateAgent(
        Guid agentId,
        string name,
        string status,
        AgentFeaturesDto? features = null) =>
        new(
            agentId,
            "external-agent",
            name,
            "A test agent",
            status,
            "Development",
            Agent365: null,
            features ?? new AgentFeaturesDto("Basic", true, "Audit"),
            LastActivityAtUtc: null,
            CreatedAtUtc: DateTime.UtcNow.AddDays(-2),
            UpdatedAtUtc: DateTime.UtcNow.AddDays(-1));
}
