using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Commands;

public record RetryProvisioningCommand(
    Guid AgentId,
    string CallerObjectId) : IRequest<AsyncOperationResponse>;
