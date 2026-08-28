using Gateway.Contracts.Dtos;

namespace Gateway.Contracts.Responses;

public sealed record AgentIngressCredentialListResponse(
    Guid AgentId,
    IReadOnlyList<AgentIngressCredentialMetadataDto> Items);

public sealed record IssueAgentIngressCredentialResponse(
    Guid AgentId,
    string ExternalAgentId,
    AgentGatewayCredentialDto GatewayCredential);

public sealed record RevokeAgentIngressCredentialResponse(
    Guid AgentId,
    AgentIngressCredentialMetadataDto Credential,
    bool AlreadyRevoked);
