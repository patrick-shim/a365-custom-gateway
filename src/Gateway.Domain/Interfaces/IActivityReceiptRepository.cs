using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public interface IActivityReceiptRepository
{
    Task AddAsync(ActivityReceipt receipt, CancellationToken ct);
    Task<bool> ExistsByExternalIdAsync(Guid agentRegistrationId, string externalActivityId, CancellationToken ct);
}
