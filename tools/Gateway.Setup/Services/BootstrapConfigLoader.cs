using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Setup.Models;

namespace Gateway.Setup.Services;

internal enum ExistingConfigurationStatus
{
    Missing,
    Loaded,
    Rejected
}

internal sealed record ExistingConfigurationResult(
    ExistingConfigurationStatus Status,
    SetupConfigurationForm? Form,
    string? Guidance);

internal interface IBootstrapConfigLoader
{
    Task<ExistingConfigurationResult> LoadAsync(CancellationToken cancellationToken = default);
}

internal sealed class BootstrapConfigLoader(RepositoryLayout repository) : IBootstrapConfigLoader
{
    private const int MaximumConfigurationBytes = 64 * 1024;
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public async Task<ExistingConfigurationResult> LoadAsync(
        CancellationToken cancellationToken = default)
    {
        var path = Path.GetFullPath(repository.BootstrapConfigPath);
        var expected = Path.GetFullPath(Path.Combine(repository.RootPath, "bootstrap", "config.json"));
        if (!string.Equals(path, expected, PathComparison))
        {
            return Rejected("The existing configuration path is outside the canonical bootstrap directory.");
        }

        var file = new FileInfo(path);
        if (!file.Exists)
        {
            return new ExistingConfigurationResult(ExistingConfigurationStatus.Missing, null, null);
        }

        if (file.LinkTarget is not null)
        {
            return Rejected("bootstrap/config.json is a symbolic link. Setup will not follow or overwrite it.");
        }

        if (file.Length is <= 0 or > MaximumConfigurationBytes)
        {
            return Rejected("bootstrap/config.json is empty or exceeds the safe 64 KiB import limit.");
        }

        try
        {
            await using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                16 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            using var document = await JsonDocument.ParseAsync(
                stream,
                new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 12
                },
                cancellationToken);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return Rejected("The existing configuration does not contain a supported JSON object.");
            }

            var configuration = document.RootElement.Deserialize<BootstrapConfiguration>(SerializerOptions);
            if (configuration is null)
            {
                return Rejected("The existing configuration does not match the supported public schema.");
            }

            var form = MapSupportedConfiguration(configuration);
            var validationResults = new List<ValidationResult>();
            if (!Validator.TryValidateObject(
                    form,
                    new ValidationContext(form),
                    validationResults,
                    validateAllProperties: true))
            {
                return Rejected("The existing configuration failed safe public-field validation.");
            }

            return new ExistingConfigurationResult(ExistingConfigurationStatus.Loaded, form, null);
        }
        catch (Exception exception) when (
            exception is JsonException or IOException or UnauthorizedAccessException or ValidationException)
        {
            return Rejected(
                "Setup could not safely import bootstrap/config.json. It will not overwrite the file; review it and use the canonical terminal Resume path.");
        }
    }

    private static SetupConfigurationForm MapSupportedConfiguration(BootstrapConfiguration configuration)
    {
        if (!string.Equals(configuration.Schema, "./config.schema.json", StringComparison.Ordinal) ||
            configuration.SubscriptionId == Guid.Empty ||
            configuration.TenantId == Guid.Empty ||
            configuration.Sql is null ||
            !string.Equals(configuration.Sql.SkuName, "Basic", StringComparison.Ordinal) ||
            !string.Equals(configuration.Sql.SkuTier, "Basic", StringComparison.Ordinal) ||
            configuration.Agent365 is null ||
            configuration.Agent365.ReviewedManagerApplicationIds is null ||
            configuration.PromptShield is null ||
            configuration.Purview is null ||
            configuration.Purview.ActivateGatewayAdapterAfterPolicyReadback ||
            configuration.Purview.PolicyProvisioningEnabled ||
            configuration.Purview.PolicyProvisioningOrganization != string.Empty ||
            configuration.Purview.PolicyProvisioningApplicationId != string.Empty ||
            configuration.Purview.PolicyProvisioningCertificateSecretUri != string.Empty ||
            string.IsNullOrWhiteSpace(configuration.Purview.CollectionPolicyName) ||
            string.IsNullOrWhiteSpace(configuration.Purview.DlpPolicyName) ||
            string.IsNullOrWhiteSpace(configuration.Purview.DlpRuleName))
        {
            throw new ValidationException("Advanced or unsupported bootstrap configuration cannot be imported by Setup.");
        }

        var profile = configuration.Environment switch
        {
            "dev" => DeploymentProfile.QuickDevelopment,
            "staging" => DeploymentProfile.StagingFoundation,
            "prod" => DeploymentProfile.ProductionSafeFoundation,
            _ => throw new ValidationException("Unknown environment.")
        };

        return new SetupConfigurationForm
        {
            Profile = profile,
            SubscriptionId = configuration.SubscriptionId,
            TenantId = configuration.TenantId,
            Environment = configuration.Environment,
            Location = configuration.Location,
            ProjectName = configuration.ProjectName,
            ResourceGroupName = configuration.ResourceGroupName,
            AlertEmail = configuration.AlertEmail,
            SeedBlueprintName = configuration.Agent365.SeedBlueprintName,
            AllowDevelopmentRegistryPreview = configuration.Agent365.AllowDevelopmentRegistryPreview,
            ReviewedManagerApplicationIds = string.Join(
                Environment.NewLine,
                configuration.Agent365.ReviewedManagerApplicationIds
                    .OrderBy(id => id.ToString("D"), StringComparer.Ordinal)
                    .Select(id => id.ToString("D"))),
            PromptShieldEnabled = configuration.PromptShield.Enabled,
            PromptShieldSkuName = configuration.PromptShield.SkuName,
            PurviewEnabled = configuration.Purview.Enabled,
            PurviewSensitiveInformationTypeId = ParseSensitiveInformationTypeId(
                configuration.Purview.SensitiveInformationTypeId),
            PurviewSensitiveInformationType = configuration.Purview.SensitiveInformationType,
            PurviewCollectionPolicyName = configuration.Purview.CollectionPolicyName,
            PurviewDlpPolicyName = configuration.Purview.DlpPolicyName,
            PurviewDlpRuleName = configuration.Purview.DlpRuleName
        };
    }

    private static ExistingConfigurationResult Rejected(string guidance) => new(
        ExistingConfigurationStatus.Rejected,
        null,
        guidance);

    private static Guid ParseSensitiveInformationTypeId(string? value)
    {
        if (value == string.Empty)
        {
            return Guid.Empty;
        }

        if (value is null ||
            !Guid.TryParseExact(value, "D", out var id) ||
            id == Guid.Empty ||
            !string.Equals(value, id.ToString("D"), StringComparison.Ordinal))
        {
            throw new ValidationException(
                "The Purview sensitive information type ID is not an empty or canonical GUID value.");
        }

        return id;
    }

    private static StringComparison PathComparison =>
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
}
