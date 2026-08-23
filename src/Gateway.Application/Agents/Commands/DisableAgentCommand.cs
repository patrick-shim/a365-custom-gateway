using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Commands;

public record DisableAgentCommand(
    Guid AgentId,
    string CallerObjectId) : IRequest<AgentStateChangeResponse>;
