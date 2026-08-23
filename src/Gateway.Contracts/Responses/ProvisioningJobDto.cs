using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

public record ProvisioningJobDto(
    Guid OperationId,
    string Type,
    string Status,
    int PercentComplete,
    DateTime StartedAtUtc,
    DateTime? CompletedAtUtc,
    OperationErrorDto? Error,
    List<OperationStepDto>? Steps);

public record ProvisioningHistoryResponse(
    Guid AgentId,
    List<ProvisioningJobDto> Jobs);
