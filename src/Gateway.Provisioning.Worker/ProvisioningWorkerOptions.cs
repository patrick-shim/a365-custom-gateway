namespace Gateway.Provisioning.Worker;

internal sealed class ProvisioningWorkerOptions
{
    public string QueueName { get; set; } = "gateway-provisioning";
    public int MaxConcurrentCalls { get; set; } = 5;
}
