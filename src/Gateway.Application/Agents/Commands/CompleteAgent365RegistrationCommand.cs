using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Commands;

public sealed record CompleteAgent365RegistrationCommand(
    Guid OperationId,
    string CallerObjectId) : IRequest<CompleteAgent365RegistrationResponse>;
