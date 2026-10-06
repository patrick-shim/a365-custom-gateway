using Gateway.Api.Infrastructure;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.Purview;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

static class IndividualBindingChecks
{
    public static async Task RunAsync()
    {
        var connection = Environment.GetEnvironmentVariable("GATEWAY_TEST_DB");
        if (connection is null) return;
        var agentId = Guid.Parse(Environment.GetEnvironmentVariable("GATEWAY_BINDING_TEST_AGENT")!);
        await using var db = new GatewayDbContext(new DbContextOptionsBuilder<GatewayDbContext>().UseNpgsql(connection)
            .AddInterceptors(new PostgresRowVersionInterceptor()).Options);
        await using var tx = await db.Database.BeginTransactionAsync(System.Data.IsolationLevel.Serializable);
        var agent = await db.AgentRegistrations.Include(x => x.FeatureConfiguration).SingleAsync(x => x.Id == agentId);
        if (await db.AgentPolicyAssignments.AnyAsync(x => x.AgentRegistrationId == agentId)) throw new Exception("Use an unassigned control agent for rollback-only checks.");
        var tenant = Guid.NewGuid(); var child = Guid.Parse(agent.Agent365AgentId!);
        var policy = new PurviewExistingPolicy(Guid.NewGuid(), "Rollback-only test", "Enable", ["Application"], [child], true, new string('a',64), [child]);
        var source = new Catalog(new(tenant, DateTimeOffset.UtcNow, [policy]));
        var bindings = new AgentPolicyBindings(db, source, Options.Create(new RuntimePurviewCatalogOptions { TenantId=tenant }));
        agent.PurviewPolicySelectionMode="ExistingPolicy"; agent.FeatureConfiguration.PurviewEnabled=true;
        agent.RequestedPurviewPolicyMode=PurviewPolicyMode.Enforce;
        var row = new AgentPolicyAssignment { Id=Guid.NewGuid(), TenantId=tenant, AgentRegistrationId=agentId, AgentIdentityId=child,
            BlueprintId=Guid.Parse(agent.BlueprintId!), PolicyId=policy.Id, PolicyName=policy.DisplayName, ReviewedRevision=policy.Revision,
            AssignedRevision=policy.Revision, Status="Assigned", CreatedAtUtc=DateTime.UtcNow, ExpiresAtUtc=DateTime.UtcNow.AddMinutes(5),
            ConfirmedAtUtc=DateTime.UtcNow, AssignedAtUtc=DateTime.UtcNow };
        db.AgentPolicyAssignments.Add(row); await db.SaveChangesAsync();
        var repository = new PromptEvaluationRepository(db, individualPolicies: bindings);
        var context = await repository.GetProtectionContextAsync(agentId, default) ?? throw new Exception("Exact current child assignment rejected.");
        if (context.PurviewMode != PurviewPolicyMode.Enforce || context.IndividualPolicyBinding is null ||
            !await repository.IsProtectionContextCurrentAsync(context, default)) throw new Exception("Individual receipt binding failed under PostgreSQL locks.");
        foreach (var invalid in new[] { policy with { Revision=new string('b',64) }, policy with { AllAccountsApplicationIds=[] }, policy with { Mode="Disable" } })
        {
            source.Value = source.Value with { Items=[invalid] };
            if (await repository.IsProtectionContextCurrentAsync(context, default) || await bindings.ReadAsync(agent, default) is not null)
                throw new Exception("Changed, excluded, or disabled scope retained a trusted binding.");
        }
        source.Value = source.Value with { Items=[policy], RetrievedAtUtc=DateTimeOffset.UtcNow.Subtract(PurviewPolicyCatalogValidation.MaximumAge).AddSeconds(-1) };
        if (await bindings.ReadAsync(agent, default) is not null) throw new Exception("Expired catalog retained a trusted binding.");
        source.Value = source.Value with { RetrievedAtUtc=DateTimeOffset.UtcNow };
        row.Status="Pending"; await db.SaveChangesAsync();
        if (await bindings.ReadAsync(agent, default) is not null) throw new Exception("Pending assignment became ready.");
        await tx.RollbackAsync();
        Console.WriteLine("PostgreSQL rollback-only checks passed: exact child binding, receipt locking, changed/disabled/excluded policy, catalog expiry, and pending assignment fail closed.");
    }
    private sealed class Catalog(PurviewPolicyCatalog value) : IPurviewPolicyCatalogClient
    {
        public PurviewPolicyCatalog Value { get; set; } = value;
        public Task<PurviewPolicyCatalog> ReadAsync(Guid tenantId, CancellationToken ct)
        { PurviewPolicyCatalogValidation.Validate(Value, tenantId); return Task.FromResult(Value); }
    }
}
