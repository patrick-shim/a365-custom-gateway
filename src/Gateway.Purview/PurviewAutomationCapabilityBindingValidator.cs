using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;

namespace Gateway.Purview;

public sealed record PurviewAutomationCapabilityBinding(
    ApplicationClientId ApplicationId,
    ServicePrincipalObjectId ServicePrincipalObjectId,
    string KeyVaultResourceId,
    string KeyVaultHost,
    string CertificateName,
    Uri CertificateSecretUri);

public static class PurviewAutomationCapabilityBindingValidator
{
    private const string VaultHostSuffix = ".vault.azure.net";
    private const int MaximumResourceIdLength = 2048;

    public static PurviewAutomationCapabilityBinding Bind(
        ProtectionCapabilityResourceIdentifiers capability,
        PurviewOptions options)
    {
        ArgumentNullException.ThrowIfNull(capability);
        ArgumentNullException.ThrowIfNull(options);

        if (capability.PurviewAutomationApplicationId is not { } applicationId ||
            capability.PurviewAutomationServicePrincipalObjectId is not { } servicePrincipalId ||
            string.IsNullOrWhiteSpace(capability.KeyVaultResourceId) ||
            string.IsNullOrWhiteSpace(capability.CertificateName))
        {
            throw Failure(
                "PURVIEW_AUTOMATION_CAPABILITY_BINDING_INCOMPLETE",
                "The bootstrap-attested Purview automation capability binding is incomplete.");
        }

        if (!Guid.TryParse(options.PolicyProvisioningApplicationId, out var configuredApplicationId) ||
            configuredApplicationId == Guid.Empty ||
            !string.Equals(
                options.PolicyProvisioningApplicationId,
                configuredApplicationId.ToString("D"),
                StringComparison.Ordinal) ||
            configuredApplicationId != applicationId.Value)
        {
            throw Failure(
                "PURVIEW_AUTOMATION_APPLICATION_MISMATCH",
                "The configured Purview automation application does not match bootstrap capability facts.");
        }

        var vaultName = ParseKeyVaultResourceId(capability.KeyVaultResourceId);
        var expectedHost = $"{vaultName}{VaultHostSuffix}";
        var certificateName = ParseCertificateName(capability.CertificateName);
        var secretUri = ParseVersionlessCertificateSecretUri(
            options.PolicyProvisioningCertificateSecretUri);
        if (!string.Equals(secretUri.Host, expectedHost, StringComparison.OrdinalIgnoreCase))
        {
            throw Failure(
                "PURVIEW_AUTOMATION_KEY_VAULT_MISMATCH",
                "The Purview certificate reference does not match the bootstrap-attested Key Vault.");
        }

        var referencedCertificate = secretUri.AbsolutePath
            .Split('/', StringSplitOptions.RemoveEmptyEntries)[1];
        if (!string.Equals(
                referencedCertificate,
                certificateName,
                StringComparison.Ordinal))
        {
            throw Failure(
                "PURVIEW_AUTOMATION_CERTIFICATE_MISMATCH",
                "The Purview certificate reference does not match bootstrap capability facts.");
        }

        return new PurviewAutomationCapabilityBinding(
            applicationId,
            servicePrincipalId,
            capability.KeyVaultResourceId,
            expectedHost,
            certificateName,
            secretUri);
    }

    public static Uri ParseVersionlessCertificateSecretUri(string? value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) ||
            !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            !uri.IsDefaultPort ||
            !uri.Host.EndsWith(VaultHostSuffix, StringComparison.OrdinalIgnoreCase) ||
            uri.Host[..^VaultHostSuffix.Length].Length is < 3 or > 24 ||
            uri.Host[..^VaultHostSuffix.Length].Any(character =>
                !char.IsAsciiLetterOrDigit(character) && character != '-') ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries) is not
                ["secrets", var secretName] ||
            !IsResourceName(secretName, 127) ||
            !string.Equals(
                uri.AbsolutePath,
                $"/secrets/{secretName}",
                StringComparison.Ordinal) ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment))
        {
            throw Failure(
                "PURVIEW_SETTINGS_CERTIFICATE_URI_INVALID",
                "The Purview certificate reference is not an approved versionless Key Vault secret URI.");
        }

        return uri;
    }

    private static string ParseKeyVaultResourceId(string value)
    {
        if (value.Length > MaximumResourceIdLength ||
            !value.StartsWith("/", StringComparison.Ordinal) ||
            value.EndsWith("/", StringComparison.Ordinal) ||
            value.Contains('%') ||
            value.Any(character => character <= '\u001f' || character == '\u007f'))
        {
            throw InvalidKeyVaultResource();
        }

        var segments = value.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments is not
            [
                "subscriptions",
                var subscriptionId,
                "resourceGroups",
                var resourceGroupName,
                "providers",
                "Microsoft.KeyVault",
                "vaults",
                var vaultName
            ] ||
            !Guid.TryParse(subscriptionId, out var parsedSubscriptionId) ||
            parsedSubscriptionId == Guid.Empty ||
            !string.Equals(
                subscriptionId,
                parsedSubscriptionId.ToString("D"),
                StringComparison.Ordinal) ||
            !IsBoundedResourceGroupName(resourceGroupName) ||
            !IsResourceName(vaultName, 24) ||
            vaultName.Length < 3)
        {
            throw InvalidKeyVaultResource();
        }

        return vaultName;
    }

    private static string ParseCertificateName(string value)
    {
        if (!IsResourceName(value, 127))
        {
            throw Failure(
                "PURVIEW_AUTOMATION_CERTIFICATE_NAME_INVALID",
                "The bootstrap-attested Purview certificate name is invalid.");
        }

        return value;
    }

    private static bool IsBoundedResourceGroupName(string value) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= 90 &&
        !value.EndsWith(".", StringComparison.Ordinal) &&
        value.All(character =>
            char.IsAsciiLetterOrDigit(character) ||
            character is '-' or '_' or '.' or '(' or ')');

    private static bool IsResourceName(string value, int maximumLength) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= maximumLength &&
        value.All(character =>
            char.IsAsciiLetterOrDigit(character) || character == '-');

    private static PurviewPolicyException InvalidKeyVaultResource() =>
        Failure(
            "PURVIEW_AUTOMATION_KEY_VAULT_RESOURCE_INVALID",
            "The bootstrap-attested Purview Key Vault resource identifier is invalid.");

    private static PurviewPolicyException Failure(string code, string message) =>
        new(code, message);
}
