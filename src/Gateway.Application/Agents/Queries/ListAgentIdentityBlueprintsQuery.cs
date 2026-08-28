using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Queries;

public sealed record ListAgentIdentityBlueprintsQuery
    : IRequest<AgentIdentityBlueprintListResponse>;
