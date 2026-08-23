using System.Globalization;
using System.Text;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class AgentRegistrationRepository : IAgentRepository
{
    private readonly GatewayDbContext _dbContext;

    public AgentRegistrationRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<AgentRegistration?> GetByIdAsync(Guid id, CancellationToken ct)
    {
        return await _dbContext.AgentRegistrations
            .Include(a => a.FeatureConfiguration)
            .Include(a => a.CredentialReference)
            .FirstOrDefaultAsync(a => a.Id == id, ct);
    }

    public async Task<AgentRegistration?> GetByExternalAgentIdAsync(string externalAgentId, CancellationToken ct)
    {
        var externalId = new ExternalAgentId(externalAgentId);
        return await _dbContext.AgentRegistrations
            .Include(a => a.FeatureConfiguration)
            .FirstOrDefaultAsync(a => a.ExternalAgentId == externalId, ct);
    }

    public async Task<AgentRegistration?> GetByExternalClientIdAsync(string externalClientId, CancellationToken ct)
    {
        return await _dbContext.AgentRegistrations
            .FirstOrDefaultAsync(a => a.ExternalClientId == externalClientId, ct);
    }

    public async Task<(List<AgentRegistration> Items, int TotalCount)> ListAsync(AgentListFilter filter, CancellationToken ct)
    {
        var query = _dbContext.AgentRegistrations
            .Include(a => a.FeatureConfiguration)
            .AsQueryable();

        if (!string.IsNullOrEmpty(filter.Status) && Enum.TryParse<AgentStatus>(filter.Status, true, out var status))
            query = query.Where(a => a.Status == status);

        if (!string.IsNullOrEmpty(filter.Environment) && Enum.TryParse<AgentEnvironment>(filter.Environment, true, out var env))
            query = query.Where(a => a.Environment == env);

        if (!string.IsNullOrEmpty(filter.Search))
            query = query.Where(a => a.Name.Contains(filter.Search));

        var totalCount = await query.CountAsync(ct);

        if (!string.IsNullOrEmpty(filter.Cursor))
        {
            var cursorBytes = Convert.FromBase64String(filter.Cursor);
            var cursorStr = Encoding.UTF8.GetString(cursorBytes);
            var separatorIndex = cursorStr.IndexOf('|');
            var cursorDate = DateTime.Parse(
                cursorStr[..separatorIndex],
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind);
            var cursorId = Guid.Parse(cursorStr[(separatorIndex + 1)..]);

            query = query.Where(a =>
                a.CreatedAtUtc > cursorDate ||
                (a.CreatedAtUtc == cursorDate && a.Id.CompareTo(cursorId) > 0));
        }

        var items = await query
            .OrderBy(a => a.CreatedAtUtc)
            .ThenBy(a => a.Id)
            .Take(filter.Limit)
            .ToListAsync(ct);

        return (items, totalCount);
    }

    public async Task AddAsync(AgentRegistration agent, CancellationToken ct)
    {
        await _dbContext.AgentRegistrations.AddAsync(agent, ct);
    }

    public async Task<bool> ExistsAsync(string externalAgentId, CancellationToken ct)
    {
        var externalId = new ExternalAgentId(externalAgentId);
        return await _dbContext.AgentRegistrations
            .AnyAsync(a => a.ExternalAgentId == externalId, ct);
    }
}
