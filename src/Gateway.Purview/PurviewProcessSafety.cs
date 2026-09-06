using System.ComponentModel;
using System.Diagnostics;

namespace Gateway.Purview;

public sealed class PurviewProcessSafety
{
    private int _unsafe;
    public bool CanMutate => Volatile.Read(ref _unsafe) == 0;
    public void MarkTerminationUnproven() => Interlocked.Exchange(ref _unsafe, 1);
}

public interface IPurviewOwnedProcess
{
    bool HasExited { get; }
    void Kill(bool entireProcessTree);
    Task WaitForExitAsync(CancellationToken cancellationToken);
}

public sealed class PurviewOwnedProcess(Process process) : IPurviewOwnedProcess
{
    public bool HasExited => process.HasExited;
    public void Kill(bool entireProcessTree) => process.Kill(entireProcessTree);
    public Task WaitForExitAsync(CancellationToken cancellationToken) =>
        process.WaitForExitAsync(cancellationToken);
}

// Own the child immediately after Start, including failures while writing stdin
// or reading output. Disposing Process alone does not stop a running child.
public sealed class PurviewProcessLease(Process process, PurviewProcessSafety safety)
    : IAsyncDisposable
{
    public async ValueTask DisposeAsync() =>
        await PurviewProcessTermination.TryTerminateAsync(
            new PurviewOwnedProcess(process), safety, TimeSpan.FromSeconds(5));
}

public static class PurviewProcessTermination
{
    public static async Task<bool> TryTerminateAsync(
        IPurviewOwnedProcess process,
        PurviewProcessSafety safety,
        TimeSpan timeout)
    {
        if (timeout <= TimeSpan.Zero || timeout > TimeSpan.FromSeconds(10))
            throw new ArgumentOutOfRangeException(nameof(timeout));

        using var deadline = new CancellationTokenSource(timeout);
        try
        {
            if (process.HasExited) return true;
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // A race with exit is possible; only exit readback can prove it.
            }
            catch (Win32Exception)
            {
                // Access/process failures do not prove that the child stopped.
            }

            await process.WaitForExitAsync(deadline.Token).WaitAsync(deadline.Token);
            if (process.HasExited) return true;
        }
        catch (OperationCanceledException)
        {
        }
        catch (InvalidOperationException)
        {
        }
        catch (Win32Exception)
        {
        }
        catch (NotSupportedException)
        {
        }

        // This process cannot accept another mutation. There is no remote reset
        // endpoint; an owned host recycle is required before admission resumes.
        safety.MarkTerminationUnproven();
        return false;
    }
}
