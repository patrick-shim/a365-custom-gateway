using Gateway.Domain.Entities;
using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IAgentRepository
{
    Task<AgentRegistration?> GetByIdAsync(Guid id, CancellationToken ct);
    Task<(List<AgentRegistration> Items, int TotalCount)> ListAsync(AgentListFilter filter, CancellationToken ct);
    Task AddAsync(AgentRegistration agent, CancellationToken ct);
    Task<bool> ExistsAsync(string externalAgentId, CancellationToken ct);
}
