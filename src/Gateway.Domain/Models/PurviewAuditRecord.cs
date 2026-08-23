using Gateway.Domain.Enums;

namespace Gateway.Domain.Models;

public sealed record PurviewAuditRecord(
    Guid AgentRegistrationId,
    string TenantUserObjectId,
    string ExternalInteractionId,
    PurviewDecisionType Decision,
    string? PolicyAction,
    DateTime OccurredAtUtc,
    string CorrelationId);
