using Gateway.Domain.Entities;
using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Interfaces;

public interface IPurviewSensitiveInformationTypeSnapshotRepository
{
    Task<PurviewSensitiveInformationTypeSnapshotGeneration?> GetGenerationAsync(
        SensitiveInformationTypeSnapshotGenerationId generationId,
        CancellationToken ct);
    Task<PurviewSensitiveInformationTypeSnapshotGeneration?> GetCurrentGenerationAsync(
        EntraTenantId tenantId,
        DateTime utcNow,
        CancellationToken ct);
    Task AddGenerationAsync(
        PurviewSensitiveInformationTypeSnapshotGeneration generation,
        CancellationToken ct);
}
