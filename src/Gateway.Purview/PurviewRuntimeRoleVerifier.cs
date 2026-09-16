using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;

namespace Gateway.Purview;

internal sealed class PurviewRuntimeRoleVerifier(IPurviewTokenRoleAttestor attestor) : IPurviewRuntimeRoleVerifier
{
    public async Task<PurviewRuntimeRoleEvidence> VerifyAsync(Guid tenantId, CancellationToken cancellationToken)
    {
        var evidence = await attestor.AttestAsync(tenantId, cancellationToken);
        return new(evidence.Status == ProtectionTokenRoleStatus.Ready, evidence.ObservedAtUtc, evidence.CredentialExpiresAtUtc);
    }
}
