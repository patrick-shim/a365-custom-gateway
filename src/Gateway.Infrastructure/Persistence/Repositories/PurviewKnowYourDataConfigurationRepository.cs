using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Gateway.Domain.ValueObjects;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class PurviewKnowYourDataConfigurationRepository
    : IPurviewKnowYourDataConfigurationRepository
{
    private readonly GatewayDbContext _dbContext;

    public PurviewKnowYourDataConfigurationRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public Task<PurviewKnowYourDataConfiguration?> GetByTenantIdAsync(
        EntraTenantId tenantId,
        CancellationToken ct) =>
        _dbContext.PurviewKnowYourDataConfigurations.SingleOrDefaultAsync(
            configuration => _dbContext.PurviewTenantConnections.Any(
                connection =>
                    connection.Id == configuration.PurviewTenantConnectionId &&
                    connection.TenantId == tenantId),
            ct);

    public Task AddAsync(
        PurviewKnowYourDataConfiguration configuration,
        CancellationToken ct) =>
        _dbContext.PurviewKnowYourDataConfigurations.AddAsync(configuration, ct).AsTask();
}
