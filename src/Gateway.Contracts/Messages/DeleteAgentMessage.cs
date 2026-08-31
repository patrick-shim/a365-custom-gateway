namespace Gateway.Contracts.Messages;

public sealed record DeleteAgentMessage(
    Guid AgentRegistrationId,
    Guid JobId,
    string? CorrelationId);
