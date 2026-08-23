using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence.Repositories;

internal sealed class ProvisioningJobRepository : IProvisioningJobRepository
{
    private readonly GatewayDbContext _dbContext;

    public ProvisioningJobRepository(GatewayDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<ProvisioningJob?> GetByIdAsync(Guid id, CancellationToken ct)
    {
        return await _dbContext.ProvisioningJobs
            .Include(j => j.Steps.OrderBy(s => s.OrderIndex))
            .FirstOrDefaultAsync(j => j.Id == id, ct);
    }

    public async Task<List<ProvisioningJob>> GetByAgentIdAsync(Guid agentRegistrationId, CancellationToken ct)
    {
        return await _dbContext.ProvisioningJobs
            .Include(j => j.Steps.OrderBy(s => s.OrderIndex))
            .Where(j => j.AgentRegistrationId == agentRegistrationId)
            .OrderByDescending(j => j.CreatedAtUtc)
            .ToListAsync(ct);
    }

    public async Task AddAsync(ProvisioningJob job, CancellationToken ct)
    {
        await _dbContext.ProvisioningJobs.AddAsync(job, ct);
    }
}
