using Gateway.Domain.Entities;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class AgentRegistrationConfiguration : IEntityTypeConfiguration<AgentRegistration>
{
    public void Configure(EntityTypeBuilder<AgentRegistration> builder)
    {
        builder.ToTable("AgentRegistrations");

        builder.HasKey(e => e.Id);

        builder.Property(e => e.ExternalAgentId)
            .HasConversion(v => v.Value, v => new ExternalAgentId(v))
            .HasMaxLength(128)
            .IsRequired();

        builder.Property(e => e.Name).HasMaxLength(256).IsRequired();
        builder.Property(e => e.Description).HasMaxLength(2000);
        builder.Property(e => e.OwnerObjectId).HasMaxLength(64).IsRequired();
        builder.Property(e => e.Environment).HasConversion<string>().HasMaxLength(20);
        builder.Property(e => e.Status).HasConversion<string>().HasMaxLength(40);
        builder.Property(e => e.Agent365AgentId).HasMaxLength(256);
        builder.Property(e => e.BlueprintId).HasMaxLength(256);
        builder.Property(e => e.Agent365InstanceId).HasMaxLength(256);
        builder.Property(e => e.ExternalClientId).HasMaxLength(256);
        builder.Property(e => e.AgentIdentityObjectId).HasMaxLength(64);
        builder.Property(e => e.BlueprintObjectId).HasMaxLength(64);
        builder.Property(e => e.BlueprintSelectionMode)
            .HasMaxLength(32)
            .HasDefaultValue("Legacy")
            .IsRequired();
        builder.Property(e => e.RequestedBlueprintObjectId).HasMaxLength(64);
        builder.Property(e => e.RequestedBlueprintDisplayName).HasMaxLength(256);
        builder.Property(e => e.PurviewPolicySelectionMode)
            .HasMaxLength(32)
            .HasDefaultValue("NotRequested")
            .IsRequired();
        builder.Property(e => e.RequestedPurviewPolicyDisplayName).HasMaxLength(200);
        builder.Property(e => e.RequestedPurviewPolicyTemplate).HasMaxLength(64);
        builder.Property(e => e.LastProvisioningErrorCode).HasMaxLength(64);
        builder.Property(e => e.LastProvisioningErrorSummary).HasMaxLength(2000);
        builder.Property(e => e.IsDeleted).HasDefaultValue(false);
        builder.Property(e => e.RowVersion).IsRowVersion();

        builder.HasIndex(e => e.ExternalAgentId)
            .IsUnique()
            .HasFilter("[IsDeleted] = 0");

        builder.HasIndex(e => e.ExternalClientId)
            .IsUnique()
            .HasFilter("[ExternalClientId] IS NOT NULL AND [IsDeleted] = 0");

        builder.HasIndex(e => e.Status);
        builder.HasIndex(e => new { e.Environment, e.Status });
        builder.HasIndex(e => e.OwnerObjectId);

        builder.HasOne(e => e.FeatureConfiguration)
            .WithOne(e => e.AgentRegistration)
            .HasForeignKey<AgentFeatureConfiguration>(e => e.AgentRegistrationId)
            .IsRequired()
            .OnDelete(DeleteBehavior.Cascade);

        builder.HasMany(e => e.ProvisioningJobs)
            .WithOne(e => e.AgentRegistration)
            .HasForeignKey(e => e.AgentRegistrationId)
            .OnDelete(DeleteBehavior.Cascade);

        builder.HasOne(e => e.CredentialReference)
            .WithOne(e => e.AgentRegistration)
            .HasForeignKey<AgentCredentialReference>(e => e.AgentRegistrationId)
            .OnDelete(DeleteBehavior.Cascade);

        builder.HasOne(e => e.PurviewPolicyProfile)
            .WithMany(e => e.AgentRegistrations)
            .HasForeignKey(e => e.PurviewPolicyProfileId)
            .OnDelete(DeleteBehavior.Restrict);

        builder.HasQueryFilter(e => !e.IsDeleted);
    }
}
