namespace Gateway.Infrastructure.Outbox;

public sealed class OutboxRelayOptions
{
    public int PollingIntervalSeconds { get; set; } = 5;
    public int BatchSize { get; set; } = 50;
    public int MaxRetryCount { get; set; } = 5;
}
