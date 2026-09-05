using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.ChangeTracking;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class PurviewKnowYourDataConfigurationConfiguration
    : IEntityTypeConfiguration<PurviewKnowYourDataConfiguration>
{
    private const string FixedGroupId = "ee1680d0-702f-4090-b26c-c49091e86531";

    public void Configure(EntityTypeBuilder<PurviewKnowYourDataConfiguration> builder)
    {
        builder.ToTable(
            "PurviewKnowYourDataConfigurations",
            table =>
            {
                table.HasCheckConstraint(
                    "CK_PurviewKyd_ScopeType",
                    "[ScopeType] = N'Group'");
                table.HasCheckConstraint(
                    "CK_PurviewKyd_GroupId",
                    $"[GroupId] = '{FixedGroupId}'");
                table.HasCheckConstraint(
                    "CK_PurviewKyd_EnforcementPlane",
                    "[EnforcementPlane] = N'Application'");
            });
        builder.HasKey(configuration => configuration.Id);

        builder.Ignore(configuration => configuration.ScopeType);
        builder.Ignore(configuration => configuration.GroupId);
        builder.Ignore(configuration => configuration.EnforcementPlane);
        builder.Property<string>("PersistedScopeType")
            .HasColumnName("ScopeType")
            .HasMaxLength(16)
            .HasDefaultValue(nameof(PurviewPolicyScopeType.Group))
            .IsRequired();
        builder.Property<Guid>("PersistedGroupId")
            .HasColumnName("GroupId")
            .HasDefaultValue(PurviewPolicyLocationContract.EnterpriseAiAppsGroupId)
            .IsRequired();
        builder.Property<string>("PersistedEnforcementPlane")
            .HasColumnName("EnforcementPlane")
            .HasMaxLength(16)
            .HasDefaultValue(nameof(PurviewEnforcementPlane.Application))
            .IsRequired();
        builder.Property(configuration => configuration.InventoryGenerationId)
            .HasConversion(
                value => value.Value,
                value => new SensitiveInformationTypeSnapshotGenerationId(value))
            .IsRequired();
        builder.Property(configuration => configuration.SensitiveInformationTypeId)
            .HasConversion(
                value => value.Value,
                value => new SensitiveInformationTypeId(value))
            .IsRequired();
        builder.Property(configuration => configuration.SensitiveInformationTypeName)
            .HasMaxLength(256)
            .IsRequired();
        builder.Property(configuration => configuration.Mode)
            .HasConversion<string>()
            .HasMaxLength(16)
            .IsRequired();
        var activities = builder.Property(configuration => configuration.Activities)
            .HasConversion(
                value => ProtectionPersistenceSerialization.SerializeActivities(value),
                value => ProtectionPersistenceSerialization.DeserializeActivities(value))
            .HasColumnName("ActivitiesJson")
            .HasMaxLength(256)
            .IsRequired();
        activities.Metadata.SetValueComparer(
            new ValueComparer<ICollection<PurviewPolicyActivity>>(
                (first, second) =>
                    first != null && second != null && first.SequenceEqual(second),
                value => value.Aggregate(
                    0,
                    (hash, item) => HashCode.Combine(hash, item)),
                value => ProtectionPersistenceSerialization.CloneActivities(value)));
        builder.Property(configuration => configuration.Status)
            .HasConversion<string>()
            .HasMaxLength(32)
            .IsRequired();
        builder.Property(configuration => configuration.ReadbackStatus)
            .HasConversion<string>()
            .HasMaxLength(24)
            .IsRequired();
        builder.Property(configuration => configuration.CollectionPolicyProviderId)
            .HasMaxLength(256);
        builder.Property(configuration => configuration.LastFailureCode).HasMaxLength(64);
        builder.Property(configuration => configuration.RowVersion).IsRowVersion();

        builder.HasIndex(configuration => configuration.PurviewTenantConnectionId)
            .IsUnique();
        builder.HasIndex(configuration => configuration.CollectionPolicyProviderId)
            .HasFilter("[CollectionPolicyProviderId] IS NOT NULL");
        builder.HasIndex(configuration => configuration.Status);

        builder.HasOne<PurviewTenantConnection>()
            .WithOne()
            .HasForeignKey<PurviewKnowYourDataConfiguration>(
                configuration => configuration.PurviewTenantConnectionId)
            .OnDelete(DeleteBehavior.NoAction);
        builder.HasOne<PurviewSensitiveInformationTypeSnapshotGeneration>()
            .WithMany()
            .HasForeignKey(configuration => configuration.InventoryGenerationId)
            .OnDelete(DeleteBehavior.NoAction);
    }
}
