using Gateway.Domain.Enums;

namespace Gateway.Domain.Entities;

public class ActivityReceipt
{
    public Guid Id { get; set; }
    public Guid AgentRegistrationId { get; set; }
    public string ExternalActivityId { get; set; } = string.Empty;
    public string? SessionId { get; set; }
    public ActivityType ActivityType { get; set; }
    public ActorType ActorType { get; set; }
    public ProcessingStatus ProcessingStatus { get; set; }
    public string CorrelationId { get; set; } = string.Empty;
    public DateTime OccurredAtUtc { get; set; }
    public DateTime ReceivedAtUtc { get; set; }
    public DateTime? ProcessedAtUtc { get; set; }

    public AgentRegistration AgentRegistration { get; set; } = null!;
}
