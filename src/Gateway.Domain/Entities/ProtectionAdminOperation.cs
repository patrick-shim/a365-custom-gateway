using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Entities;

public class ProtectionAdminOperation
{
    private readonly List<ProtectionAdminOperationStep> _steps = [];

    public Guid Id { get; set; }
    public int WorkflowVersion { get; set; } = ProtectionAdminWorkflow.CurrentVersion;
    public ProtectionAdminOperationType Type { get; set; }
    public ProtectionAdminOperationStatus Status { get; set; }
    public EntraTenantId TenantId { get; set; }
    public string ActorObjectId { get; set; } = string.Empty;
    public ProtectionAdminTargetType TargetType { get; set; }
    public string TargetIdentifier { get; set; } = string.Empty;
    public string ReviewedPayloadHash { get; set; } = string.Empty;
    public string? AcceptedRequestHash { get; set; }
    public string? ResultJson { get; set; }
    public ProtectionIdempotencyKey IdempotencyKey { get; set; }
    public byte[] ExpectedRowVersion { get; set; } = [];
    public ProtectionConfirmationVerifier? ConfirmationVerifier { get; set; }
    public ProtectionRetryDisposition RetryDisposition { get; set; }
    public int AttemptCount { get; set; }
    public int MaximumAttempts { get; set; }
    public DateTime? NextAttemptAtUtc { get; set; }
    public Guid CorrelationId { get; set; }
    public Guid? ReadbackReferenceId { get; set; }
    public string? LastFailureCode { get; set; }
    public string? RequiredAction { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public DateTime? StartedAtUtc { get; set; }
    public DateTime? CompletedAtUtc { get; set; }
    public DateTime UpdatedAtUtc { get; set; }
    public byte[] RowVersion { get; set; } = [];

    public IReadOnlyList<ProtectionAdminOperationStep> OrderedSteps =>
        _steps.OrderBy(step => step.OrderIndex).ToArray();

    public bool RequiresManualIntervention =>
        Status == ProtectionAdminOperationStatus.RequiresManualIntervention ||
        RetryDisposition == ProtectionRetryDisposition.RequiresManualIntervention;

    public bool CanRetryAt(DateTime utcNow) =>
        utcNow.Kind == DateTimeKind.Utc &&
        Status == ProtectionAdminOperationStatus.Failed &&
        RetryDisposition == ProtectionRetryDisposition.Retryable &&
        AttemptCount < MaximumAttempts &&
        (NextAttemptAtUtc is null || NextAttemptAtUtc <= utcNow);

    public void AddStep(ProtectionAdminOperationStep step)
    {
        ArgumentNullException.ThrowIfNull(step);
        if (step.OrderIndex < 0)
            throw new ArgumentOutOfRangeException(nameof(step), "A step order cannot be negative.");
        if (_steps.Any(existing => existing.OrderIndex == step.OrderIndex))
            throw new InvalidOperationException("Protection operation step order values must be distinct.");

        step.ProtectionAdminOperationId = Id;
        step.Operation = this;
        _steps.Add(step);
    }
}
