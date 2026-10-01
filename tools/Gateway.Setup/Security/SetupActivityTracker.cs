namespace Gateway.Setup.Security;

internal sealed class SetupActivityTracker
{
    private readonly object sync = new();
    private DateTimeOffset lastActivityUtc = DateTimeOffset.UtcNow;
    private DateTimeOffset? completedUtc;
    private bool operationActive;

    public void Touch()
    {
        lock (sync)
        {
            lastActivityUtc = DateTimeOffset.UtcNow;
        }
    }

    public void SetOperationActive(bool active)
    {
        lock (sync)
        {
            operationActive = active;
            lastActivityUtc = DateTimeOffset.UtcNow;
        }
    }

    public void MarkCompleted()
    {
        lock (sync)
        {
            completedUtc ??= DateTimeOffset.UtcNow;
            lastActivityUtc = DateTimeOffset.UtcNow;
        }
    }

    public SetupActivitySnapshot Snapshot()
    {
        lock (sync)
        {
            return new SetupActivitySnapshot(lastActivityUtc, completedUtc, operationActive);
        }
    }
}

internal sealed record SetupActivitySnapshot(
    DateTimeOffset LastActivityUtc,
    DateTimeOffset? CompletedUtc,
    bool OperationActive);
