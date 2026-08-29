using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class PromptEvaluationRecordConfiguration : IEntityTypeConfiguration<PromptEvaluationRecord>
{
    public void Configure(EntityTypeBuilder<PromptEvaluationRecord> builder)
    {
        builder.ToTable("PromptEvaluationRecords");
        builder.HasKey(record => record.Id);
        builder.Property(record => record.ExternalInteractionId).HasMaxLength(256).IsRequired();
        builder.Property(record => record.TenantUserObjectId).HasMaxLength(36).IsRequired();
        builder.Property(record => record.PromptHashSalt).HasMaxLength(32).IsRequired();
        builder.Property(record => record.PromptHash).HasMaxLength(32).IsRequired();
        builder.Property(record => record.Outcome).HasConversion<string>().HasMaxLength(20);
        builder.Property(record => record.PromptShieldDecision).HasConversion<string>().HasMaxLength(20);
        builder.Property(record => record.PurviewDecision).HasConversion<string>().HasMaxLength(40);
        builder.Property(record => record.CorrelationId).HasMaxLength(64).IsRequired();
        builder.Property(record => record.RowVersion).IsRowVersion();
        builder.HasIndex(record => new { record.AgentRegistrationId, record.ExternalInteractionId });
        builder.HasIndex(record => record.ExpiresAtUtc);
        builder.HasOne(record => record.AgentRegistration)
            .WithMany()
            .HasForeignKey(record => record.AgentRegistrationId)
            .OnDelete(DeleteBehavior.Cascade);
    }
}
