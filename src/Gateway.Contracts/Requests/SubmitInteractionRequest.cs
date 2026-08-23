using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Requests;

public record SubmitInteractionRequest(
    string ExternalAgentId,
    string InteractionId,
    string? SessionId,
    DateTime OccurredAtUtc,
    UserContextDto? UserContext,
    ContentDto Prompt,
    ContentDto Response,
    ModelDto? Model,
    Dictionary<string, string>? Metadata);
