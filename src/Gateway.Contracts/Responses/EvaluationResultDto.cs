using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

public record EvaluationResultDto(
    string InteractionId,
    string Decision,
    List<PolicyActionDto>? PolicyActions,
    DateTime EvaluatedAtUtc,
    Guid ReceiptId,
    string? PurviewProcessing,
    string? ObservabilityProcessing);
