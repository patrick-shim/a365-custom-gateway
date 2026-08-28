namespace Gateway.Contracts.Responses;

public sealed record CompleteAgent365RegistrationResponse(
    Guid OperationId,
    Guid AgentId,
    string Agent365RegistrationId,
    string Status);
