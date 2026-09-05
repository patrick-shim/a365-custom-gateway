using Gateway.Domain.Entities;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class PurviewSensitiveInformationTypeSnapshotGenerationConfiguration
    : IEntityTypeConfiguration<PurviewSensitiveInformationTypeSnapshotGeneration>
{
    public void Configure(
        EntityTypeBuilder<PurviewSensitiveInformationTypeSnapshotGeneration> builder)
    {
        builder.ToTable(
            "PurviewSensitiveInformationTypeSnapshotGenerations",
            table =>
            {
                table.HasCheckConstraint(
                    "CK_PurviewSitSnapshotGenerations_Expiration",
                    "[ExpiresAtUtc] > [RetrievedAtUtc]");
                table.HasCheckConstraint(
                    "CK_PurviewSitSnapshotGenerations_ItemCount",
                    "[ItemCount] >= 0");
            });
        builder.HasKey(generation => generation.Id);

        builder.Property(generation => generation.Id)
            .HasConversion(
                value => value.Value,
                value => new SensitiveInformationTypeSnapshotGenerationId(value))
            .ValueGeneratedNever();
        builder.Property(generation => generation.TenantId)
            .HasConversion(
                value => value.Value,
                value => new EntraTenantId(value))
            .IsRequired();
        builder.HasIndex(generation => new
        {
            generation.TenantId,
            generation.RetrievedAtUtc,
        }).IsDescending(false, true);
        builder.HasOne<PurviewTenantConnection>()
            .WithMany()
            .HasForeignKey(generation => generation.PurviewTenantConnectionId)
            .OnDelete(DeleteBehavior.NoAction);
    }
}
