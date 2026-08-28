using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Commands;

public sealed record RevokeAgentIngressCredentialCommand(
    Guid AgentId,
    Guid CredentialId,
    string CallerObjectId) : IRequest<RevokeAgentIngressCredentialResponse>;
