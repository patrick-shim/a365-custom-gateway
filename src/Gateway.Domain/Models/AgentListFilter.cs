namespace Gateway.Domain.Models;

public record AgentListFilter(
    string? Status,
    string? Environment,
    string? Search,
    int Limit,
    string? Cursor);
