using Gateway.Application.Agents.Queries;
using Gateway.Application.Exceptions;
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

    public async Task<(List<AgentRegistration> Items, int TotalCount)> ListAsync(AgentListFilter filter, CancellationToken ct)
    {
        DateTime cursorDate = default;
        Guid cursorId = default;
        var hasCursor = !string.IsNullOrEmpty(filter.Cursor);
        if (hasCursor && !ListAgentsCursor.TryDecode(filter.Cursor, out cursorDate, out cursorId))
            throw new ValidationException(new Dictionary<string, string[]>
            {
                [nameof(filter.Cursor)] = [ListAgentsCursor.InvalidMessage]
            });

        var query = _dbContext.AgentRegistrations.AsQueryable();

        if (!string.IsNullOrWhiteSpace(filter.Search))
        {
            var search = filter.Search.Trim();
            // ExternalAgentId is value-converted. Search its stored value without client evaluation
            // and use literal substring matching under an explicit case-insensitive SQL collation.
            query = _dbContext.AgentRegistrations.FromSqlInterpolated($"""
                SELECT * FROM [AgentRegistrations]
                WHERE CHARINDEX({search}, [Name] COLLATE Latin1_General_100_CI_AS_SC) > 0
                   OR CHARINDEX({search}, [ExternalAgentId] COLLATE Latin1_General_100_CI_AS_SC) > 0
                """);
        }

        if (!string.IsNullOrEmpty(filter.Status) && Enum.TryParse<AgentStatus>(filter.Status, true, out var status))
            query = query.Where(a => a.Status == status);

        if (!string.IsNullOrEmpty(filter.Environment) && Enum.TryParse<AgentEnvironment>(filter.Environment, true, out var env))
            query = query.Where(a => a.Environment == env);

        var totalCount = await query.CountAsync(ct);

        if (hasCursor)
        {
            query = query.Where(a =>
                a.CreatedAtUtc > cursorDate ||
                (a.CreatedAtUtc == cursorDate && a.Id.CompareTo(cursorId) > 0));
        }

        var items = await query
            .Include(a => a.FeatureConfiguration)
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
