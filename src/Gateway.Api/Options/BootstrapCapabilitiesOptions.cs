using System.Text.RegularExpressions;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Options;

public sealed class BootstrapCapabilitiesOptions
{
    public const string SectionName = "BootstrapCapabilities";

    public bool Enabled { get; set; }
    public string DeploymentOwnershipId { get; set; } = string.Empty;
    public string AcceptedSourceFingerprint { get; set; } = string.Empty;
    public DateTimeOffset AttestedAtUtc { get; set; }
    public BootstrapCapabilityFactOptions Agent365RegistrationBeta { get; set; } = new();
    public BootstrapCapabilityFactOptions PromptShields { get; set; } = new();
    public BootstrapCapabilityFactOptions Purview { get; set; } = new();
}

public sealed class BootstrapCapabilityFactOptions
{
    public string Status { get; set; } = string.Empty;
    public string Agent365RegistryApiApplicationId { get; set; } = string.Empty;
    public string ContentSafetyAccountResourceId { get; set; } = string.Empty;
    public string ContentSafetyEndpoint { get; set; } = string.Empty;
    public string GatewayApiManagedIdentityPrincipalObjectId { get; set; } = string.Empty;
    public string PurviewRuntimeManagedIdentityPrincipalObjectId { get; set; } = string.Empty;
    public string PurviewAutomationApplicationId { get; set; } = string.Empty;
    public string PurviewAutomationServicePrincipalObjectId { get; set; } = string.Empty;
    public string KeyVaultResourceId { get; set; } = string.Empty;
    public string KeyVaultHost { get; set; } = string.Empty;
    public string CertificateName { get; set; } = string.Empty;
    public string CertificateSecretUri { get; set; } = string.Empty;
}

