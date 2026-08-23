namespace Gateway.Domain.Models;

public sealed record ObservabilityExportRequest(
    Guid AgentRegistrationId,
    string Agent365AgentId,
    string SpanType,
    string CorrelationId,
    string? SessionId,
    string? TenantUserObjectId,
    DateTime StartedAtUtc,
    DateTime EndedAtUtc,
    IReadOnlyDictionary<string, string> Attributes);
