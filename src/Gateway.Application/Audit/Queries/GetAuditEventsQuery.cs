using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Audit.Queries;

public record GetAuditEventsQuery(
    Guid AgentId,
    int Limit = 50,
    string? Cursor = null) : IRequest<AuditEventListResponse>;
