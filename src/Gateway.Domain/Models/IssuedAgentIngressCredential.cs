using Gateway.Domain.Entities;

namespace Gateway.Domain.Models;

public sealed record IssuedAgentIngressCredential(
    AgentIngressCredential Credential,
    string ApiKey);
