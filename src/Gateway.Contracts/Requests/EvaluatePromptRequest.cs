using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Requests;

public sealed record EvaluatePromptRequest(
    string ExternalAgentId,
    string InteractionId,
    DateTime OccurredAtUtc,
    UserContextDto? UserContext,
    ContentDto Prompt);
