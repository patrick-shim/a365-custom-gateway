using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public interface IOutboxRepository
{
    Task AddAsync(OutboxMessage message, CancellationToken ct);
    Task<List<OutboxMessage>> GetPendingAsync(int batchSize, CancellationToken ct);
    Task<IReadOnlyList<OutboxMessage>> ClaimPendingAsync(
        int batchSize,
        DateTime utcNow,
        DateTime claimExpiresAtUtc,
        CancellationToken ct);
    Task<bool> MarkPublishedAsync(
        Guid id,
        DateTime claimExpiresAtUtc,
        DateTime publishedAtUtc,
        CancellationToken ct);
    Task<bool> MarkFailedAsync(
        Guid id,
        DateTime claimExpiresAtUtc,
        DateTime? nextRetryAtUtc,
        bool terminal,
        CancellationToken ct);
}
