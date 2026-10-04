namespace Gateway.Infrastructure.Messaging;

public sealed class RabbitMqOptions
{
    public const string SectionName = "RabbitMq";

    public string ConnectionUri { get; set; } = "amqp://gateway:gateway@localhost:5672/";
    public string ProvisioningQueueName { get; set; } = "gateway-provisioning-v3";
}
