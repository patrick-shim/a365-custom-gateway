using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class PurviewDecisionConfiguration : IEntityTypeConfiguration<PurviewDecision>
{
    public void Configure(EntityTypeBuilder<PurviewDecision> builder)
    {
        builder.ToTable("PurviewDecisions");

        builder.HasKey(e => e.Id);

        builder.Property(e => e.Decision).HasConversion<string>().HasMaxLength(40);
        builder.Property(e => e.PolicyAction).HasMaxLength(30);
        builder.Property(e => e.ExecutionMode).HasConversion<string>().HasMaxLength(20);
        builder.Property(e => e.ProtectionScopeId).HasMaxLength(256);
        builder.Property(e => e.TenantUserObjectId).HasMaxLength(64);

        builder.HasIndex(e => new { e.AgentRegistrationId, e.EvaluatedAtUtc }).IsDescending(false, true);

        builder.HasOne(e => e.AgentRegistration)
            .WithMany()
            .HasForeignKey(e => e.AgentRegistrationId)
            .OnDelete(DeleteBehavior.Cascade);
    }
}
