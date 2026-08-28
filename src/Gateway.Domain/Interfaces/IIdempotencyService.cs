using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public interface IIdempotencyService
{
    Task<IIdempotencyScopeLease> AcquireScopeAsync(
        Guid agentRegistrationId,
        string endpoint,
        string key,
        CancellationToken ct);

    Task<IdempotencyRecord?> GetAsync(
        Guid agentRegistrationId,
        string endpoint,
        string key,
        DateTime asOfUtc,
        CancellationToken ct);

    Task SaveAsync(IdempotencyRecord record, CancellationToken ct);
}

public interface IIdempotencyScopeLease : IAsyncDisposable
{
    Task CompleteAsync(CancellationToken ct);
}
