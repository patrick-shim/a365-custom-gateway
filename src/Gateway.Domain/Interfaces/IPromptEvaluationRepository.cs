using Gateway.Domain.Entities;
using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IPromptEvaluationRepository
{
    Task<PromptEvaluationRecord?> GetByIdAsync(Guid id, CancellationToken cancellationToken);
    Task<PromptProtectionContext?> GetProtectionContextAsync(Guid agentRegistrationId, CancellationToken cancellationToken);
    Task<bool> IsProtectionContextCurrentAsync(PromptProtectionContext context, CancellationToken cancellationToken);
    Task<bool> TryConsumeAsync(PromptEvaluationRecord receipt, PromptProtectionContext context, CancellationToken cancellationToken);
    Task AddAsync(PromptEvaluationRecord record, CancellationToken cancellationToken);
}
