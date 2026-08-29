using Gateway.Domain.Enums;
using Microsoft.Extensions.Options;

namespace Gateway.Purview;

internal sealed class PurviewOptionsValidator : IValidateOptions<PurviewOptions>
{
    public ValidateOptionsResult Validate(string? name, PurviewOptions options)
    {
        if (options.ProtectionScopeCacheMinutes is < 1 or > 1440)
            return ValidateOptionsResult.Fail(
                "Purview:ProtectionScopeCacheMinutes must be between 1 and 1440.");

        if (options.RequestTimeoutSeconds is < 1 or > 120)
            return ValidateOptionsResult.Fail(
                "Purview:RequestTimeoutSeconds must be between 1 and 120.");

        if (!Enum.TryParse<PurviewMode>(options.DefaultMode, ignoreCase: false, out _))
            return ValidateOptionsResult.Fail(
                "Purview:DefaultMode must be AuditOnly or Enforce.");

        if (string.IsNullOrWhiteSpace(options.AppName) || options.AppName.Length > 256)
            return ValidateOptionsResult.Fail(
                "Purview:AppName must be between 1 and 256 characters.");

        if (string.IsNullOrWhiteSpace(options.AppVersion) || options.AppVersion.Length > 64)
            return ValidateOptionsResult.Fail(
                "Purview:AppVersion must be between 1 and 64 characters.");

        if (!string.IsNullOrWhiteSpace(options.ManagedIdentityClientId)
            && (!Guid.TryParse(options.ManagedIdentityClientId, out var clientId)
                || clientId == Guid.Empty))
        {
            return ValidateOptionsResult.Fail(
                "Purview:ManagedIdentityClientId must be a non-empty GUID when configured.");
        }

        if (options.PolicyProvisioningTimeoutSeconds is < 30 or > 900)
            return ValidateOptionsResult.Fail(
                "Purview:PolicyProvisioningTimeoutSeconds must be between 30 and 900.");

        if (options.PolicyProvisioningEnabled)
        {
            if (string.IsNullOrWhiteSpace(options.PolicyProvisioningOrganization) ||
                !options.PolicyProvisioningOrganization.Contains('.', StringComparison.Ordinal))
                return ValidateOptionsResult.Fail(
                    "Purview:PolicyProvisioningOrganization is required when policy provisioning is enabled.");

            if (!Guid.TryParse(options.PolicyProvisioningApplicationId, out var appId) || appId == Guid.Empty)
                return ValidateOptionsResult.Fail(
                    "Purview:PolicyProvisioningApplicationId must be a non-empty GUID when policy provisioning is enabled.");

            if (!Uri.TryCreate(options.PolicyProvisioningCertificateSecretUri, UriKind.Absolute, out var secretUri) ||
                !string.Equals(secretUri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
                !secretUri.IsDefaultPort ||
                !secretUri.Host.EndsWith(".vault.azure.net", StringComparison.OrdinalIgnoreCase) ||
                secretUri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries) is not ["secrets", _] ||
                !string.IsNullOrEmpty(secretUri.Query) ||
                !string.IsNullOrEmpty(secretUri.Fragment))
                return ValidateOptionsResult.Fail(
                    "Purview:PolicyProvisioningCertificateSecretUri must be a versionless HTTPS Azure Key Vault secret URI.");

            if (string.IsNullOrWhiteSpace(options.PolicyProvisioningPowerShellPath))
                return ValidateOptionsResult.Fail(
                    "Purview:PolicyProvisioningPowerShellPath is required when policy provisioning is enabled.");

            if (string.IsNullOrWhiteSpace(options.DefaultSensitiveInformationType) ||
                options.DefaultSensitiveInformationType.Length > 200)
                return ValidateOptionsResult.Fail(
                    "Purview:DefaultSensitiveInformationType must be between 1 and 200 characters.");
        }

        return ValidateOptionsResult.Success;
    }
}
