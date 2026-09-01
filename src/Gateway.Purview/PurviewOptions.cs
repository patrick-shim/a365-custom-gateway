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
    public bool PolicyProvisioningEnabled { get; set; }
    public string? PolicyProvisioningOrganization { get; set; }
    public string? PolicyProvisioningApplicationId { get; set; }
    public string? PolicyProvisioningCertificateSecretUri { get; set; }
    public string PolicyProvisioningPowerShellPath { get; set; } = "pwsh";
    public int PolicyProvisioningTimeoutSeconds { get; set; } = 180;
    public string DefaultSensitiveInformationTypeId { get; set; } = string.Empty;
    public string DefaultSensitiveInformationType { get; set; } = string.Empty;
}

internal static class PurviewSensitiveInformationTypeContract
{
    public const int MaximumNameLength = 255;

    public static bool IsValidName(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > MaximumNameLength)
            return false;

        foreach (var character in value)
        {
            if (character <= '\u001f' || character == '\u007f')
                return false;
        }

        return true;
    }
}
