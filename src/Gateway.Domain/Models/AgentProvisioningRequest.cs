namespace Gateway.Domain.Models;

public sealed record AgentProvisioningRequest(
    Guid AgentRegistrationId,
    string ExternalAgentId,
    string Name,
    string? Description,
    string OwnerObjectId,
    string Environment);
