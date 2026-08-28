namespace Gateway.Purview;

public sealed class PurviewOptions
{
    public const string SectionName = "Purview";

    public bool Enabled { get; set; }
    public string DefaultMode { get; set; } = "AuditOnly";
    public int ProtectionScopeCacheMinutes { get; set; } = 30;
    public int RequestTimeoutSeconds { get; set; } = 15;
    public string AppName { get; set; } = "A365 Gateway";
    public string AppVersion { get; set; } = "1.0";
    public string? ManagedIdentityClientId { get; set; }
}
