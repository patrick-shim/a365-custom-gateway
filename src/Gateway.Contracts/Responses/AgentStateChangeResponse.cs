namespace Gateway.Contracts.Responses;

public record AgentStateChangeResponse(
    Guid AgentId,
    string Status,
    DateTime EffectiveAtUtc);
