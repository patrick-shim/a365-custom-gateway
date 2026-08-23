using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

public record DeleteAgentResponse(
    Guid AgentId,
    string Status,
    Guid OperationId,
    bool DeleteMicrosoftResources,
    LinksDto? Links);
