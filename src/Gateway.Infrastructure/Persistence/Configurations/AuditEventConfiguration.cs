using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class AuditEventConfiguration : IEntityTypeConfiguration<AuditEvent>
{
    public void Configure(EntityTypeBuilder<AuditEvent> builder)
    {
        builder.ToTable("AuditEvents");

        builder.HasKey(e => e.Id);

        builder.Property(e => e.EventType).HasMaxLength(64).IsRequired();
        builder.Property(e => e.PerformedByObjectId).HasMaxLength(64);
        builder.Property(e => e.PerformedByRole).HasMaxLength(40);
        builder.Property(e => e.CorrelationId).HasMaxLength(64);

        builder.HasIndex(e => new { e.AgentRegistrationId, e.OccurredAtUtc }).IsDescending(false, true);
        builder.HasIndex(e => new { e.EventType, e.OccurredAtUtc }).IsDescending(false, true);

        builder.HasOne(e => e.AgentRegistration)
            .WithMany()
            .HasForeignKey(e => e.AgentRegistrationId)
            .IsRequired(false)
            .OnDelete(DeleteBehavior.SetNull);
    }
}
