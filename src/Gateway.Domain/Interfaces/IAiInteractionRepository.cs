using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public interface IAiInteractionRepository
{
    Task AddAsync(AiInteractionRecord record, CancellationToken ct);
}
