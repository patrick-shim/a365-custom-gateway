using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class ActivityReceiptConfiguration : IEntityTypeConfiguration<ActivityReceipt>
{
    public void Configure(EntityTypeBuilder<ActivityReceipt> builder)
    {
        builder.ToTable("ActivityReceipts");

        builder.HasKey(e => e.Id);

        builder.Property(e => e.ExternalActivityId).HasMaxLength(256).IsRequired();
        builder.Property(e => e.SessionId).HasMaxLength(256);
        builder.Property(e => e.ActivityType).HasConversion<string>().HasMaxLength(20);
        builder.Property(e => e.ActorType).HasConversion<string>().HasMaxLength(10);
        builder.Property(e => e.ProcessingStatus).HasConversion<string>().HasMaxLength(20);
        builder.Property(e => e.CorrelationId).HasMaxLength(64).IsRequired();

        builder.HasIndex(e => new { e.AgentRegistrationId, e.ExternalActivityId }).IsUnique();
        builder.HasIndex(e => new { e.AgentRegistrationId, e.ReceivedAtUtc }).IsDescending(false, true);

        builder.HasOne(e => e.AgentRegistration)
            .WithMany()
            .HasForeignKey(e => e.AgentRegistrationId)
            .OnDelete(DeleteBehavior.Cascade);
    }
}
