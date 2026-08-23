namespace Gateway.Contracts.Responses;

public record AgentListResponse(
    List<AgentSummaryDto> Items,
    string? NextCursor,
    int? TotalCount);
