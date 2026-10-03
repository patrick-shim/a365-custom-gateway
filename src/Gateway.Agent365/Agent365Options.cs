namespace Gateway.Agent365;

public sealed class Agent365Options
{
    public const string SectionName = "Agent365";
    public const string DirectRegistryPreviewProvider = "DirectRegistryPreview";
    public const string DelegatedAdministratorAuthenticationMode = "DelegatedAdministrator";
    public const string OfficialAgentXManagerApplicationId = "59eca866-2f46-40b8-96ff-63f663121ef9";

    public string TenantId { get; set; } = string.Empty;
    public string? ProvisioningManagedIdentityClientId { get; set; }
    public string? ProvisioningManagedIdentityPrincipalId { get; set; }

    /// <summary>
    /// Portable compose host: confidential-client secret for Graph application permissions.
    /// When set with <see cref="ProvisioningManagedIdentityClientId"/> (app client id) and
    /// <see cref="TenantId"/>, provisioning uses ClientSecretCredential instead of managed identity.
    /// </summary>
    public string? ProvisioningClientSecret { get; set; }

    /// <summary>
    /// Portable compose host: client secret on the Agent Identity blueprint used for local FMI
    /// token exchange (Microsoft's documented development path). Azure deployments leave this empty
    /// and use managed-identity federated credentials instead.
    /// </summary>
    public string? BlueprintClientSecret { get; set; }
    public string ObservabilityApplicationClientId { get; set; } =
        "9b975845-388f-4429-889e-eab1ef63949c";
    public string ObservabilityAppRoleValue { get; set; } =
        "Agent365.Observability.OtelWrite";
    public int ProvisioningHttpTimeoutSeconds { get; set; } = 30;
    public string RegistryOriginatingStore { get; set; } = "A365CustomGateway";
    public string RegistryManagerApplicationId { get; set; } = OfficialAgentXManagerApplicationId;
    public string[] ManagerApplicationIds { get; set; } = [];
    public string ObservabilityServerAddress { get; set; } = string.Empty;
    public int ObservabilityServerPort { get; set; } = 443;
    public int ObservabilityExportTimeoutSeconds { get; set; } = 30;
}
