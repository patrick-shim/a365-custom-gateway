using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class PurviewCatalogSnapshotConfiguration : IEntityTypeConfiguration<PurviewCatalogSnapshot>
{
    public void Configure(EntityTypeBuilder<PurviewCatalogSnapshot> builder)
    {
        builder.ToTable("PurviewCatalogSnapshots");
        builder.HasKey(x => x.Id);
        builder.HasIndex(x => new { x.TenantId, x.Generation }).IsUnique();
        builder.HasIndex(x => x.OperationId).IsUnique();
        builder.Property(x => x.CatalogHash).HasMaxLength(64);
        builder.Property(x => x.CatalogJson).HasColumnType("jsonb");
    }
}
