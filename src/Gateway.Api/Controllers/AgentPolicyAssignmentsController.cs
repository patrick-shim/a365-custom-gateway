using Gateway.Contracts.Responses;
using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Persistence;
using Gateway.Purview;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/agents/{agentId:guid}/purview-policies")]
[Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
public sealed class AgentPolicyAssignmentsController(GatewayDbContext db, IPurviewPolicyCatalogClient catalog,
    IAgentPolicyBindingReader bindings, IOptions<RuntimePolicyAssignmentOptions> options) : ControllerBase
{
    public sealed record Selection(Guid PolicyId, string Revision);

    [HttpGet]
    [ProducesResponseType(typeof(AgentPolicyAssignmentsResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> List(Guid agentId, CancellationToken ct)
    {
        Response.Headers.CacheControl = "no-store";
        var actor = User.GetProtectionActor();
        var agent = await db.AgentRegistrations.Include(x => x.FeatureConfiguration).SingleOrDefaultAsync(x => x.Id == agentId && !x.IsDeleted, ct);
        if (agent is null) return NotFound();
        var rows = await db.AgentPolicyAssignments.AsNoTracking().Where(x => x.AgentRegistrationId == agentId && x.TenantId == actor.TenantId && x.ConfirmedAtUtc != null).ToListAsync(ct);
        var current = rows.GroupBy(x => x.PolicyId).Select(g => g.OrderByDescending(x => x.ConfirmedAtUtc).First()).ToArray();
        var binding = await bindings.ReadAsync(agent, ct);
        var since = current.Select(x => x.AssignedAtUtc ?? DateTime.MaxValue).DefaultIfEmpty(DateTime.MaxValue).Max();
        var observations = db.PromptEvaluationRecords.AsNoTracking().Where(x => x.AgentRegistrationId == agentId &&
            x.ProtectionRevision == agent.ProtectionRevision && x.CreatedAtUtc >= since && x.EvaluatedPurviewPolicyMode == PurviewPolicyMode.Enforce);
        var allow = await observations.Where(x => x.PurviewDecision == PurviewDecisionType.Allowed).Select(x => (DateTime?)x.CreatedAtUtc).MaxAsync(ct);
        var block = await observations.Where(x => x.PurviewDecision == PurviewDecisionType.Blocked).Select(x => (DateTime?)x.CreatedAtUtc).MaxAsync(ct);
        return Ok(new AgentPolicyAssignmentsResponse(agentId, agent.Agent365AgentId, binding is not null,
            binding is not null ? allow : null, binding is not null ? block : null,
            current.Select(x => new AgentPolicyAssignmentResponse(x.Id, x.PolicyId, x.PolicyName, x.Status,
                x.FailureCode, x.ConfirmedAtUtc, x.ExpiresAtUtc, x.AssignedAtUtc))));
    }

    [HttpPost("review")]
    [ProducesResponseType(typeof(PolicyAssignmentReviewResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> Review(Guid agentId, Selection selection, CancellationToken ct)
    {
        var actor = User.GetProtectionActor();
        if (string.IsNullOrWhiteSpace(options.Value.AuthenticationKey) || string.IsNullOrWhiteSpace(options.Value.QueueDirectory))
            return Problem("Run the Purview assignment setup during bootstrap.", statusCode: 503);
        var agent = await db.AgentRegistrations.Include(x => x.FeatureConfiguration).SingleOrDefaultAsync(x => x.Id == agentId && !x.IsDeleted, ct);
        if (agent is null) return NotFound();
        if (agent.Status != AgentStatus.Active || !Guid.TryParse(agent.Agent365AgentId, out var child) ||
            !Guid.TryParse(agent.BlueprintId, out var blueprint) || child == blueprint || child == Guid.Empty)
            return Conflict(new { detail = "This agent requires its own active identity before assignment." });
        if (agent.FeatureConfiguration.PurviewEnabled && agent.PurviewPolicySelectionMode != "ExistingPolicy")
            return Conflict(new { detail = "Review the existing shared blueprint configuration before moving this agent to individual assignments." });
        var snapshot = await catalog.ReadAsync(actor.TenantId, ct);
        var policy = snapshot.Items.SingleOrDefault(x => x.Id == selection.PolicyId);
        if (policy is null || policy.Revision != selection.Revision || PurviewPolicyCatalogValidation.Incompatibility(policy) is not null)
            return Conflict(new { detail = "The policy changed or is incompatible. Refresh the catalog and review again." });
        var row = new AgentPolicyAssignment { Id = Guid.NewGuid(), TenantId = actor.TenantId, AgentRegistrationId = agentId,
            AgentIdentityId = child, BlueprintId = blueprint, PolicyId = policy.Id, PolicyName = policy.DisplayName,
            ReviewedRevision = policy.Revision, ReviewedProtectionRevision = agent.ProtectionRevision,
            ActorObjectId = actor.ObjectId, CreatedAtUtc = DateTime.UtcNow, ExpiresAtUtc = DateTime.UtcNow.AddMinutes(10) };
        db.AgentPolicyAssignments.Add(row); await db.SaveChangesAsync(ct);
        return Ok(new PolicyAssignmentReviewResponse(row.Id, agentId, child, policy.Id, policy.DisplayName,
            row.ExpiresAtUtc, "Add this individual agent for all accounts and enable its Purview content-evaluation access; preserve other targets and policy rules. Gateway requests fail closed while assignment or inline evaluation is unavailable."));
    }

    [HttpPost("{operationId:guid}/confirm")]
    [ProducesResponseType(typeof(PolicyAssignmentConfirmationResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(PolicyAssignmentConfirmationResponse), StatusCodes.Status202Accepted)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<IActionResult> Confirm(Guid agentId, Guid operationId, CancellationToken ct)
    {
        var actor = User.GetProtectionActor();
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var agent = await (db.AgentRegistrations.FromSqlInterpolated($"SELECT * FROM \"AgentRegistrations\" WHERE \"Id\" = {agentId} FOR UPDATE"))
            .Include(x => x.FeatureConfiguration).SingleOrDefaultAsync(ct);
        var row = await db.AgentPolicyAssignments.SingleOrDefaultAsync(x => x.Id == operationId && x.AgentRegistrationId == agentId && x.TenantId == actor.TenantId, ct);
        if (agent is null || row is null || row.ActorObjectId != actor.ObjectId) return NotFound();
        if (row.ConfirmedAtUtc is not null) return Ok(new PolicyAssignmentConfirmationResponse(operationId, row.Status));
        if (row.ExpiresAtUtc <= DateTime.UtcNow || row.ReviewedProtectionRevision != agent.ProtectionRevision || agent.IsDeleted || agent.Status != AgentStatus.Active ||
            agent.Agent365AgentId != row.AgentIdentityId.ToString() || agent.BlueprintId != row.BlueprintId.ToString())
            return Conflict(new { detail = "The review expired or the agent changed. Review again." });
        var snapshot = await catalog.ReadAsync(actor.TenantId, ct);
        if (snapshot.Items.SingleOrDefault(x => x.Id == row.PolicyId)?.Revision != row.ReviewedRevision)
            return Conflict(new { detail = "The policy changed. Refresh and review again." });
        if (await db.AgentPolicyAssignments.AnyAsync(x => x.AgentRegistrationId == agentId && x.Status == "Pending", ct))
            return Conflict(new { detail = "An assignment is already pending for this agent." });
        row.Status = "Pending"; row.ConfirmedAtUtc = DateTime.UtcNow; row.ExpiresAtUtc = DateTime.UtcNow.AddMinutes(15);
        agent.PurviewPolicySelectionMode = "ExistingPolicy";
        agent.FeatureConfiguration.PurviewEnabled = true; agent.FeatureConfiguration.PurviewMode = PurviewMode.Enforce;
        agent.RequestedPurviewPolicyMode = PurviewPolicyMode.Enforce;
        agent.ProtectionRevision = Guid.NewGuid(); agent.UpdatedAtUtc = DateTime.UtcNow; agent.UpdatedByObjectId = actor.ObjectId;
        await db.SaveChangesAsync(ct); await tx.CommitAsync(ct);
        return Accepted(new PolicyAssignmentConfirmationResponse(operationId, row.Status));
    }
}
