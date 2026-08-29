namespace Gateway.Domain.Models;

/// <summary>
/// Safe, resumable provisioning state. It contains identifiers and a Key Vault
/// reference only; credential material must never be placed in this object.
/// </summary>
public sealed record Agent365ProvisioningState
{
    public string? ApplicationObjectId { get; init; }
    public string? ApplicationClientId { get; init; }
    public string? ServicePrincipalObjectId { get; init; }
    public string? AppRoleAssignmentId { get; init; }
    public string? PasswordCredentialKeyId { get; init; }
    public string? KeyVaultSecretUri { get; init; }
    public DateTimeOffset? CredentialExpiresAtUtc { get; init; }
    public string? BlueprintObjectId { get; init; }
    public string? BlueprintClientId { get; init; }
    public string? BlueprintPrincipalObjectId { get; init; }
    public string? AgentIdentityObjectId { get; init; }
    public string? AgentIdentityClientId { get; init; }
    public string? ObservabilityAppRoleAssignmentId { get; init; }
    public string? GatewayManagedIdentityPrincipalId { get; init; }
    public string? GatewayFederatedCredentialId { get; init; }
    public Guid? PurviewPolicyProfileId { get; init; }
    public string? PurviewCollectionPolicyId { get; init; }
    public string? PurviewDlpPolicyId { get; init; }
    public string? PurviewDlpRuleId { get; init; }
    public DateTimeOffset? PurviewPolicyAssignmentVerifiedAtUtc { get; init; }
    public string? PlannedAgent365RegistrationId { get; init; }
    public string? Agent365RegistrationId { get; init; }
    public string? RegistryProvider { get; init; }
    public string? RegistryAuthenticationMode { get; init; }
    public string? RegistryCreatedByObjectId { get; init; }
    public DateTimeOffset? Agent365RegistrationAcceptedAtUtc { get; init; }
    // Retained for serialized workflow compatibility. New workflow-v3
    // registrations use Agent365RegistrationAcceptedAtUtc because Microsoft
    // Graph's documented 201 response is the authoritative create boundary.
    public DateTimeOffset? Agent365RegistrationVerifiedAtUtc { get; init; }
    public DateTimeOffset? Agent365ConnectionVerifiedAtUtc { get; init; }
}
