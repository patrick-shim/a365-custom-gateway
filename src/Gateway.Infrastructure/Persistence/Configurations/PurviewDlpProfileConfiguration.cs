using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.ChangeTracking;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class PurviewDlpProfileConfiguration
    : IEntityTypeConfiguration<PurviewDlpProfile>
{
    public void Configure(EntityTypeBuilder<PurviewDlpProfile> builder)
    {
        builder.ToTable(
            "PurviewDlpProfiles",
            table =>
            {
                table.HasCheckConstraint(
                    "CK_PurviewDlpProfiles_ScopeType",
                    "[ScopeType] = N'Individual'");
                table.HasCheckConstraint(
                    "CK_PurviewDlpProfiles_EnforcementPlane",
                    "[EnforcementPlane] = N'Application'");
            });
        builder.HasKey(profile => profile.Id);

        builder.Property(profile => profile.Id)
            .HasConversion(
                value => value.Value,
                value => new PurviewDlpProfileId(value))
            .ValueGeneratedNever();
        builder.Property(profile => profile.BlueprintApplicationId)
            .HasConversion(
                value => value.Value,
                value => new BlueprintApplicationId(value))
            .IsRequired();
        builder.Property(profile => profile.DisplayName).HasMaxLength(200).IsRequired();
        builder.Property(profile => profile.InventoryGenerationId)
            .HasConversion(
                value => value.Value,
                value => new SensitiveInformationTypeSnapshotGenerationId(value))
            .IsRequired();
        builder.Property(profile => profile.SensitiveInformationTypeId)
            .HasConversion(
                value => value.Value,
                value => new SensitiveInformationTypeId(value))
            .IsRequired();
        builder.Property(profile => profile.SensitiveInformationTypeName)
            .HasMaxLength(256)
            .IsRequired();
        builder.Property(profile => profile.Mode)
            .HasConversion<string>()
            .HasMaxLength(16)
            .IsRequired();
        var activities = builder.Property(profile => profile.Activities)
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
        var actions = builder.Property(profile => profile.Actions)
            .HasConversion(
                value => ProtectionPersistenceSerialization.SerializeActions(value),
                value => ProtectionPersistenceSerialization.DeserializeActions(value))
            .HasColumnName("ActionsJson")
            .HasMaxLength(1024)
            .IsRequired();
        actions.Metadata.SetValueComparer(
            new ValueComparer<ICollection<PurviewDlpRuleAction>>(
                (first, second) =>
                    first != null && second != null && first.SequenceEqual(second),
                value => value.Aggregate(
                    0,
                    (hash, item) => HashCode.Combine(hash, item)),
                value => ProtectionPersistenceSerialization.CloneActions(value)));
        builder.Ignore(profile => profile.ScopeType);
        builder.Ignore(profile => profile.EnforcementPlane);
        builder.Property<string>("PersistedScopeType")
            .HasColumnName("ScopeType")
            .HasMaxLength(16)
            .HasDefaultValue(nameof(PurviewPolicyScopeType.Individual))
            .IsRequired();
        builder.Property<string>("PersistedEnforcementPlane")
            .HasColumnName("EnforcementPlane")
            .HasMaxLength(16)
            .HasDefaultValue(nameof(PurviewEnforcementPlane.Application))
            .IsRequired();
        builder.Property(profile => profile.Status)
            .HasConversion<string>()
            .HasMaxLength(32)
            .IsRequired();
        builder.Property(profile => profile.Readiness)
            .HasConversion(
                value => ProtectionPersistenceSerialization.SerializeReadiness(value),
                value => ProtectionPersistenceSerialization.DeserializeReadiness(value))
            .HasColumnName("ReadinessJson")
            .HasMaxLength(512)
            .IsRequired();
        builder.Property(profile => profile.DlpPolicyProviderId).HasMaxLength(256);
        builder.Property(profile => profile.DlpRuleProviderId).HasMaxLength(256);
        builder.Property(profile => profile.LastFailureCode).HasMaxLength(64);
        builder.Property(profile => profile.RowVersion).IsRowVersion();

        builder.HasIndex(profile => profile.BlueprintApplicationId).IsUnique();
        builder.HasIndex(profile => profile.DlpPolicyProviderId)
            .HasFilter("[DlpPolicyProviderId] IS NOT NULL");
        builder.HasIndex(profile => profile.DlpRuleProviderId)
            .HasFilter("[DlpRuleProviderId] IS NOT NULL");
        builder.HasIndex(profile => profile.Status);

        builder.HasOne<PurviewTenantConnection>()
            .WithMany()
            .HasForeignKey(profile => profile.PurviewTenantConnectionId)
            .OnDelete(DeleteBehavior.NoAction);
        builder.HasOne<PurviewSensitiveInformationTypeSnapshotGeneration>()
            .WithMany()
            .HasForeignKey(profile => profile.InventoryGenerationId)
            .OnDelete(DeleteBehavior.NoAction);
    }
}
