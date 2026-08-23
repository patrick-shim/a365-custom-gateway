using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public class AiInteractionRecord
{
    public Guid Id { get; set; }
    public Guid AgentRegistrationId { get; set; }
    public string ExternalInteractionId { get; set; } = string.Empty;
    public string? SessionId { get; set; }
    public string? TenantUserObjectId { get; set; }
    public string? ContentBlobUri { get; set; }
    public string? ModelProvider { get; set; }
    public string? ModelName { get; set; }
    public ProcessingStatus ProcessingStatus { get; set; }
    public PurviewDecisionType PurviewStatus { get; set; }
    public string ObservabilityStatus { get; set; } = string.Empty;
    public string CorrelationId { get; set; } = string.Empty;
    public DateTime OccurredAtUtc { get; set; }
    public DateTime ReceivedAtUtc { get; set; }
    public DateTime? ProcessedAtUtc { get; set; }

    public AgentRegistration AgentRegistration { get; set; } = null!;
    public PurviewDecision? PurviewDecision { get; set; }
}
