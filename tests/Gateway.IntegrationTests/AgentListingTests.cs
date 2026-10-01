using System.Data.SqlTypes;
using System.Text.Json;
using Gateway.Application.Agents.Queries;
using Gateway.Application.Agents.Validators;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.IntegrationTests.Fixtures;
using Gateway.TestSupport;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests;

[Collection(SqlServerCollection.Name)]
[Trait("Category", "SqlServer")]
public sealed class AgentListingTests(SqlServerFixture fixture)
{
    [Fact]
    public async Task All_237_rows_round_trip_through_100_100_37_pages_in_SQL_timestamp_and_Guid_order()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agents = await SeedFleet(database);
        var expected = InSqlOrder(agents).Select(agent => agent.Id).ToArray();
        Assert.False(expected.SequenceEqual(agents.OrderBy(agent => agent.CreatedAtUtc).ThenBy(agent => agent.Id).Select(agent => agent.Id)));
        var actual = new List<Guid>();
        var cursors = new List<string?> { null };

        foreach (var count in new[] { 100, 100, 37 })
        {
            await using var context = database.CreateContext();
            var query = new ListAgentsQuery(null, null, null, 100, cursors[^1]);
            Assert.True(new ListAgentsValidator().Validate(query).IsValid);
            var response = await Handler(context).Handle(query, default);
            var wireResponse = JsonSerializer.Deserialize<AgentListResponse>(JsonSerializer.Serialize(response))!;

            Assert.Equal(count, wireResponse.Items.Count);
            Assert.Equal(237, wireResponse.TotalCount);
            Assert.Equal(expected.Skip(actual.Count).Take(count), wireResponse.Items.Select(agent => agent.AgentId));
            actual.AddRange(wireResponse.Items.Select(agent => agent.AgentId));
            cursors.Add(wireResponse.NextCursor);
        }

