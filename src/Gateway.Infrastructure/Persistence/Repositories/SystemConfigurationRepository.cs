using Gateway.Application.Configuration;
using Gateway.Domain.Entities;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class SystemConfigurationRepository : ISystemConfigurationRepository
{
    private readonly GatewayDbContext _dbContext;

    public SystemConfigurationRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<SystemConfiguration?> GetAsync(CancellationToken ct)
    {
        return await _dbContext.SystemConfigurations.FirstOrDefaultAsync(ct);
    }
}
