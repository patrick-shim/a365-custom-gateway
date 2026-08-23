using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IPurviewPolicyClient
{
    Task<PurviewEvaluationResult> EvaluateInteractionAsync(PurviewInteraction interaction, CancellationToken ct);
    Task SubmitAuditRecordAsync(PurviewAuditRecord record, CancellationToken ct);
}
