using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
using Microsoft.EntityFrameworkCore;

internal static class AgentSearchRegression
{
    public static async Task CheckAsync(GatewayDbContext db, Guid agentId)
    {
        if (db.Database.CurrentTransaction is null) throw new Exception("Search fixtures require a rollback-only transaction.");
        var agent = await db.AgentRegistrations.SingleAsync(x => x.Id == agentId);
        var originalName = agent.Name;
        var marker = $"Search-{Guid.NewGuid():N} %_ O'Brien";
        agent.Name = marker;
        await db.SaveChangesAsync();
        var repository = new AgentRegistrationRepository(db);
        foreach (var search in new[] { marker.ToUpperInvariant(), "%_ O'BRIEN", agent.ExternalAgentId.ToString().ToUpperInvariant() })
        {
            var result = await repository.ListAsync(new AgentListFilter(null, null, search, 50, null), default);
            if (!result.Items.Any(x => x.Id == agentId)) throw new Exception("Case-insensitive name/external ID search failed.");
        }
        var absent = await repository.ListAsync(new AgentListFilter(null, null, "%_' OR 1=1 --", 50, null), default);
        if (absent.TotalCount != 0 || absent.Items.Count != 0) throw new Exception("Search must treat SQL and wildcard characters literally.");
        agent.IsDeleted = true;
        await db.SaveChangesAsync();
        var deleted = await repository.ListAsync(new AgentListFilter(null, null, marker, 50, null), default);
        if (deleted.TotalCount != 0 || deleted.Items.Count != 0) throw new Exception("Search must preserve the soft-delete filter.");
        agent.IsDeleted = false;
        agent.Name = originalName;
        await db.SaveChangesAsync();
        Console.WriteLine("PostgreSQL agent search: name/external ID, case, literal punctuation, and soft deletion passed (transaction rolls back).");
    }
}
