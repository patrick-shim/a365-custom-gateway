using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Models;

/// <summary>
/// Explicitly named, non-secret identifiers read back for installed capabilities.
/// Unrelated Entra object types remain represented by distinct value-object types.
/// </summary>
public sealed record ProtectionCapabilityResourceIdentifiers(
    ApplicationClientId? Agent365RegistryApiApplicationId = null,
    string? ContentSafetyAccountResourceId = null,
    string? ContentSafetyEndpoint = null,
    ServicePrincipalObjectId? GatewayApiManagedIdentityPrincipalObjectId = null,
    ServicePrincipalObjectId? PurviewRuntimeManagedIdentityPrincipalObjectId = null,
    ApplicationClientId? PurviewAutomationApplicationId = null,
    ServicePrincipalObjectId? PurviewAutomationServicePrincipalObjectId = null,
    string? KeyVaultResourceId = null,
    string? CertificateName = null,
    Guid? BootstrapDeploymentOwnershipId = null,
    string? BootstrapSourceFingerprint = null,
    string? KeyVaultHost = null,
    string? CertificateSecretUri = null);
