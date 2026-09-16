using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class CapabilityPreparationHistoryConfiguration : IEntityTypeConfiguration<CapabilityPreparationHistory>
{
    public void Configure(EntityTypeBuilder<CapabilityPreparationHistory> builder)
    {
        builder.ToTable("CapabilityPreparationHistory", table =>
        {
            table.HasCheckConstraint("CK_CapabilityPreparationHistory_Json",
                "ISJSON([PriorCapabilityFactsJson]) = 1 AND ISJSON([TargetCapabilityFactsJson]) = 1 AND ISJSON([ReceiptJson]) = 1");
        });
        builder.HasKey(value => value.Id);
        builder.Property(value => value.Id).ValueGeneratedNever();
        builder.Property(value => value.ApprovedPlanFingerprint).HasMaxLength(71).IsRequired();
        builder.Property(value => value.ReceiptFingerprint).HasMaxLength(71).IsRequired();
        builder.Property(value => value.PreviousReceiptFingerprint).HasMaxLength(71);
        builder.Property(value => value.OriginalCapabilityFactsHash).HasMaxLength(71).IsRequired();
        builder.Property(value => value.PriorCapabilityFactsJson).IsRequired();
        builder.Property(value => value.TargetCapabilityFactsJson).IsRequired();
        builder.Property(value => value.ReceiptJson).IsRequired();
        builder.HasIndex(value => value.ReceiptFingerprint).IsUnique();
        builder.HasIndex(value => new { value.DeploymentOwnershipId, value.ApprovedPlanFingerprint }).IsUnique();
        foreach (var property in builder.Metadata.GetProperties())
            property.SetAfterSaveBehavior(PropertySaveBehavior.Throw);
    }
}
