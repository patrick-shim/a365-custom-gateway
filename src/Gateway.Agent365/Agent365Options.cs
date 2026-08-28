namespace Gateway.Agent365;

public sealed class Agent365Options
{
    public const string SectionName = "Agent365";
    public const string DisabledRegistryProvider = "Disabled";
    public const string DirectRegistryPreviewProvider = "DirectRegistryPreview";
    public const string DelegatedAdministratorAuthenticationMode = "DelegatedAdministrator";
    public const string OfficialAgentXManagerApplicationId = "59eca866-2f46-40b8-96ff-63f663121ef9";

    public string TenantId { get; set; } = string.Empty;
    public string? CliPath { get; set; }
    public bool UseGraphAgentRegistration { get; set; } = true;
    public bool UseCliProvisioningFallback { get; set; }
    public int CliTimeoutSeconds { get; set; } = 300;
    public string RegistryProvider { get; set; } = DisabledRegistryProvider;
    public bool DirectRegistryPreviewEnabled { get; set; }
    public string? ProvisioningManagedIdentityClientId { get; set; }
    public string? ProvisioningManagedIdentityPrincipalId { get; set; }
    public string GatewayApiApplicationClientId { get; set; } = string.Empty;
    public string GatewayApiAudience { get; set; } = string.Empty;
    public string GatewayApiBaseUrl { get; set; } = string.Empty;
    public string ExternalAgentAppRoleValue { get; set; } = "ExternalAgent";
    public string ObservabilityApplicationClientId { get; set; } =
        "9b975845-388f-4429-889e-eab1ef63949c";
    public string ObservabilityAppRoleValue { get; set; } =
        "Agent365.Observability.OtelWrite";
    public string CredentialKeyVaultUri { get; set; } = string.Empty;
    public int ApplicationPasswordLifetimeDays { get; set; } = 180;
    public int ProvisioningHttpTimeoutSeconds { get; set; } = 30;
    public string RegistryOriginatingStore { get; set; } = "A365CustomGateway";
    public string RegistryManagerApplicationId { get; set; } = OfficialAgentXManagerApplicationId;
    public string[] ManagerApplicationIds { get; set; } = [];
    public string ObservabilityServerAddress { get; set; } = string.Empty;
    public int ObservabilityServerPort { get; set; } = 443;
    public int ObservabilityExportTimeoutSeconds { get; set; } = 30;
}
