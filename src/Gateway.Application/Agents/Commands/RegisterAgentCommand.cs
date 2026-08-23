using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Commands;

public record RegisterAgentCommand(
    string ExternalAgentId,
    string Name,
    string? Description,
    string OwnerObjectId,
    string Environment,
    AgentFeaturesDto? Features,
    string CallerObjectId) : IRequest<RegisterAgentResponse>;
