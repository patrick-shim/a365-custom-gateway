namespace Gateway.Domain.Models;

public sealed record ObservabilityExportRequest(
    Guid AgentRegistrationId,
    Guid EventId,
    string ExternalAgentId,
    string AgentName,
    string SpanType,
    string CorrelationId,
    string? SessionId,
    string? TenantUserObjectId,
    DateTime StartedAtUtc,
    DateTime EndedAtUtc,
    string? ModelProvider = null,
    string? ModelName = null,
    string? AgentIdentityClientId = null,
    string? BlueprintClientId = null);
