using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Configuration.Queries;

public record GetSystemConfigQuery : IRequest<SystemConfigDto>;
