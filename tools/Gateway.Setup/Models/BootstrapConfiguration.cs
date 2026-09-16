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

    public string? CapabilityPreset { get; init; }

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
            form.RegistryBetaAcknowledged,
            form.GetReviewedManagerApplicationIds()),
        PromptShield = new BootstrapPromptShieldConfiguration(
            form.PromptShieldEnabled,
            form.PromptShieldSkuName,
            form.PromptShieldCostAndQuotaAcknowledged),
        Purview = new BootstrapPurviewConfiguration(
            form.PurviewEnabled,
            form.PurviewAuthorityRequirementsAcknowledged),
        CapabilityPreset = form.CapabilityPreset.ConfigurationValue()
    };
}

internal sealed record BootstrapSqlConfiguration(string SkuName, string SkuTier);

internal sealed record BootstrapAgent365Configuration(
    string SeedBlueprintName,
    bool AllowDevelopmentRegistryPreview,
    bool RegistryBetaAcknowledged,
    Guid[] ReviewedManagerApplicationIds);

internal sealed record BootstrapPromptShieldConfiguration(
    bool Enabled,
    string SkuName,
    bool CostAndQuotaAcknowledged);

internal sealed record BootstrapPurviewConfiguration(
    bool Enabled,
    bool AuthorityRequirementsAcknowledged,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? CollectionPolicyName = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? DlpPolicyName = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? DlpRuleName = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? SensitiveInformationTypeId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? SensitiveInformationType = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    bool? ActivateGatewayAdapterAfterPolicyReadback = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    bool? PolicyProvisioningEnabled = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? PolicyProvisioningOrganization = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? PolicyProvisioningApplicationId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? PolicyProvisioningCertificateSecretUri = null)
{
    [JsonIgnore]
    public bool HasLegacyPolicyConfiguration =>
        CollectionPolicyName is not null ||
        DlpPolicyName is not null ||
        DlpRuleName is not null ||
        SensitiveInformationTypeId is not null ||
        SensitiveInformationType is not null ||
        ActivateGatewayAdapterAfterPolicyReadback is not null ||
        PolicyProvisioningEnabled is not null ||
        PolicyProvisioningOrganization is not null ||
        PolicyProvisioningApplicationId is not null ||
        PolicyProvisioningCertificateSecretUri is not null;
}
