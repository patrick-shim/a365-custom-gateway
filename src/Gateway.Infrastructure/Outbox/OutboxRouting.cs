namespace Gateway.Infrastructure.Outbox;

internal static class OutboxRouting
{
    public const string ProvisioningDestination = "gateway-provisioning-v3";

    public static string ResolveDestination(string messageType)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(messageType);
        return messageType switch
        {
            "ProvisionAgent" or "DeleteAgent" or "RetryProvisioning" or
            "ProcessActivity" or "ExportInteraction" => ProvisioningDestination,
            _ => throw new InvalidOperationException($"Unsupported outbox message type: {messageType}.")
        };
    }

    public static string ResolveQueueName(string messageType, string provisioningQueueName)
    {
        var destination = ResolveDestination(messageType);
        if (!string.Equals(provisioningQueueName, destination, StringComparison.Ordinal))
            throw new InvalidOperationException("RabbitMQ provisioning queue must be gateway-provisioning-v3.");
        return destination;
    }
}
