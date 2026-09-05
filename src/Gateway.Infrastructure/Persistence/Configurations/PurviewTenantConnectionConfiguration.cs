using Gateway.Domain.Entities;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class PurviewTenantConnectionConfiguration
    : IEntityTypeConfiguration<PurviewTenantConnection>
{
    public void Configure(EntityTypeBuilder<PurviewTenantConnection> builder)
    {
        builder.ToTable("PurviewTenantConnections");
        builder.HasKey(connection => connection.Id);

        builder.Property(connection => connection.TenantId)
            .HasConversion(
                value => value.Value,
                value => new EntraTenantId(value))
            .IsRequired();
        builder.Property(connection => connection.Status)
            .HasConversion<string>()
            .HasMaxLength(32)
            .IsRequired();
        builder.Property(connection => connection.AuthorityApplicationId)
            .HasConversion(
                value => value.HasValue ? value.Value.Value : (Guid?)null,
                value => value.HasValue ? new ApplicationClientId(value.Value) : null);
        builder.Property(connection => connection.AuthorityServicePrincipalObjectId)
            .HasConversion(
                value => value.HasValue ? value.Value.Value : (Guid?)null,
                value => value.HasValue ? new ServicePrincipalObjectId(value.Value) : null);
        builder.Property(connection => connection.AuthorityKind).HasMaxLength(64);
        builder.Property(connection => connection.ActiveInventoryGenerationId)
            .HasConversion(
                value => value.HasValue ? value.Value.Value : (Guid?)null,
                value => value.HasValue
                    ? new SensitiveInformationTypeSnapshotGenerationId(value.Value)
                    : null);
        builder.Property(connection => connection.LastFailureCode).HasMaxLength(64);
        builder.Property(connection => connection.CreatedByObjectId)
            .HasMaxLength(64)
            .IsRequired();
        builder.Property(connection => connection.RowVersion).IsRowVersion();

        builder.HasIndex(connection => connection.TenantId).IsUnique();
        builder.HasIndex(connection => connection.Status);
        builder.HasIndex(connection => connection.ActiveInventoryGenerationId)
            .IsUnique()
            .HasFilter("[ActiveInventoryGenerationId] IS NOT NULL");

        builder.HasOne<PurviewSensitiveInformationTypeSnapshotGeneration>()
            .WithMany()
            .HasForeignKey(connection => connection.ActiveInventoryGenerationId)
            .OnDelete(DeleteBehavior.NoAction);
    }
}
