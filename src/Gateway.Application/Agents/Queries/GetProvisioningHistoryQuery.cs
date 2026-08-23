using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Queries;

public record GetProvisioningHistoryQuery(Guid AgentId) : IRequest<ProvisioningHistoryResponse>;
