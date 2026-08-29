namespace Gateway.Setup.Security;

internal sealed class SetupShutdownService(
    SetupActivityTracker activity,
    IHostApplicationLifetime lifetime,
    TimeProvider timeProvider) : BackgroundService
{
    internal static readonly TimeSpan IdleTimeout = TimeSpan.FromMinutes(45);
    internal static readonly TimeSpan CompletionTimeout = TimeSpan.FromMinutes(2);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(10), timeProvider);
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            var now = timeProvider.GetUtcNow();
            var snapshot = activity.Snapshot();
            if (snapshot.OperationActive)
            {
                continue;
            }

            if (snapshot.CompletedUtc is { } completed && now - completed >= CompletionTimeout)
            {
                lifetime.StopApplication();
                return;
            }

            if (now - snapshot.LastActivityUtc >= IdleTimeout)
            {
                lifetime.StopApplication();
                return;
            }
        }
    }
}
