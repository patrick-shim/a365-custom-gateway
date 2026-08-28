using Gateway.Domain.Models;
using Gateway.Domain.Enums;

namespace Gateway.Domain.Interfaces;

public interface IPurviewPolicyClient
{
    bool IsEnabled { get; }
    PurviewMode DefaultMode { get; }

    Task<PurviewEvaluationResult> EvaluateInteractionAsync(PurviewInteraction interaction, CancellationToken ct);
}
