namespace Gateway.Provisioning.Worker;

internal sealed class ProvisioningWorkerOptions
{
    public string QueueName { get; set; } = "gateway-provisioning-v3";
    public int MaxConcurrentCalls { get; set; } = 5;
    public int MaxDeliveryCount { get; set; } = 10;
    public bool ProcessingEnabled { get; set; } = true;
    public bool ProvisioningExecutionEnabled { get; set; }
}
