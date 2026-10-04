using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal sealed class AgentPolicyAssignmentConfiguration : IEntityTypeConfiguration<AgentPolicyAssignment>
{
    public void Configure(EntityTypeBuilder<AgentPolicyAssignment> b)
    {
        b.ToTable("AgentPolicyAssignments");
        b.HasKey(x => x.Id);
        b.HasOne<AgentRegistration>().WithMany().HasForeignKey(x => x.AgentRegistrationId)
            .OnDelete(DeleteBehavior.Restrict).HasConstraintName("FK_AgentPolicyAssignments_Registration");
        b.HasIndex(x => new { x.AgentRegistrationId, x.ConfirmedAtUtc });
        b.Property(x => x.PolicyName).HasMaxLength(256);
        b.Property(x => x.ReviewedRevision).HasMaxLength(64);
        b.Property(x => x.AssignedRevision).HasMaxLength(64);
        b.Property(x => x.ActorObjectId).HasMaxLength(36);
        b.Property(x => x.Status).HasMaxLength(24).IsConcurrencyToken();
        b.Property(x => x.FailureCode).HasMaxLength(128);
    }
}
