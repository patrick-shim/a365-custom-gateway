using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.ChangeTracking;

namespace Gateway.Infrastructure.Persistence;

internal sealed class AgentProtectionWriteGuard
{
    private static readonly string[] AgentSecurityFields =
    [
        nameof(AgentRegistration.Status), nameof(AgentRegistration.IsDeleted),
        nameof(AgentRegistration.Environment), nameof(AgentRegistration.ExternalAgentId),
        nameof(AgentRegistration.Agent365AgentId), nameof(AgentRegistration.BlueprintId),
        nameof(AgentRegistration.Agent365InstanceId), nameof(AgentRegistration.ExternalClientId),
        nameof(AgentRegistration.AgentIdentityObjectId), nameof(AgentRegistration.BlueprintObjectId),
        nameof(AgentRegistration.RequestedPurviewPolicyMode),
        nameof(AgentRegistration.RequestedPurviewPolicyProfileId), nameof(AgentRegistration.PurviewPolicyProfileId)
    ];
    private static readonly string[] FeatureSecurityFields =
    [
        nameof(AgentFeatureConfiguration.PromptShieldEnabled),
        nameof(AgentFeatureConfiguration.PurviewEnabled),
        nameof(AgentFeatureConfiguration.PurviewMode)
    ];
    private readonly GatewayDbContext _db;
    private readonly EntityEntry<AgentRegistration>[] _agents;
    private readonly EntityEntry<AgentFeatureConfiguration>[] _features;
    private readonly Guid[] _ids;

    public AgentProtectionWriteGuard(GatewayDbContext db)
    {
        _db = db;
        db.ChangeTracker.DetectChanges();
        _agents = db.ChangeTracker.Entries<AgentRegistration>().ToArray();
        _features = db.ChangeTracker.Entries<AgentFeatureConfiguration>()
            .Where(entry => entry.State is EntityState.Added or EntityState.Modified or EntityState.Deleted).ToArray();
        var added = _agents.Where(entry => entry.State == EntityState.Added).Select(entry => entry.Entity.Id).ToHashSet();
        _ids = _agents.Where(entry => entry.State is EntityState.Modified or EntityState.Deleted).Select(entry => entry.Entity.Id)
            .Concat(_features.Select(entry => entry.Entity.AgentRegistrationId))
            .Where(id => !added.Contains(id)).Distinct()
            .OrderBy(id => id.ToString("D"), StringComparer.Ordinal).ToArray();
    }

    public bool RequiresSqlTransaction => _ids.Length > 0 && _db.Database.IsSqlServer();

    public void Prepare()
    {
        var storedAgents = new Dictionary<Guid, AgentRegistration>();
        foreach (var id in _ids)
            storedAgents[id] = AgentQuery(id).SingleOrDefault()
                ?? throw new DbUpdateConcurrencyException("The agent registration changed before its write.");
        foreach (var id in _ids)
            AdvanceIfChanged(id, storedAgents[id],
                _db.AgentFeatureConfigurations.AsNoTracking().SingleOrDefault(feature => feature.AgentRegistrationId == id));
    }

    public async Task PrepareAsync(CancellationToken ct)
    {
        var storedAgents = new Dictionary<Guid, AgentRegistration>();
        foreach (var id in _ids)
            storedAgents[id] = await AgentQuery(id).SingleOrDefaultAsync(ct)
                ?? throw new DbUpdateConcurrencyException("The agent registration changed before its write.");
        foreach (var id in _ids)
            AdvanceIfChanged(id, storedAgents[id],
                await _db.AgentFeatureConfigurations.AsNoTracking().SingleOrDefaultAsync(feature => feature.AgentRegistrationId == id, ct));
    }

    private IQueryable<AgentRegistration> AgentQuery(Guid id)
    {
        if (_db.Database.IsSqlServer())
        {
            if (_db.Database.CurrentTransaction is null)
                throw new InvalidOperationException("Agent writes require a transaction for registration-first locking.");
            // X, not U: U is compatible with a receipt reader's S lock and can
            // deadlock during conversion after EF takes a feature-row X lock.
            return _db.AgentRegistrations.FromSqlInterpolated(
                $"SELECT * FROM dbo.AgentRegistrations WITH (XLOCK, HOLDLOCK) WHERE Id = {id}")
                .IgnoreQueryFilters().AsNoTracking();
        }
        return _db.AgentRegistrations.IgnoreQueryFilters().AsNoTracking().Where(agent => agent.Id == id);
    }

    private void AdvanceIfChanged(Guid id, AgentRegistration storedAgent, AgentFeatureConfiguration? storedFeature)
    {
        var agentEntry = _agents.SingleOrDefault(entry => entry.Entity.Id == id);
        if (agentEntry?.State == EntityState.Deleted)
            return;
        var agentChanged = agentEntry is not null &&
            Changed(agentEntry, _db.Entry(storedAgent), AgentSecurityFields);
        var featureChanged = _features.Where(entry => entry.Entity.AgentRegistrationId == id).Any(entry =>
            entry.State == EntityState.Deleted ? storedFeature is not null :
            storedFeature is null || Changed(entry, _db.Entry(storedFeature), FeatureSecurityFields));
        if (!agentChanged && !featureChanged)
            return;
        agentEntry ??= _db.AgentRegistrations.Attach(storedAgent);
        if (agentEntry.Entity.ProtectionRevision == storedAgent.ProtectionRevision)
            agentEntry.Property(agent => agent.ProtectionRevision).CurrentValue = Guid.NewGuid();
    }

    private static bool Changed<TEntity>(EntityEntry<TEntity> current, EntityEntry<TEntity> stored, string[] fields)
        where TEntity : class => fields.Any(name =>
            (current.State == EntityState.Added || current.Property(name).IsModified) &&
            !Equals(current.Property(name).CurrentValue, stored.Property(name).CurrentValue));
}
