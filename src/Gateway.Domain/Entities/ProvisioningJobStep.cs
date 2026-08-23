using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public class ProvisioningJobStep
{
    public Guid Id { get; set; }
    public Guid ProvisioningJobId { get; set; }
    public ProvisioningStepType StepType { get; set; }
    public StepStatus Status { get; set; }
    public int OrderIndex { get; set; }
    public string? ResultData { get; set; }
    public string? ErrorCode { get; set; }
    public string? ErrorMessage { get; set; }
    public DateTime? StartedAtUtc { get; set; }
    public DateTime? CompletedAtUtc { get; set; }

    public ProvisioningJob ProvisioningJob { get; set; } = null!;
}
