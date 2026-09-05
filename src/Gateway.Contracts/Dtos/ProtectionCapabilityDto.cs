namespace Gateway.Contracts.Dtos;

public sealed record ProtectionCapabilityResourceIdentifiersDto(
    Guid? Agent365RegistryApiApplicationId,
    string? ContentSafetyAccountResourceId,
    string? ContentSafetyEndpoint,
    Guid? GatewayApiManagedIdentityPrincipalObjectId,
    Guid? PurviewRuntimeManagedIdentityPrincipalObjectId,
    Guid? PurviewAutomationApplicationId,
    Guid? PurviewAutomationServicePrincipalObjectId,
    string? KeyVaultResourceId,
    string? CertificateName);

public sealed record ProtectionCapabilityDto(
    Guid Id,
    string Capability,
    string Status,
    ProtectionCapabilityResourceIdentifiersDto ResourceIdentifiers,
    DateTime? LastReadbackAtUtc,
    string? LastFailureCode,
    string RowVersion);
