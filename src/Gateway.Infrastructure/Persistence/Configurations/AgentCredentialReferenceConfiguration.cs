using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class AgentCredentialReferenceConfiguration : IEntityTypeConfiguration<AgentCredentialReference>
{
    public void Configure(EntityTypeBuilder<AgentCredentialReference> builder)
    {
        builder.ToTable("AgentCredentialReferences");

        builder.HasKey(e => e.Id);

        builder.Property(e => e.CredentialType).HasConversion<string>().HasMaxLength(20);
        builder.Property(e => e.KeyVaultSecretUri).HasMaxLength(512).IsRequired();
        builder.Property(e => e.CertificateThumbprint).HasMaxLength(128);
    }
}
