using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public class ProvisioningJob
{
    public Guid Id { get; set; }
    public Guid AgentRegistrationId { get; set; }
    public OperationType Type { get; set; }
    public JobStatus Status { get; set; }
    public int PercentComplete { get; set; }
    public int WorkflowVersion { get; set; } = 1;
    public string? ErrorCode { get; set; }
    public string? ErrorSummary { get; set; }
    public DateTime StartedAtUtc { get; set; }
    public DateTime? CompletedAtUtc { get; set; }
    public DateTime CreatedAtUtc { get; set; }

    public AgentRegistration AgentRegistration { get; set; } = null!;
    public ICollection<ProvisioningJobStep> Steps { get; set; }

    public ProvisioningJob()
    {
        Steps = new List<ProvisioningJobStep>();
    }
}
