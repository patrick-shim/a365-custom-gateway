using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;

namespace Gateway.Infrastructure.Persistence.Configurations;

internal static class ProtectionPersistenceSerialization
{
    private static readonly JsonSerializerOptions JsonOptions = CreateOptions();

    public static string SerializeResourceIdentifiers(
        ProtectionCapabilityResourceIdentifiers value) =>
        JsonSerializer.Serialize(
            new PersistedResourceIdentifiers(
                value.Agent365RegistryApiApplicationId?.Value,
                value.ContentSafetyAccountResourceId,
                value.ContentSafetyEndpoint,
                value.GatewayApiManagedIdentityPrincipalObjectId?.Value,
                value.PurviewRuntimeManagedIdentityPrincipalObjectId?.Value,
                value.PurviewAutomationApplicationId?.Value,
                value.PurviewAutomationServicePrincipalObjectId?.Value,
                value.KeyVaultResourceId,
                value.CertificateName,
                value.BootstrapDeploymentOwnershipId,
                value.BootstrapSourceFingerprint,
                value.KeyVaultHost,
                value.CertificateSecretUri),
            JsonOptions);

    public static ProtectionCapabilityResourceIdentifiers DeserializeResourceIdentifiers(
        string value)
    {
        var persisted =
            JsonSerializer.Deserialize<PersistedResourceIdentifiers>(
                value,
                JsonOptions)
            ?? throw new InvalidOperationException(
                "Protection capability resource identifier metadata is malformed.");
        return new ProtectionCapabilityResourceIdentifiers(
            persisted.Agent365RegistryApiApplicationId is { } registryId
                ? new ApplicationClientId(registryId)
                : null,
            persisted.ContentSafetyAccountResourceId,
            persisted.ContentSafetyEndpoint,
            persisted.GatewayApiManagedIdentityPrincipalObjectId is { } apiId
                ? new ServicePrincipalObjectId(apiId)
                : null,
            persisted.PurviewRuntimeManagedIdentityPrincipalObjectId is
            { } runtimeId
                ? new ServicePrincipalObjectId(runtimeId)
                : null,
            persisted.PurviewAutomationApplicationId is { } automationId
                ? new ApplicationClientId(automationId)
                : null,
            persisted.PurviewAutomationServicePrincipalObjectId is
            { } automationPrincipalId
                ? new ServicePrincipalObjectId(automationPrincipalId)
                : null,
            persisted.KeyVaultResourceId,
            persisted.CertificateName,
            persisted.BootstrapDeploymentOwnershipId,
            persisted.BootstrapSourceFingerprint,
            persisted.KeyVaultHost,
            persisted.CertificateSecretUri);
    }

    public static ProtectionCapabilityResourceIdentifiers CloneResourceIdentifiers(
        ProtectionCapabilityResourceIdentifiers value) =>
        DeserializeResourceIdentifiers(SerializeResourceIdentifiers(value));

    public static string SerializeActivities(ICollection<PurviewPolicyActivity> value) =>
        JsonSerializer.Serialize(value, JsonOptions);

    public static ICollection<PurviewPolicyActivity> DeserializeActivities(string value) =>
        JsonSerializer.Deserialize<List<PurviewPolicyActivity>>(value, JsonOptions)
        ?? throw new InvalidOperationException("Purview activity metadata is malformed.");

    public static ICollection<PurviewPolicyActivity> CloneActivities(
        ICollection<PurviewPolicyActivity> value) =>
        DeserializeActivities(SerializeActivities(value));

    public static string SerializeActions(ICollection<PurviewDlpRuleAction> value) =>
        JsonSerializer.Serialize(value, JsonOptions);

    public static ICollection<PurviewDlpRuleAction> DeserializeActions(string value) =>
        JsonSerializer.Deserialize<List<PurviewDlpRuleAction>>(value, JsonOptions)
        ?? throw new InvalidOperationException("Purview DLP action metadata is malformed.");

