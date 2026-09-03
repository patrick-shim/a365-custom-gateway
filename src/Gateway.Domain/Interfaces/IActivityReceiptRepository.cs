using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public interface IActivityReceiptRepository
{
    Task<ActivityReceipt?> GetByIdAsync(Guid id, CancellationToken ct);
    Task AddAsync(ActivityReceipt receipt, CancellationToken ct);
    Task<bool> ExistsByExternalIdAsync(Guid agentRegistrationId, string externalActivityId, CancellationToken ct);

    /// <summary>
    /// Latest receipt time per agent, for the agents that have any. Agents with no
    /// receipts are absent from the result rather than present with a default date.
    /// Batched so that listing agents stays one query instead of one per row.
    /// </summary>
    Task<IReadOnlyDictionary<Guid, DateTime>> GetLatestReceivedAtUtcAsync(
        IReadOnlyCollection<Guid> agentRegistrationIds,
        CancellationToken ct);
}
