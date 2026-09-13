using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class PromptEvaluationRepository : IPromptEvaluationRepository
{
    private readonly GatewayDbContext _dbContext;
    private readonly TimeProvider _timeProvider;
    private readonly IPurviewRuntimeCertificationVerifier? _runtimeCertification;

    public PromptEvaluationRepository(GatewayDbContext dbContext, TimeProvider? timeProvider = null,
        IPurviewRuntimeCertificationVerifier? runtimeCertification = null)
    {
        _dbContext = dbContext;
        _timeProvider = timeProvider ?? TimeProvider.System;
        _runtimeCertification = runtimeCertification;
    }

    public Task<PromptEvaluationRecord?> GetByIdAsync(Guid id, CancellationToken cancellationToken) =>
        _dbContext.PromptEvaluationRecords.AsNoTracking().SingleOrDefaultAsync(record => record.Id == id, cancellationToken);

    public Task<PromptProtectionContext?> GetProtectionContextAsync(Guid agentRegistrationId, CancellationToken cancellationToken) =>
        ReadContextAsync(agentRegistrationId, lockRows: false, cancellationToken);

    public async Task<bool> IsProtectionContextCurrentAsync(PromptProtectionContext context, CancellationToken cancellationToken)
    {
        if (IsSqlServer)
        {
            if (_dbContext.Database.CurrentTransaction is null)
                throw new InvalidOperationException("A transaction is required for atomic prompt protection context validation.");
            // All EF agent/feature writers first take registration X locks in this
            // same ID order. Readers take S locks before touching features/profiles.
            var agents = new[] { context.AgentRegistrationId, context.RuntimeCertificationBinding?.TestAgentRegistrationId ?? context.AgentRegistrationId };
            var orderedAgents = agents.Distinct().OrderBy(value => value.ToString("D"), StringComparer.Ordinal).ToArray();
            foreach (var id in orderedAgents)
            {
                if (await _dbContext.AgentRegistrations.FromSqlInterpolated(
                    $"SELECT * FROM dbo.AgentRegistrations WITH (HOLDLOCK) WHERE Id = {id}")
                    .AsNoTracking().SingleOrDefaultAsync(cancellationToken) is null)
                    return false;
            }
            foreach (var id in orderedAgents)
                _ = await _dbContext.AgentFeatureConfigurations.FromSqlInterpolated(
                    $"SELECT * FROM dbo.AgentFeatureConfigurations WITH (HOLDLOCK) WHERE AgentRegistrationId = {id}")
                    .AsNoTracking().SingleOrDefaultAsync(cancellationToken);
            if (context.PurviewBlueprintApplicationId is { } blueprint)
                _ = await _dbContext.PurviewDlpProfiles.FromSqlInterpolated(
                    $"SELECT * FROM dbo.PurviewDlpProfiles WITH (HOLDLOCK) WHERE BlueprintApplicationId = {blueprint}")
                    .AsNoTracking().SingleOrDefaultAsync(cancellationToken);
        }
        var current = await ReadContextAsync(context.AgentRegistrationId, lockRows: true, cancellationToken, context);
        return current is not null && current.Hash == context.Hash &&
            current.IsCurrentAt(_timeProvider.GetUtcNow().UtcDateTime);
    }

    public async Task<bool> TryConsumeAsync(
        PromptEvaluationRecord receipt,
        PromptProtectionContext context,
        CancellationToken cancellationToken)
    {
        // Serializable key/range locks remain held by the ingress transaction through SaveChanges/commit.
        // They protect existing AND missing agent/profile/capability rows from concurrent edits/inserts.
        if (!await IsProtectionContextCurrentAsync(context, cancellationToken))
            return false;

        var query = IsSqlServer
            ? _dbContext.PromptEvaluationRecords.FromSqlInterpolated(
                $"SELECT * FROM dbo.PromptEvaluationRecords WITH (UPDLOCK, HOLDLOCK) WHERE Id = {receipt.Id}")
            : _dbContext.PromptEvaluationRecords.Where(record => record.Id == receipt.Id);
        var current = await query.AsNoTracking().SingleOrDefaultAsync(cancellationToken);
        var now = _timeProvider.GetUtcNow().UtcDateTime;
        if (current is null || !context.MatchesReceipt(receipt, now) || !context.MatchesReceipt(current, now) ||
            current.ExternalInteractionId != receipt.ExternalInteractionId ||
            current.TenantUserObjectId != receipt.TenantUserObjectId ||
            !current.PromptHash.AsSpan().SequenceEqual(receipt.PromptHash) ||
            !current.PromptHashSalt.AsSpan().SequenceEqual(receipt.PromptHashSalt))
            return false;

        if (IsSqlServer)
            return await _dbContext.PromptEvaluationRecords
                .Where(record => record.Id == current.Id && record.ConsumedAtUtc == null && record.ExpiresAtUtc > now)
                .ExecuteUpdateAsync(setters => setters.SetProperty(record => record.ConsumedAtUtc, now), cancellationToken) == 1;

        var tracked = await _dbContext.PromptEvaluationRecords.SingleAsync(record => record.Id == current.Id, cancellationToken);
        if (tracked.ConsumedAtUtc is not null)
            return false;
        tracked.ConsumedAtUtc = now;
        return true;
    }

    public async Task AddAsync(PromptEvaluationRecord record, CancellationToken cancellationToken) =>
        await _dbContext.PromptEvaluationRecords.AddAsync(record, cancellationToken);

    private bool IsSqlServer => _dbContext.Database.ProviderName == "Microsoft.EntityFrameworkCore.SqlServer";

    private async Task<PromptProtectionContext?> ReadContextAsync(Guid agentId, bool lockRows, CancellationToken ct,
        PromptProtectionContext? expectedContext = null)
    {
        if (lockRows && IsSqlServer && _dbContext.Database.CurrentTransaction is null)
            throw new InvalidOperationException("A transaction is required for atomic prompt protection context validation.");
        if (!IsSqlServer && _dbContext.Database.ProviderName != "Microsoft.EntityFrameworkCore.InMemory")
            throw new NotSupportedException("The configured database provider does not support prompt protection context validation.");
        var locked = lockRows && IsSqlServer;

        var agents = locked ? _dbContext.AgentRegistrations.FromSqlInterpolated(
            $"SELECT * FROM dbo.AgentRegistrations WITH (HOLDLOCK) WHERE Id = {agentId}")
            : _dbContext.AgentRegistrations.Where(agent => agent.Id == agentId);
        var agent = await agents.AsNoTracking().SingleOrDefaultAsync(ct);
        if (agent is null)
            return null;
        var features = locked ? _dbContext.AgentFeatureConfigurations.FromSqlInterpolated(
            $"SELECT * FROM dbo.AgentFeatureConfigurations WITH (HOLDLOCK) WHERE AgentRegistrationId = {agentId}")
            : _dbContext.AgentFeatureConfigurations.Where(feature => feature.AgentRegistrationId == agentId);
        var feature = await features.AsNoTracking().SingleOrDefaultAsync(ct);
        if (feature is null)
            return null;
        agent.FeatureConfiguration = feature;
        if (locked && expectedContext?.MatchesAgent(agent) != true)
            return null;

        PurviewDlpProfile? profile = null;
        if (feature.PurviewEnabled && Guid.TryParse(agent.BlueprintId, out var blueprintId))
        {
            var profiles = locked ? _dbContext.PurviewDlpProfiles.FromSqlInterpolated(
                $"SELECT * FROM dbo.PurviewDlpProfiles WITH (HOLDLOCK) WHERE BlueprintApplicationId = {blueprintId}")
                : _dbContext.PurviewDlpProfiles.Where(profile => profile.BlueprintApplicationId == new BlueprintApplicationId(blueprintId));
            profile = await profiles.AsNoTracking().SingleOrDefaultAsync(ct);
        }
        var mode = !feature.PurviewEnabled ? PurviewPolicyMode.Disabled : profile?.EffectivePolicyMode ??
            agent.RequestedPurviewPolicyMode ?? PurviewPolicyModeCompatibility.FromLegacy(feature.PurviewMode ?? PurviewMode.Enforce);
        var purviewActive = feature.PurviewEnabled && mode != PurviewPolicyMode.Disabled;
        var promptCapability = feature.PromptShieldEnabled
            ? await ReadCapabilityAsync(ProtectionCapabilityKind.PromptShields, locked, ct) : null;
        var purviewCapability = purviewActive
            ? await ReadCapabilityAsync(ProtectionCapabilityKind.Purview, locked, ct) : null;

        PurviewTenantConnection? connection = null;
        PurviewSensitiveInformationTypeSnapshotGeneration? inventory = null;
        ProtectionAdminOperation? certification = null;
        if (purviewActive && profile is not null)
        {
            var connections = locked ? _dbContext.PurviewTenantConnections.FromSqlInterpolated(
                $"SELECT * FROM dbo.PurviewTenantConnections WITH (HOLDLOCK) WHERE Id = {profile.PurviewTenantConnectionId}")
                : _dbContext.PurviewTenantConnections.Where(connection => connection.Id == profile.PurviewTenantConnectionId);
            connection = await connections.AsNoTracking().SingleOrDefaultAsync(ct);
            var generations = locked ? _dbContext.PurviewSensitiveInformationTypeSnapshotGenerations.FromSqlInterpolated(
                $"SELECT * FROM dbo.PurviewSensitiveInformationTypeSnapshotGenerations WITH (HOLDLOCK) WHERE Id = {profile.InventoryGenerationId.Value}")
                : _dbContext.PurviewSensitiveInformationTypeSnapshotGenerations.Where(generation => generation.Id == profile.InventoryGenerationId);
            inventory = await generations.AsNoTracking().SingleOrDefaultAsync(ct);
            if (inventory is not null)
            {
                var items = locked ? _dbContext.PurviewSensitiveInformationTypeSnapshots.FromSqlInterpolated(
                    $"SELECT * FROM dbo.PurviewSensitiveInformationTypeSnapshots WITH (HOLDLOCK) WHERE GenerationId = {inventory.Id.Value}")
                    : _dbContext.PurviewSensitiveInformationTypeSnapshots.Where(item => item.GenerationId == inventory.Id);
                inventory.Items = await items.AsNoTracking().ToListAsync(ct);
            }
            if (profile.RuntimeBehaviorCertificationOperationId is { } certificationId)
            {
                var operations = locked ? _dbContext.ProtectionAdminOperations.FromSqlInterpolated(
                    $"SELECT * FROM dbo.ProtectionAdminOperations WITH (HOLDLOCK) WHERE Id = {certificationId}")
                    : _dbContext.ProtectionAdminOperations.Where(operation => operation.Id == certificationId);
                certification = await operations.AsNoTracking().SingleOrDefaultAsync(ct);
            }
        }
        PurviewRuntimeCertificationBinding? runtimeBinding = null;
        if (mode == PurviewPolicyMode.Enforce && profile is not null && _runtimeCertification is not null)
        {
            if (locked && (expectedContext?.RuntimeCertificationBinding is not { } expectedBinding ||
                profile.RuntimeBehaviorCertificationOperationId != expectedBinding.CertificationOperationId ||
                (certification is not null && certification.RuntimeTestConfigurationFingerprint != expectedBinding.ConfigurationFingerprint)))
                return null;
            runtimeBinding = await _runtimeCertification.GetCurrentBindingAsync(profile, ct);
            if (runtimeBinding is not null && locked)
            {
                if (runtimeBinding.TestAgentRegistrationId != expectedContext!.RuntimeCertificationBinding!.TestAgentRegistrationId)
                    return null;
                // The certified probe may belong to another child registration. Protect that
                // child's identity/revision as well as the caller, then reverify the read-only binding.
                var testAgent = await _dbContext.AgentRegistrations.FromSqlInterpolated(
                    $"SELECT * FROM dbo.AgentRegistrations WITH (HOLDLOCK) WHERE Id = {runtimeBinding.TestAgentRegistrationId}")
                    .AsNoTracking().SingleOrDefaultAsync(ct);
                if (testAgent is null || testAgent.Status != AgentStatus.Active || testAgent.IsDeleted ||
                    testAgent.ProtectionRevision != runtimeBinding.TestAgentProtectionRevision ||
                    !Guid.TryParse(testAgent.BlueprintId, out var testBlueprint) || testBlueprint != profile.BlueprintApplicationId.Value ||
                    await _runtimeCertification.GetCurrentBindingAsync(profile, ct) != runtimeBinding)
                    return null;
            }
        }
        if (lockRows && mode == PurviewPolicyMode.Enforce && runtimeBinding is null)
            return null;
        return PromptProtectionContext.Capture(agent, profile, promptCapability, purviewCapability, connection, inventory,
            certification, runtimeBinding);
    }

    private async Task<ProtectionCapability?> ReadCapabilityAsync(ProtectionCapabilityKind kind, bool locked, CancellationToken ct)
    {
        var query = locked ? _dbContext.ProtectionCapabilities.FromSqlInterpolated(
            $"SELECT * FROM dbo.ProtectionCapabilities WITH (HOLDLOCK) WHERE Kind = {kind.ToString()}")
            : _dbContext.ProtectionCapabilities.Where(capability => capability.Kind == kind);
        return await query.AsNoTracking().SingleOrDefaultAsync(ct);
    }
}
