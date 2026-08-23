using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Commands;

public record EnableAgentCommand(
    Guid AgentId,
    string CallerObjectId) : IRequest<AgentStateChangeResponse>;
