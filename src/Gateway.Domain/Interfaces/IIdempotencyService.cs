using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public interface IIdempotencyService
{
    Task<IdempotencyRecord?> GetAsync(string key, CancellationToken ct);
    Task SaveAsync(IdempotencyRecord record, CancellationToken ct);
}
