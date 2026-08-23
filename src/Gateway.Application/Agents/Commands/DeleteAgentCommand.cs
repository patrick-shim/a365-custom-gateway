using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Commands;

public record DeleteAgentCommand(
    Guid AgentId,
    bool DeleteMicrosoftResources,
    string CallerObjectId) : IRequest<DeleteAgentResponse>;
