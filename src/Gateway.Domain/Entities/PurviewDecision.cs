using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public class PurviewDecision
{
    public Guid Id { get; set; }
    public Guid AgentRegistrationId { get; set; }
    public Guid? AiInteractionRecordId { get; set; }
    public PurviewDecisionType Decision { get; set; }
    public string? PolicyAction { get; set; }
    public PurviewExecutionMode? ExecutionMode { get; set; }
    public string? ProtectionScopeId { get; set; }
    public string? TenantUserObjectId { get; set; }
    public DateTime EvaluatedAtUtc { get; set; }

    public AgentRegistration AgentRegistration { get; set; } = null!;
    public AiInteractionRecord? AiInteractionRecord { get; set; }
}
