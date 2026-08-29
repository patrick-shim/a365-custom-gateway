using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public interface IPurviewPolicyProfileRepository
{
    Task<IReadOnlyList<PurviewPolicyProfile>> ListReadyAsync(CancellationToken ct);
    Task<PurviewPolicyProfile?> GetByIdAsync(Guid id, CancellationToken ct);
    Task<bool> DisplayNameExistsAsync(string displayName, CancellationToken ct);
    Task AddAsync(PurviewPolicyProfile profile, CancellationToken ct);
}
