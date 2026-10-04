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
    private readonly IAgentPolicyBindingReader? _individualPolicies;

    public PromptEvaluationRepository(GatewayDbContext dbContext, TimeProvider? timeProvider = null,
        IAgentPolicyBindingReader? individualPolicies = null)
    {
        _dbContext = dbContext;
        _timeProvider = timeProvider ?? TimeProvider.System;
        _individualPolicies = individualPolicies;
    }

    public Task<PromptEvaluationRecord?> GetByIdAsync(Guid id, CancellationToken cancellationToken) =>
        _dbContext.PromptEvaluationRecords.AsNoTracking().SingleOrDefaultAsync(record => record.Id == id, cancellationToken);

    public Task<PromptProtectionContext?> GetProtectionContextAsync(Guid agentRegistrationId, CancellationToken cancellationToken) =>
        ReadContextAsync(agentRegistrationId, lockRows: false, cancellationToken);

    public async Task<bool> IsProtectionContextCurrentAsync(PromptProtectionContext context, CancellationToken cancellationToken)
    {
        if (IsNpgsql)
        {
            if (_dbContext.Database.CurrentTransaction is null)
                throw new InvalidOperationException("A transaction is required for atomic prompt protection context validation.");
            // Writers and receipt validation lock the registration before its feature row.
            var agents = new[] { context.AgentRegistrationId };
            var orderedAgents = agents.Distinct().OrderBy(value => value.ToString("D"), StringComparer.Ordinal).ToArray();
            foreach (var id in orderedAgents)
            {
                if (await (_dbContext.AgentRegistrations.FromSqlInterpolated(
                        $"SELECT * FROM \"AgentRegistrations\" WHERE \"Id\" = {id} FOR UPDATE"))
                    .AsNoTracking().SingleOrDefaultAsync(cancellationToken) is null)
                    return false;
            }
            foreach (var id in orderedAgents)
                _ = await (_dbContext.AgentFeatureConfigurations.FromSqlInterpolated(
                        $"SELECT * FROM \"AgentFeatureConfigurations\" WHERE \"AgentRegistrationId\" = {id} FOR UPDATE"))
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
        // PostgreSQL row locks remain held through the ingress transaction commit.
        // An absent registration or required capability cannot produce an accepted context.
        if (!await IsProtectionContextCurrentAsync(context, cancellationToken))
            return false;

        var query = IsNpgsql ? _dbContext.PromptEvaluationRecords.FromSqlInterpolated(
                $"SELECT * FROM \"PromptEvaluationRecords\" WHERE \"Id\" = {receipt.Id} FOR UPDATE")
            : _dbContext.PromptEvaluationRecords.Where(record => record.Id == receipt.Id);
        var current = await query.AsNoTracking().SingleOrDefaultAsync(cancellationToken);
        var now = _timeProvider.GetUtcNow().UtcDateTime;
        if (current is null || !context.MatchesReceipt(receipt, now) || !context.MatchesReceipt(current, now) ||
            current.ExternalInteractionId != receipt.ExternalInteractionId ||
            current.TenantUserObjectId != receipt.TenantUserObjectId ||
            !current.PromptHash.AsSpan().SequenceEqual(receipt.PromptHash) ||
            !current.PromptHashSalt.AsSpan().SequenceEqual(receipt.PromptHashSalt))
            return false;

        if (IsNpgsql)
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

    private bool IsNpgsql => _dbContext.Database.ProviderName == "Npgsql.EntityFrameworkCore.PostgreSQL";

    private async Task<PromptProtectionContext?> ReadContextAsync(Guid agentId, bool lockRows, CancellationToken ct,
        PromptProtectionContext? expectedContext = null)
    {
        if (lockRows && (IsNpgsql) && _dbContext.Database.CurrentTransaction is null)
            throw new InvalidOperationException("A transaction is required for atomic prompt protection context validation.");
        if (!IsNpgsql && _dbContext.Database.ProviderName != "Microsoft.EntityFrameworkCore.InMemory")
            throw new NotSupportedException("The configured database provider does not support prompt protection context validation.");
        var lockedPostgres = lockRows && IsNpgsql;

        var agents = lockedPostgres ? _dbContext.AgentRegistrations.FromSqlInterpolated(
                $"SELECT * FROM \"AgentRegistrations\" WHERE \"Id\" = {agentId} FOR UPDATE")
            : _dbContext.AgentRegistrations.Where(agent => agent.Id == agentId);
        var agent = await agents.AsNoTracking().SingleOrDefaultAsync(ct);
        if (agent is null)
            return null;
        var features = lockedPostgres ? _dbContext.AgentFeatureConfigurations.FromSqlInterpolated(
                $"SELECT * FROM \"AgentFeatureConfigurations\" WHERE \"AgentRegistrationId\" = {agentId} FOR UPDATE")
            : _dbContext.AgentFeatureConfigurations.Where(feature => feature.AgentRegistrationId == agentId);
        var feature = await features.AsNoTracking().SingleOrDefaultAsync(ct);
        if (feature is null)
            return null;
        agent.FeatureConfiguration = feature;
        if ((lockedPostgres) && expectedContext?.MatchesAgent(agent) != true)
            return null;

        if (agent.PurviewPolicySelectionMode == "ExistingPolicy" && feature.PurviewEnabled)
        {
            var binding = _individualPolicies is null ? null : await _individualPolicies.ReadAsync(agent, ct);
            // No receipt can be issued or consumed without a current authenticated scope readback.
            if (binding is null) return null;
            return PromptProtectionContext.Capture(agent, individualPolicyBinding: binding);
        }
        if (feature.PurviewEnabled) return null;
        return PromptProtectionContext.Capture(agent);
    }
}
