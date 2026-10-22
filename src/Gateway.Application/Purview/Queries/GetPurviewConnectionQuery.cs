using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Purview.Queries;

public sealed record GetPurviewConnectionQuery(
    Guid TenantId,
    Guid? ConfiguredConnectorInstanceId,
    string? ConfiguredProfile) : IRequest<PurviewConnectionResponse>;
