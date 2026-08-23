namespace Gateway.Purview;

public sealed class PurviewOptions
{
    public const string SectionName = "Purview";

    public bool Enabled { get; set; }
    public string DefaultMode { get; set; } = "AuditOnly";
    public int ProtectionScopeCacheMinutes { get; set; } = 60;
}
