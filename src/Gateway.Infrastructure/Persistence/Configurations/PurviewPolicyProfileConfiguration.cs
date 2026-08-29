using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class PurviewPolicyProfileConfiguration : IEntityTypeConfiguration<PurviewPolicyProfile>
{
    public void Configure(EntityTypeBuilder<PurviewPolicyProfile> builder)
    {
        builder.ToTable("PurviewPolicyProfiles");
        builder.HasKey(profile => profile.Id);
        builder.Property(profile => profile.DisplayName).HasMaxLength(200).IsRequired();
        builder.Property(profile => profile.Template).HasMaxLength(64).IsRequired();
        builder.Property(profile => profile.Mode).HasMaxLength(32).IsRequired();
        builder.Property(profile => profile.Status).HasMaxLength(32).IsRequired();
        builder.Property(profile => profile.CollectionPolicyName).HasMaxLength(200).IsRequired();
        builder.Property(profile => profile.DlpPolicyName).HasMaxLength(200).IsRequired();
        builder.Property(profile => profile.DlpRuleName).HasMaxLength(200).IsRequired();
        builder.Property(profile => profile.CollectionPolicyId).HasMaxLength(256);
        builder.Property(profile => profile.DlpPolicyId).HasMaxLength(256);
        builder.Property(profile => profile.DlpRuleId).HasMaxLength(256);
        builder.Property(profile => profile.BlueprintApplicationIdsJson).HasMaxLength(8000).IsRequired();
        builder.Property(profile => profile.LastErrorCode).HasMaxLength(64);
        builder.Property(profile => profile.RowVersion).IsRowVersion();
        builder.HasIndex(profile => profile.DisplayName).IsUnique();
        builder.HasIndex(profile => profile.Status);
    }
}
