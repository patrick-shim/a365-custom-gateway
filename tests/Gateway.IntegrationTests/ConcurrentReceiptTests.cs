using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Responses;
using Gateway.Domain.Models;
using Gateway.IntegrationTests.Fixtures;
using Gateway.TestSupport;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests;

[Collection(SqlServerCollection.Name)]
[Trait("Category", "SqlServer")]
public sealed class ConcurrentReceiptTests(SqlServerFixture fixture)
{
    [Fact]
    public async Task Concurrent_evaluations_with_same_key_wait_on_SQL_and_replay_one_provider_result()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = await PromptWorkflowTests.SeedProtectedAgentAsync(database);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var shield = new OfflinePromptShield
        {
            IsEnabled = true,
            Evaluate = async (_, _, ct) =>
            {
                entered.TrySetResult();
                await release.Task.WaitAsync(ct);
                return new PromptShieldEvaluationResult(false);
            }
        };
        await using var firstContext = database.CreateContext();
        await using var secondContext = database.CreateContext();
        var request = GatewaySqlHarness.Evaluation(agent);
        var first = new GatewaySqlHarness(firstContext, shield).Evaluate().Handle(request, timeout.Token);
        await entered.Task.WaitAsync(timeout.Token);
        var second = new GatewaySqlHarness(secondContext, shield).Evaluate().Handle(request, timeout.Token);
        try
        {
            await database.WaitForApplicationLockWaitAsync();
            Assert.False(second.IsCompleted);
        }
        finally
        {
            release.TrySetResult();
        }
        var results = await Task.WhenAll(first, second).WaitAsync(timeout.Token);
        Assert.Equal(results[0], results[1]);
        Assert.Equal(1, shield.Calls);
        await using var verify = database.CreateContext();
        Assert.Equal(1, await verify.PromptEvaluationRecords.CountAsync());
        Assert.Equal(1, await verify.IdempotencyRecords.CountAsync());
        Assert.Equal(1, await verify.AuditEvents.CountAsync());
        var conflict = await Assert.ThrowsAsync<ConflictException>(() =>
            new GatewaySqlHarness(verify, shield).Evaluate().Handle(
                request with { Prompt = new("text/plain", "changed payload") }, default));
        Assert.Equal(ErrorCodes.IDEMPOTENCY_CONFLICT, conflict.ErrorCode);
        Assert.Equal(1, shield.Calls);
    }

    [Fact]
    public async Task Concurrent_ingestion_same_key_stages_and_commits_only_once_then_replays()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = await PromptWorkflowTests.SeedProtectedAgentAsync(database);
        Guid receiptId;
        await using (var evaluate = database.CreateContext())
            receiptId = (await new GatewaySqlHarness(evaluate, GatewaySqlHarness.AllowingShield()).Evaluate()
                .Handle(GatewaySqlHarness.Evaluation(agent), default)).EvaluationReceiptId!.Value;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var store = new OfflineContentStore
        {
            AllowStaging = true,
            BeforeReturn = async ct =>
            {
                entered.TrySetResult();
                await release.Task.WaitAsync(ct);
            }
        };
        await using var firstContext = database.CreateContext();
        await using var secondContext = database.CreateContext();
        var request = GatewaySqlHarness.Interaction(agent, receiptId);
        var first = new GatewaySqlHarness(firstContext, content: store).Submit().Handle(request, timeout.Token);
        await entered.Task.WaitAsync(timeout.Token);
        var second = new GatewaySqlHarness(secondContext, content: store).Submit().Handle(request, timeout.Token);
        try
        {
            await database.WaitForApplicationLockWaitAsync();
            Assert.False(second.IsCompleted);
        }
        finally
        {
            release.TrySetResult();
        }
        var results = await Task.WhenAll(first, second).WaitAsync(timeout.Token);
        Assert.Equal(results[0], results[1]);
        Assert.Equal(1, store.Stores);
        Assert.Equal(0, store.Discards);
        await using var verify = database.CreateContext();
        Assert.Equal(1, await verify.AiInteractionRecords.CountAsync());
        Assert.Equal(1, await verify.OutboxMessages.CountAsync());
        Assert.Equal(2, await verify.IdempotencyRecords.CountAsync());
        Assert.Equal(1, await verify.AuditEvents.CountAsync(item => item.EventType == "InteractionSubmitted"));
        var conflict = await Assert.ThrowsAsync<ConflictException>(() =>
            new GatewaySqlHarness(verify, content: store).Submit().Handle(
                request with { Response = new("text/plain", "changed response") }, default));
        Assert.Equal(ErrorCodes.IDEMPOTENCY_CONFLICT, conflict.ErrorCode);
        Assert.Equal(1, store.Stores);
    }

    [Fact]
    public async Task Different_keys_racing_for_one_receipt_have_one_SQL_winner_and_compensate_only_the_loser()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        var agent = await PromptWorkflowTests.SeedProtectedAgentAsync(database);
        Guid receiptId;
        await using (var evaluate = database.CreateContext())
            receiptId = (await new GatewaySqlHarness(evaluate, GatewaySqlHarness.AllowingShield()).Evaluate()
                .Handle(GatewaySqlHarness.Evaluation(agent), default)).EvaluationReceiptId!.Value;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var bothStaged = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var arrivals = 0;
        var store = new OfflineContentStore
        {
            AllowStaging = true,
            MaximumStores = 2,
            BeforeReturn = async ct =>
            {
                if (Interlocked.Increment(ref arrivals) == 2)
                    bothStaged.TrySetResult();
                await bothStaged.Task.WaitAsync(ct);
            }
        };
        await using var firstContext = database.CreateContext();
        await using var secondContext = database.CreateContext();
        var first = AttemptAsync(new GatewaySqlHarness(firstContext, content: store), "race-1");
        var second = AttemptAsync(new GatewaySqlHarness(secondContext, content: store), "race-2");
        var results = await Task.WhenAll(first, second).WaitAsync(timeout.Token);
        Assert.Single(results, result => result.Receipt is not null);
        var rejected = Assert.Single(results, result => result.Error is not null);
        Assert.Equal(ErrorCodes.PROMPT_EVALUATION_INVALID, rejected.Error!.ErrorCode);
        Assert.Equal(2, store.Stores);
        Assert.Equal(1, store.Discards);
        Assert.Single(store.Staged);
        await using var verify = database.CreateContext();
        Assert.Equal(1, await verify.AiInteractionRecords.CountAsync());
        Assert.Equal(1, await verify.OutboxMessages.CountAsync());
        Assert.Equal(2, await verify.IdempotencyRecords.CountAsync());
        Assert.Equal(1, await verify.AuditEvents.CountAsync(item => item.EventType == "InteractionSubmitted"));
        Assert.NotNull((await verify.PromptEvaluationRecords.SingleAsync()).ConsumedAtUtc);

        async Task<(InteractionReceiptDto? Receipt, DomainException? Error)> AttemptAsync(GatewaySqlHarness harness, string key)
        {
            try { return (await harness.Submit().Handle(GatewaySqlHarness.Interaction(agent, receiptId, key), timeout.Token), null); }
            catch (DomainException error) { return (null, error); }
        }
    }
}
