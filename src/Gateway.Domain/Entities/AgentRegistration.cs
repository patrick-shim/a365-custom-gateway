using Gateway.Domain.Enums;
using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Entities;

public class AgentRegistration
{
    public Guid Id { get; set; }
    public ExternalAgentId ExternalAgentId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }
    public string OwnerObjectId { get; set; } = string.Empty;
    public AgentEnvironment Environment { get; set; }
    public AgentStatus Status { get; set; }
    public string? Agent365AgentId { get; set; }
    public string? BlueprintId { get; set; }
    public string? Agent365InstanceId { get; set; }
    public string? ExternalClientId { get; set; }
    public string? AgentIdentityObjectId { get; set; }
    public string? BlueprintObjectId { get; set; }
    public string BlueprintSelectionMode { get; set; } = "Legacy";
    public string? RequestedBlueprintObjectId { get; set; }
    public string? RequestedBlueprintDisplayName { get; set; }
    public string? LastProvisioningErrorCode { get; set; }
    public string? LastProvisioningErrorSummary { get; set; }
    public bool IsDeleted { get; set; }
    public DateTime? DeletedAtUtc { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public string CreatedByObjectId { get; set; } = string.Empty;
    public DateTime UpdatedAtUtc { get; set; }
    public string UpdatedByObjectId { get; set; } = string.Empty;
    public byte[] RowVersion { get; set; } = [];

    public AgentFeatureConfiguration FeatureConfiguration { get; set; } = null!;
    public ICollection<ProvisioningJob> ProvisioningJobs { get; set; }
    public AgentCredentialReference? CredentialReference { get; set; }

    public AgentRegistration()
    {
        ProvisioningJobs = new List<ProvisioningJob>();
    }
}
