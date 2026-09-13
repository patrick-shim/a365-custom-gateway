using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class PromptEvaluationRecordConfiguration : IEntityTypeConfiguration<PromptEvaluationRecord>
{
    public void Configure(EntityTypeBuilder<PromptEvaluationRecord> builder)
    {
        builder.ToTable("PromptEvaluationRecords", table => table.HasCheckConstraint(
            "CK_PromptEvaluationRecords_ProtectionBinding",
            "([ProtectionRevision] IS NULL AND [ProtectionContextHash] IS NULL AND [PromptShieldRequired] IS NULL AND [EvaluatedPurviewPolicyMode] IS NULL) OR " +
            "([ProtectionRevision] IS NOT NULL AND [ProtectionRevision] <> '00000000-0000-0000-0000-000000000000' AND " +
            "[ProtectionContextHash] IS NOT NULL AND DATALENGTH([ProtectionContextHash]) = 64 AND " +
            "[ProtectionContextHash] COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^0-9a-f]%' AND [PromptShieldRequired] IS NOT NULL AND " +
            "[EvaluatedPurviewPolicyMode] IS NOT NULL AND [EvaluatedPurviewPolicyMode] IN (N'Disabled', N'SimulationWithTips', N'SimulationWithoutTips', N'Enforce') AND " +
            "([Outcome] <> N'Allowed' OR (([PromptShieldRequired] = 0 OR [PromptShieldDecision] = N'Allowed') AND " +
            "([EvaluatedPurviewPolicyMode] <> N'Enforce' OR [PurviewDecision] = N'Allowed'))))"));
        builder.HasKey(record => record.Id);
        builder.Property(record => record.ExternalInteractionId).HasMaxLength(256).IsRequired();
        builder.Property(record => record.TenantUserObjectId).HasMaxLength(36).IsRequired();
        builder.Property(record => record.PromptHashSalt).HasMaxLength(32).IsRequired();
        builder.Property(record => record.PromptHash).HasMaxLength(32).IsRequired();
        builder.Property(record => record.Outcome).HasConversion<string>().HasMaxLength(20);
        builder.Property(record => record.PromptShieldDecision).HasConversion<string>().HasMaxLength(20);
        builder.Property(record => record.PurviewDecision).HasConversion<string>().HasMaxLength(40);
        builder.Property(record => record.ProtectionContextHash).HasMaxLength(64).IsUnicode(false);
        builder.Property(record => record.EvaluatedPurviewPolicyMode).HasConversion<string>().HasMaxLength(32);
        builder.Property(record => record.CorrelationId).HasMaxLength(64).IsRequired();
        builder.Property(record => record.RowVersion).IsRowVersion();
        builder.HasIndex(record => new { record.AgentRegistrationId, record.ExternalInteractionId });
        builder.HasIndex(record => record.ExpiresAtUtc);
        // Answers "what did Prompt Shields decide for this Agent 365 agent" directly,
        // without joining back through the gateway registration.
        builder.HasIndex(record => new { record.Agent365AgentId, record.CreatedAtUtc });
        builder.HasOne(record => record.AgentRegistration)
            .WithMany()
            .HasForeignKey(record => record.AgentRegistrationId)
            .OnDelete(DeleteBehavior.Cascade);
    }
}
