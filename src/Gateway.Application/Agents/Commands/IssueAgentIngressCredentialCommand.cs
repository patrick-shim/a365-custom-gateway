using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Commands;

public sealed record IssueAgentIngressCredentialCommand(
    Guid AgentId,
    string CallerObjectId) : IRequest<IssueAgentIngressCredentialResponse>;
