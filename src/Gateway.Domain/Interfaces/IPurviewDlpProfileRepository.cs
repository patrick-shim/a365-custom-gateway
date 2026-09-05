using Gateway.Domain.Entities;
using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Interfaces;

public interface IPurviewDlpProfileRepository
{
    Task<IReadOnlyList<PurviewDlpProfile>> ListAsync(CancellationToken ct);
    Task<PurviewDlpProfile?> GetByIdAsync(
        PurviewDlpProfileId id,
        CancellationToken ct);
    Task<PurviewDlpProfile?> GetByBlueprintApplicationIdAsync(
        BlueprintApplicationId blueprintApplicationId,
        CancellationToken ct);
    Task AddAsync(PurviewDlpProfile profile, CancellationToken ct);
}
