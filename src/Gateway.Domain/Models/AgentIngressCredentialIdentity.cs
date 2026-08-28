namespace Gateway.Domain.Models;

public sealed record AgentIngressCredentialIdentity(
    Guid CredentialId,
    Guid AgentRegistrationId,
    string ExternalAgentId);
