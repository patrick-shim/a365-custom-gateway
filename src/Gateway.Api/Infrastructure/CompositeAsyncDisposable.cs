namespace Gateway.Api.Infrastructure;

internal sealed class CompositeAsyncDisposable : IAsyncDisposable
{
    private readonly IReadOnlyList<IAsyncDisposable> _leases;

    public CompositeAsyncDisposable(IReadOnlyList<IAsyncDisposable> leases)
    {
        _leases = leases;
    }

    public async ValueTask DisposeAsync()
    {
        for (var index = _leases.Count - 1; index >= 0; index--)
            await _leases[index].DisposeAsync();
    }
}
