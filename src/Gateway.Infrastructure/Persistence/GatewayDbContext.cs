using System.Data;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Outbox;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence;

public class GatewayDbContext : DbContext
{
    public GatewayDbContext(DbContextOptions<GatewayDbContext> options) : base(options) { }

    public DbSet<AgentPolicyAssignment> AgentPolicyAssignments => Set<AgentPolicyAssignment>();
    public DbSet<AgentRegistration> AgentRegistrations => Set<AgentRegistration>();
    public DbSet<AgentFeatureConfiguration> AgentFeatureConfigurations => Set<AgentFeatureConfiguration>();
    public DbSet<ProvisioningJob> ProvisioningJobs => Set<ProvisioningJob>();
    public DbSet<ProvisioningJobStep> ProvisioningJobSteps => Set<ProvisioningJobStep>();
    public DbSet<AgentIngressCredential> AgentIngressCredentials => Set<AgentIngressCredential>();
    public DbSet<ActivityReceipt> ActivityReceipts => Set<ActivityReceipt>();
    public DbSet<AiInteractionRecord> AiInteractionRecords => Set<AiInteractionRecord>();
    public DbSet<PurviewDecision> PurviewDecisions => Set<PurviewDecision>();
    public DbSet<AuditEvent> AuditEvents => Set<AuditEvent>();
    public DbSet<OutboxMessage> OutboxMessages => Set<OutboxMessage>();
    public DbSet<IdempotencyRecord> IdempotencyRecords => Set<IdempotencyRecord>();
    public DbSet<SystemConfiguration> SystemConfigurations => Set<SystemConfiguration>();
    public DbSet<PromptEvaluationRecord> PromptEvaluationRecords => Set<PromptEvaluationRecord>();
    public DbSet<SystemConfigurationMutation> SystemConfigurationMutations => Set<SystemConfigurationMutation>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(GatewayDbContext).Assembly);
        if (PostgresAdvisoryLock.IsNpgsql(this))
            PostgresModelCustomizer.Apply(modelBuilder);
    }

    public override int SaveChanges(bool acceptAllChangesOnSuccess)
    {
        ApplyPersistenceInvariants();
        var guard = new AgentProtectionWriteGuard(this);
        using var transaction = guard.RequiresSqlTransaction && Database.CurrentTransaction is null
            ? Database.BeginTransaction(IsolationLevel.ReadCommitted) : null;
        guard.Prepare();
        var result = base.SaveChanges(acceptAllChangesOnSuccess);
        transaction?.Commit();
        return result;
    }

    public override async Task<int> SaveChangesAsync(
        bool acceptAllChangesOnSuccess,
        CancellationToken cancellationToken = default)
    {
        ApplyPersistenceInvariants();
        var guard = new AgentProtectionWriteGuard(this);
        await using var transaction = guard.RequiresSqlTransaction && Database.CurrentTransaction is null
            ? await Database.BeginTransactionAsync(IsolationLevel.ReadCommitted, cancellationToken) : null;
        await guard.PrepareAsync(cancellationToken);
        var result = await base.SaveChangesAsync(acceptAllChangesOnSuccess, cancellationToken);
        if (transaction is not null)
            await transaction.CommitAsync(cancellationToken);
        return result;
    }

    private void ApplyPersistenceInvariants()
    {
        foreach (var entry in ChangeTracker.Entries<OutboxMessage>()
                     .Where(entry => entry.State is EntityState.Added or EntityState.Modified))
        {
            entry.Property<string>("Destination").CurrentValue =
                OutboxRouting.ResolveDestination(entry.Entity.MessageType);
        }

    }
}
