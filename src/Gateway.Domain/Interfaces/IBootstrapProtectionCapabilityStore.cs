using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IBootstrapProtectionCapabilityStore
{
    Task SynchronizeAsync(
        BootstrapProtectionCapabilityAttestation attestation,
        DateTime utcNow,
        CancellationToken cancellationToken);
}
