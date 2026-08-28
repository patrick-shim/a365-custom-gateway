namespace Gateway.Contracts.Dtos;

public sealed record AgentGatewayCredentialDto(
    Guid KeyId,
    string ApiKey,
    DateTime ExpiresAtUtc);
