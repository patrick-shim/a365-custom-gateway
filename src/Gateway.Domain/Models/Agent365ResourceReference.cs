namespace Gateway.Domain.Models;

public sealed record Agent365ResourceReference(
    Guid AgentRegistrationId,
    string? AppRegistrationId,
    string? ServicePrincipalId,
    string? BlueprintId,
    string? Agent365AgentId,
    string? Agent365InstanceId);
