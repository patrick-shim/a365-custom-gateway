namespace Gateway.Contracts.Dtos;

public record OperationStepDto(
    string Step,
    string Status,
    DateTime? CompletedAtUtc);
