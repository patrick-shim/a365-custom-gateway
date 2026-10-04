namespace Gateway.Agent365;

public sealed class Agent365Options
{
    public const string SectionName = "Agent365";
    public const string DirectRegistryPreviewProvider = "DirectRegistryPreview";
    public const string DelegatedAdministratorAuthenticationMode = "DelegatedAdministrator";
    public const string OfficialAgentXManagerApplicationId = "59eca866-2f46-40b8-96ff-63f663121ef9";

    public string TenantId { get; set; } = string.Empty;
    public string? ProvisioningClientId { get; set; }
    public string? ProvisioningPrincipalId { get; set; }

    /// <summary>
    /// Runtime compose host: confidential-client secret for Graph application permissions.
    /// When set with <see cref="ProvisioningClientId"/> (app client id) and
    /// <see cref="TenantId"/>, provisioning uses ClientSecretCredential.
    /// </summary>
    public string? ProvisioningClientSecret { get; set; }

    /// <summary>Local runtime credential directory, writable only by the provisioning worker.</summary>
    public string? RuntimeBlueprintCredentialDirectory { get; set; }
    /// <summary>Credentials keyed by blueprint application ID. Unmapped runtime blueprints use their individual local credential, never a different blueprint's fallback.</summary>
    public Dictionary<string, string> BlueprintClientSecrets { get; set; } = new(StringComparer.OrdinalIgnoreCase);
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
