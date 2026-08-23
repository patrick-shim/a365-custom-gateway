using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Requests;

public record SubmitActivityRequest(
    string ExternalAgentId,
    string ActivityId,
    string? SessionId,
    string ActivityType,
    DateTime OccurredAtUtc,
    ActorDto Actor,
    ToolDto? Tool,
    Dictionary<string, string>? Attributes);
