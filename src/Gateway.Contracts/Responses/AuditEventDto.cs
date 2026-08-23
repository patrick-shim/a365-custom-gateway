namespace Gateway.Contracts.Responses;

public record AuditEventDto(
    Guid EventId,
    Guid AgentId,
    string EventType,
    string? PerformedByObjectId,
    DateTime OccurredAtUtc,
    object? Details);
