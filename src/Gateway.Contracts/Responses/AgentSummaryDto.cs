using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

public record AgentSummaryDto(
    Guid AgentId,
    string ExternalAgentId,
    string Name,
    string? Description,
    string Status,
    string Environment,
    Agent365InfoDto? Agent365,
    AgentFeaturesDto? Features,
    DateTime? LastActivityAtUtc,
    DateTime CreatedAtUtc,
    DateTime UpdatedAtUtc);
