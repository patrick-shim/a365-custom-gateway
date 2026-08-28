namespace Gateway.Api.Options;

public sealed class ProvisioningOptions
{
    public const string SectionName = "Provisioning";

    public bool ExecutionEnabled { get; init; }

    // Development-only deployments may keep the authenticated administrator
    // registration path continuously available. Deployment IaC constrains this
    // switch to the development environment.
    public bool AllowContinuousDevelopmentAccess { get; init; }

    // Development deployments require an exact identifier binding for every
    // bounded admission window. Tests may explicitly disable this requirement,
    // but the deployed Bicep contract always enables it.
    public bool RequireExactAdmissionBinding { get; init; } = true;

    public string? AuthorizedExternalAgentId { get; init; }

    public string? AuthorizedRetryAgentId { get; init; }

    // Keep the raw value so malformed deployment input closes admission instead of
    // failing options binding before the API can return the safe 503 contract.
    public string? AdmissionExpiresAtUtc { get; init; }
}
