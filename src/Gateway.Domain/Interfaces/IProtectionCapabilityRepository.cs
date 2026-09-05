using Gateway.Domain.Entities;
using Gateway.Domain.Enums;

namespace Gateway.Domain.Interfaces;

public interface IProtectionCapabilityRepository
{
    Task<IReadOnlyList<ProtectionCapability>> ListAsync(CancellationToken ct);
    Task<ProtectionCapability?> GetByKindAsync(
        ProtectionCapabilityKind kind,
        CancellationToken ct);
    Task AddAsync(ProtectionCapability capability, CancellationToken ct);
}
