using System.Net;
using Bunit;
using Gateway.AdminUi.Authentication;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Components;
using Microsoft.AspNetCore.Components.Web;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.FluentUI.AspNetCore.Components;

namespace Gateway.AdminUi.Tests.Components;

public sealed class AgentListingJourneyTests
{
    private const string SecondCursor = "opaque+second/page==";
    private const string ThirdCursor = "opaque-third-page";

    [Fact]
    public async Task Prerendered_filter_and_paging_controls_cannot_accept_edits_or_actions()
    {
        using var fixture = new AdminUiFixture { Rendering = new RendererInfo("Static", isInteractive: false) };
        var query = new AgentListQuery("Active", "Production", "invoice-eu", 100);
        fixture.Services.GetRequiredService<NavigationManager>()
            .NavigateTo("/agents?search=invoice-eu&status=Active&environment=Production");
        ExpectPage(fixture, query, Agents(100), SecondCursor, 137);
        var page = fixture.Render<Agents>();

        Assert.All(new[] { "#agent-search", "#agent-status", "#agent-environment" }.Select(page.Find),
            input => Assert.True(input.HasAttribute("disabled")));
        Assert.Equal("true", page.Find("#agent-filters").GetAttribute("aria-busy"));
        Assert.Equal("true", page.Find("#agent-results").GetAttribute("aria-busy"));
        foreach (var label in new[] { "Refresh", "Search", "Clear", "Previous", "Next" })
        {
            Assert.True(Button(page, label).Instance.Disabled);
            await AdminUiFixture.ClickAsync(page, label);
        }
        await page.Find("#agent-search").KeyDownAsync(new KeyboardEventArgs { Key = "Enter" });

        Assert.Equal("invoice-eu", page.Find("#agent-search").GetAttribute("value"));
        Assert.Equal("Active", page.Find("#agent-status").GetAttribute("value"));
        Assert.Equal("Production", page.Find("#agent-environment").GetAttribute("value"));
        Assert.Single(fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Interactive_controls_become_ready_after_the_query_loads_and_keep_its_filters_while_paging()
    {
        using var fixture = new AdminUiFixture { Rendering = new RendererInfo("Server", isInteractive: true) };
        var query = new AgentListQuery("Active", "Production", "invoice-eu", 100);
        fixture.Services.GetRequiredService<NavigationManager>()
            .NavigateTo("/agents?search=invoice-eu&status=Active&environment=Production");
        var pending = new TaskCompletionSource<AgentListResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Script.Expect<AgentListResponse>(nameof(IGatewayApiClient.GetAgentsAsync), arguments =>
        {
            Assert.Equal(query, arguments[0]);
            return pending.Task;
        });
        ExpectPage(fixture, query with { Cursor = SecondCursor }, Agents(137)[100..], null, 137);
        var page = fixture.Render<Agents>();
        Assert.Equal("true", page.Find("#agent-filters").GetAttribute("aria-busy"));
        Assert.All(page.FindAll("#agent-filters input, #agent-filters select"),
            input => Assert.True(input.HasAttribute("disabled")));

        pending.SetResult(new(Agents(100).ToList(), SecondCursor, 137));
        page.WaitForAssertion(() =>
        {
            Assert.Equal("false", page.Find("#agent-filters").GetAttribute("aria-busy"));
            Assert.Equal("false", page.Find("#agent-results").GetAttribute("aria-busy"));
            Assert.All(page.FindAll("#agent-filters input, #agent-filters select"),
                input => Assert.False(input.HasAttribute("disabled")));
            Assert.False(Button(page, "Next").Instance.Disabled);
        }, TimeSpan.FromSeconds(5));
        await AdminUiFixture.ClickAsync(page, "Next");

        Assert.Contains("101–137 of 137 matching agents", page.Markup);
        Assert.Equal("invoice-eu", page.Find("#agent-search").GetAttribute("value"));
        Assert.Equal("Active", page.Find("#agent-status").GetAttribute("value"));
        Assert.Equal("Production", page.Find("#agent-environment").GetAttribute("value"));
        Assert.True(Button(page, "Next").Instance.Disabled);
        Assert.False(Button(page, "Previous").Instance.Disabled);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Prerendered_empty_and_error_views_do_not_offer_active_recovery_actions(bool readError)
    {
        using var fixture = new AdminUiFixture { Rendering = new RendererInfo("Static", isInteractive: false) };
        fixture.Services.GetRequiredService<NavigationManager>().NavigateTo("/agents?search=invoice-eu");
        if (readError)
            fixture.Script.Expect<AgentListResponse>(nameof(IGatewayApiClient.GetAgentsAsync), _ =>
                Task.FromException<AgentListResponse>(new HttpRequestException("private transport detail")));
        else
            ExpectPage(fixture, new(Search: "invoice-eu", Limit: 100), [], null, 0);
        var page = fixture.Render<Agents>();

        Assert.Equal("true", page.Find("#agent-filters").GetAttribute("aria-busy"));
        Assert.All(page.FindComponents<FluentButton>(), button => Assert.True(button.Instance.Disabled));
        Assert.Empty(page.FindAll(".error-actions"));
        if (!readError)
            await AdminUiFixture.ClickAsync(page, "Clear filters");
        Assert.Equal("invoice-eu", page.Find("#agent-search").GetAttribute("value"));
        Assert.Single(fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task The_237_row_fleet_has_100_100_37_distinct_rows_and_previous_pages_preserve_exact_cursors()
    {
        using var fixture = new AdminUiFixture(GatewayRoles.SupportReader);
        var agents = Agents(237);
        var firstQuery = new AgentListQuery(Limit: 100);
        ExpectPage(fixture, firstQuery, agents[..100], SecondCursor, 237);
        ExpectPage(fixture, firstQuery with { Cursor = SecondCursor }, agents[100..200], ThirdCursor, 237);
        ExpectPage(fixture, firstQuery with { Cursor = ThirdCursor }, agents[200..], null, 237);
        ExpectPage(fixture, firstQuery with { Cursor = SecondCursor }, agents[100..200], ThirdCursor, 237);
        ExpectPage(fixture, firstQuery, agents[..100], SecondCursor, 237);
        var page = fixture.Render<Agents>();
        var allLinks = new List<string>();

        foreach (var (count, summary) in new[] { (100, "1–100"), (100, "101–200"), (37, "201–237") })
        {
            Assert.Equal(count, page.FindAll("tbody tr").Count);
            Assert.Contains($"{summary} of 237 agents", page.Markup);
            allLinks.AddRange(page.FindAll("tbody a").Select(link => link.GetAttribute("href")!));
            if (summary != "201–237")
                await AdminUiFixture.ClickAsync(page, "Next");
        }

        Assert.Equal(237, allLinks.Distinct().Count());
        Assert.Contains("Page 3 of 3", page.Markup);
        Assert.True(Button(page, "Next").Instance.Disabled);
        await AdminUiFixture.ClickAsync(page, "Next");
        Assert.Equal(3, fixture.Script.Calls.Count);
        await AdminUiFixture.ClickAsync(page, "Previous");
        Assert.Contains("101–200 of 237 agents", page.Markup);
        await AdminUiFixture.ClickAsync(page, "Previous");
        Assert.Contains("1–100 of 237 agents", page.Markup);
        Assert.True(Button(page, "Previous").Instance.Disabled);
        Assert.Empty(page.FindAll("[href='/agents/register']"));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Applying_combined_filters_and_clearing_them_resets_history_without_reusing_another_query_cursor()
    {
        using var fixture = new AdminUiFixture();
        var agents = Agents(237);
        var unfiltered = new AgentListQuery(Limit: 100);
        var filtered = new AgentListQuery("Active", "Production", "invoice-eu", 100);
        const string filteredCursor = "opaque-filtered-page";
        ExpectPage(fixture, unfiltered, agents[..100], SecondCursor, 237);
        ExpectPage(fixture, unfiltered with { Cursor = SecondCursor }, agents[100..200], ThirdCursor, 237);
        ExpectPage(fixture, filtered, agents[..100], filteredCursor, 137);
        ExpectPage(fixture, filtered with { Cursor = filteredCursor }, agents[100..137], null, 137);
        ExpectPage(fixture, filtered, agents[..100], filteredCursor, 137);
        ExpectPage(fixture, unfiltered, agents[..100], SecondCursor, 237);
        var page = fixture.Render<Agents>();
        await AdminUiFixture.ClickAsync(page, "Next");

        page.Find("#agent-search").Input(" invoice-eu ");
        page.Find("#agent-status").Change("Active");
        page.Find("#agent-environment").Change("Production");
        Assert.True(Button(page, "Next").Instance.Disabled);
        Assert.True(Button(page, "Previous").Instance.Disabled);
        await AdminUiFixture.ClickAsync(page, "Next");
        Assert.Equal(2, fixture.Script.Calls.Count);
        await AdminUiFixture.ClickAsync(page, "Search");
        Assert.Contains("1–100 of 137 matching agents", page.Markup);
        Assert.True(Button(page, "Previous").Instance.Disabled);
        await AdminUiFixture.ClickAsync(page, "Next");
        Assert.Contains("101–137 of 137 matching agents", page.Markup);
        Assert.True(Button(page, "Next").Instance.Disabled);
        Assert.Equal(" invoice-eu ", page.Find("#agent-search").GetAttribute("value"));
        Assert.Equal("Active", page.Find("#agent-status").GetAttribute("value"));
        Assert.Equal("Production", page.Find("#agent-environment").GetAttribute("value"));
        await AdminUiFixture.ClickAsync(page, "Previous");
        await AdminUiFixture.ClickAsync(page, "Clear");
        Assert.Contains("1–100 of 237 agents", page.Markup);
        Assert.True(Button(page, "Previous").Instance.Disabled);
        Assert.True(string.IsNullOrEmpty(page.Find("#agent-search").GetAttribute("value")));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Keyboard_search_and_refresh_start_at_the_first_page_of_the_applied_query()
    {
        using var fixture = new AdminUiFixture();
        var rows = Agents(137);
        var filtered = new AgentListQuery(Search: "invoice-eu", Limit: 100);
        ExpectPage(fixture, new(Limit: 100), rows[..100], SecondCursor, 237);
        ExpectPage(fixture, filtered, rows[..100], SecondCursor, 137);
        ExpectPage(fixture, filtered with { Cursor = SecondCursor }, rows[100..], null, 137);
        ExpectPage(fixture, filtered, rows[..100], SecondCursor, 137);
        var page = fixture.Render<Agents>();

        page.Find("#agent-search").Input("invoice-eu");
        await page.Find("#agent-search").KeyDownAsync(new KeyboardEventArgs { Key = "Enter" });
        Assert.Contains(fixture.JSInterop.Invocations, invocation => invocation.Identifier == "Blazor._internal.domWrapper.focus");
        Assert.Equal("-1", page.Find("#agent-results-heading").GetAttribute("tabindex"));
        await AdminUiFixture.ClickAsync(page, "Next");
        Assert.Contains("Page 2 of 2", page.Markup);
        await AdminUiFixture.ClickAsync(page, "Refresh");
        Assert.Contains("Page 1 of 2", page.Markup);
        Assert.Equal("invoice-eu", page.Find("#agent-search").GetAttribute("value"));
        fixture.AssertComplete();
    }

    [Fact]
    public void A_registration_recovery_search_link_is_applied_before_the_first_API_read()
    {
        using var fixture = new AdminUiFixture();
        ExpectPage(fixture, new(Search: "retained-external-id", Limit: 100), [], null, 0);
        fixture.Services.GetRequiredService<NavigationManager>().NavigateTo("/agents?search=retained-external-id");
        var page = fixture.Render<Agents>();

        Assert.Contains("No matching agents", page.Find(".empty-state").TextContent);
        Assert.Equal("retained-external-id", page.Find("#agent-search").GetAttribute("value"));
        Assert.DoesNotContain("No agents registered yet", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task A_bad_cursor_offers_a_safe_restart_with_filters_not_an_exception_or_blind_retry()
    {
        using var fixture = new AdminUiFixture();
        var query = new AgentListQuery(Search: "invoice-eu", Limit: 100);
        ExpectPage(fixture, query, Agents(100), SecondCursor, 137);
        fixture.Script.Expect<AgentListResponse>(nameof(IGatewayApiClient.GetAgentsAsync), arguments =>
        {
            Assert.Equal(query with { Cursor = SecondCursor }, arguments[0]);
            return Task.FromException<AgentListResponse>(new GatewayApiException(HttpStatusCode.BadRequest,
                "Validation Failed", "raw private cursor parsing detail", null, null, "VALIDATION_FAILED", "cursor-fixture",
                new Dictionary<string, string[]> { ["Cursor"] = ["Restart the list."] }, null));
        });
        ExpectPage(fixture, query, Agents(100), SecondCursor, 137);
        fixture.Services.GetRequiredService<NavigationManager>().NavigateTo("/agents?search=invoice-eu");
        var page = fixture.Render<Agents>();
        await AdminUiFixture.ClickAsync(page, "Next");

        Assert.Contains("This page link is no longer valid", page.Find("[role='alert']").TextContent);
        Assert.DoesNotContain("raw private", page.Markup);
        Assert.DoesNotContain("Try again", page.Markup);
        Assert.DoesNotContain("0 shown", page.Markup);
        Assert.Contains("cursor-fixture", page.Markup);
        await AdminUiFixture.ClickAsync(page, "Restart list");
        Assert.Contains("1–100 of 137 matching agents", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Navigating_to_a_new_query_cancels_the_old_read_and_ignores_its_late_result()
    {
        using var fixture = new AdminUiFixture();
        var pending = new TaskCompletionSource<AgentListResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        CancellationToken oldToken = default;
        fixture.Script.Expect<AgentListResponse>(nameof(IGatewayApiClient.GetAgentsAsync), arguments =>
        {
            Assert.Equal(new AgentListQuery(Limit: 100), arguments[0]);
            oldToken = Assert.IsType<CancellationToken>(arguments[1]);
            return pending.Task;
        });
        ExpectPage(fixture, new(Search: "invoice-eu", Limit: 100), Agents(100), SecondCursor, 137);
        var navigation = fixture.Services.GetRequiredService<NavigationManager>();
        var page = fixture.Render<Agents>();
        Assert.Contains("Loading agents", page.Markup);

        await page.InvokeAsync(() => navigation.NavigateTo("/agents?search=invoice-eu"));
        page.WaitForAssertion(() => Assert.Contains("1–100 of 137 matching agents", page.Markup));
        Assert.True(oldToken.IsCancellationRequested);
        pending.SetResult(new([], null, 0));
        page.WaitForAssertion(() =>
        {
            Assert.Contains("1–100 of 137 matching agents", page.Markup);
            Assert.DoesNotContain("No agents registered", page.Markup);
        });
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    public void Missing_totals_do_not_become_zero_or_an_inferred_fleet_size(int returned)
    {
        using var fixture = new AdminUiFixture();
        ExpectPage(fixture, new(Limit: 100), Agents(returned), null, null);
        var page = fixture.Render<Agents>();

        Assert.Contains("total unavailable", page.Markup);
        Assert.Contains("total pages unavailable", page.Markup);
        Assert.DoesNotContain("of 0 agents", page.Markup);
        Assert.DoesNotContain("No agents registered yet", page.Markup);
        if (returned == 0)
            Assert.Contains("No agents returned", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task An_empty_page_after_fleet_changes_preserves_previous_navigation_and_offers_restart()
    {
        using var fixture = new AdminUiFixture();
        var query = new AgentListQuery(Limit: 100);
        ExpectPage(fixture, query, Agents(100), SecondCursor, 137);
        ExpectPage(fixture, query with { Cursor = SecondCursor }, [], null, 100);
        ExpectPage(fixture, query, Agents(100), null, 100);
        var page = fixture.Render<Agents>();
        await AdminUiFixture.ClickAsync(page, "Next");

        Assert.Contains("No agents on this page", page.Markup);
        Assert.DoesNotContain("Page 2 of 1", page.Markup);
        Assert.DoesNotContain("No agents registered yet", page.Markup);
        Assert.False(Button(page, "Previous").Instance.Disabled);
        await AdminUiFixture.ClickAsync(page, "Restart list");
        Assert.Contains("1–100 of 100 agents", page.Markup);
        Assert.True(Button(page, "Next").Instance.Disabled);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Failed_refresh_never_displays_previous_results_as_current_or_as_an_empty_fleet()
    {
        using var fixture = new AdminUiFixture();
        ExpectPage(fixture, new(Limit: 100), Agents(100), SecondCursor, 237);
        fixture.Script.Expect<AgentListResponse>(nameof(IGatewayApiClient.GetAgentsAsync), _ =>
            Task.FromException<AgentListResponse>(new HttpRequestException("private transport body")));
        ExpectPage(fixture, new(Limit: 100), Agents(100), SecondCursor, 238);
        var page = fixture.Render<Agents>();
        await AdminUiFixture.ClickAsync(page, "Refresh");

        Assert.Empty(page.FindAll("tbody"));
        Assert.DoesNotContain("of 237", page.Markup);
        Assert.DoesNotContain("No agents registered", page.Markup);
        Assert.DoesNotContain("private transport body", page.Markup);
        await AdminUiFixture.ClickAsync(page, "Try again");
        Assert.Contains("1–100 of 238 agents", page.Markup);
        fixture.AssertComplete();
    }

    private static IRenderedComponent<FluentButton> Button(IRenderedComponent<Agents> page, string text) =>
        page.FindComponents<FluentButton>().Single(button => button.Find("fluent-button").TextContent.Trim() == text);

    private static void ExpectPage(AdminUiFixture fixture, AgentListQuery query, IEnumerable<AgentSummaryDto> rows, string? cursor, int? total) =>
        fixture.Script.Return(nameof(IGatewayApiClient.GetAgentsAsync), new AgentListResponse(rows.ToList(), cursor, total),
            arguments => Assert.Equal(query, arguments[0]));

    private static AgentSummaryDto[] Agents(int count) => Enumerable.Range(0, count).Select(index =>
        new AgentSummaryDto(Guid.Parse($"00000000-0000-4000-8000-{index + 1:000000000000}"),
            $"external-{index:000}", $"Listing fixture {index:000}", null, "Active", "Production", null,
            new("Disabled", false, null), null, DateTime.UnixEpoch, DateTime.UnixEpoch)).ToArray();
}
