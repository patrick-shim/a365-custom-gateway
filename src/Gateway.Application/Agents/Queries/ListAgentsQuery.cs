using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Queries;

public record ListAgentsQuery(
    string? Status,
    string? Environment,
    string? Search,
    int Limit = 50,
    string? Cursor = null) : IRequest<AgentListResponse>;
