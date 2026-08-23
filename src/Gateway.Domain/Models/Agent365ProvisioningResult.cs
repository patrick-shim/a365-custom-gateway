namespace Gateway.Domain.Models;

public sealed record Agent365ProvisioningResult(
    bool Succeeded,
    string? AppRegistrationId,
    string? ServicePrincipalId,
    string? BlueprintId,
    string? Agent365AgentId,
    string? Agent365InstanceId,
    string? ErrorCode,
    string? ErrorSummary);
