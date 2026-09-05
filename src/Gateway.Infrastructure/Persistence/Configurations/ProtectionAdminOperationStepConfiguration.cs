using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class ProtectionAdminOperationStepConfiguration
    : IEntityTypeConfiguration<ProtectionAdminOperationStep>
{
    public void Configure(EntityTypeBuilder<ProtectionAdminOperationStep> builder)
    {
        builder.ToTable(
            "ProtectionAdminOperationSteps",
            table =>
            {
                table.HasCheckConstraint(
                    "CK_ProtectionAdminOperationSteps_OrderIndex",
                    "[OrderIndex] >= 0");
                table.HasCheckConstraint(
                    "CK_ProtectionAdminOperationSteps_AttemptCount",
                    "[AttemptCount] >= 0");
            });
        builder.HasKey(step => step.Id);

        builder.Property(step => step.StepType)
            .HasConversion<string>()
            .HasMaxLength(40)
            .IsRequired();
        builder.Property(step => step.Status)
            .HasConversion<string>()
            .HasMaxLength(40)
            .IsRequired();
        builder.Property(step => step.RetryDisposition)
            .HasConversion<string>()
            .HasMaxLength(40)
            .IsRequired();
        builder.Property(step => step.FailureCode).HasMaxLength(64);

        builder.HasIndex(step => new
        {
            step.ProtectionAdminOperationId,
            step.OrderIndex,
        }).IsUnique();
        builder.HasIndex(step => new
        {
            step.Status,
            step.NextAttemptAtUtc,
        }).HasFilter(
            "[Status] IN (N'Pending', N'Running', N'PendingPropagation')");
    }
}
