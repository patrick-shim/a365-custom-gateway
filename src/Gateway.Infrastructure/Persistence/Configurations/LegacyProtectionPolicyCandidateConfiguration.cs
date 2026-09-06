using Gateway.Domain.Models;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class LegacyProtectionPolicyCandidateConfiguration
    : IEntityTypeConfiguration<LegacyProtectionPolicyCandidate>
{
    public void Configure(EntityTypeBuilder<LegacyProtectionPolicyCandidate> builder)
    {
        builder.ToTable(
            "LegacyProtectionPolicyCandidates",
            table =>
            {
                table.HasCheckConstraint(
                    "CK_LegacyProtectionPolicyCandidates_BindingStatus",
                    "[BindingStatus] = N'Unbound'");
                table.HasCheckConstraint(
                    "CK_LegacyProtectionPolicyCandidates_ReviewStatus",
                    "[ReviewStatus] = N'ReviewRequired'");
                table.HasCheckConstraint(
                    "CK_LegacyProtectionPolicyCandidates_EnforcementPlane",
                    "[EnforcementPlane] = N'Application'");
                // AND binds before OR. SQL Server omits redundant AND-group parentheses
                // in catalog readback, which bootstrap compares with this model exactly.
                table.HasCheckConstraint(
                    "CK_LegacyProtectionPolicyCandidates_Scope",
                    "[CandidateKind] = N'KnowYourData' " +
                    $"AND [ScopeType] = N'Group' AND [BlueprintApplicationId] IS NULL " +
                    $"AND [LocationId] = '{PurviewPolicyLocationContract.EnterpriseAiAppsCollectionLocationId}' " +
                    "OR [CandidateKind] = N'DlpProfile' " +
                    "AND [ScopeType] = N'Individual' AND [BlueprintApplicationId] IS NOT NULL " +
                    "AND [LocationId] = [BlueprintApplicationId]");
            });
        builder.HasKey(candidate => candidate.Id);

        builder.Property(candidate => candidate.CandidateKind).HasMaxLength(32).IsRequired();
        builder.Property(candidate => candidate.BindingStatus)
            .HasMaxLength(16)
            .HasDefaultValue("Unbound")
            .IsRequired();
        builder.Property(candidate => candidate.ReviewStatus)
            .HasMaxLength(32)
            .HasDefaultValue("ReviewRequired")
            .IsRequired();
        builder.Property(candidate => candidate.ScopeType).HasMaxLength(16).IsRequired();
        builder.Property(candidate => candidate.EnforcementPlane)
            .HasMaxLength(16)
            .HasDefaultValue("Application")
            .IsRequired();
        builder.Property(candidate => candidate.DisplayName).HasMaxLength(200).IsRequired();
        builder.Property(candidate => candidate.LegacyTemplate).HasMaxLength(64).IsRequired();
        builder.Property(candidate => candidate.Mode).HasMaxLength(32).IsRequired();
        builder.Property(candidate => candidate.LegacyStatus).HasMaxLength(32).IsRequired();
        builder.Property(candidate => candidate.CollectionPolicyProviderId).HasMaxLength(256);
        builder.Property(candidate => candidate.DlpPolicyProviderId).HasMaxLength(256);
        builder.Property(candidate => candidate.DlpRuleProviderId).HasMaxLength(256);
        builder.Property(candidate => candidate.LegacyFailureCode).HasMaxLength(64);
        builder.Property(candidate => candidate.CreatedByObjectId).HasMaxLength(64).IsRequired();
        builder.Property(candidate => candidate.RowVersion).IsRowVersion();

        builder.HasIndex(candidate => new
        {
            candidate.LegacySourceProfileId,
            candidate.CandidateKind,
            candidate.LocationId,
        }).IsUnique();
        builder.HasIndex(candidate => candidate.BlueprintApplicationId)
            .HasFilter("[BlueprintApplicationId] IS NOT NULL");
        builder.HasIndex(candidate => new
        {
            candidate.BindingStatus,
            candidate.ReviewStatus,
        });

        builder.HasOne<Gateway.Domain.Entities.PurviewPolicyProfile>()
            .WithMany()
            .HasForeignKey(candidate => candidate.LegacySourceProfileId)
            .OnDelete(DeleteBehavior.NoAction);
    }
}
