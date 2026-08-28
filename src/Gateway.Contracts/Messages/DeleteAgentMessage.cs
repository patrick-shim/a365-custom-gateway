namespace Gateway.Contracts.Messages;

public sealed record DeleteAgentMessage(
    Guid AgentRegistrationId,
    Guid JobId,
    bool DeleteMicrosoftResources,
    string? CorrelationId);
