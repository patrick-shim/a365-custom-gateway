using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Outbox;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence;

public class GatewayDbContext : DbContext
{
    public GatewayDbContext(DbContextOptions<GatewayDbContext> options) : base(options) { }

    public DbSet<AgentRegistration> AgentRegistrations => Set<AgentRegistration>();
    public DbSet<AgentFeatureConfiguration> AgentFeatureConfigurations => Set<AgentFeatureConfiguration>();
    public DbSet<ProvisioningJob> ProvisioningJobs => Set<ProvisioningJob>();
    public DbSet<ProvisioningJobStep> ProvisioningJobSteps => Set<ProvisioningJobStep>();
    public DbSet<AgentCredentialReference> AgentCredentialReferences => Set<AgentCredentialReference>();
    public DbSet<AgentIngressCredential> AgentIngressCredentials => Set<AgentIngressCredential>();
    public DbSet<ActivityReceipt> ActivityReceipts => Set<ActivityReceipt>();
    public DbSet<AiInteractionRecord> AiInteractionRecords => Set<AiInteractionRecord>();
    public DbSet<PurviewDecision> PurviewDecisions => Set<PurviewDecision>();
    public DbSet<AuditEvent> AuditEvents => Set<AuditEvent>();
    public DbSet<OutboxMessage> OutboxMessages => Set<OutboxMessage>();
    public DbSet<IdempotencyRecord> IdempotencyRecords => Set<IdempotencyRecord>();
    public DbSet<SystemConfiguration> SystemConfigurations => Set<SystemConfiguration>();
    public DbSet<PurviewPolicyProfile> PurviewPolicyProfiles => Set<PurviewPolicyProfile>();
    public DbSet<PromptEvaluationRecord> PromptEvaluationRecords => Set<PromptEvaluationRecord>();
    public DbSet<ProtectionCapability> ProtectionCapabilities => Set<ProtectionCapability>();
    public DbSet<PurviewTenantConnection> PurviewTenantConnections => Set<PurviewTenantConnection>();
    public DbSet<PurviewSensitiveInformationTypeSnapshotGeneration>
        PurviewSensitiveInformationTypeSnapshotGenerations =>
        Set<PurviewSensitiveInformationTypeSnapshotGeneration>();
    public DbSet<PurviewSensitiveInformationTypeSnapshot>
        PurviewSensitiveInformationTypeSnapshots =>
        Set<PurviewSensitiveInformationTypeSnapshot>();
    public DbSet<PurviewKnowYourDataConfiguration> PurviewKnowYourDataConfigurations =>
        Set<PurviewKnowYourDataConfiguration>();
    public DbSet<PurviewDlpProfile> PurviewDlpProfiles => Set<PurviewDlpProfile>();
    public DbSet<ProtectionAdminOperation> ProtectionAdminOperations =>
        Set<ProtectionAdminOperation>();
    public DbSet<ProtectionAdminOperationStep> ProtectionAdminOperationSteps =>
        Set<ProtectionAdminOperationStep>();
    internal DbSet<LegacyProtectionPolicyCandidate> LegacyProtectionPolicyCandidates =>
        Set<LegacyProtectionPolicyCandidate>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(GatewayDbContext).Assembly);
    }

    public override int SaveChanges(bool acceptAllChangesOnSuccess)
    {
        ApplyPersistenceInvariants();
        return base.SaveChanges(acceptAllChangesOnSuccess);
    }

    public override Task<int> SaveChangesAsync(
        bool acceptAllChangesOnSuccess,
        CancellationToken cancellationToken = default)
    {
        ApplyPersistenceInvariants();
        return base.SaveChangesAsync(acceptAllChangesOnSuccess, cancellationToken);
    }

    private void ApplyPersistenceInvariants()
    {
        foreach (var entry in ChangeTracker.Entries<OutboxMessage>()
                     .Where(entry => entry.State is EntityState.Added or EntityState.Modified))
        {
            entry.Property<string>("Destination").CurrentValue =
                OutboxRouting.ResolveDestination(entry.Entity.MessageType);
        }

        foreach (var entry in ChangeTracker.Entries<PurviewKnowYourDataConfiguration>()
                     .Where(entry => entry.State is EntityState.Added or EntityState.Modified))
        {
            entry.Property<string>("PersistedScopeType").CurrentValue =
                nameof(PurviewPolicyScopeType.Group);
            entry.Property<Guid>("PersistedGroupId").CurrentValue =
                PurviewPolicyLocationContract.EnterpriseAiAppsGroupId;
            entry.Property<string>("PersistedEnforcementPlane").CurrentValue =
                nameof(PurviewEnforcementPlane.Application);
        }

        foreach (var entry in ChangeTracker.Entries<PurviewDlpProfile>()
                     .Where(entry => entry.State is EntityState.Added or EntityState.Modified))
        {
            entry.Property<string>("PersistedScopeType").CurrentValue =
                nameof(PurviewPolicyScopeType.Individual);
            entry.Property<string>("PersistedEnforcementPlane").CurrentValue =
                nameof(PurviewEnforcementPlane.Application);
        }
    }
}
