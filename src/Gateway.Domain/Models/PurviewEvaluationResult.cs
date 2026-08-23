using Gateway.Domain.Enums;

namespace Gateway.Domain.Models;

public sealed record PurviewEvaluationResult(
    bool IsAllowed,
    PurviewDecisionType Decision,
    string? PolicyAction,
    string? ProtectionScopeId);
