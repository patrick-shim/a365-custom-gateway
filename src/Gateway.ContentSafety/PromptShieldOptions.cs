namespace Gateway.ContentSafety;

public sealed class PromptShieldOptions
{
    public const string SectionName = "PromptShield";
    public const string AuthModeApiKey = "ApiKey";
    public const string AuthModeClientSecret = "ClientSecret";

    public bool Enabled { get; set; }
    public string Endpoint { get; set; } = string.Empty;
    public string ApiVersion { get; set; } = "2024-09-01";
    public int RequestTimeoutSeconds { get; set; } = 10;
    public int ReceiptLifetimeSeconds { get; set; } = 300;

    /// <summary>
    /// ApiKey or ClientSecret authentication.
    /// </summary>
    public string AuthMode { get; set; } = AuthModeClientSecret;

    /// <summary>
    /// Azure AI Content Safety subscription key used when AuthMode is ApiKey.
    /// </summary>
    public string? ApiKey { get; set; }

    /// <summary>
    /// Runtime workload app credentials when AuthMode is ClientSecret.
    /// </summary>
    public string? TenantId { get; set; }
    public string? ClientId { get; set; }
    public string? ClientSecret { get; set; }

    /// <summary>
    /// Optional service-principal object id used to validate token identity for ClientSecret mode.
    /// </summary>
    public string? ClientPrincipalId { get; set; }

    public bool UsesApiKey =>
        string.Equals(AuthMode, AuthModeApiKey, StringComparison.OrdinalIgnoreCase);

    public bool UsesClientSecret =>
        string.Equals(AuthMode, AuthModeClientSecret, StringComparison.OrdinalIgnoreCase);

}
