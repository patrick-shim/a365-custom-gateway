using System.Security.Cryptography;
using System.Text.Json;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Persistence;
using Gateway.Purview;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Infrastructure;

public sealed class AgentPolicyBindings(GatewayDbContext db,
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
        foreach (var row in selected)
        {
            if (string.IsNullOrWhiteSpace(row.AssignedRevision) || row.AssignedRevision.Length != 64 ||
                !row.AssignedRevision.All(char.IsAsciiHexDigitLower))
                return null;
        }

        // Runtime Graph scope computation and processContent provide current
        // fail-closed enforcement. The management catalog is operator inventory,
        // so its age must not silently disable an otherwise confirmed assignment.
        return new(PolicyAssignmentProtocol.Digest(selected.Select(x => new
        {
            x.Id,
            x.PolicyId,
            x.AssignedRevision,
            x.AgentIdentityId,
            x.BlueprintId,
            x.AssignedAtUtc
        })));
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
                        var accepted = await TryApplyAssignmentResultFileAsync(
                            row,
                            request,
                            prefix + ".result.json",
                            options.Value.AuthenticationKey,
                            DateTime.UtcNow,
                            stoppingToken);
                        if (!accepted)
                            logger.LogWarning(
                                "Invalid signed assignment result rejected for operation {OperationId}; no success or retry was inferred.",
                                row.Id);
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

    internal static async Task<bool> TryApplyAssignmentResultFileAsync(
        AgentPolicyAssignment row,
        PolicyAssignmentRequest request,
        string resultPath,
        string authenticationKey,
        DateTime utcNow,
        CancellationToken cancellationToken)
    {
        try
        {
            var info = new FileInfo(resultPath);
            if (info.Length is <= 0 or > 32_768)
                throw new InvalidDataException("Assignment response exceeds bound.");
            return TryApplyAssignmentResult(
                row,
                request,
                await File.ReadAllTextAsync(resultPath, cancellationToken),
                authenticationKey,
                utcNow);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            MarkAssignmentResultInvalid(row);
            return false;
        }
    }

    internal static bool TryApplyAssignmentResult(
        AgentPolicyAssignment row,
        PolicyAssignmentRequest request,
        string envelope,
        string authenticationKey,
        DateTime utcNow)
    {
        try
        {
            var result = PolicyAssignmentProtocol.Verify<PolicyAssignmentResult>(
                envelope,
                authenticationKey,
                "result");
            PolicyAssignmentProtocol.Validate(result, request, utcNow);
            if (row.ConfirmedAtUtc is not { } confirmedAtUtc || result.ReadAtUtc < confirmedAtUtc)
                throw new InvalidOperationException("Assignment response binding mismatch.");

            row.Status = result.Assigned ? "Assigned" : "Failed";
            row.FailureCode = result.FailureCode;
            row.AssignedAtUtc = result.Assigned ? result.ReadAtUtc : null;
            row.AssignedRevision = result.Assigned ? result.DefinitionRevision : null;
            return true;
        }
        catch (Exception failure) when (failure is CryptographicException or JsonException or
            ArgumentException or FormatException or InvalidOperationException or InvalidDataException)
        {
            MarkAssignmentResultInvalid(row);
            return false;
        }
    }

    private static void MarkAssignmentResultInvalid(AgentPolicyAssignment row)
    {
        row.Status = "Failed";
        row.FailureCode = ErrorCodes.ASSIGNMENT_RESULT_INVALID;
        row.AssignedAtUtc = null;
        row.AssignedRevision = null;
    }
}
