using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public class PromptEvaluationRecord
{
    public Guid Id { get; set; }
    public Guid AgentRegistrationId { get; set; }

    // Which Agent 365 identity the verdict belongs to. Null until that agent's
    // provisioning completes; an absent identity is recorded as absent rather than
    // filled in with a placeholder, so the evidence never overstates what is known.
    public Guid? Agent365AgentId { get; set; }
    public Guid? BlueprintId { get; set; }
    public string ExternalInteractionId { get; set; } = string.Empty;
    public string TenantUserObjectId { get; set; } = string.Empty;
    public byte[] PromptHashSalt { get; set; } = [];
    public byte[] PromptHash { get; set; } = [];
    public PromptEvaluationOutcome Outcome { get; set; }
    public PromptShieldDecisionType PromptShieldDecision { get; set; }
    public PurviewDecisionType PurviewDecision { get; set; }
    public string CorrelationId { get; set; } = string.Empty;
    public DateTime CreatedAtUtc { get; set; }
    public DateTime ExpiresAtUtc { get; set; }
    public DateTime? ConsumedAtUtc { get; set; }
    public byte[] RowVersion { get; set; } = [];

    public AgentRegistration AgentRegistration { get; set; } = null!;
}
