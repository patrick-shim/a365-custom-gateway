namespace Gateway.Contracts.Dtos;

public sealed record PurviewDlpRuleActionDto(
    string Activity,
    string Action);

public sealed record PurviewDlpProfileSelectionDto(
    Guid ProfileId,
    Guid BlueprintApplicationId,
    string? ExpectedProfileRowVersion = null);

public sealed record PurviewDlpProfileDto(
    Guid Id,
    Guid BlueprintApplicationId,
    string DisplayName,
    Guid SensitiveInformationTypeId,
    string SensitiveInformationTypeName,
    string Mode,
    IReadOnlyList<string> Activities,
    IReadOnlyList<PurviewDlpRuleActionDto> Actions,
    string Status,
    ProtectionReadinessDto Readiness,
    string? DlpPolicyProviderId,
    string? DlpRuleProviderId,
    DateTime? LastReadbackAtUtc,
    string RowVersion);
