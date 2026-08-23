using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Requests;

public record RegisterAgentRequest(
    string ExternalAgentId,
    string Name,
    string? Description,
    string OwnerObjectId,
    string Environment,
    AgentFeaturesDto? Features);
