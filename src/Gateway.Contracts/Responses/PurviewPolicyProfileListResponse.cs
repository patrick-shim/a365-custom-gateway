using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

public sealed record PurviewPolicyProfileListResponse(
    IReadOnlyList<PurviewPolicyProfileSummaryDto> Items);
