using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class PurviewConnectorStateConfiguration : IEntityTypeConfiguration<PurviewConnectorStateRecord>
{
    public void Configure(EntityTypeBuilder<PurviewConnectorStateRecord> builder)
    {
        builder.ToTable("PurviewConnectorStates");
        builder.HasKey(x => x.Id);
        builder.HasIndex(x => x.TenantId).IsUnique();
        builder.Property(x => x.ConnectorProfile).HasMaxLength(32);
        builder.Property(x => x.State).HasConversion<string>().HasMaxLength(24);
        builder.Property(x => x.RefreshMode).HasMaxLength(16);
        builder.Property(x => x.CatalogVerificationStatus).HasMaxLength(24);
        builder.Property(x => x.LastFailureCode).HasMaxLength(128);
        builder.Property(x => x.LastCorrelationId).HasMaxLength(128);
        builder.Property(x => x.RowVersion).IsRowVersion();
    }
}
