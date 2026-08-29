using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public class PromptEvaluationRecord
{
    public Guid Id { get; set; }
    public Guid AgentRegistrationId { get; set; }
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
