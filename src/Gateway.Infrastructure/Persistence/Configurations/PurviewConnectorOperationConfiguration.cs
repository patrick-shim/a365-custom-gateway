using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class PurviewConnectorOperationConfiguration : IEntityTypeConfiguration<PurviewConnectorOperation>
{
    public void Configure(EntityTypeBuilder<PurviewConnectorOperation> builder)
    {
        builder.ToTable("PurviewConnectorOperations");
        builder.HasKey(x => x.Id);
        builder.HasIndex(x => new { x.TenantId, x.IdempotencyKey }).IsUnique();
        builder.HasIndex(x => new { x.Status, x.CreatedAtUtc });
        builder.Property(x => x.Type).HasConversion<string>().HasMaxLength(32);
        builder.Property(x => x.Status).HasConversion<string>().HasMaxLength(24);
        builder.Property(x => x.CurrentStep).HasMaxLength(64);
        builder.Property(x => x.IdempotencyKey).HasMaxLength(36);
        builder.Property(x => x.RequestHash).HasMaxLength(64);
        builder.Property(x => x.RequestedByObjectId).HasMaxLength(36);
        builder.Property(x => x.CorrelationId).HasMaxLength(128);
        builder.Property(x => x.ResultHash).HasMaxLength(64);
        builder.Property(x => x.CatalogHash).HasMaxLength(64);
        builder.Property(x => x.FailureCode).HasMaxLength(128);
        builder.Property(x => x.FailureSummary).HasMaxLength(512);
        builder.Property(x => x.RowVersion).IsRowVersion();
        builder.ToTable(table => table.HasCheckConstraint(
            "CK_PurviewConnectorOperations_Status",
            $"\"Status\" IN ('{PurviewConnectorOperationStatus.Pending}','{PurviewConnectorOperationStatus.Running}','{PurviewConnectorOperationStatus.Succeeded}','{PurviewConnectorOperationStatus.Failed}','{PurviewConnectorOperationStatus.NeedsAttention}','{PurviewConnectorOperationStatus.TimedOut}','{PurviewConnectorOperationStatus.Cancelled}')"));
    }
}
