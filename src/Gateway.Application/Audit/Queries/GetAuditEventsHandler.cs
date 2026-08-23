using Gateway.Contracts.Responses;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Audit.Queries;

internal sealed class GetAuditEventsHandler : IRequestHandler<GetAuditEventsQuery, AuditEventListResponse>
{
    private readonly IAuditEventRepository _auditEventRepository;

    public GetAuditEventsHandler(IAuditEventRepository auditEventRepository)
    {
        _auditEventRepository = auditEventRepository;
    }

    public async Task<AuditEventListResponse> Handle(GetAuditEventsQuery request, CancellationToken cancellationToken)
    {
        var (items, nextCursor) = await _auditEventRepository.GetByAgentIdAsync(
            request.AgentId, request.Limit, request.Cursor, cancellationToken);

        var dtos = items.Select(e => new AuditEventDto(
            e.Id,
            e.AgentRegistrationId ?? Guid.Empty,
            e.EventType,
            e.PerformedByObjectId,
            e.OccurredAtUtc,
            e.Details)).ToList();

        return new AuditEventListResponse(dtos, nextCursor);
    }
}
