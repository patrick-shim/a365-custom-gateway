namespace Gateway.Contracts.Dtos;

public sealed record PurviewKnowYourDataConfigurationDto(
    Guid Id,
    Guid TenantConnectionId,
    Guid GroupId,
    string ScopeType,
    string EnforcementPlane,
    Guid InventoryGenerationId,
    Guid SensitiveInformationTypeId,
    string SensitiveInformationTypeName,
    string Mode,
    IReadOnlyList<string> Activities,
    bool IngestionEnabled,
    string Status,
    string ReadbackStatus,
    string? CollectionPolicyProviderId,
    DateTime? LastReadbackAtUtc,
    string? LastFailureCode,
    string RowVersion);
