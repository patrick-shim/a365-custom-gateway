namespace Gateway.Domain.Models;

public sealed record AgentProvisioningRequest(
    Guid AgentRegistrationId,
    string ExternalAgentId,
    string Name,
    string? Description,
    string OwnerObjectId,
    string Environment,
    string BlueprintSelectionMode = "UseExisting",
    string? RequestedBlueprintObjectId = null,
    string? RequestedBlueprintDisplayName = null);
