using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public class ProtectionAdminOperationStep
{
    public Guid Id { get; set; }
    public Guid ProtectionAdminOperationId { get; set; }
    public ProtectionAdminStepType StepType { get; set; }
    public ProtectionAdminStepStatus Status { get; set; }
    public int OrderIndex { get; set; }
    public int AttemptCount { get; set; }
    public ProtectionRetryDisposition RetryDisposition { get; set; }
    public DateTime? NextAttemptAtUtc { get; set; }
    public Guid? ReadbackReferenceId { get; set; }
    public string? FailureCode { get; set; }
    public DateTime? StartedAtUtc { get; set; }
    public DateTime? CompletedAtUtc { get; set; }

    public ProtectionAdminOperation Operation { get; set; } = null!;

    public bool RequiresManualIntervention =>
        Status == ProtectionAdminStepStatus.RequiresManualIntervention ||
        RetryDisposition == ProtectionRetryDisposition.RequiresManualIntervention;

    public bool CanRetryAt(DateTime utcNow, int maximumAttempts) =>
        utcNow.Kind == DateTimeKind.Utc &&
        Status == ProtectionAdminStepStatus.Failed &&
        RetryDisposition == ProtectionRetryDisposition.Retryable &&
        AttemptCount < maximumAttempts &&
        (NextAttemptAtUtc is null || NextAttemptAtUtc <= utcNow);
}
