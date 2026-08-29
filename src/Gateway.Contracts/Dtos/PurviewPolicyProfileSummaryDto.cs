namespace Gateway.Contracts.Dtos;

public sealed record PurviewPolicyProfileSummaryDto(
    Guid Id,
    string DisplayName,
    string Template,
    string Mode,
    string Status,
    int BlueprintCount,
    DateTime? VerifiedAtUtc);
