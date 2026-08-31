namespace Gateway.Api.Options;

public sealed class ProvisioningOptions
{
    public const string SectionName = "Provisioning";

    public bool ExecutionEnabled { get; init; }

    // Development-only deployments may keep the authenticated administrator
    // registration path continuously available. Deployment IaC constrains this
    // switch to the development environment.
    public bool AllowContinuousDevelopmentAccess { get; init; }
}
