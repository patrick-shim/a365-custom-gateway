using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class AiInteractionRecordConfiguration : IEntityTypeConfiguration<AiInteractionRecord>
{
    public void Configure(EntityTypeBuilder<AiInteractionRecord> builder)
    {
        builder.ToTable("AiInteractionRecords");

        builder.HasKey(e => e.Id);

        builder.Property(e => e.ExternalInteractionId).HasMaxLength(256).IsRequired();
        builder.Property(e => e.ContentBlobUri).HasMaxLength(1024);
        builder.Property(e => e.ModelProvider).HasMaxLength(256);
        builder.Property(e => e.ModelName).HasMaxLength(256);
        builder.Property(e => e.ProcessingStatus).HasConversion<string>().HasMaxLength(20);
        builder.Property(e => e.PurviewStatus).HasConversion<string>().HasMaxLength(40);
        builder.Property(e => e.ObservabilityStatus).HasMaxLength(20);

        builder.HasIndex(e => new { e.AgentRegistrationId, e.ExternalInteractionId }).IsUnique();
        builder.HasIndex(e => new { e.AgentRegistrationId, e.ReceivedAtUtc }).IsDescending(false, true);

        builder.HasOne(e => e.AgentRegistration)
            .WithMany()
            .HasForeignKey(e => e.AgentRegistrationId)
            .OnDelete(DeleteBehavior.Cascade);

        builder.HasOne(e => e.PurviewDecision)
            .WithOne(e => e.AiInteractionRecord)
            .HasForeignKey<PurviewDecision>(e => e.AiInteractionRecordId)
            .OnDelete(DeleteBehavior.ClientSetNull);
    }
}
