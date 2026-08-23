namespace Gateway.Contracts.Dtos;

public record OperationErrorDto(
    string? Code,
    string? Message);
