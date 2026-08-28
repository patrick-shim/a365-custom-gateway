namespace Gateway.AdminUi.Models;

public sealed record AgentListQuery(
    string? Status = null,
    string? Environment = null,
    string? Search = null,
    int Limit = 50,
    string? Cursor = null);
