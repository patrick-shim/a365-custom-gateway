using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class ProvisioningJobStepConfiguration : IEntityTypeConfiguration<ProvisioningJobStep>
{
    public void Configure(EntityTypeBuilder<ProvisioningJobStep> builder)
    {
        builder.ToTable("ProvisioningJobSteps");

        builder.HasKey(e => e.Id);

        builder.Property(e => e.StepType).HasConversion<string>().HasMaxLength(40);
        builder.Property(e => e.Status).HasConversion<string>().HasMaxLength(20);
        builder.Property(e => e.ResultData).HasMaxLength(4000);

        builder.HasIndex(e => new { e.ProvisioningJobId, e.OrderIndex });

        builder.HasOne(e => e.ProvisioningJob)
            .WithMany(e => e.Steps)
            .HasForeignKey(e => e.ProvisioningJobId)
            .OnDelete(DeleteBehavior.Cascade);
    }
}
