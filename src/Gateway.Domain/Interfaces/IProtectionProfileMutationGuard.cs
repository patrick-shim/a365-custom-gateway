namespace Gateway.Domain.Interfaces;

public interface IProtectionProfileMutationGuard
{
    // Held through the outer registration/policy transaction, until the DI scope is disposed.
    Task HoldAsync(Guid profileId, CancellationToken cancellationToken);
}
