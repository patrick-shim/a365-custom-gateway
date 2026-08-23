namespace Gateway.Contracts.Responses;

public record ActivityReceiptDto(
    Guid ReceiptId,
    string ActivityId,
    string Status,
    DateTime ReceivedAtUtc,
    string? CorrelationId);