public sealed partial class BootstrapCapabilitiesOptionsValidator
    : IValidateOptions<BootstrapCapabilitiesOptions>
{
    public ValidateOptionsResult Validate(
        string? name,
        BootstrapCapabilitiesOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (!options.Enabled)
        {
            return HasAnyConfiguredValue(options)
                ? ValidateOptionsResult.Fail(
                    "Disabled bootstrap capability attestation cannot contain partial facts.")
                : ValidateOptionsResult.Success;
        }

        if (!TryCanonicalGuid(options.DeploymentOwnershipId, out _) ||
            !FingerprintPattern().IsMatch(options.AcceptedSourceFingerprint) ||
            options.AttestedAtUtc == default ||
            options.AttestedAtUtc.Offset != TimeSpan.Zero ||
            !TryValidateFact(
                ProtectionCapabilityKind.Agent365RegistrationBeta,
                options.Agent365RegistrationBeta) ||
            !TryValidateFact(
                ProtectionCapabilityKind.PromptShields,
                options.PromptShields) ||
            !TryValidateFact(
                ProtectionCapabilityKind.Purview,
                options.Purview))
        {
            return ValidateOptionsResult.Fail(
                "Bootstrap capability attestation requires complete canonical ownership, source, timestamp, status, and kind-specific identifiers.");
        }

        var promptPrincipal =
            options.PromptShields.GatewayApiManagedIdentityPrincipalObjectId;
        var purviewPrincipal =
            options.Purview.GatewayApiManagedIdentityPrincipalObjectId;
        if (IsInstalled(options.PromptShields) &&
            IsInstalled(options.Purview) &&
            !string.Equals(
                promptPrincipal,
                purviewPrincipal,
                StringComparison.Ordinal))
        {
            return ValidateOptionsResult.Fail(
                "Prompt Shields and Purview must attest the same Gateway API managed identity.");
        }

        return ValidateOptionsResult.Success;
    }

    public static BootstrapProtectionCapabilityAttestation CreateAttestation(
        BootstrapCapabilitiesOptions options)
    {
        var validation = new BootstrapCapabilitiesOptionsValidator()
            .Validate(
                Microsoft.Extensions.Options.Options.DefaultName,
                options);
        if (validation.Failed)
        {
            throw new InvalidOperationException(
                validation.FailureMessage);
        }

        var ownershipId = Guid.ParseExact(
            options.DeploymentOwnershipId,
            "D");
        return new BootstrapProtectionCapabilityAttestation(
            ownershipId,
            options.AcceptedSourceFingerprint,
            options.AttestedAtUtc.UtcDateTime,
            [
                CreateFact(
                    ProtectionCapabilityKind.Agent365RegistrationBeta,
                    options.Agent365RegistrationBeta,
                    ownershipId,
                    options.AcceptedSourceFingerprint),
                CreateFact(
                    ProtectionCapabilityKind.PromptShields,
                    options.PromptShields,
                    ownershipId,
                    options.AcceptedSourceFingerprint),
                CreateFact(
                    ProtectionCapabilityKind.Purview,
                    options.Purview,
                    ownershipId,
                    options.AcceptedSourceFingerprint)
            ]);
    }

    private static BootstrapProtectionCapabilityFact CreateFact(
        ProtectionCapabilityKind kind,
        BootstrapCapabilityFactOptions options,
        Guid ownershipId,
        string sourceFingerprint)
    {
        var status = Enum.Parse<ProtectionCapabilityStatus>(
            options.Status,
            ignoreCase: false);
        if (status == ProtectionCapabilityStatus.NotInstalled)
        {
            return new BootstrapProtectionCapabilityFact(
                kind,
                status,
                new ProtectionCapabilityResourceIdentifiers(
                    BootstrapDeploymentOwnershipId: ownershipId,
                    BootstrapSourceFingerprint: sourceFingerprint));
        }

        return new BootstrapProtectionCapabilityFact(
            kind,
            status,
            new ProtectionCapabilityResourceIdentifiers(
                ParseApplicationId(options.Agent365RegistryApiApplicationId),
                NullIfEmpty(options.ContentSafetyAccountResourceId),
                NullIfEmpty(options.ContentSafetyEndpoint),
                ParseServicePrincipal(
                    options.GatewayApiManagedIdentityPrincipalObjectId),
                ParseServicePrincipal(
                    options.PurviewRuntimeManagedIdentityPrincipalObjectId),
                ParseApplicationId(options.PurviewAutomationApplicationId),
                ParseServicePrincipal(
                    options.PurviewAutomationServicePrincipalObjectId),
                NullIfEmpty(options.KeyVaultResourceId),
                NullIfEmpty(options.CertificateName),
                ownershipId,
                sourceFingerprint,
                NullIfEmpty(options.KeyVaultHost),
                NullIfEmpty(options.CertificateSecretUri)));
    }

    private static bool TryValidateFact(
        ProtectionCapabilityKind kind,
        BootstrapCapabilityFactOptions options)
    {
        if (options is null ||
            !Enum.TryParse<ProtectionCapabilityStatus>(
                options.Status,
                ignoreCase: false,
                out var status) ||
            !string.Equals(
                options.Status,
                status.ToString(),
                StringComparison.Ordinal) ||
            status is not ProtectionCapabilityStatus.Installed and
                not ProtectionCapabilityStatus.NotInstalled)
        {
            return false;
        }

        if (status == ProtectionCapabilityStatus.NotInstalled)
            return IdentifiersAreEmpty(options);

        return kind switch
        {
            ProtectionCapabilityKind.Agent365RegistrationBeta =>
                TryCanonicalGuid(
                    options.Agent365RegistryApiApplicationId,
                    out _) &&
                OnlyHas(
                    options,
                    nameof(options.Agent365RegistryApiApplicationId)),
            ProtectionCapabilityKind.PromptShields =>
                IsContentSafetyResourceId(
                    options.ContentSafetyAccountResourceId) &&
                IsCanonicalContentSafetyEndpoint(
                    options.ContentSafetyEndpoint,
                    options.ContentSafetyAccountResourceId) &&
                TryCanonicalGuid(
                    options.GatewayApiManagedIdentityPrincipalObjectId,
                    out _) &&
                OnlyHas(
                    options,
                    nameof(options.ContentSafetyAccountResourceId),
                    nameof(options.ContentSafetyEndpoint),
                    nameof(options.GatewayApiManagedIdentityPrincipalObjectId)),
            ProtectionCapabilityKind.Purview =>
                TryCanonicalGuid(
                    options.GatewayApiManagedIdentityPrincipalObjectId,
                    out _) &&
                TryCanonicalGuid(
                    options.PurviewRuntimeManagedIdentityPrincipalObjectId,
                    out _) &&
                TryCanonicalGuid(
                    options.PurviewAutomationApplicationId,
                    out _) &&
                TryCanonicalGuid(
                    options.PurviewAutomationServicePrincipalObjectId,
                    out _) &&
                IsKeyVaultResourceId(options.KeyVaultResourceId) &&
                CertificateNamePattern().IsMatch(options.CertificateName) &&
                IsCanonicalKeyVaultBinding(options) &&
                OnlyHas(
                    options,
                    nameof(options.GatewayApiManagedIdentityPrincipalObjectId),
                    nameof(options.PurviewRuntimeManagedIdentityPrincipalObjectId),
                    nameof(options.PurviewAutomationApplicationId),
                    nameof(options.PurviewAutomationServicePrincipalObjectId),
                    nameof(options.KeyVaultResourceId),
                    nameof(options.KeyVaultHost),
                    nameof(options.CertificateName),
                    nameof(options.CertificateSecretUri)),
            _ => false
        };
    }

    private static bool OnlyHas(
        BootstrapCapabilityFactOptions options,
        params string[] allowed)
    {
        var allowedNames = allowed.ToHashSet(StringComparer.Ordinal);
        return typeof(BootstrapCapabilityFactOptions)
            .GetProperties()
            .Where(property => property.Name != nameof(options.Status))
            .All(property =>
                allowedNames.Contains(property.Name) ==
                !string.IsNullOrEmpty((string?)property.GetValue(options)));
    }

    private static bool IdentifiersAreEmpty(
        BootstrapCapabilityFactOptions options) =>
        typeof(BootstrapCapabilityFactOptions)
            .GetProperties()
            .Where(property => property.Name != nameof(options.Status))
            .All(property =>
                string.IsNullOrEmpty(
                    (string?)property.GetValue(options)));

    private static bool HasAnyConfiguredValue(
        BootstrapCapabilitiesOptions options) =>
        !string.IsNullOrEmpty(options.DeploymentOwnershipId) ||
        !string.IsNullOrEmpty(options.AcceptedSourceFingerprint) ||
        options.AttestedAtUtc != default ||
        HasAnyFactValue(options.Agent365RegistrationBeta) ||
        HasAnyFactValue(options.PromptShields) ||
        HasAnyFactValue(options.Purview);

    private static bool HasAnyFactValue(
        BootstrapCapabilityFactOptions options) =>
        typeof(BootstrapCapabilityFactOptions)
            .GetProperties()
            .Any(property =>
                !string.IsNullOrEmpty(
                    (string?)property.GetValue(options)));

    private static bool IsInstalled(
        BootstrapCapabilityFactOptions options) =>
        string.Equals(
            options.Status,
            nameof(ProtectionCapabilityStatus.Installed),
            StringComparison.Ordinal);

    private static bool IsContentSafetyResourceId(string value) =>
        IsAzureResourceId(
            value,
            "Microsoft.CognitiveServices",
            "accounts");

    private static bool IsKeyVaultResourceId(string value) =>
        IsAzureResourceId(value, "Microsoft.KeyVault", "vaults");

    private static bool IsCanonicalKeyVaultBinding(
        BootstrapCapabilityFactOptions options)
    {
        if (!TryGetAzureResourceName(
                options.KeyVaultResourceId,
                out var vaultName) ||
            !string.Equals(
                options.KeyVaultHost,
                $"{vaultName}.vault.azure.net",
                StringComparison.Ordinal) ||
            !Uri.TryCreate(
                options.CertificateSecretUri,
                UriKind.Absolute,
                out var secretUri))
        {
            return false;
        }

        return string.Equals(
                secretUri.Scheme,
                Uri.UriSchemeHttps,
                StringComparison.Ordinal) &&
            secretUri.IsDefaultPort &&
            string.IsNullOrEmpty(secretUri.UserInfo) &&
            string.IsNullOrEmpty(secretUri.Query) &&
            string.IsNullOrEmpty(secretUri.Fragment) &&
            string.Equals(
                secretUri.Host,
                options.KeyVaultHost,
                StringComparison.Ordinal) &&
            string.Equals(
                secretUri.AbsolutePath,
                $"/secrets/{options.CertificateName}",
                StringComparison.Ordinal) &&
            string.Equals(
                secretUri.AbsoluteUri,
                options.CertificateSecretUri,
                StringComparison.Ordinal);
    }

    private static bool IsAzureResourceId(
        string value,
        string provider,
        string resourceType)
    {
        if (string.IsNullOrEmpty(value) ||
            value.Length > 512 ||
            value.Contains('%') ||
            value.Contains('\\') ||
            value.Any(character =>
                character <= '\u001f' || character == '\u007f'))
        {
            return false;
        }

        var segments = value.Split(
            '/',
            StringSplitOptions.RemoveEmptyEntries);
        return segments is
            [
                "subscriptions",
                var subscriptionId,
                "resourceGroups",
                var resourceGroup,
                "providers",
                var actualProvider,
                var actualResourceType,
                var resourceName
            ] &&
            TryCanonicalGuid(subscriptionId, out _) &&
            ResourceNamePattern().IsMatch(resourceGroup) &&
            string.Equals(
                actualProvider,
                provider,
                StringComparison.Ordinal) &&
            string.Equals(
                actualResourceType,
                resourceType,
                StringComparison.Ordinal) &&
            ResourceNamePattern().IsMatch(resourceName);
    }

    private static bool IsCanonicalHttpsEndpoint(string value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        string.Equals(
            uri.Scheme,
            Uri.UriSchemeHttps,
            StringComparison.Ordinal) &&
        uri.IsDefaultPort &&
        string.IsNullOrEmpty(uri.UserInfo) &&
        string.IsNullOrEmpty(uri.Query) &&
        string.IsNullOrEmpty(uri.Fragment) &&
        uri.AbsolutePath == "/" &&
        string.Equals(
            uri.AbsoluteUri,
            value,
            StringComparison.Ordinal);

    private static bool IsCanonicalContentSafetyEndpoint(
        string endpoint,
        string resourceId)
    {
        if (!IsCanonicalHttpsEndpoint(endpoint) ||
            !TryGetAzureResourceName(resourceId, out var accountName) ||
            !Uri.TryCreate(endpoint, UriKind.Absolute, out var uri))
        {
            return false;
        }

        return string.Equals(
                uri.Host,
                $"{accountName}.cognitiveservices.azure.com",
                StringComparison.Ordinal) ||
            string.Equals(
                uri.Host,
                $"{accountName}.services.ai.azure.com",
                StringComparison.Ordinal);
    }

    private static bool TryGetAzureResourceName(
        string resourceId,
        out string resourceName)
    {
        resourceName = string.Empty;
        var segments = resourceId.Split(
            '/',
            StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length != 8)
            return false;
        resourceName = segments[7];
        return true;
    }

    private static bool TryCanonicalGuid(
        string value,
        out Guid parsed) =>
        Guid.TryParseExact(value, "D", out parsed) &&
        parsed != Guid.Empty &&
        string.Equals(
            value,
            parsed.ToString("D"),
            StringComparison.Ordinal);

    private static ApplicationClientId? ParseApplicationId(string value) =>
        string.IsNullOrEmpty(value)
            ? null
            : new ApplicationClientId(Guid.ParseExact(value, "D"));

    private static ServicePrincipalObjectId? ParseServicePrincipal(
        string value) =>
        string.IsNullOrEmpty(value)
            ? null
            : new ServicePrincipalObjectId(Guid.ParseExact(value, "D"));

    private static string? NullIfEmpty(string value) =>
        string.IsNullOrEmpty(value) ? null : value;

    [GeneratedRegex("^sha256:[0-9a-f]{64}$", RegexOptions.CultureInvariant)]
    private static partial Regex FingerprintPattern();

    [GeneratedRegex(
        "^[A-Za-z0-9][A-Za-z0-9._()-]{0,127}$",
        RegexOptions.CultureInvariant)]
    private static partial Regex ResourceNamePattern();

    [GeneratedRegex(
        "^[A-Za-z0-9][A-Za-z0-9-]{0,126}$",
        RegexOptions.CultureInvariant)]
    private static partial Regex CertificateNamePattern();
}
