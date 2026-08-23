namespace Gateway.Contracts.Dtos;

public record AgentFeaturesDto(
    string? ObservabilityMode,
    bool? PurviewEnabled,
    string? PurviewMode);
