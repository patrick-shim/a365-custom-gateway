using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

public record OperationStatusDto(
    Guid OperationId,
    string Type,
    string Status,
    string? CurrentStep,
    int PercentComplete,
    Guid AgentId,
    DateTime StartedAtUtc,
    DateTime? CompletedAtUtc,
    OperationErrorDto? Error,
    List<OperationStepDto>? Steps,
    int WorkflowVersion = 1,
    bool Legacy = true,
    bool ReplaySupported = false,
    bool PollingRecommended = false,
    string? RequiredAction = null,
    bool Agent365RegistrationCompletionAvailable = false);
