using System.Text.Json.Serialization;

namespace Gateway.Setup.Models;

internal sealed record BootstrapConfiguration
{
    [JsonPropertyName("$schema")]
    public string Schema { get; init; } = "./config.schema.json";

    public required Guid SubscriptionId { get; init; }

    public required Guid TenantId { get; init; }

    public required string Environment { get; init; }

    public required string Location { get; init; }

    public required string ProjectName { get; init; }

    public required string ResourceGroupName { get; init; }

    public required string AlertEmail { get; init; }

    public required BootstrapSqlConfiguration Sql { get; init; }

    public required BootstrapAgent365Configuration Agent365 { get; init; }

    public required BootstrapPromptShieldConfiguration PromptShield { get; init; }

    public required BootstrapPurviewConfiguration Purview { get; init; }

    public static BootstrapConfiguration From(SetupConfigurationForm form) => new()
    {
        SubscriptionId = form.SubscriptionId,
        TenantId = form.TenantId,
        Environment = form.Environment,
        Location = form.Location,
        ProjectName = form.ProjectName,
        ResourceGroupName = form.ResourceGroupName,
        AlertEmail = form.AlertEmail,
        Sql = new BootstrapSqlConfiguration("Basic", "Basic"),
        Agent365 = new BootstrapAgent365Configuration(
            form.SeedBlueprintName,
            form.AllowDevelopmentRegistryPreview,
            form.GetReviewedManagerApplicationIds()),
        PromptShield = new BootstrapPromptShieldConfiguration(
            form.PromptShieldEnabled,
            form.PromptShieldSkuName),
        Purview = new BootstrapPurviewConfiguration(
            form.PurviewEnabled,
            false,
            form.PurviewCollectionPolicyName,
            form.PurviewDlpPolicyName,
            form.PurviewDlpRuleName,
            form.PurviewSensitiveInformationType.Trim(),
            false,
            string.Empty,
            string.Empty,
            string.Empty)
    };
}

internal sealed record BootstrapSqlConfiguration(string SkuName, string SkuTier);

internal sealed record BootstrapAgent365Configuration(
    string SeedBlueprintName,
    bool AllowDevelopmentRegistryPreview,
    Guid[] ReviewedManagerApplicationIds);

internal sealed record BootstrapPromptShieldConfiguration(bool Enabled, string SkuName);

internal sealed record BootstrapPurviewConfiguration(
    bool Enabled,
    bool ActivateGatewayAdapterAfterPolicyReadback,
    string CollectionPolicyName,
    string DlpPolicyName,
    string DlpRuleName,
    string SensitiveInformationType,
    bool PolicyProvisioningEnabled,
    string PolicyProvisioningOrganization,
    string PolicyProvisioningApplicationId,
    string PolicyProvisioningCertificateSecretUri);
