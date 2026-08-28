namespace Gateway.Infrastructure.Outbox;

public sealed class OutboxRelayOptions
{
    public bool Enabled { get; set; } = true;
    public int PollingIntervalSeconds { get; set; } = 5;
    public int BatchSize { get; set; } = 50;
    public int MaxRetryCount { get; set; } = 5;
    public int InitialRetryDelaySeconds { get; set; } = 5;
    public int MaxRetryDelaySeconds { get; set; } = 300;
    public int ClaimLeaseSeconds { get; set; } = 120;
}
