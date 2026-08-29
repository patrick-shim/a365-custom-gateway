using Gateway.Domain.Entities;
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

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(GatewayDbContext).Assembly);
    }
}
