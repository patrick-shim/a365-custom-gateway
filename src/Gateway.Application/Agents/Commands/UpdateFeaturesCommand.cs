using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Commands;

public record UpdateFeaturesCommand(
    Guid AgentId,
    string? ObservabilityMode,
    bool? PurviewEnabled,
    string? PurviewMode,
    string CallerObjectId) : IRequest<UpdateFeaturesResponse>;
