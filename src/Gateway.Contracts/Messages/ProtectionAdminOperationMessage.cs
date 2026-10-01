namespace Gateway.Contracts.Messages;

/// <summary>
/// Carries only durable operation coordinates. Reviewed intent and readback
/// evidence are loaded from persistence rather than copied into the queue.
/// </summary>
public sealed record ProtectionAdminOperationMessage(
    Guid OperationId,
    int WorkflowVersion,
    int ExpectedStepIndex,
    Guid CorrelationId,
    // The durable step attempt count at enqueue, before that attempt starts.
    // Null identifies legacy/unbound messages; it must never imply attempt zero.
    int? ExpectedStepAttemptCount = null);

public static class ProtectionAdminQueueContract
{
    public const string QueueName = "gateway-protection-admin-v1";
    public const int WorkflowVersion = 1;
}
