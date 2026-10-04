namespace Gateway.Domain.Entities;

// Each review is immutable once confirmed. Retries use the same operation ID.
public sealed class AgentPolicyAssignment
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public Guid AgentRegistrationId { get; set; }
    public Guid AgentIdentityId { get; set; }
    public Guid BlueprintId { get; set; }
    public Guid PolicyId { get; set; }
    public string PolicyName { get; set; } = "";
    public string ReviewedRevision { get; set; } = "";
    public string? AssignedRevision { get; set; }
    public string ActorObjectId { get; set; } = "";
    public Guid ReviewedProtectionRevision { get; set; }
    public string Status { get; set; } = "Review";
    public string? FailureCode { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public DateTime ExpiresAtUtc { get; set; }
    public DateTime? ConfirmedAtUtc { get; set; }
    public DateTime? AssignedAtUtc { get; set; }
}
