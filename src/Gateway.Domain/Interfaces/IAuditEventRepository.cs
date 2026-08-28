using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public interface IAuditEventRepository
{
    Task<bool> ExistsAsync(Guid auditEventId, CancellationToken ct);
    Task AddAsync(AuditEvent auditEvent, CancellationToken ct);
    Task<(List<AuditEvent> Items, string? NextCursor)> GetByAgentIdAsync(Guid agentRegistrationId, int limit, string? cursor, CancellationToken ct);
}
