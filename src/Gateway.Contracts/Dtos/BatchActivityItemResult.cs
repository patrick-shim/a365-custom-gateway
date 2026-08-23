namespace Gateway.Contracts.Dtos;

public record BatchActivityItemResult(
    string ActivityId,
    string Status,
    Guid? ReceiptId,
    string? Code,
    string? Detail);
