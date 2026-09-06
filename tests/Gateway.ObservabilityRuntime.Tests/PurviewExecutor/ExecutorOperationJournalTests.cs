using Gateway.Purview;
using Gateway.Purview.Executor;
using System.Collections.Concurrent;

namespace Gateway.ObservabilityRuntime.Tests.PurviewExecutor;

public sealed class ExecutorOperationJournalTests
{
    private readonly Guid _deployment = Guid.NewGuid();
    private readonly Guid _tenant = Guid.NewGuid();
    private readonly Guid _operation = Guid.NewGuid();
    private readonly MemoryStore _store = new();

    [Fact]
    public async Task ConcurrentDuplicate_InvokesProviderOnce()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var journal = CreateJournal();
        var first = Execute(journal, async _ =>
        {
            Interlocked.Increment(ref calls);
            await release.Task;
        });
        var duplicates = await Task.WhenAll(Enumerable.Range(0, 30).Select(_ =>
            Execute(journal, _ => { Interlocked.Increment(ref calls); return Task.CompletedTask; })));
        Assert.All(duplicates, value => Assert.Equal(ExecutorMutationDisposition.OutcomeUnknown, value));
        release.SetResult();
        Assert.Equal(ExecutorMutationDisposition.Completed, await first);
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task CompletedClaim_ReplaysWithoutProvider()
    {
        var calls = 0;
        Task Mutation(CancellationToken _) { calls++; return Task.CompletedTask; }
        Assert.Equal(ExecutorMutationDisposition.Completed, await Execute(CreateJournal(), Mutation));
        Assert.Equal(ExecutorMutationDisposition.Replayed, await Execute(CreateJournal(), Mutation));
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task DifferentInput_ConflictsBeforeProvider()
    {
        await Execute(CreateJournal(), _ => Task.CompletedTask);
        var result = await CreateJournal().ExecuteAsync(_deployment, _tenant, _operation,
            "CreateDlpPolicy", "changed", _ => throw new InvalidOperationException(), default);
        Assert.Equal(ExecutorMutationDisposition.Conflict, result);
    }

    [Fact]
    public async Task DlpPolicyAndRule_AreIndependentMutationClaims()
    {
        var calls = 0;
        foreach (var step in new[] { "CreateDlpPolicy", "CreateDlpRule" })
        {
            Assert.Equal(ExecutorMutationDisposition.Completed,
                await CreateJournal().ExecuteAsync(_deployment, _tenant, _operation,
                    step, "same-intent", _ => { calls++; return Task.CompletedTask; }, default));
        }
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task DifferentTenantOrDeployment_CannotReplayAnotherClaim()
    {
        await Execute(CreateJournal(), _ => Task.CompletedTask);
        var calls = 0;
        foreach (var binding in new[] { (Guid.NewGuid(), _tenant), (_deployment, Guid.NewGuid()) })
        {
            Assert.Equal(ExecutorMutationDisposition.Completed,
                await CreateJournal().ExecuteAsync(binding.Item1, binding.Item2, _operation,
                    "CreateDlpPolicy", "intent", _ => { calls++; return Task.CompletedTask; }, default));
        }
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task AmbiguousProviderFailure_NeverRetriesMutation()
    {
        Assert.Equal(ExecutorMutationDisposition.OutcomeUnknown,
            await Execute(CreateJournal(), _ => throw new ExecutorProviderException()));
        Assert.Equal(ExecutorMutationDisposition.OutcomeUnknown,
            await Execute(CreateJournal(), _ => throw new InvalidOperationException()));
    }

    [Fact]
    public async Task LostCompletionWrite_PreservesStartedClaim()
    {
        _store.FailCompletion = true;
        await Assert.ThrowsAsync<IOException>(() => Execute(CreateJournal(), _ => Task.CompletedTask));
        _store.FailCompletion = false;
        Assert.Equal(ExecutorMutationDisposition.OutcomeUnknown,
            await Execute(CreateJournal(), _ => throw new InvalidOperationException()));
    }

    [Fact]
    public async Task Cancellation_NeverReleasesMutationClaim()
    {
        Assert.Equal(ExecutorMutationDisposition.OutcomeUnknown,
            await Execute(CreateJournal(), _ => throw new OperationCanceledException()));
        Assert.Equal(ExecutorMutationDisposition.OutcomeUnknown,
            await Execute(CreateJournal(), _ => throw new InvalidOperationException()));
    }

    [Fact]
    public async Task FailedClaimWrite_DoesNotInvokeProvider()
    {
        _store.FailCreate = true;
        var calls = 0;
        await Assert.ThrowsAsync<IOException>(() => Execute(CreateJournal(),
            _ => { calls++; return Task.CompletedTask; }));
        Assert.Equal(0, calls);
    }

    private ExecutorOperationJournal CreateJournal() => new(_store, TimeProvider.System, new PurviewProcessSafety());

    private Task<ExecutorMutationDisposition> Execute(ExecutorOperationJournal journal,
        Func<CancellationToken, Task> mutation) =>
        journal.ExecuteAsync(_deployment, _tenant, _operation, "CreateDlpPolicy", "intent", mutation, default);

    private sealed class MemoryStore : IExecutorClaimStore
    {
        private readonly ConcurrentDictionary<string, ExecutorClaim> _claims = new();
        public bool FailCompletion { get; set; }
        public bool FailCreate { get; set; }

        public Task<bool> TryCreateAsync(string key, ExecutorClaim value, CancellationToken cancellationToken)
        {
            if (FailCreate) throw new IOException("Simulated persistence failure.");
            return Task.FromResult(_claims.TryAdd(key, value));
        }

        public Task<ExecutorClaim?> ReadAsync(string key, CancellationToken cancellationToken) =>
            Task.FromResult(_claims.TryGetValue(key, out var claim) ? claim : null);

        public Task CompleteAsync(string key, ExecutorClaim started, CancellationToken cancellationToken)
        {
            if (FailCompletion) throw new IOException("Simulated persistence failure.");
            Assert.True(_claims.TryUpdate(key,
                started with { State = ExecutorClaimState.Completed, CompletedAtUtc = DateTimeOffset.UtcNow }, started));
            return Task.CompletedTask;
        }
    }
}
