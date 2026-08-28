using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class AgentIngressCredentialConfiguration
    : IEntityTypeConfiguration<AgentIngressCredential>
{
    public void Configure(EntityTypeBuilder<AgentIngressCredential> builder)
    {
        builder.ToTable("AgentIngressCredentials");

        builder.HasKey(item => item.Id);
        builder.Property(item => item.FormatVersion).IsRequired();
        builder.Property(item => item.HashAlgorithm).HasMaxLength(32).IsRequired();
        builder.Property(item => item.SecretSalt).HasMaxLength(64).IsRequired();
        builder.Property(item => item.SecretHash).HasMaxLength(64).IsRequired();
        builder.Property(item => item.CreatedByObjectId).HasMaxLength(64).IsRequired();
        builder.Property(item => item.ExpiresAtUtc).IsRequired();

        builder.HasIndex(item => item.AgentRegistrationId);
        builder.HasIndex(item => item.ExpiresAtUtc);

        builder.HasOne(item => item.AgentRegistration)
            .WithMany()
            .HasForeignKey(item => item.AgentRegistrationId)
            .OnDelete(DeleteBehavior.Cascade);
    }
}
