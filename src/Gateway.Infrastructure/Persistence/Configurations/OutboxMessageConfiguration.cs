using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class OutboxMessageConfiguration : IEntityTypeConfiguration<OutboxMessage>
{
    public void Configure(EntityTypeBuilder<OutboxMessage> builder)
    {
        builder.ToTable("OutboxMessages");

        builder.HasKey(e => e.Id);

        builder.Property(e => e.MessageType).HasMaxLength(256).IsRequired();
        builder.Property(e => e.Status).HasConversion<string>().HasMaxLength(20);
        builder.Property<string>("Destination")
            .HasMaxLength(128)
            .HasDefaultValue(Outbox.OutboxRouting.ProvisioningDestination)
            .IsRequired();

        builder.HasIndex(e => new { e.Status, e.NextRetryAtUtc })
            .HasFilter("[Status] = 'Pending'");
        builder.HasIndex("Destination", nameof(OutboxMessage.Status), nameof(OutboxMessage.NextRetryAtUtc))
            .HasDatabaseName("IX_OutboxMessages_Destination_Status_NextRetryAtUtc")
            .HasFilter("[Status] IN ('Pending', 'Processing')");
    }
}
