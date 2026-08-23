using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Queries;

public record GetOperationStatusQuery(Guid OperationId) : IRequest<OperationStatusDto>;
