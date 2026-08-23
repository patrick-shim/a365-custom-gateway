namespace Gateway.Infrastructure.ServiceBus;

public sealed class ServiceBusOptions
{
    public string ConnectionString { get; set; } = string.Empty;
    public string QueueName { get; set; } = "gateway-provisioning";
}
