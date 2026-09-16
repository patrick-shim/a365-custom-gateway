using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class IngressRateLimitBucket
{
    public byte ScopeType { get; set; }
    public Guid ScopeId { get; set; }
    public DateTime WindowStartUtc { get; set; }
    public int RequestCount { get; set; }
    public DateTime UpdatedAtUtc { get; set; }
}

internal sealed class IngressRateLimitBucketConfiguration : IEntityTypeConfiguration<IngressRateLimitBucket>
{
    public void Configure(EntityTypeBuilder<IngressRateLimitBucket> builder)
    {
        // The limiter uses atomic SQL, but its table must also be in the exact bootstrap model.
        builder.ToTable("IngressRateLimitBuckets", table =>
        {
            table.HasCheckConstraint("CK_IngressRateLimitBuckets_ScopeType", "[ScopeType] IN (0, 1, 2)");
            table.HasCheckConstraint("CK_IngressRateLimitBuckets_RequestCount", "[RequestCount] >= 0");
        });
        builder.HasKey(bucket => new { bucket.ScopeType, bucket.ScopeId });
        builder.Property(bucket => bucket.WindowStartUtc).HasPrecision(0);
        builder.Property(bucket => bucket.UpdatedAtUtc).HasPrecision(7);
    }
}