        Assert.Null(cursors[^1]);
        Assert.Equal(237, actual.Distinct().Count());
        Assert.Equal(expected, actual);
        await using var previousContext = database.CreateContext();
        var previous = await Handler(previousContext).Handle(new(null, null, null, 100, cursors[1]), default);
        Assert.Equal(expected.Skip(100).Take(100), previous.Items.Select(agent => agent.AgentId));
    }

    [Fact]
    public async Task Combined_filters_find_137_name_or_external_id_matches_and_keep_the_authoritative_total_on_every_page()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agents = await SeedFleet(database);
        var expected = InSqlOrder(agents.Take(137)).Select(agent => agent.Id).ToArray();
        Assert.Contains("INVOICE-EU", agents[0].Name);
        Assert.DoesNotContain("invoice-eu", agents[0].ExternalAgentId.Value, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("invoice-eu", agents[1].Name, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("invoice-eu", agents[1].ExternalAgentId.Value);
        var query = new ListAgentsQuery("active", "production", " invoice-eu ", 100);

        await using var context = database.CreateContext();
        var first = await Handler(context).Handle(query, default);
        var last = await Handler(context).Handle(query with { Cursor = first.NextCursor }, default);
        var previous = await Handler(context).Handle(query, default);

        Assert.Equal(100, first.Items.Count);
        Assert.Equal(37, last.Items.Count);
        Assert.NotNull(first.NextCursor);
        Assert.Null(last.NextCursor);
        Assert.Equal(137, first.TotalCount);
        Assert.Equal(137, last.TotalCount);
        Assert.Equal(expected, first.Items.Concat(last.Items).Select(agent => agent.AgentId));
        Assert.Equal(first.Items.Select(agent => agent.AgentId), previous.Items.Select(agent => agent.AgentId));
        Assert.All(first.Items.Concat(last.Items), agent =>
        {
            Assert.Equal("Active", agent.Status);
            Assert.Equal("Production", agent.Environment);
        });

        var changed = await Handler(context).Handle(query with { Status = "Failed", Cursor = null }, default);
        Assert.Equal(20, changed.TotalCount);
        Assert.Equal(20, changed.Items.Count);
        Assert.Null(changed.NextCursor);
        var cleared = await Handler(context).Handle(new(null, null, null, 100), default);
        Assert.Equal(237, cleared.TotalCount);
        Assert.Equal(100, cleared.Items.Count);
        var noMatches = await Handler(context).Handle(query with { Search = "no-such-registration" }, default);
        Assert.Equal(0, noMatches.TotalCount);
        Assert.Empty(noMatches.Items);
        Assert.Null(noMatches.NextCursor);
    }

    [Fact]
    public async Task Search_is_case_insensitive_even_on_case_sensitive_columns_and_treats_wildcards_as_literals()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await database.ExecuteAsync("""
            ALTER TABLE [AgentRegistrations] ALTER COLUMN [Name] nvarchar(256) COLLATE Latin1_General_100_CS_AS_SC NOT NULL;
            DROP INDEX [IX_AgentRegistrations_ExternalAgentId] ON [AgentRegistrations];
            ALTER TABLE [AgentRegistrations] ALTER COLUMN [ExternalAgentId] nvarchar(128) COLLATE Latin1_General_100_CS_AS_SC NOT NULL;
            CREATE UNIQUE INDEX [IX_AgentRegistrations_ExternalAgentId] ON [AgentRegistrations] ([ExternalAgentId]) WHERE [IsDeleted] = 0;
            """);
        var nameMatch = TestData.Agent();
        nameMatch.Name = "INVOICE-EU name only";
        nameMatch.ExternalAgentId = new("name-match-only");
        var idMatch = TestData.Agent();
        idMatch.Name = "External identifier only";
        idMatch.ExternalAgentId = new("External-Invoice-Eu-match");
        var literal = TestData.Agent();
        literal.Name = @"Literal %_[\ characters";
        var unrelated = TestData.Agent();
        unrelated.Name = "Unrelated registration";
        await using var context = database.CreateContext();
        context.AgentRegistrations.AddRange(nameMatch, idMatch, literal, unrelated);
        await context.SaveChangesAsync();
        var handler = Handler(context);

        foreach (var search in new[] { "invoice-eu", "INVOICE-EU", " Invoice-Eu " })
        {
            var response = await handler.Handle(new(null, null, search, 100), default);
            Assert.Equal(2, response.TotalCount);
            Assert.Equal(new[] { nameMatch.Id, idMatch.Id }.Order(), response.Items.Select(agent => agent.AgentId).Order());
        }
        foreach (var search in new[] { "%", "_[", @"\" })
        {
            var response = await handler.Handle(new(null, null, search, 100), default);
            Assert.Equal(1, response.TotalCount);
            Assert.Equal(literal.Id, Assert.Single(response.Items).AgentId);
        }
        var injection = await handler.Handle(new(null, null, "' OR 1=1 --", 100), default);
        Assert.Equal(0, injection.TotalCount);
        Assert.Empty(injection.Items);
    }

    [Fact]
    public async Task Fleet_totals_do_not_depend_on_preview_size_and_refresh_after_disable_and_Gateway_deletion()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await SeedFleet(database);
        await using var context = database.CreateContext();
        var handler = Handler(context);
        var fleet = await handler.Handle(new(null, null, null, 1), default);
        var active = await handler.Handle(new("Active", null, null, 1), default);
        var approval = await handler.Handle(new("AwaitingAdminApproval", null, null, 8), default);
        var failed = await handler.Handle(new("Failed", null, null, 8), default);
        var manual = await handler.Handle(new("RequiresManualIntervention", null, null, 8), default);
        Assert.Single(fleet.Items);
        Assert.Single(active.Items);
        Assert.Equal(237, fleet.TotalCount);
        Assert.Equal(180, active.TotalCount);
        Assert.Equal(30, approval.TotalCount + failed.TotalCount + manual.TotalCount);

        var registration = await context.AgentRegistrations.FirstAsync(agent => agent.Status == AgentStatus.Active);
        registration.Status = AgentStatus.Disabled;
        await context.SaveChangesAsync();
        Assert.Equal(179, (await handler.Handle(new("Active", null, null, 1), default)).TotalCount);
        Assert.Equal(237, (await handler.Handle(new(null, null, null, 1), default)).TotalCount);
        registration.IsDeleted = true;
        registration.Status = AgentStatus.Deleted;
        registration.DeletedAtUtc = TestData.Now.AddDays(1);
        await context.SaveChangesAsync();
        Assert.Equal(236, (await handler.Handle(new(null, null, null, 1), default)).TotalCount);
        Assert.Equal(0, (await handler.Handle(new(null, null, registration.ExternalAgentId.Value, 100), default)).TotalCount);
    }

    [Fact]
    public async Task A_full_final_page_has_no_cursor_and_invalid_cursors_never_reach_parsing_exceptions()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await SeedFleet(database);
        await using var context = database.CreateContext();
        var response = await Handler(context).Handle(new("Disabled", null, null, 20), default);
        Assert.Equal(20, response.Items.Count);
        Assert.Equal(20, response.TotalCount);
        Assert.Null(response.NextCursor);
        var repository = new AgentRegistrationRepository(context);
        var error = await Assert.ThrowsAsync<Gateway.Application.Exceptions.ValidationException>(() =>
            repository.ListAsync(new AgentListFilter(null, null, null, 100, "malformed-cursor"), default));
        Assert.Equal([ListAgentsCursor.InvalidMessage], error.Errors["Cursor"]);
    }

    private static ListAgentsHandler Handler(GatewayDbContext context) => new(
        new AgentRegistrationRepository(context), new AiInteractionRepository(context), new ActivityReceiptRepository(context));

    private static IOrderedEnumerable<AgentRegistration> InSqlOrder(IEnumerable<AgentRegistration> agents) =>
        agents.OrderBy(agent => agent.CreatedAtUtc).ThenBy(agent => new SqlGuid(agent.Id));

    private static async Task<List<AgentRegistration>> SeedFleet(LocalSqlDatabase database)
    {
        var agents = Enumerable.Range(0, 237).Select(index =>
        {
            var agent = TestData.Agent();
            agent.Id = Guid.Parse($"{1000 - index:x8}-0000-4000-8000-{index + 1:x12}");
            agent.FeatureConfiguration.AgentRegistrationId = agent.Id;
            agent.CreatedAtUtc = TestData.Now.AddTicks(index / 120);
            agent.UpdatedAtUtc = agent.CreatedAtUtc;
            agent.Name = index < 137 && index % 2 == 0 || index is >= 160 and < 200
                ? $"INVOICE-EU name {index:000}" : $"Ordinary name {index:000}";
            agent.ExternalAgentId = new(index < 137 && index % 2 != 0
                ? $"external-invoice-eu-{index:000}" : $"external-other-{index:000}");
            agent.Environment = index < 180 || index is >= 200 and < 225 ? AgentEnvironment.Production
                : index < 200 ? AgentEnvironment.Test : AgentEnvironment.Development;
            agent.Status = index switch
            {
                < 160 => AgentStatus.Active,
                < 180 => AgentStatus.Failed,
                < 200 => AgentStatus.Active,
                < 220 => AgentStatus.Disabled,
                < 225 => AgentStatus.AwaitingAdminApproval,
                < 230 => AgentStatus.RequiresManualIntervention,
                _ => AgentStatus.Draft
            };
            return agent;
        }).ToList();
        await using var context = database.CreateContext();
        context.AgentRegistrations.AddRange(agents);
        await context.SaveChangesAsync();
        return agents;
    }
}
