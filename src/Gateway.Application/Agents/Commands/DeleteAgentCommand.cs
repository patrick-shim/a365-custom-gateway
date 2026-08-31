using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Commands;

public record DeleteAgentCommand(
    Guid AgentId,
    string CallerObjectId) : IRequest<DeleteAgentResponse>;
