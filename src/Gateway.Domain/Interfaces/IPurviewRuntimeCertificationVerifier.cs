using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public sealed record PurviewRuntimeCertificationBinding(
    Guid CertificationOperationId,
    string ConfigurationFingerprint,
    Guid TestAgentRegistrationId,
    Guid TestAgentProtectionRevision,
    Guid RuntimePrincipalObjectId,
    DateTimeOffset ValidUntilUtc);

public interface IPurviewRuntimeCertificationVerifier
{
    Task<bool> IsCurrentAsync(PurviewDlpProfile profile, CancellationToken cancellationToken);

    // Read-only; uses the caller's database scope/transaction and never calls a provider.
    // Atomic consumers must protect all read dependencies, including the separate test agent.
    Task<PurviewRuntimeCertificationBinding?> GetCurrentBindingAsync(
        PurviewDlpProfile profile, CancellationToken cancellationToken);
}
