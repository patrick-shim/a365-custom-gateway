using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Queries;

public record GetAgentQuery(Guid AgentId) : IRequest<AgentDetailDto>;
