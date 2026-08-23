namespace Gateway.Contracts.Dtos;

public record BatchActivityItemDto(
    string ActivityId,
    string? SessionId,
    string ActivityType,
    DateTime OccurredAtUtc,
    ActorDto Actor,
    ToolDto? Tool,
    Dictionary<string, string>? Attributes);
