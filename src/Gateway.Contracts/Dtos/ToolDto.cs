namespace Gateway.Contracts.Dtos;

public record ToolDto(
    string Name,
    string? Operation,
    string Outcome,
    int? DurationMs);
