namespace Gateway.Domain.Entities;

public class AuditEvent
{
    public Guid Id { get; set; }
    public Guid? AgentRegistrationId { get; set; }
    public string EventType { get; set; } = string.Empty;
    public string? PerformedByObjectId { get; set; }
    public string? PerformedByRole { get; set; }
    public string? Details { get; set; }
    public string? CorrelationId { get; set; }
    public DateTime OccurredAtUtc { get; set; }

    public AgentRegistration? AgentRegistration { get; set; }
}
