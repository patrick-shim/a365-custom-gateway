using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence;
using Gateway.Purview;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Infrastructure;

public sealed class AgentPolicyBindings(GatewayDbContext db, IPurviewPolicyCatalogClient catalog,
    IOptions<RuntimePurviewCatalogOptions> options) : IAgentPolicyBindingReader
{
    public async Task<AgentPolicyBinding?> ReadAsync(AgentRegistration agent, CancellationToken ct)
    {
        if (agent.PurviewPolicySelectionMode != "ExistingPolicy" || !agent.FeatureConfiguration.PurviewEnabled ||
            !Guid.TryParse(agent.Agent365AgentId, out var child) || !Guid.TryParse(agent.BlueprintId, out var blueprint) || child == blueprint)
            return null;
        var rows = await db.AgentPolicyAssignments.AsNoTracking().Where(x => x.AgentRegistrationId == agent.Id && x.ConfirmedAtUtc != null).ToListAsync(ct);
        var selected = rows.GroupBy(x => x.PolicyId).Select(g => g.OrderByDescending(x => x.ConfirmedAtUtc).First()).OrderBy(x => x.PolicyId).ToArray();
        if (selected.Length == 0 || selected.Any(x => x.TenantId != options.Value.TenantId || x.Status != "Assigned" ||
            x.AgentIdentityId != child || x.BlueprintId != blueprint || x.AssignedAtUtc is null)) return null;
        try
        {
            var snapshot = await catalog.ReadAsync(options.Value.TenantId, ct);
            foreach (var row in selected)
            {
                var policy = snapshot.Items.SingleOrDefault(x => x.Id == row.PolicyId);
                if (policy is null || policy.Revision != row.AssignedRevision || PurviewPolicyCatalogValidation.Incompatibility(policy) is not null ||
                    policy.AllAccountsApplicationIds?.Contains(child) != true) return null;
            }
            return new(PolicyAssignmentProtocol.Digest(selected.Select(x => new { x.Id, x.PolicyId, x.AssignedRevision, x.AgentIdentityId })),
                snapshot.RetrievedAtUtc.Add(PurviewPolicyCatalogValidation.MaximumAge).UtcDateTime);
        }
        catch (PurviewPolicyException) { return null; }
    }
}

public sealed class AgentPolicyAssignmentWorker(IServiceScopeFactory scopes, IOptions<RuntimePolicyAssignmentOptions> options,
    ILogger<AgentPolicyAssignmentWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (string.IsNullOrWhiteSpace(options.Value.QueueDirectory) || string.IsNullOrWhiteSpace(options.Value.AuthenticationKey)) return;
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var scope = scopes.CreateScope();
                var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
                var pending = await db.AgentPolicyAssignments.Where(x => x.Status == "Pending").OrderBy(x => x.ConfirmedAtUtc).Take(20).ToListAsync(stoppingToken);
                foreach (var row in pending)
                {
                    var request = new PolicyAssignmentRequest(row.Id, row.TenantId, row.AgentRegistrationId, row.AgentIdentityId,
                        row.BlueprintId, row.PolicyId, row.ReviewedRevision, row.ExpiresAtUtc);
                    var prefix = Path.Combine(options.Value.QueueDirectory, row.Id.ToString("D"));
                    if (File.Exists(prefix + ".result.json"))
                    {
                        if (new FileInfo(prefix + ".result.json").Length > 32768) throw new InvalidOperationException("Assignment response exceeds bound.");
                        var result = PolicyAssignmentProtocol.Verify<PolicyAssignmentResult>(await File.ReadAllTextAsync(prefix + ".result.json", stoppingToken), options.Value.AuthenticationKey, "result");
                        if (result.OperationId != row.Id || result.TenantId != row.TenantId || result.AgentIdentityId != row.AgentIdentityId ||
                            result.PolicyId != row.PolicyId || result.RequestDigest != PolicyAssignmentProtocol.Digest(request) ||
                            result.ReadAtUtc < row.ConfirmedAtUtc || result.ReadAtUtc > DateTime.UtcNow.AddMinutes(1))
                            throw new InvalidOperationException("Assignment response binding mismatch.");
                        row.Status = result.Assigned ? "Assigned" : "Failed";
                        row.FailureCode = result.FailureCode;
                        row.AssignedAtUtc = result.Assigned ? result.ReadAtUtc : null;
                        row.AssignedRevision = result.Assigned ? result.Revision : null;
                        await db.SaveChangesAsync(stoppingToken);
                    }
                    else if (row.ExpiresAtUtc < DateTime.UtcNow)
                    {
                        // No automatic second write after an unknown outcome. A new reviewed operation
                        // always reads current scope before deciding whether an add is necessary.
                        row.Status = "Failed"; row.FailureCode = "ASSIGNMENT_OUTCOME_UNCONFIRMED";
                        await db.SaveChangesAsync(stoppingToken);
                    }
                    else if (!File.Exists(prefix + ".request.json"))
                    {
                        var agent = await db.AgentRegistrations.AsNoTracking().SingleOrDefaultAsync(x => x.Id == row.AgentRegistrationId, stoppingToken);
                        if (agent is null || agent.IsDeleted || agent.Status != Gateway.Domain.Enums.AgentStatus.Active ||
                            agent.Agent365AgentId != row.AgentIdentityId.ToString() || agent.BlueprintId != row.BlueprintId.ToString() ||
                            !Guid.TryParse(agent.AgentIdentityObjectId, out var principal))
                        {
                            row.Status = "Failed"; row.FailureCode = "ASSIGNMENT_AGENT_CHANGED";
                            await db.SaveChangesAsync(stoppingToken); continue;
                        }
                        try
                        {
                            await scope.ServiceProvider.GetRequiredService<Gateway.Agent365.IAgentPurviewAccessProvisioner>()
                                .EnsureAsync(row.TenantId, principal, row.AgentIdentityId, row.BlueprintId, stoppingToken);
                        }
                        catch (Gateway.Domain.Models.Agent365ProvisioningException)
                        {
                            row.Status = "Failed"; row.FailureCode = "ASSIGNMENT_RUNTIME_ACCESS_UNCONFIRMED";
                            await db.SaveChangesAsync(stoppingToken); continue;
                        }
                        Directory.CreateDirectory(options.Value.QueueDirectory);
                        await PolicyAssignmentProtocol.WriteAtomicAsync(prefix + ".request.json",
                            PolicyAssignmentProtocol.Sign(request, options.Value.AuthenticationKey, "request"), stoppingToken);
                    }
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception failure) { logger.LogWarning("Policy assignment processing unavailable ({FailureType}); no success inferred.", failure.GetType().Name); }
            try { await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken); } catch (OperationCanceledException) { break; }
        }
    }
}
