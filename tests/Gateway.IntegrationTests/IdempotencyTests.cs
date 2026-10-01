using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Infrastructure.Services;
using Gateway.IntegrationTests.Fixtures;
using Gateway.TestSupport;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests;

[Collection(SqlServerCollection.Name)]
[Trait("Category", "SqlServer")]
public sealed class IdempotencyTests(SqlServerFixture fixture)
{
    [Fact]
    public async Task Disposing_without_complete_rolls_back_saved_rows_and_releases_SQL_transaction_lock()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = TestData.Agent();
        await using (var seed = database.CreateContext())
        {
            seed.Add(agent);
            await seed.SaveChangesAsync();
        }
        await using (var context = database.CreateContext())
        {
            var service = new IdempotencyService(context);
            await using var lease = await service.AcquireScopeAsync(agent.Id, "/test", "same-key", default);
            Assert.NotNull(context.Database.CurrentTransaction);
            await service.SaveAsync(Record(agent.Id), default);
            await context.SaveChangesAsync();
            Assert.Equal(1, await context.IdempotencyRecords.CountAsync());
        }
        await using (var verify = database.CreateContext())
            Assert.Equal(0, await verify.IdempotencyRecords.CountAsync());
        await using (var retry = database.CreateContext())
        {
            var service = new IdempotencyService(retry);
            await using var lease = await service.AcquireScopeAsync(agent.Id, "/test", "same-key", default);
            await service.SaveAsync(Record(agent.Id), default);
            await retry.SaveChangesAsync();
            await lease.CompleteAsync(default);
            await lease.CompleteAsync(default);
        }
        await using var persisted = database.CreateContext();
        Assert.Equal(1, await persisted.IdempotencyRecords.CountAsync());
    }

    [Fact]
    public async Task Expired_scoped_record_reuses_its_row_but_unexpired_content_cannot_be_overwritten()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        var agent = TestData.Agent();
        context.Add(agent);
        (await context.SystemConfigurations.SingleAsync()).RetentionDaysIdempotencyRecords = 1;
        await context.SaveChangesAsync();
        var service = new IdempotencyService(context);
        var first = Record(agent.Id);
        await using (var lease = await service.AcquireScopeAsync(agent.Id, "/test", "same-key", default))
        {
            await service.SaveAsync(first, default);
            await context.SaveChangesAsync();
            await lease.CompleteAsync(default);
        }
        Assert.Equal(TestData.Now.AddDays(1), first.ExpiresAtUtc);
        Assert.NotNull(await service.GetAsync(agent.Id, "/test", "same-key", first.ExpiresAtUtc.AddTicks(-1), default));
        Assert.Null(await service.GetAsync(agent.Id, "/test", "same-key", first.ExpiresAtUtc, default));
        await Assert.ThrowsAsync<ConflictException>(() => service.SaveAsync(Record(agent.Id), default));

        var replacement = Record(agent.Id);
        replacement.CreatedAtUtc = first.ExpiresAtUtc;
        replacement.ResponseBody = "{\"replaced\":true}";
        await using (var lease = await service.AcquireScopeAsync(agent.Id, "/test", "same-key", default))
        {
            await service.SaveAsync(replacement, default);
            await context.SaveChangesAsync();
            await lease.CompleteAsync(default);
        }
        await using var verify = database.CreateContext();
        var saved = await verify.IdempotencyRecords.SingleAsync();
        Assert.Equal(first.Id, saved.Id);
        Assert.Equal(replacement.ResponseBody, saved.ResponseBody);
        Assert.Equal(TestData.Now.AddDays(2), saved.ExpiresAtUtc);
    }

    [Fact]
    public async Task Replay_is_registration_and_endpoint_scoped_and_legacy_unowned_records_are_quarantined()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        var firstAgent = TestData.Agent();
        var otherAgent = TestData.Agent();
        context.AddRange(firstAgent, otherAgent);
        await context.SaveChangesAsync();
        var service = new IdempotencyService(context);
        var first = Record(firstAgent.Id);
        await service.SaveAsync(first, default);
        await context.SaveChangesAsync();
        Assert.NotNull(await service.GetAsync(firstAgent.Id, "/test", "same-key", TestData.Now, default));
        Assert.Null(await service.GetAsync(otherAgent.Id, "/test", "same-key", TestData.Now, default));
        Assert.Null(await service.GetAsync(firstAgent.Id, "/other", "same-key", TestData.Now, default));

        var legacy = Record(firstAgent.Id);
        legacy.AgentRegistrationId = null;
        legacy.IdempotencyKey = "legacy-key";
        legacy.ExpiresAtUtc = TestData.Now.AddDays(1);
        context.IdempotencyRecords.Add(legacy);
        await context.SaveChangesAsync();
        var conflict = await Assert.ThrowsAsync<ConflictException>(() =>
            service.GetAsync(otherAgent.Id, "/test", "legacy-key", TestData.Now, default));
        Assert.Equal(ErrorCodes.IDEMPOTENCY_CONFLICT, conflict.ErrorCode);
        Assert.Null(await service.GetAsync(otherAgent.Id, "/test", "legacy-key", legacy.ExpiresAtUtc, default));
        await Assert.ThrowsAsync<ArgumentException>(() => service.SaveAsync(legacy, default));
    }

    [Fact]
    public async Task Data_plane_lease_defers_SQL_transaction_until_commit_phase_and_requires_that_phase()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        await using var context = database.CreateContext();
        var service = new IdempotencyService(context);
        await using (var lease = await service.AcquireDataPlaneScopeAsync(Guid.NewGuid(), "/test", "phase-key", default))
        {
            Assert.Null(context.Database.CurrentTransaction);
            await Assert.ThrowsAsync<InvalidOperationException>(() => lease.CompleteAsync(default));
            await lease.BeginCommitAsync(default);
            Assert.NotNull(context.Database.CurrentTransaction);
            await lease.CompleteAsync(default);
        }
        await using var transaction = await context.Database.BeginTransactionAsync();
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            service.AcquireDataPlaneScopeAsync(Guid.NewGuid(), "/test", "phase-key", default));
    }

    private static IdempotencyRecord Record(Guid agentId) => new()
    {
        Id = Guid.NewGuid(), AgentRegistrationId = agentId, Endpoint = "/test", IdempotencyKey = "same-key",
        RequestBodyHash = new string('a', 64), ResponseBody = "{\"accepted\":true}", ResponseStatusCode = 202,
        CreatedAtUtc = TestData.Now
    };
}
