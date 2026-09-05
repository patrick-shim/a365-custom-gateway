using System.Buffers.Text;
using System.Globalization;
using System.Text.Json;
using Azure.Core;
using Gateway.Application.Protection;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Microsoft.Extensions.Configuration;

namespace Gateway.ContentSafety;

internal sealed class BootstrapPromptShieldRuntimeBinding
    : IBootstrapPromptShieldRuntimeBinding
{
    private const string RootSection = "BootstrapCapabilities";
    private const string CapabilitySection =
        $"{RootSection}:PromptShields";
    private const int MaximumTokenLength = 32 * 1024;
    private readonly IConfiguration _configuration;
    private readonly Func<PromptShieldOptions> _runtimeOptions;

    public BootstrapPromptShieldRuntimeBinding(
        IConfiguration configuration,
        Func<PromptShieldOptions> runtimeOptions)
    {
        _configuration = configuration;
        _runtimeOptions = runtimeOptions;
    }

    public bool IsExact(ProtectionCapability? capability)
    {
        if (!TryRead(out var attestation) ||
            capability is not
            {
                Kind: ProtectionCapabilityKind.PromptShields,
                Status: ProtectionCapabilityStatus.Installed,
                LastReadbackAtUtc: not null
            })
        {
            return false;
        }

        var runtime = _runtimeOptions();
        if (!runtime.Enabled ||
            !string.Equals(runtime.Endpoint, attestation.ContentSafetyEndpoint, StringComparison.Ordinal))
        {
            return false;
        }

        var identifiers = capability.ResourceIdentifiers;
        return capability.LastFailureCode is null &&
            capability.LastReadbackAtUtc == attestation.AttestedAtUtc &&
            string.Equals(
                identifiers.ContentSafetyAccountResourceId,
                attestation.ContentSafetyAccountResourceId,
                StringComparison.Ordinal) &&
            string.Equals(
                identifiers.ContentSafetyEndpoint,
                attestation.ContentSafetyEndpoint,
                StringComparison.Ordinal) &&
            identifiers.GatewayApiManagedIdentityPrincipalObjectId ==
                new ServicePrincipalObjectId(
                    attestation.GatewayApiManagedIdentityPrincipalObjectId) &&
            identifiers.BootstrapDeploymentOwnershipId ==
                attestation.DeploymentOwnershipId &&
            string.Equals(
                identifiers.BootstrapSourceFingerprint,
                attestation.SourceFingerprint,
                StringComparison.Ordinal) &&
            identifiers.Agent365RegistryApiApplicationId is null &&
            identifiers.PurviewRuntimeManagedIdentityPrincipalObjectId is null &&
            identifiers.PurviewAutomationApplicationId is null &&
            identifiers.PurviewAutomationServicePrincipalObjectId is null &&
            identifiers.KeyVaultResourceId is null &&
            identifiers.KeyVaultHost is null &&
            identifiers.CertificateName is null &&
            identifiers.CertificateSecretUri is null;
    }

    internal bool IsConfigurationExact(PromptShieldOptions options) =>
        TryRead(out var attestation) &&
        options.Enabled &&
        string.Equals(
            options.Endpoint,
            attestation.ContentSafetyEndpoint,
            StringComparison.Ordinal);

    internal void EnsureConfigurationExact(
        PromptShieldOptions options,
        Uri? httpBaseAddress = null)
    {
        if (!IsConfigurationExact(options) ||
            httpBaseAddress is not null &&
            !string.Equals(
                httpBaseAddress.AbsoluteUri,
                options.Endpoint,
                StringComparison.Ordinal))
        {
            throw BindingFailure();
        }
    }

    internal void EnsureTokenIdentity(AccessToken token)
    {
        if (!IsTokenIdentityExact(token))
            throw BindingFailure();
    }

    internal bool IsTokenIdentityExact(AccessToken token) =>
        TryRead(out var attestation) &&
        TryReadObjectId(token.Token, out var tokenObjectId) &&
        tokenObjectId == attestation.GatewayApiManagedIdentityPrincipalObjectId;

    private bool TryRead(out PromptShieldAttestation attestation)
    {
        attestation = default;
        if (!bool.TryParse(
                _configuration[$"{RootSection}:Enabled"],
                out var enabled) ||
            !enabled ||
            !string.Equals(
                _configuration[$"{CapabilitySection}:Status"],
                nameof(ProtectionCapabilityStatus.Installed),
                StringComparison.Ordinal) ||
            !TryCanonicalGuid(
                _configuration[$"{RootSection}:DeploymentOwnershipId"],
                out var deploymentOwnershipId) ||
            !TrySourceFingerprint(
                _configuration[$"{RootSection}:AcceptedSourceFingerprint"],
                out var sourceFingerprint) ||
            !DateTimeOffset.TryParse(
                _configuration[$"{RootSection}:AttestedAtUtc"],
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var attestedAt) ||
            attestedAt.Offset != TimeSpan.Zero ||
            !TryContentSafetyResourceId(
                _configuration[
                    $"{CapabilitySection}:ContentSafetyAccountResourceId"],
                out var contentSafetyResourceId,
                out var accountName) ||
            !TryContentSafetyEndpoint(
                _configuration[
                    $"{CapabilitySection}:ContentSafetyEndpoint"],
                accountName,
                out var contentSafetyEndpoint) ||
            !TryCanonicalGuid(
                _configuration[
                    $"{CapabilitySection}:GatewayApiManagedIdentityPrincipalObjectId"],
                out var gatewayApiPrincipalObjectId))
        {
            return false;
        }

        attestation = new PromptShieldAttestation(
            deploymentOwnershipId,
            sourceFingerprint,
            attestedAt.UtcDateTime,
            contentSafetyResourceId,
            contentSafetyEndpoint,
            gatewayApiPrincipalObjectId);
        return true;
    }

    private static bool TryContentSafetyResourceId(
        string? value,
        out string resourceId,
        out string accountName)
    {
        resourceId = string.Empty;
        accountName = string.Empty;
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
        if (segments is not
            [
                "subscriptions",
                var subscriptionId,
                "resourceGroups",
                var resourceGroup,
                "providers",
                "Microsoft.CognitiveServices",
                "accounts",
                var resourceName
            ] ||
            !TryCanonicalGuid(subscriptionId, out _) ||
            !IsResourceName(resourceGroup, 90) ||
            !IsResourceName(resourceName, 64))
        {
            return false;
        }

        resourceId = value;
        accountName = resourceName;
        return true;
    }

    private static bool TryContentSafetyEndpoint(
        string? value,
        string accountName,
        out string endpoint)
    {
        endpoint = string.Empty;
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) ||
            !string.Equals(
                uri.Scheme,
                Uri.UriSchemeHttps,
                StringComparison.Ordinal) ||
            !uri.IsDefaultPort ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment) ||
            uri.AbsolutePath != "/" ||
            !string.Equals(uri.AbsoluteUri, value, StringComparison.Ordinal) ||
            !string.Equals(
                uri.Host,
                $"{accountName}.cognitiveservices.azure.com",
                StringComparison.Ordinal) &&
            !string.Equals(
                uri.Host,
                $"{accountName}.services.ai.azure.com",
                StringComparison.Ordinal))
        {
            return false;
        }

        endpoint = value;
        return true;
    }

    private static bool TryReadObjectId(
        string token,
        out Guid objectId)
    {
        objectId = Guid.Empty;
        if (string.IsNullOrEmpty(token) ||
            token.Length > MaximumTokenLength)
        {
            return false;
        }

        var segments = token.Split('.');
        if (segments.Length != 3)
            return false;
        if (!TryDecodeBase64Url(segments[1], out var payload))
            return false;

        try
        {
            using var document = JsonDocument.Parse(payload);
            if (document.RootElement.ValueKind != JsonValueKind.Object ||
                !document.RootElement.TryGetProperty("oid", out var claim) ||
                claim.ValueKind != JsonValueKind.String)
            {
                return false;
            }

            return Guid.TryParse(claim.GetString(), out objectId) &&
                objectId != Guid.Empty;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool TryDecodeBase64Url(
        string value,
        out byte[] decoded)
    {
        decoded = [];
        if (string.IsNullOrEmpty(value))
            return false;

        try
        {
            decoded = Base64Url.DecodeFromChars(value);
            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static bool TryCanonicalGuid(
        string? value,
        out Guid parsed) =>
        Guid.TryParse(value, out parsed) &&
        parsed != Guid.Empty &&
        string.Equals(
            value,
            parsed.ToString("D"),
            StringComparison.Ordinal);

    private static bool TrySourceFingerprint(
        string? value,
        out string fingerprint)
    {
        fingerprint = string.Empty;
        if (value is null ||
            value.Length != 71 ||
            !value.StartsWith("sha256:", StringComparison.Ordinal) ||
            value.AsSpan(7).ContainsAnyExcept(
                "0123456789abcdef"))
        {
            return false;
        }

        fingerprint = value;
        return true;
    }

    private static bool IsResourceName(
        string value,
        int maximumLength) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= maximumLength &&
        value.All(character =>
            char.IsAsciiLetterOrDigit(character) ||
            character is '-' or '_' or '.' or '(' or ')');

    private static PromptShieldException BindingFailure() =>
        new(
            "PROMPT_SHIELD_CAPABILITY_BINDING_INVALID",
            "Prompt Shields capability binding is unavailable.");

    private readonly record struct PromptShieldAttestation(
        Guid DeploymentOwnershipId,
        string SourceFingerprint,
        DateTime AttestedAtUtc,
        string ContentSafetyAccountResourceId,
        string ContentSafetyEndpoint,
        Guid GatewayApiManagedIdentityPrincipalObjectId);
}
