namespace Gateway.Contracts.Dtos;

public sealed record ProtectionOperationReviewSummaryDto(
    Guid TenantId,
    string OperationType,
    string TargetType,
    string TargetIdentifier,
    Guid? BlueprintApplicationId,
    Guid? SensitiveInformationTypeId,
    string? SensitiveInformationTypeName,
    string? Mode,
    IReadOnlyList<string> Activities,
    IReadOnlyList<PurviewDlpRuleActionDto> Actions,
    string ScopeType,
    string EnforcementPlane,
    string ReadinessDisclaimer,
    Guid? SourceOperationId = null,
    Guid? InventoryGenerationId = null,
    string? EvidenceDigest = null,
    string? PolicyMode = null,
    IReadOnlyList<PurviewSensitiveInformationTypeSelectionDto>? SensitiveInformationTypes = null,
    bool AffectsAllBlueprintAgents = false,
    PurviewDeferredBlueprintDto? DeferredBlueprint = null,
    bool ReplacesUnverifiedLegacyThresholds = false);
