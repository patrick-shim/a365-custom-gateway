using Gateway.Contracts.Messages;

namespace Gateway.Infrastructure.Outbox;

internal static class OutboxRouting
{
    public const string ProvisioningDestination = "gateway-provisioning-v3";
    public const string ProtectionAdminDestination = ProtectionAdminQueueContract.QueueName;
    public const string ProtectionAdminMessageType = nameof(ProtectionAdminOperationMessage);

    public static string ResolveDestination(string messageType)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(messageType);
        if (string.Equals(
            messageType,
            ProtectionAdminMessageType,
            StringComparison.Ordinal))
        {
            return ProtectionAdminDestination;
        }

        if (IsProtectionAdminLike(messageType))
        {
            throw new InvalidOperationException(
                "The protection administration outbox message type is not the exact supported v1 contract.");
        }

        return ProvisioningDestination;
    }

    public static string ResolveQueueName(
        string messageType,
        string provisioningQueueName)
    {
        var destination = ResolveDestination(messageType);
        if (destination == ProtectionAdminDestination)
            return ProtectionAdminQueueContract.QueueName;

        if (!string.Equals(
                provisioningQueueName,
                ProvisioningDestination,
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "The existing outbox publisher must remain isolated on gateway-provisioning-v3.");
        }

        return provisioningQueueName;
    }

    private static bool IsProtectionAdminLike(string messageType) =>
        messageType.Contains("ProtectionAdmin", StringComparison.Ordinal);
}
