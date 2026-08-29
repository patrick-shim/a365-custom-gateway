using Gateway.Domain.Entities;

namespace Gateway.Domain.Interfaces;

public interface IPromptEvaluationRepository
{
    Task<PromptEvaluationRecord?> GetByIdAsync(Guid id, CancellationToken cancellationToken);
    Task<bool> TryConsumeAsync(Guid id, DateTime consumedAtUtc, CancellationToken cancellationToken);
    Task AddAsync(PromptEvaluationRecord record, CancellationToken cancellationToken);
}
