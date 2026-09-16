using System.Data;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class PurviewRuntimeTestRepository(GatewayDbContext database) : IPurviewRuntimeTestRepository
{
    public async Task<PurviewRuntimeTestSnapshot?> LoadFreshSnapshotAsync(
        Guid profileId, Guid tenantId, Guid? registrationId, CancellationToken cancellationToken)
    {
        // Commit-time callers already know the certified test agent. Read it first so
        // serializable locks follow the same registration-before-profile order as writers.
        var requestedAgent = registrationId is null ? null :
            await database.AgentRegistrations.AsNoTracking()
                .SingleOrDefaultAsync(value => value.Id == registrationId.Value, cancellationToken);
        var profile = await database.PurviewDlpProfiles.AsNoTracking()
            .SingleOrDefaultAsync(value => value.Id == new PurviewDlpProfileId(profileId), cancellationToken);
        if (profile is null)
            return null;
        var connection = await database.PurviewTenantConnections.AsNoTracking()
            .SingleOrDefaultAsync(value => value.Id == profile.PurviewTenantConnectionId &&
                value.TenantId == new EntraTenantId(tenantId), cancellationToken);
        if (connection is null)
            return null;
        var capability = await database.ProtectionCapabilities.AsNoTracking()
            .SingleOrDefaultAsync(value => value.Kind == ProtectionCapabilityKind.Purview, cancellationToken);
        var inventory = await database.PurviewSensitiveInformationTypeSnapshotGenerations.AsNoTracking()
            .Include(value => value.Items).SingleOrDefaultAsync(value => value.Id == profile.InventoryGenerationId, cancellationToken);
        var blueprint = profile.BlueprintApplicationId.Value.ToString("D");
        AgentRegistration? agent;
        if (registrationId is not null)
            agent = requestedAgent is { IsDeleted: false, Status: AgentStatus.Active, Agent365AgentId: not null } &&
                requestedAgent.BlueprintId == blueprint ? requestedAgent : null;
        else
            agent = await database.AgentRegistrations.AsNoTracking().Where(value =>
                    !value.IsDeleted && value.Status == AgentStatus.Active && value.BlueprintId == blueprint &&
                    value.Agent365AgentId != null)
                .OrderBy(value => value.Id).FirstOrDefaultAsync(cancellationToken);
        return capability is null || inventory is null
            ? null : new(profile, connection, capability, inventory, agent);
    }

    public async Task<IReadOnlyList<ProtectionAdminOperation>> ListSuiteOperationsAsync(
        string configurationFingerprint, string suiteHash, DateTime sinceUtc, CancellationToken cancellationToken) =>
        await database.ProtectionAdminOperations.AsNoTracking()
            .Where(value => value.Type == ProtectionAdminOperationType.TestDlpRuntime &&
                value.RuntimeTestConfigurationFingerprint == configurationFingerprint &&
                value.RuntimeTestSuiteHash == suiteHash && value.StartedAtUtc >= sinceUtc)
            .OrderBy(value => value.StartedAtUtc).ThenBy(value => value.Id).Take(129).ToArrayAsync(cancellationToken);

    public Task<ProtectionAdminOperation?> GetFreshCertificationOperationAsync(Guid operationId, CancellationToken cancellationToken) =>
        database.ProtectionAdminOperations.AsNoTracking()
            .SingleOrDefaultAsync(value => value.Id == operationId, cancellationToken);

    public async Task<IPurviewRuntimeWriteLease> BeginFreshWriteAsync(CancellationToken cancellationToken)
    {
        if (database.Database.CurrentTransaction is not null)
            throw new InvalidOperationException("Runtime finalization must not reuse an acceptance transaction.");
        database.ChangeTracker.Clear();
        if (database.Database.IsSqlServer())
            return new WriteLease(await database.Database.BeginTransactionAsync(IsolationLevel.Serializable, cancellationToken));
        if (database.Database.ProviderName == "Microsoft.EntityFrameworkCore.InMemory")
            return new WriteLease(null);
        throw new NotSupportedException("Runtime finalization requires SQL Server or the in-memory test provider.");
    }

    public void UpdateProfile(PurviewDlpProfile profile) => database.PurviewDlpProfiles.Update(profile);
    public void EnsureNoActiveTransaction()
    {
        if (database.Database.CurrentTransaction is not null)
            throw new InvalidOperationException("Runtime provider work requires committed acceptance.");
    }

    private sealed class WriteLease(IDbContextTransaction? transaction) : IPurviewRuntimeWriteLease
    {
        public Task CompleteAsync(CancellationToken cancellationToken) =>
            transaction?.CommitAsync(cancellationToken) ?? Task.CompletedTask;
        public ValueTask DisposeAsync() => transaction?.DisposeAsync() ?? ValueTask.CompletedTask;
    }
}
