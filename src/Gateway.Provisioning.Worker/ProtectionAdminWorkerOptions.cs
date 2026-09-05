namespace Gateway.Provisioning.Worker;

internal sealed class ProtectionAdminWorkerOptions
{
    public const string SectionName = "ProtectionAdminWorker";

    public int MaxConcurrentCalls { get; set; } = 2;
    public int MaxDeliveryCount { get; set; } = 10;
    public int MaximumPropagationAttempts { get; set; } = 5;
    public int PropagationRetryDelaySeconds { get; set; } = 30;
    public bool ProcessingEnabled { get; set; }
}