    public static ICollection<PurviewDlpRuleAction> CloneActions(
        ICollection<PurviewDlpRuleAction> value) =>
        DeserializeActions(SerializeActions(value));

    public static string SerializeReadiness(ProtectionReadiness value) =>
        JsonSerializer.Serialize(value, JsonOptions);

    public static ProtectionReadiness DeserializeReadiness(string value) =>
        JsonSerializer.Deserialize<ProtectionReadiness>(value, JsonOptions)
        ?? throw new InvalidOperationException("Protection readiness metadata is malformed.");

    public static string SerializeConfirmationVerifier(
        ProtectionConfirmationVerifier value) =>
        JsonSerializer.Serialize(
            new PersistedConfirmationVerifier(
                value.ReviewTokenId,
                value.ConfirmationTokenId,
                value.FormatVersion,
                value.HashAlgorithm,
                value.VerifierSalt.ToArray(),
                value.VerifierHash.ToArray(),
                value.ExpiresAtUtc,
                value.ConsumedAtUtc),
            JsonOptions);

    public static ProtectionConfirmationVerifier DeserializeConfirmationVerifier(string value)
    {
        var persisted = JsonSerializer.Deserialize<PersistedConfirmationVerifier>(
            value,
            JsonOptions)
            ?? throw new InvalidOperationException(
                "Protection confirmation verifier metadata is malformed.");
        var verifier = new ProtectionConfirmationVerifier(
            persisted.ReviewTokenId,
            persisted.ConfirmationTokenId,
            persisted.FormatVersion,
            persisted.HashAlgorithm,
            persisted.VerifierSalt,
            persisted.VerifierHash,
            DateTime.SpecifyKind(persisted.ExpiresAtUtc, DateTimeKind.Utc));
        if (persisted.ConsumedAtUtc is not null)
        {
            verifier.MarkConsumed(
                DateTime.SpecifyKind(persisted.ConsumedAtUtc.Value, DateTimeKind.Utc));
        }

        return verifier;
    }

    public static ProtectionConfirmationVerifier CloneConfirmationVerifier(
        ProtectionConfirmationVerifier value) =>
        DeserializeConfirmationVerifier(SerializeConfirmationVerifier(value));

    public static bool ConfirmationVerifiersEqual(
        ProtectionConfirmationVerifier? first,
        ProtectionConfirmationVerifier? second) =>
        ReferenceEquals(first, second) ||
        first is not null &&
        second is not null &&
        string.Equals(
            SerializeConfirmationVerifier(first),
            SerializeConfirmationVerifier(second),
            StringComparison.Ordinal);

    public static int ConfirmationVerifierHashCode(
        ProtectionConfirmationVerifier value) =>
        StringComparer.Ordinal.GetHashCode(SerializeConfirmationVerifier(value));

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        };
        options.Converters.Add(new JsonStringEnumConverter());
        return options;
    }

    private sealed record PersistedConfirmationVerifier(
        Guid ReviewTokenId,
        Guid ConfirmationTokenId,
        int FormatVersion,
        string HashAlgorithm,
        byte[] VerifierSalt,
        byte[] VerifierHash,
        DateTime ExpiresAtUtc,
        DateTime? ConsumedAtUtc);

    private sealed record PersistedResourceIdentifiers(
        Guid? Agent365RegistryApiApplicationId,
        string? ContentSafetyAccountResourceId,
        string? ContentSafetyEndpoint,
        Guid? GatewayApiManagedIdentityPrincipalObjectId,
        Guid? PurviewRuntimeManagedIdentityPrincipalObjectId,
        Guid? PurviewAutomationApplicationId,
        Guid? PurviewAutomationServicePrincipalObjectId,
        string? KeyVaultResourceId,
        string? CertificateName,
        Guid? BootstrapDeploymentOwnershipId,
        string? BootstrapSourceFingerprint,
        string? KeyVaultHost,
        string? CertificateSecretUri);
}
