namespace Gateway.Domain.Interfaces;

public sealed record PurviewRuntimeRoleEvidence(
    bool Ready, DateTimeOffset ObservedAtUtc, DateTimeOffset? CredentialExpiresAtUtc);

public interface IPurviewRuntimeRoleVerifier
{
    Task<PurviewRuntimeRoleEvidence> VerifyAsync(Guid tenantId, CancellationToken cancellationToken);
}
