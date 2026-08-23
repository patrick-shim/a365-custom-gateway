namespace Gateway.Contracts.Responses;

public record InteractionReceiptDto(
    Guid ReceiptId,
    string InteractionId,
    string Status,
    string? PurviewProcessing,
    string? ObservabilityProcessing,
    string? CorrelationId);
