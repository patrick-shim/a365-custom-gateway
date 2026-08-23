using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class IdempotencyRecordConfiguration : IEntityTypeConfiguration<IdempotencyRecord>
{
    public void Configure(EntityTypeBuilder<IdempotencyRecord> builder)
    {
        builder.ToTable("IdempotencyRecords");

        builder.HasKey(e => e.Id);

        builder.Property(e => e.IdempotencyKey).HasMaxLength(64).IsRequired();
        builder.Property(e => e.RequestBodyHash).HasMaxLength(64).IsRequired();
        builder.Property(e => e.Endpoint).HasMaxLength(256).IsRequired();

        builder.HasIndex(e => e.IdempotencyKey).IsUnique();
        builder.HasIndex(e => e.ExpiresAtUtc);
    }
}
