namespace Gateway.Contracts.Responses;

public sealed record AgentIdentityBlueprintSummaryDto(
    Guid BlueprintObjectId,
    Guid BlueprintClientId,
    string DisplayName,
    bool IsAgent365Compatible,
    string? Agent365CompatibilityIssue);

public sealed record AgentIdentityBlueprintListResponse(
    IReadOnlyList<AgentIdentityBlueprintSummaryDto> Items);
