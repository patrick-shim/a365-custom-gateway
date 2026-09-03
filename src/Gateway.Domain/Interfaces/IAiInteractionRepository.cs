using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public interface IAiInteractionRepository
{
    Task<AiInteractionRecord?> GetByIdAsync(Guid id, CancellationToken ct);
    Task AddAsync(AiInteractionRecord record, CancellationToken ct);

    /// <summary>
    /// Latest interaction time per agent, for the agents that have any. Agents with
    /// no interactions are absent from the result rather than present with a default
    /// date. Batched so that listing agents stays one query instead of one per row.
    /// </summary>
    Task<IReadOnlyDictionary<Guid, DateTime>> GetLatestReceivedAtUtcAsync(
        IReadOnlyCollection<Guid> agentRegistrationIds,
        CancellationToken ct);
}
