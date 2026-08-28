using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public interface IAiInteractionRepository
{
    Task<AiInteractionRecord?> GetByIdAsync(Guid id, CancellationToken ct);
    Task AddAsync(AiInteractionRecord record, CancellationToken ct);
}
