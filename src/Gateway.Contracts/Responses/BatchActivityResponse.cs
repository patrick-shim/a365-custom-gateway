using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

public record BatchActivityResponse(
    int Accepted,
    int Rejected,
    List<BatchActivityItemResult> Items,
    string? CorrelationId);
