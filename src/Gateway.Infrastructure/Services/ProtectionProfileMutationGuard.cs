using Gateway.Domain.Interfaces;

namespace Gateway.Infrastructure.Services;

internal sealed class ProtectionProfileMutationGuard(IProtectionAdminOperationLockProvider locks)
    : IProtectionProfileMutationGuard, IAsyncDisposable, IDisposable
{
    private readonly Dictionary<Guid, IAsyncDisposable> _held = [];
    public async Task HoldAsync(Guid profileId, CancellationToken cancellationToken)
    {
        if (!_held.ContainsKey(profileId))
            _held.Add(profileId, await locks.AcquireExecutionAsync(profileId, cancellationToken));
    }
    public async ValueTask DisposeAsync()
    {
        foreach (var lease in _held.Values.Reverse())
            await lease.DisposeAsync();
        _held.Clear();
    }
    public void Dispose() => DisposeAsync().AsTask().GetAwaiter().GetResult();
}
