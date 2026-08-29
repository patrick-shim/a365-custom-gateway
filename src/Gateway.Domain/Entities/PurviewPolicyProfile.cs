namespace Gateway.Domain.Entities;

/// <summary>
/// Durable, non-secret description of a Gateway-managed Purview collection
/// and DLP policy pair. Provider identifiers are stored only after exact
/// readback verification.
/// </summary>
public class PurviewPolicyProfile
{
    public Guid Id { get; set; }
    public string DisplayName { get; set; } = string.Empty;
    public string Template { get; set; } = "AllSensitiveInformation";
    public string Mode { get; set; } = "AuditOnly";
    public string Status { get; set; } = "Pending";
    public string CollectionPolicyName { get; set; } = string.Empty;
    public string DlpPolicyName { get; set; } = string.Empty;
    public string DlpRuleName { get; set; } = string.Empty;
    public string? CollectionPolicyId { get; set; }
    public string? DlpPolicyId { get; set; }
    public string? DlpRuleId { get; set; }
    public string BlueprintApplicationIdsJson { get; set; } = "[]";
    public DateTime? VerifiedAtUtc { get; set; }
    public string? LastErrorCode { get; set; }
    public DateTime CreatedAtUtc { get; set; }
    public string CreatedByObjectId { get; set; } = string.Empty;
    public DateTime UpdatedAtUtc { get; set; }
    public byte[] RowVersion { get; set; } = [];

    public ICollection<AgentRegistration> AgentRegistrations { get; set; } =
        new List<AgentRegistration>();
}
