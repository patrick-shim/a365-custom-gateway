using Bunit;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.Tests.Components;

public sealed class OverviewCountsTests
{
    [Theory]
    [InlineData("Healthy", "Unavailable")]
    [InlineData("Healthy", "Unhealthy")]
    [InlineData("Unhealthy", "Ready")]
    public void An_empty_fleet_does_not_assert_readiness_when_a_Gateway_check_is_unhealthy(
        string healthStatus, string readinessStatus)
    {
        using var fixture = new AdminUiFixture();
        ExpectOverview(fixture, registered: 0, active: 0, approval: 0, failed: 0, manual: 0,
            includePreview: false, readinessStatus: readinessStatus, healthStatus: healthStatus);
        var page = fixture.Render<Home>();

        Assert.Equal("0", Count(page, "registered"));
        Assert.DoesNotContain("Your Gateway is ready for its first agent.", page.Markup);
        Assert.Contains("Gateway health checks need attention", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public void Overview_uses_complete_fleet_and_status_totals_not_its_small_previews()
    {
        using var fixture = new AdminUiFixture(GatewayRoles.SupportReader);
        ExpectOverview(fixture);
        var page = fixture.Render<Home>();

        Assert.Equal("237", Count(page, "registered"));
        Assert.Equal("180", Count(page, "active"));
        Assert.Equal("30", Count(page, "action-required"));
        Assert.Equal(3, page.FindAll("tbody tr").Count);
        Assert.Contains("Active registrations", page.Markup);
        Assert.Contains("configured policy are not evidence of current enforcement", page.Markup);
        Assert.Contains("does not confirm downstream delivery", page.Markup);
        Assert.Contains("not a fleet snapshot", page.Markup);
        Assert.Empty(page.FindAll("[href='/agents/register']"));
        Assert.Empty(page.FindAll("a[href^='/operations/']"));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(GatewayRoles.Administrator, true)]
    [InlineData(GatewayRoles.Operator, false)]
    [InlineData(GatewayRoles.Auditor, false)]
    [InlineData(GatewayRoles.SupportReader, false)]
    public void Authoritative_empty_fleet_shows_the_permitted_first_registration_handoff(string role, bool administrator)
    {
        using var fixture = new AdminUiFixture(role);
        ExpectOverview(fixture, registered: 0, active: 0, approval: 0, failed: 0, manual: 0, includePreview: false);
        var page = fixture.Render<Home>();

        Assert.Contains("Your Gateway is ready for its first agent.", page.Markup);
        Assert.DoesNotContain("Gateway health checks need attention", page.Markup);
        Assert.Contains("save its Gateway ID and one-time key", page.Markup);
        Assert.Equal("0", Count(page, "registered"));
        Assert.Equal(administrator, page.FindAll("[href='/agents/register']").Count > 0);
        Assert.Equal(!administrator, page.Markup.Contains("Administrator task:"));
        Assert.NotNull(page.Find("a[href='/getting-started']"));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(null, null, null, "Unavailable", "Unavailable", "Unavailable")]
    [InlineData(237, 180, null, "237", "180", "Unavailable")]
    [InlineData(null, 180, 5, "Unavailable", "180", "30")]
    public void Missing_totals_remain_unavailable_even_when_previews_are_empty(
        int? registered, int? active, int? approval, string expectedRegistered, string expectedActive, string expectedActions)
    {
        using var fixture = new AdminUiFixture();
        ExpectOverview(fixture, registered, active, approval, includePreview: false);
        var page = fixture.Render<Home>();

        Assert.Equal(expectedRegistered, Count(page, "registered"));
        Assert.Equal(expectedActive, Count(page, "active"));
        Assert.Equal(expectedActions, Count(page, "action-required"));
        Assert.DoesNotContain("Your Gateway is ready for its first agent.", page.Markup);
        Assert.DoesNotContain("No registration actions required", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task A_failed_count_read_is_an_error_not_zero_or_a_current_stale_fleet()
    {
        using var fixture = new AdminUiFixture();
        ExpectOverview(fixture);
        ExpectOverview(fixture, failApproval: true);
        ExpectOverview(fixture, registered: 236, active: 179);
        var page = fixture.Render<Home>();
        await AdminUiFixture.ClickAsync(page, "Refresh");

        Assert.NotNull(page.Find("[role='alert']"));
        Assert.Empty(page.FindAll(".metric-value"));
        Assert.DoesNotContain("No registration actions required", page.Markup);
        Assert.DoesNotContain("private service body", page.Markup);
        Assert.Contains("Last successful read", page.Markup);
        await AdminUiFixture.ClickAsync(page, "Try again");
        Assert.Equal("236", Count(page, "registered"));
        Assert.Equal("179", Count(page, "active"));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task A_failed_readiness_read_is_an_error_not_a_successful_empty_install()
    {
        using var fixture = new AdminUiFixture();
        ExpectOverview(fixture, registered: 0, active: 0, approval: 0, failed: 0, manual: 0, includePreview: false);
        ExpectOverview(fixture, registered: 0, active: 0, approval: 0, failed: 0, manual: 0,
            includePreview: false, failReadiness: true);
        ExpectOverview(fixture, registered: 0, active: 0, approval: 0, failed: 0, manual: 0, includePreview: false);
        var page = fixture.Render<Home>();
        Assert.Contains("Your Gateway is ready for its first agent.", page.Markup);

        await AdminUiFixture.ClickAsync(page, "Refresh");
        Assert.Contains("Readiness could not be loaded.", page.Find("[role='alert']").TextContent);
        Assert.Empty(page.FindAll(".metric-value"));
        Assert.DoesNotContain("Your Gateway is ready for its first agent.", page.Markup);
        Assert.DoesNotContain("private readiness detail", page.Markup);

        await AdminUiFixture.ClickAsync(page, "Try again");
        Assert.Contains("Your Gateway is ready for its first agent.", page.Markup);
        Assert.Equal("0", Count(page, "registered"));
        Assert.Empty(page.FindAll("[role='alert']"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Pending_fleet_read_shows_loading_without_zero_counts_or_empty_success()
    {
        using var fixture = new AdminUiFixture();
        var pending = new TaskCompletionSource<AgentListResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        ExpectOverview(fixture, fleetResponse: pending.Task);
        var page = fixture.Render<Home>();

        Assert.Contains("Loading gateway overview", page.Markup);
        Assert.Empty(page.FindAll(".metric-value"));
        Assert.DoesNotContain("first agent", page.Markup);
        pending.SetResult(new([Agent("Active")], "opaque-next", 237));
        page.WaitForAssertion(() => Assert.Equal("237", Count(page, "registered")));
        fixture.AssertComplete();
    }

    private static string Count(IRenderedComponent<Home> page, string name) =>
        page.Find($"[data-count='{name}'] .metric-value").TextContent.Trim();

    private static void ExpectOverview(AdminUiFixture fixture, int? registered = 237, int? active = 180,
        int? approval = 5, int? failed = 20, int? manual = 5, bool includePreview = true, bool failApproval = false,
        Task<AgentListResponse>? fleetResponse = null, string readinessStatus = "Ready",
        string healthStatus = "Healthy", bool failReadiness = false)
    {
        fixture.Script.Expect<AgentListResponse>(nameof(IGatewayApiClient.GetAgentsAsync), arguments =>
        {
            Assert.Equal(new AgentListQuery(Limit: 1), arguments[0]);
            return fleetResponse ?? Task.FromResult(new AgentListResponse(includePreview ? [Agent("Active")] : [], "opaque-fleet", registered));
        });
        ExpectCount("Active", 1, active);
        if (failApproval)
            fixture.Script.Expect<AgentListResponse>(nameof(IGatewayApiClient.GetAgentsAsync), arguments =>
            {
                Assert.Equal(new AgentListQuery(Status: "AwaitingAdminApproval", Limit: 8), arguments[0]);
                return Task.FromException<AgentListResponse>(new GatewayApiTransportException(
                    "Gateway is unavailable.", "overview-fixture", new HttpRequestException("private service body")));
            });
        else
            ExpectCount("AwaitingAdminApproval", 8, approval);
        ExpectCount("Failed", 8, failed);
        ExpectCount("RequiresManualIntervention", 8, manual);
        fixture.Script.Return(nameof(IGatewayApiClient.GetHealthAsync), new GatewayHealthStatus(healthStatus));
        if (failReadiness)
            fixture.Script.Expect<GatewayHealthStatus>(nameof(IGatewayApiClient.GetReadinessAsync), _ =>
                Task.FromException<GatewayHealthStatus>(new GatewayApiTransportException(
                    "Readiness could not be loaded.", "readiness-fixture", new HttpRequestException("private readiness detail"))));
        else
            fixture.Script.Return(nameof(IGatewayApiClient.GetReadinessAsync), new GatewayHealthStatus(readinessStatus));

        void ExpectCount(string status, int limit, int? total) =>
            fixture.Script.Return(nameof(IGatewayApiClient.GetAgentsAsync),
                new AgentListResponse(includePreview ? [Agent(status)] : [], total > limit ? "opaque-status" : null, total),
                arguments => Assert.Equal(new AgentListQuery(Status: status, Limit: limit), arguments[0]));
    }

    private static AgentSummaryDto Agent(string status) => new(Guid.NewGuid(), $"fixture-{status}", $"Fixture {status}", null,
        status, "Production", null, new AgentFeaturesDto("Disabled", false, null), null, DateTime.UnixEpoch, DateTime.UnixEpoch);
}
