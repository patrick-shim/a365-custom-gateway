namespace Gateway.ContentSafety;

public sealed class PromptShieldOptions
{
    public const string SectionName = "PromptShield";

    public bool Enabled { get; set; }
    public string Endpoint { get; set; } = string.Empty;
    public string ApiVersion { get; set; } = "2024-09-01";
    public int RequestTimeoutSeconds { get; set; } = 10;
    public int ReceiptLifetimeSeconds { get; set; } = 300;
    public string? ManagedIdentityClientId { get; set; }
}
