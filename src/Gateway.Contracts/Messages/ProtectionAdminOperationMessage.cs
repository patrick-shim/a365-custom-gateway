namespace Gateway.Contracts.Messages;

/// <summary>
/// Carries only durable operation coordinates. Reviewed intent and readback
/// evidence are loaded from persistence rather than copied into the queue.
/// </summary>
public sealed record ProtectionAdminOperationMessage(
    Guid OperationId,
    int WorkflowVersion,
    int ExpectedStepIndex,
    Guid CorrelationId);

public static class ProtectionAdminQueueContract
{
    public const string QueueName = "gateway-protection-admin-v1";
    public const int WorkflowVersion = 1;
}
