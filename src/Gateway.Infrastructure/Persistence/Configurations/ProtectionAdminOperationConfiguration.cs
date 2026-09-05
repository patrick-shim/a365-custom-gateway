using Gateway.Domain.Entities;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.ChangeTracking;
using Microsoft.EntityFrameworkCore.Metadata;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class ProtectionAdminOperationConfiguration
    : IEntityTypeConfiguration<ProtectionAdminOperation>
{
    public void Configure(EntityTypeBuilder<ProtectionAdminOperation> builder)
    {
        builder.ToTable(
            "ProtectionAdminOperations",
            table =>
            {
                table.HasCheckConstraint(
                    "CK_ProtectionAdminOperations_Attempts",
                    "[AttemptCount] >= 0 AND [MaximumAttempts] > 0 AND [AttemptCount] <= [MaximumAttempts]");
                table.HasCheckConstraint(
                    "CK_ProtectionAdminOperations_WorkflowVersion",
                    $"[WorkflowVersion] = {ProtectionAdminWorkflow.CurrentVersion}");
            });
        builder.HasKey(operation => operation.Id);

        builder.Property(operation => operation.WorkflowVersion)
            .HasDefaultValue(ProtectionAdminWorkflow.CurrentVersion);
        builder.Property(operation => operation.Type)
            .HasConversion<string>()
            .HasMaxLength(48)
            .IsRequired();
        builder.Property(operation => operation.Status)
            .HasConversion<string>()
            .HasMaxLength(40)
            .IsRequired();
        builder.Property(operation => operation.TenantId)
            .HasConversion(
                value => value.Value,
                value => new EntraTenantId(value))
            .IsRequired();
        builder.Property(operation => operation.ActorObjectId).HasMaxLength(64).IsRequired();
        builder.Property(operation => operation.TargetType)
            .HasConversion<string>()
            .HasMaxLength(48)
            .IsRequired();
        builder.Property(operation => operation.TargetIdentifier)
            .HasMaxLength(256)
            .IsRequired();
        builder.Property(operation => operation.ReviewedPayloadHash)
            .HasMaxLength(71)
            .IsRequired();
        builder.Property(operation => operation.AcceptedRequestHash).HasMaxLength(71);
        builder.Property(operation => operation.ResultJson).HasMaxLength(4000);
        builder.Property(operation => operation.IdempotencyKey)
            .HasConversion(
                value => value.Value,
                value => new ProtectionIdempotencyKey(value))
            .IsRequired();
        builder.Property(operation => operation.ExpectedRowVersion)
            .HasMaxLength(8)
            .IsRequired();
        var confirmationVerifier = builder.Property(operation => operation.ConfirmationVerifier)
            .HasConversion(
                value => value == null
                    ? null
                    : ProtectionPersistenceSerialization.SerializeConfirmationVerifier(value),
                value => value == null
                    ? null
                    : ProtectionPersistenceSerialization.DeserializeConfirmationVerifier(value))
            .HasColumnName("ConfirmationVerifierJson")
            .HasMaxLength(2048);
        confirmationVerifier.Metadata.SetValueComparer(
            new ValueComparer<ProtectionConfirmationVerifier?>(
                (first, second) =>
                    ProtectionPersistenceSerialization.ConfirmationVerifiersEqual(first, second),
                value => value == null
                    ? 0
                    : ProtectionPersistenceSerialization.ConfirmationVerifierHashCode(value),
                value => value == null
                    ? null
                    : ProtectionPersistenceSerialization.CloneConfirmationVerifier(value)));
        builder.Property(operation => operation.RetryDisposition)
            .HasConversion<string>()
            .HasMaxLength(40)
            .IsRequired();
        builder.Property(operation => operation.LastFailureCode).HasMaxLength(64);
        builder.Property(operation => operation.RequiredAction).HasMaxLength(512);
        builder.Property(operation => operation.RowVersion).IsRowVersion();
        builder.Ignore(operation => operation.OrderedSteps);

        builder.HasIndex(operation => new
        {
            operation.TenantId,
            operation.IdempotencyKey,
        }).IsUnique();
        builder.HasIndex(operation => operation.CorrelationId).IsUnique();
        builder.HasIndex(operation => new
        {
            operation.Status,
            operation.NextAttemptAtUtc,
        }).HasFilter(
            "[Status] IN (N'Pending', N'Running', N'PendingPropagation')");

        builder.HasMany<ProtectionAdminOperationStep>("_steps")
            .WithOne(step => step.Operation)
            .HasForeignKey(step => step.ProtectionAdminOperationId)
            .OnDelete(DeleteBehavior.Cascade);
        builder.Navigation("_steps").UsePropertyAccessMode(PropertyAccessMode.Field);
    }
}
