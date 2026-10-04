namespace Gateway.Domain.Models;

/// <summary>
/// Resumable provisioning identifiers and verified milestones.
/// Credential material must never be placed in this object.
/// </summary>
public sealed record Agent365ProvisioningState
{
    public string? BlueprintObjectId { get; init; }
    public string? BlueprintClientId { get; init; }
    public string? BlueprintPrincipalObjectId { get; init; }
    public string? AgentIdentityObjectId { get; init; }
    public string? AgentIdentityClientId { get; init; }
    public string? ObservabilityAppRoleAssignmentId { get; init; }
    public string? GatewayWorkloadPrincipalId { get; init; }
    public string? GatewayFederatedCredentialId { get; init; }
    public string? PlannedAgent365RegistrationId { get; init; }
    public string? Agent365RegistrationId { get; init; }
    public string? RegistryProvider { get; init; }
    public string? RegistryAuthenticationMode { get; init; }
    public string? RegistryCreatedByObjectId { get; init; }
    public DateTimeOffset? Agent365RegistrationAcceptedAtUtc { get; init; }
    public DateTimeOffset? Agent365ConnectionVerifiedAtUtc { get; init; }
}
