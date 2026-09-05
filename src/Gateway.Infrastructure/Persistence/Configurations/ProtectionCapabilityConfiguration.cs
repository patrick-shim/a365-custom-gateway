using Gateway.Domain.Entities;
using Gateway.Domain.Models;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.ChangeTracking;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class ProtectionCapabilityConfiguration
    : IEntityTypeConfiguration<ProtectionCapability>
{
    public void Configure(EntityTypeBuilder<ProtectionCapability> builder)
    {
        builder.ToTable("ProtectionCapabilities");
        builder.HasKey(capability => capability.Id);

        builder.Property(capability => capability.Kind)
            .HasConversion<string>()
            .HasMaxLength(40)
            .IsRequired();
        builder.Property(capability => capability.Status)
            .HasConversion<string>()
            .HasMaxLength(32)
            .IsRequired();
        var identifiers = builder.Property(capability => capability.ResourceIdentifiers)
            .HasConversion(
                value => ProtectionPersistenceSerialization.SerializeResourceIdentifiers(value),
                value => ProtectionPersistenceSerialization.DeserializeResourceIdentifiers(value))
            .HasColumnName("ResourceIdentifiersJson")
            .HasMaxLength(4000)
            .IsRequired();
        identifiers.Metadata.SetValueComparer(
            new ValueComparer<ProtectionCapabilityResourceIdentifiers>(
                (first, second) => first == second,
                value => value.GetHashCode(),
                value => ProtectionPersistenceSerialization.CloneResourceIdentifiers(value)));
        builder.Property(capability => capability.LastFailureCode).HasMaxLength(64);
        builder.Property(capability => capability.RowVersion).IsRowVersion();

        builder.HasIndex(capability => capability.Kind).IsUnique();
        builder.HasIndex(capability => capability.Status);
    }
}
