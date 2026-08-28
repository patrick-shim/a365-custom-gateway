using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

public record RegisterAgentResponse(
    Guid AgentId,
    string ExternalAgentId,
    string Name,
    string Status,
    Guid OperationId,
    DateTime CreatedAtUtc,
    LinksDto? Links,
    AgentGatewayCredentialDto? GatewayCredential = null);
