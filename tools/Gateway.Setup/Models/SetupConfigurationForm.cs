using System.ComponentModel.DataAnnotations;

namespace Gateway.Setup.Models;

internal sealed class SetupConfigurationForm : IValidatableObject
{
    public DeploymentProfile Profile { get; set; } = DeploymentProfile.QuickDevelopment;

    public Guid SubscriptionId { get; set; }

    public Guid TenantId { get; set; }

    [Required, RegularExpression("^(dev|staging|prod)$")]
    public string Environment { get; set; } = "dev";

    [Required, RegularExpression("^[a-z0-9]+$"), StringLength(32, MinimumLength = 2)]
    public string Location { get; set; } = "eastus2";

    [Required, RegularExpression("^[a-z][a-z0-9]{1,7}$")]
    public string ProjectName { get; set; } = "a365gw";

    [Required, StringLength(90), RegularExpression("^(?=.{1,90}$)[A-Za-z0-9._()\\-]*[A-Za-z0-9_()\\-]$")]
    public string ResourceGroupName { get; set; } = "rg-a365gw-dev";

    [Required, EmailAddress, StringLength(254)]
    public string AlertEmail { get; set; } = string.Empty;

    public bool AllowDevelopmentRegistryPreview { get; set; }

    [Required, StringLength(100, MinimumLength = 1)]
    public string SeedBlueprintName { get; set; } = "A365 Gateway a365gw dev";

    [Required, StringLength(500, MinimumLength = 36)]
    public string ReviewedManagerApplicationIds { get; set; } = string.Empty;

    public bool PromptShieldEnabled { get; set; }

    [Required, RegularExpression("^(F0|S0)$")]
    public string PromptShieldSkuName { get; set; } = "F0";

    public bool PurviewEnabled { get; set; }

    [Required(AllowEmptyStrings = true), StringLength(128)]
    public string PurviewSensitiveInformationType { get; set; } = string.Empty;

    [Required, StringLength(200, MinimumLength = 1)]
    public string PurviewCollectionPolicyName { get; set; } = "A365 Gateway a365gw AI collection";

    [Required, StringLength(200, MinimumLength = 1)]
    public string PurviewDlpPolicyName { get; set; } = "A365 Gateway a365gw inline DLP";

    [Required, StringLength(200, MinimumLength = 1)]
    public string PurviewDlpRuleName { get; set; } = "A365 Gateway a365gw inline DLP rule";

    public void ApplyProjectName(string projectName)
    {
        ProjectName = projectName;
        ResourceGroupName = $"rg-{ProjectName}-{Environment}";
        SeedBlueprintName = $"A365 Gateway {ProjectName} {Environment}";
        PurviewCollectionPolicyName = $"A365 Gateway {ProjectName} AI collection";
        PurviewDlpPolicyName = $"A365 Gateway {ProjectName} inline DLP";
        PurviewDlpRuleName = $"A365 Gateway {ProjectName} inline DLP rule";
    }

    public void ApplyProfile(DeploymentProfile profile)
    {
        Profile = profile;
        Environment = profile switch
        {
            DeploymentProfile.QuickDevelopment => "dev",
            DeploymentProfile.StagingFoundation => "staging",
            DeploymentProfile.ProductionSafeFoundation => "prod",
            _ => throw new ArgumentOutOfRangeException(nameof(profile), profile, null)
        };

        if (profile != DeploymentProfile.QuickDevelopment)
        {
            AllowDevelopmentRegistryPreview = false;
        }

        ResourceGroupName = $"rg-{ProjectName}-{Environment}";
        SeedBlueprintName = $"A365 Gateway {ProjectName} {Environment}";
    }

    public void SelectSubscription(AzureSubscription subscription)
    {
        SubscriptionId = subscription.SubscriptionId;
        TenantId = subscription.TenantId;
    }

    public void ClearSubscription()
    {
        SubscriptionId = Guid.Empty;
        TenantId = Guid.Empty;
    }

    public void SetReviewedManagerApplicationIds(IEnumerable<Guid> applicationIds)
    {
        ArgumentNullException.ThrowIfNull(applicationIds);
        var values = applicationIds
            .Where(id => id != Guid.Empty)
            .Distinct()
            .OrderBy(id => id.ToString("D"), StringComparer.Ordinal)
            .ToArray();
        if (values.Length is < 1 or > 10)
        {
            throw new ValidationException(
                "Agent 365 manager application discovery must produce one to ten unique non-empty application IDs.");
        }

        ReviewedManagerApplicationIds = string.Join(
            System.Environment.NewLine,
            values.Select(id => id.ToString("D")));
    }

    public void ClearReviewedManagerApplicationIds() => ReviewedManagerApplicationIds = string.Empty;

    public IEnumerable<ValidationResult> Validate(ValidationContext validationContext)
    {
        if (SubscriptionId == Guid.Empty)
        {
            yield return new ValidationResult(
                "Select an Azure subscription discovered from the current Azure CLI session.",
                [nameof(SubscriptionId)]);
        }

        if (TenantId == Guid.Empty)
        {
            yield return new ValidationResult(
                "The selected subscription must include a non-empty Microsoft Entra tenant ID.",
                [nameof(TenantId)]);
        }

        if (AllowDevelopmentRegistryPreview && !string.Equals(Environment, "dev", StringComparison.Ordinal))
        {
            yield return new ValidationResult(
                "The Agent 365 Registry preview can be enabled only for a development deployment.",
                [nameof(AllowDevelopmentRegistryPreview)]);
        }

        if (!TryParseReviewedManagerApplicationIds(ReviewedManagerApplicationIds, out _))
        {
            yield return new ValidationResult(
                "Enter one to ten unique, non-empty manager application GUIDs independently reviewed for this Agent 365 tenant/provider version.",
                [nameof(ReviewedManagerApplicationIds)]);
        }

        if (PurviewEnabled && string.IsNullOrWhiteSpace(PurviewSensitiveInformationType))
        {
            yield return new ValidationResult(
                "Enter the exact tenant-approved Purview sensitive information type.",
                [nameof(PurviewSensitiveInformationType)]);
        }

        if (!SafePublicValuePolicy.IsAllowed(SeedBlueprintName))
        {
            yield return new ValidationResult(
                "The seed blueprint name contains content that cannot be written to public bootstrap configuration.",
                [nameof(SeedBlueprintName)]);
        }

        if (!SafePublicValuePolicy.IsAllowed(PurviewSensitiveInformationType))
        {
            yield return new ValidationResult(
                "The Purview classifier name contains content that cannot be written to public bootstrap configuration.",
                [nameof(PurviewSensitiveInformationType)]);
        }
    }

    public Guid[] GetReviewedManagerApplicationIds()
    {
        if (!TryParseReviewedManagerApplicationIds(ReviewedManagerApplicationIds, out var values))
        {
            throw new ValidationException(
                "Reviewed Agent 365 manager application IDs are missing or invalid.");
        }

        return values;
    }

    private static bool TryParseReviewedManagerApplicationIds(string? value, out Guid[] values)
    {
        values = [];
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var parts = value.Split(
            [',', ';', ' ', '\t', '\r', '\n'],
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length is < 1 or > 10)
        {
            return false;
        }

        var parsed = new HashSet<Guid>();
        foreach (var part in parts)
        {
            if (!Guid.TryParse(part, out var id) || id == Guid.Empty || !parsed.Add(id))
            {
                return false;
            }
        }

        values = parsed
            .OrderBy(id => id.ToString("D"), StringComparer.Ordinal)
            .ToArray();
        return true;
    }
}
