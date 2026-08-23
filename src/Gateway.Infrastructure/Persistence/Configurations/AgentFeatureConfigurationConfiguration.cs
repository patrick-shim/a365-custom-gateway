using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class AgentFeatureConfigurationConfiguration : IEntityTypeConfiguration<AgentFeatureConfiguration>
{
    public void Configure(EntityTypeBuilder<AgentFeatureConfiguration> builder)
    {
        builder.ToTable("AgentFeatureConfigurations");

        builder.HasKey(e => e.Id);

        builder.Property(e => e.ObservabilityMode).HasConversion<string>().HasMaxLength(20);
        builder.Property(e => e.PurviewMode).HasConversion<string>().HasMaxLength(20);
    }
}
