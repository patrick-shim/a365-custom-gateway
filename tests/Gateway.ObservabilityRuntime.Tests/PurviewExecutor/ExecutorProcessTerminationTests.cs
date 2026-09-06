using Gateway.Purview;
using Gateway.Purview.Executor;
using System.ComponentModel;

namespace Gateway.ObservabilityRuntime.Tests.PurviewExecutor;

public sealed class PurviewProcessTerminationTests
{
    [Fact]
    public async Task FailedKill_AndNonCooperativeWait_AreBoundedAndBlockMutation()
    {
        var safety = new PurviewProcessSafety();
        var process = new FakeProcess { KillFails = true, NeverExits = true };
        var result = await PurviewProcessTermination.TryTerminateAsync(process, safety,
            TimeSpan.FromMilliseconds(30)).WaitAsync(TimeSpan.FromSeconds(2));
        Assert.False(result);
        Assert.False(safety.CanMutate);
        Assert.True(process.KillCalled);
    }

    [Fact]
    public async Task KillReturns_ButChildDoesNotExit_StillBlocksMutation()
    {
        var safety = new PurviewProcessSafety();
        var process = new FakeProcess { NeverExits = true };
        Assert.False(await PurviewProcessTermination.TryTerminateAsync(process, safety,
            TimeSpan.FromMilliseconds(30)));
        Assert.False(safety.CanMutate);
    }

    [Fact]
    public async Task FailedKill_WithIndependentExitProof_DoesNotQuarantine()
    {
        var safety = new PurviewProcessSafety();
        var process = new FakeProcess { KillFails = true };
        Assert.True(await PurviewProcessTermination.TryTerminateAsync(process, safety,
            TimeSpan.FromSeconds(1)));
        Assert.True(safety.CanMutate);
    }

    [Fact]
    public async Task ExitedChild_DoesNotRequireKill()
    {
        var safety = new PurviewProcessSafety();
        var process = new FakeProcess { HasExited = true };
        Assert.True(await PurviewProcessTermination.TryTerminateAsync(process, safety,
            TimeSpan.FromSeconds(1)));
        Assert.False(process.KillCalled);
    }

    [Fact]
    public async Task QuarantinedHost_DoesNotClaimOrInvokeAnotherMutation()
    {
        var safety = new PurviewProcessSafety();
        safety.MarkTerminationUnproven();
        var journal = new ExecutorOperationJournal(new MustNotUseStore(), TimeProvider.System, safety);
        Assert.Equal(ExecutorMutationDisposition.HostUnavailable,
            await journal.ExecuteAsync(Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(),
                "CreateDlpPolicy", "intent", _ => throw new InvalidOperationException(), default));
    }

    private sealed class FakeProcess : IPurviewOwnedProcess
    {
        public bool HasExited { get; set; }
        public bool KillFails { get; set; }
        public bool NeverExits { get; set; }
        public bool KillCalled { get; private set; }
        public void Kill(bool entireProcessTree)
        {
            Assert.True(entireProcessTree);
            KillCalled = true;
            if (KillFails) throw new Win32Exception();
        }

        public Task WaitForExitAsync(CancellationToken cancellationToken)
        {
            if (NeverExits) return new TaskCompletionSource().Task;
            HasExited = true;
            return Task.CompletedTask;
        }
    }

    private sealed class MustNotUseStore : IExecutorClaimStore
    {
        public Task<bool> TryCreateAsync(string key, ExecutorClaim value, CancellationToken cancellationToken) =>
            throw new InvalidOperationException();
        public Task<ExecutorClaim?> ReadAsync(string key, CancellationToken cancellationToken) =>
            throw new InvalidOperationException();
        public Task CompleteAsync(string key, ExecutorClaim started, CancellationToken cancellationToken) =>
            throw new InvalidOperationException();
    }
}
