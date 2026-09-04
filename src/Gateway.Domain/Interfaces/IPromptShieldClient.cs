using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IPromptShieldClient
{
    bool IsEnabled { get; }
    TimeSpan ReceiptLifetime { get; }
    Task<PromptShieldEvaluationResult> EvaluateAsync(
        string prompt,
        PromptShieldSubject subject,
        CancellationToken cancellationToken);
}
