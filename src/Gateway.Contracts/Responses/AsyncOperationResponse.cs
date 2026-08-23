using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

public record AsyncOperationResponse(
    Guid AgentId,
    string? Status,
    Guid OperationId,
    LinksDto? Links);
