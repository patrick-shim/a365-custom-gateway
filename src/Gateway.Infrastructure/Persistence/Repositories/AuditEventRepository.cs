using System.Globalization;
using System.Text;
using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class AuditEventRepository : IAuditEventRepository
{
    private readonly GatewayDbContext _dbContext;

    public AuditEventRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task AddAsync(AuditEvent auditEvent, CancellationToken ct)
    {
        await _dbContext.AuditEvents.AddAsync(auditEvent, ct);
    }

    public async Task<(List<AuditEvent> Items, string? NextCursor)> GetByAgentIdAsync(
        Guid agentRegistrationId, int limit, string? cursor, CancellationToken ct)
    {
        var query = _dbContext.AuditEvents
            .Where(e => e.AgentRegistrationId == agentRegistrationId);

        if (!string.IsNullOrEmpty(cursor))
        {
            var cursorBytes = Convert.FromBase64String(cursor);
            var cursorStr = Encoding.UTF8.GetString(cursorBytes);
            var separatorIndex = cursorStr.IndexOf('|');
            var cursorDate = DateTime.Parse(
                cursorStr[..separatorIndex],
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind);
            var cursorId = Guid.Parse(cursorStr[(separatorIndex + 1)..]);

            query = query.Where(e =>
                e.OccurredAtUtc < cursorDate ||
                (e.OccurredAtUtc == cursorDate && e.Id.CompareTo(cursorId) < 0));
        }

        var items = await query
            .OrderByDescending(e => e.OccurredAtUtc)
            .ThenByDescending(e => e.Id)
            .Take(limit)
            .ToListAsync(ct);

        string? nextCursor = null;
        if (items.Count == limit)
        {
            var last = items[^1];
            nextCursor = Convert.ToBase64String(
                Encoding.UTF8.GetBytes($"{last.OccurredAtUtc:O}|{last.Id}"));
        }

        return (items, nextCursor);
    }
}
