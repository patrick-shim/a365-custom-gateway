using Gateway.Domain.Entities;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class PurviewSensitiveInformationTypeSnapshotConfiguration
    : IEntityTypeConfiguration<PurviewSensitiveInformationTypeSnapshot>
{
    public void Configure(EntityTypeBuilder<PurviewSensitiveInformationTypeSnapshot> builder)
    {
        builder.ToTable(
            "PurviewSensitiveInformationTypeSnapshots",
            table => table.HasCheckConstraint(
                "CK_PurviewSitSnapshots_SortOrder",
                "[SortOrder] >= 0"));
        builder.HasKey(snapshot => snapshot.Id);

        builder.Property(snapshot => snapshot.GenerationId)
            .HasConversion(
                value => value.Value,
                value => new SensitiveInformationTypeSnapshotGenerationId(value))
            .IsRequired();
        builder.Property(snapshot => snapshot.SensitiveInformationTypeId)
            .HasConversion(
                value => value.Value,
                value => new SensitiveInformationTypeId(value))
            .IsRequired();
        builder.Property(snapshot => snapshot.ExactName).HasMaxLength(256).IsRequired();
        builder.Property(snapshot => snapshot.Publisher).HasMaxLength(256).IsRequired();

        builder.HasIndex(snapshot => new
        {
            snapshot.GenerationId,
            snapshot.SensitiveInformationTypeId,
        }).IsUnique();
        builder.HasIndex(snapshot => new
        {
            snapshot.GenerationId,
            snapshot.SortOrder,
        }).IsUnique();

        builder.HasOne(snapshot => snapshot.Generation)
            .WithMany(generation => generation.Items)
            .HasForeignKey(snapshot => snapshot.GenerationId)
            .OnDelete(DeleteBehavior.Cascade);
    }
}
