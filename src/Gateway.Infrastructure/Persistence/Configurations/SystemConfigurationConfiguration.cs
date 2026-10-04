using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class SystemConfigurationConfiguration : IEntityTypeConfiguration<SystemConfiguration>
{
    private static readonly Guid SingletonId = new("7c9e6679-7425-40de-944b-e07fc1f90ae7");

    public void Configure(EntityTypeBuilder<SystemConfiguration> builder)
    {
        builder.ToTable("SystemConfigurations", t =>
            t.HasCheckConstraint("CK_SystemConfigurations_Singleton",
                $"\"Id\" = '{SingletonId}'"));

        builder.HasKey(e => e.Id);

        builder.Property(e => e.DefaultObservabilityMode).HasMaxLength(20);
        builder.Property(e => e.RowVersion).IsRowVersion();

        builder.HasData(new SystemConfiguration
        {
            Id = SingletonId,
            DefaultObservabilityMode = "Agent365",
            DefaultPromptShieldEnabled = false,
            RetentionDaysIdempotencyRecords = 7,
            RateLimitPerClient = 100,
            RateLimitPerAgent = 1000,
            RateLimitGlobal = 10000,
            UpdatedAtUtc = new DateTime(2024, 1, 1, 0, 0, 0, DateTimeKind.Utc)
        });
    }
}
