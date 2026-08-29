namespace Gateway.Contracts.Responses;

public sealed record PromptEvaluationResultDto(
    Guid EvaluationId,
    Guid? EvaluationReceiptId,
    string InteractionId,
    bool Allowed,
    string Decision,
    string PromptShieldProcessing,
    string PurviewProcessing,
    DateTime? ExpiresAtUtc,
    string UserMessage,
    string CorrelationId);
