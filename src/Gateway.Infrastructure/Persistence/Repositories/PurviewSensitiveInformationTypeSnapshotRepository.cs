using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class PurviewSensitiveInformationTypeSnapshotRepository
    : IPurviewSensitiveInformationTypeSnapshotRepository
{
    private readonly GatewayDbContext _dbContext;

    public PurviewSensitiveInformationTypeSnapshotRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public Task<PurviewSensitiveInformationTypeSnapshotGeneration?> GetGenerationAsync(
        SensitiveInformationTypeSnapshotGenerationId generationId,
        CancellationToken ct) =>
        _dbContext.PurviewSensitiveInformationTypeSnapshotGenerations
            .Include(generation => generation.Items.OrderBy(item => item.SortOrder))
            .SingleOrDefaultAsync(generation => generation.Id == generationId, ct);

    public Task<PurviewSensitiveInformationTypeSnapshotGeneration?> GetCurrentGenerationAsync(
        EntraTenantId tenantId,
        DateTime utcNow,
        CancellationToken ct)
    {
        if (utcNow.Kind != DateTimeKind.Utc)
            throw new ArgumentException("The snapshot evaluation time must be UTC.", nameof(utcNow));

        return _dbContext.PurviewSensitiveInformationTypeSnapshotGenerations
            .Include(generation => generation.Items.OrderBy(item => item.SortOrder))
            .Where(generation =>
                generation.TenantId == tenantId &&
                generation.ExpiresAtUtc > utcNow &&
                _dbContext.PurviewTenantConnections.Any(connection =>
                    connection.TenantId == tenantId &&
                    connection.ActiveInventoryGenerationId == generation.Id))
            .OrderByDescending(generation => generation.RetrievedAtUtc)
            .ThenByDescending(generation => generation.CreatedAtUtc)
            .FirstOrDefaultAsync(ct);
    }

    public Task AddGenerationAsync(
        PurviewSensitiveInformationTypeSnapshotGeneration generation,
        CancellationToken ct) =>
        _dbContext.PurviewSensitiveInformationTypeSnapshotGenerations
            .AddAsync(generation, ct)
            .AsTask();
}
