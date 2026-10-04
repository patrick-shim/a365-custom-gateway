using Gateway.Domain.Entities;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class SystemConfigurationMutationConfiguration : IEntityTypeConfiguration<SystemConfigurationMutation>
{
    public void Configure(EntityTypeBuilder<SystemConfigurationMutation> builder)
    {
        builder.ToTable("SystemConfigurationMutations");
        builder.HasKey(x => x.Id);
        builder.Property(x => x.TenantId).HasConversion(x => x.Value, x => new EntraTenantId(x));
        builder.Property(x => x.IdempotencyKey).HasConversion(x => x.Value, x => new ProtectionIdempotencyKey(x));
        builder.Property(x => x.ActorObjectId).HasMaxLength(64).IsRequired();
        builder.Property(x => x.AcceptedRequestHash).HasMaxLength(71).IsRequired();
        builder.Property(x => x.ResultJson).HasMaxLength(4000);
        builder.HasIndex(x => new { x.TenantId, x.IdempotencyKey }).IsUnique();
        builder.HasOne<SystemConfiguration>().WithMany().HasForeignKey(x => x.ConfigurationId).OnDelete(DeleteBehavior.Restrict);
    }
}
