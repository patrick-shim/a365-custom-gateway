using System.Collections.Frozen;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Persistence;

namespace Gateway.Infrastructure.Services;

public sealed record CapabilityPreparationPrincipal(string ClientId, string ObjectId);

public sealed record CapabilityPreparationFact(
    string Kind, string Status,
    string? Agent365RegistryApiApplicationId,
    string? ContentSafetyAccountResourceId, string? ContentSafetyEndpoint,
    string? GatewayApiManagedIdentityPrincipalObjectId,
    string? PurviewRuntimeManagedIdentityPrincipalObjectId,
    string? PurviewAutomationApplicationId, string? PurviewAutomationServicePrincipalObjectId,
    string? KeyVaultResourceId, string? KeyVaultHost, string? CertificateName, string? CertificateSecretUri);

public sealed record CapabilityPreparationRole(
    string Capability, string Kind, string PrincipalObjectId, string ResourceId,
    string RoleName, string RoleDefinitionId, string AssignmentId,
    string? ResourcePrincipalObjectId = null);

public sealed record CapabilityPreparationSnapshot(
    string AttestedAtUtc,
    IReadOnlyList<CapabilityPreparationFact> Capabilities,
    IReadOnlyList<CapabilityPreparationRole> RoleBindings);

public sealed record CapabilityPreparationReceipt(
    int SchemaVersion, string Kind, string UpgradeId, string Status,
    string ApprovedPlanFingerprint, string CandidateSourceFingerprint,
    string DeploymentOwnershipId, string TenantId, string SubscriptionId, string ResourceGroup,
    string OriginalBootstrapSourceFingerprint,
    string OriginalStateReference, string OriginalStateFingerprint,
    string OriginalConfigurationReference, string OriginalConfigurationFingerprint,
    string OriginalCapabilityFactsHash, string? PreviousReceiptFingerprint,
    string ExpectedPriorCapabilityFactsHash, string TargetSnapshotHash,
    CapabilityPreparationPrincipal ApiPrincipal, CapabilityPreparationPrincipal WorkerPrincipal,
    CapabilityPreparationPrincipal? PurviewRuntimePrincipal,
    CapabilityPreparationSnapshot TargetSnapshot, string ReadbackAtUtc);

// These pins are emitted by the reviewed maintenance deployment, not accepted on a Gateway API.
public sealed class CapabilityPreparationOptions
{
    public string ReceiptJson { get; set; } = string.Empty;
    public string ReceiptFingerprint { get; set; } = string.Empty;
    public string ApprovedPlanFingerprint { get; set; } = string.Empty;
    public string CandidateSourceFingerprint { get; set; } = string.Empty;
    public string TenantId { get; set; } = string.Empty;
    public string SubscriptionId { get; set; } = string.Empty;
    public string ResourceGroup { get; set; } = string.Empty;
    public string OriginalStateReference { get; set; } = string.Empty;
    public string OriginalStateFingerprint { get; set; } = string.Empty;
    public string OriginalConfigurationReference { get; set; } = string.Empty;
    public string OriginalConfigurationFingerprint { get; set; } = string.Empty;
    public CapabilityPreparationPrincipal? ApiPrincipal { get; set; }
    public CapabilityPreparationPrincipal? WorkerPrincipal { get; set; }
    public CapabilityPreparationPrincipal? PurviewRuntimePrincipal { get; set; }
    public bool IsConfigured => !string.IsNullOrEmpty(ReceiptJson) || !string.IsNullOrEmpty(ReceiptFingerprint) ||
        !string.IsNullOrEmpty(ApprovedPlanFingerprint) || !string.IsNullOrEmpty(CandidateSourceFingerprint) ||
        !string.IsNullOrEmpty(TenantId) || !string.IsNullOrEmpty(SubscriptionId) || !string.IsNullOrEmpty(ResourceGroup) ||
        !string.IsNullOrEmpty(OriginalStateReference) || !string.IsNullOrEmpty(OriginalStateFingerprint) ||
        !string.IsNullOrEmpty(OriginalConfigurationReference) || !string.IsNullOrEmpty(OriginalConfigurationFingerprint) ||
        ApiPrincipal is not null || WorkerPrincipal is not null || PurviewRuntimePrincipal is not null;
}

public sealed class CapabilityPreparationAuthorization
{
    internal CapabilityPreparationAuthorization(CapabilityPreparationReceipt receipt, string json, string fingerprint)
    {
        Receipt = receipt;
        ReceiptJson = json;
        ReceiptFingerprint = fingerprint;
    }
    public CapabilityPreparationReceipt Receipt { get; }
    public string ReceiptJson { get; }
    public string ReceiptFingerprint { get; }
}

public interface ICapabilityPreparationStore
{
    Task SynchronizePreparedAsync(BootstrapProtectionCapabilityAttestation target,
        CapabilityPreparationAuthorization authorization, DateTime utcNow, CancellationToken cancellationToken);
}

public static class CapabilityPreparationContract
{
    public const string ReceiptKind = "A365GatewayCapabilityPreparation";
    public const string PreparedStatus = "PreparedConfiguration";
    public const int MaximumReceiptCharacters = 32768;

    // Application identifiers, not delegated scopes: https://learn.microsoft.com/graph/permissions-reference
    public static IReadOnlyDictionary<string, string> GraphApplicationRoleIds { get; } =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["Content.Process.User"] = "24ceb246-ad29-4680-90b4-3e91ffad15eb",
            ["ProtectionScopes.Compute.User"] = "fe696d63-5e1f-4515-8232-cccc316903c6",
            ["ContentActivity.Write"] = "2932e07a-3c29-44e4-bb36-6d0fc176387f"
        }.ToFrozenDictionary(StringComparer.Ordinal);

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        MaxDepth = 8
    };

    public static string Serialize(CapabilityPreparationReceipt receipt) =>
        JsonSerializer.Serialize(receipt with
        {
            TargetSnapshot = CanonicalSnapshot(receipt.TargetSnapshot)
        }, Json);

    public static string SnapshotHash(CapabilityPreparationSnapshot snapshot) =>
        DatabaseUpgradeAttestation.Fingerprint(JsonSerializer.Serialize(CanonicalSnapshot(snapshot), Json));

    public static string FactsJson(BootstrapProtectionCapabilityAttestation attestation) =>
        SerializeFacts(attestation.DeploymentOwnershipId.ToString("D"), attestation.AcceptedSourceFingerprint,
            DateTime.SpecifyKind(attestation.AttestedAtUtc, DateTimeKind.Utc).ToString("O", CultureInfo.InvariantCulture),
            attestation.Capabilities.OrderBy(value => value.Kind).Select(FromFact).ToArray());

    internal static string TargetFactsJson(CapabilityPreparationReceipt receipt) =>
        SerializeFacts(receipt.DeploymentOwnershipId, receipt.OriginalBootstrapSourceFingerprint,
            receipt.TargetSnapshot.AttestedAtUtc, receipt.TargetSnapshot.Capabilities);

    private static string SerializeFacts(string ownership, string source, string time, IReadOnlyList<CapabilityPreparationFact> facts) =>
        JsonSerializer.Serialize(new
        {
            deploymentOwnershipId = ownership, originalBootstrapSourceFingerprint = source,
            attestedAtUtc = time, capabilities = facts
        }, Json);

    public static string FactsHash(BootstrapProtectionCapabilityAttestation attestation) =>
        DatabaseUpgradeAttestation.Fingerprint(FactsJson(attestation));

    public static CapabilityPreparationAuthorization Authorize(CapabilityPreparationOptions pins,
        BootstrapProtectionCapabilityAttestation target, DateTime utcNow)
    {
        ArgumentNullException.ThrowIfNull(pins);
        Require(utcNow.Kind == DateTimeKind.Utc && pins.ReceiptJson.Length is > 0 and <= MaximumReceiptCharacters,
            "Missing or oversized preparation receipt.");
        Require(DatabaseUpgradeAttestation.IsFingerprint(pins.ReceiptFingerprint) &&
            DatabaseUpgradeAttestation.Fingerprint(pins.ReceiptJson) == pins.ReceiptFingerprint, "Receipt digest mismatch.");
        var receipt = Parse(pins.ReceiptJson);
        Validate(receipt, target, utcNow);
        Require(receipt.ApprovedPlanFingerprint == pins.ApprovedPlanFingerprint &&
            receipt.CandidateSourceFingerprint == pins.CandidateSourceFingerprint &&
            receipt.TenantId == pins.TenantId && receipt.SubscriptionId == pins.SubscriptionId &&
            receipt.OriginalStateReference == pins.OriginalStateReference && receipt.OriginalStateFingerprint == pins.OriginalStateFingerprint &&
            receipt.OriginalConfigurationReference == pins.OriginalConfigurationReference &&
            receipt.OriginalConfigurationFingerprint == pins.OriginalConfigurationFingerprint &&
            receipt.ResourceGroup == pins.ResourceGroup && receipt.ApiPrincipal == pins.ApiPrincipal &&
            receipt.WorkerPrincipal == pins.WorkerPrincipal && receipt.PurviewRuntimePrincipal == pins.PurviewRuntimePrincipal,
            "Receipt does not match independently pinned deployment bindings.");
        return new(receipt, pins.ReceiptJson, pins.ReceiptFingerprint);
    }

    public static CapabilityPreparationReceipt Parse(string json)
    {
        Require(json is { Length: > 0 and <= MaximumReceiptCharacters }, "Missing or oversized preparation receipt.");
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
        RejectDuplicates(document.RootElement);
        var receipt = JsonSerializer.Deserialize<CapabilityPreparationReceipt>(json, Json)
            ?? throw Invalid("Missing preparation receipt.");
        Require(receipt.TargetSnapshot?.Capabilities is not null && receipt.TargetSnapshot.RoleBindings is not null &&
            receipt.TargetSnapshot.Capabilities.All(value => value is not null) &&
            receipt.TargetSnapshot.RoleBindings.All(value => value is not null), "Incomplete target snapshot.");
        Require(Serialize(receipt) == json, "Receipt is not canonical.");
        return receipt;
    }

    internal static void Validate(CapabilityPreparationReceipt receipt,
        BootstrapProtectionCapabilityAttestation target, DateTime utcNow)
    {
        Require(receipt.SchemaVersion == 1 && receipt.Kind == ReceiptKind && receipt.Status == PreparedStatus,
            "Only v1 prepared configuration receipts are supported.");
        foreach (var id in new[] { receipt.UpgradeId, receipt.DeploymentOwnershipId, receipt.TenantId, receipt.SubscriptionId })
            Require(DatabaseUpgradeAttestation.IsCanonicalGuid(id), "Noncanonical preparation identity.");
        foreach (var hash in new[] { receipt.ApprovedPlanFingerprint, receipt.CandidateSourceFingerprint,
            receipt.OriginalBootstrapSourceFingerprint, receipt.OriginalStateFingerprint, receipt.OriginalConfigurationFingerprint,
            receipt.OriginalCapabilityFactsHash, receipt.ExpectedPriorCapabilityFactsHash, receipt.TargetSnapshotHash })
            Require(DatabaseUpgradeAttestation.IsFingerprint(hash), "Invalid preparation fingerprint.");
        Require(receipt.PreviousReceiptFingerprint is null || DatabaseUpgradeAttestation.IsFingerprint(receipt.PreviousReceiptFingerprint),
            "Invalid preceding receipt fingerprint.");
        Require(Regex.IsMatch(receipt.ResourceGroup ?? "", "^[A-Za-z0-9][A-Za-z0-9_.()-]{0,89}$"),
            "Invalid resource group.");
        foreach (var reference in new[] { receipt.OriginalStateReference, receipt.OriginalConfigurationReference })
            Require(reference is not null && Regex.IsMatch(reference, "^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$") &&
                !reference.Contains("..", StringComparison.Ordinal), "Invalid immutable reference; URLs and scripts are not accepted.");
        ValidatePrincipal(receipt.ApiPrincipal);
        ValidatePrincipal(receipt.WorkerPrincipal);
        Require(receipt.ApiPrincipal != receipt.WorkerPrincipal &&
            receipt.ApiPrincipal.ObjectId != receipt.WorkerPrincipal.ObjectId &&
            receipt.ApiPrincipal.ClientId != receipt.WorkerPrincipal.ClientId, "Runtime principals must be distinct.");
        if (receipt.PurviewRuntimePrincipal is { } purview)
        {
            ValidatePrincipal(purview);
            Require(purview.ObjectId != receipt.ApiPrincipal.ObjectId && purview.ObjectId != receipt.WorkerPrincipal.ObjectId &&
                purview.ClientId != receipt.ApiPrincipal.ClientId && purview.ClientId != receipt.WorkerPrincipal.ClientId,
                "Purview runtime identity is not isolated.");
        }
        Require(DateTime.TryParseExact(receipt.ReadbackAtUtc, "O", CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out var readback) && readback.Kind == DateTimeKind.Utc &&
            readback <= utcNow.AddMinutes(2) && readback == target.AttestedAtUtc &&
            receipt.TargetSnapshot.AttestedAtUtc == receipt.ReadbackAtUtc,
            "Prepared resource readback time is invalid.");
        Require(receipt.DeploymentOwnershipId == target.DeploymentOwnershipId.ToString("D") &&
            receipt.OriginalBootstrapSourceFingerprint == target.AcceptedSourceFingerprint &&
            SnapshotHash(receipt.TargetSnapshot) == receipt.TargetSnapshotHash &&
            receipt.TargetSnapshot.Capabilities.Count == 3 &&
            receipt.TargetSnapshot.Capabilities.SequenceEqual(target.Capabilities.OrderBy(value => value.Kind).Select(FromFact)),
            "Configured target facts do not match the receipt.");
        ValidateTargetAndRoles(receipt);
    }

    private static void ValidateTargetAndRoles(CapabilityPreparationReceipt receipt)
    {
        var facts = receipt.TargetSnapshot.Capabilities;
        Require(facts.Select(value => value.Kind).SequenceEqual(Enum.GetValues<ProtectionCapabilityKind>().Select(value => value.ToString())),
            "Exactly three ordered capability facts are required.");
        var requiredRoles = new List<(string Capability, string Kind, string Principal, string Resource, string Name, string Definition)>();
        foreach (var fact in facts)
        {
            Require(fact.Status is "Installed" or "NotInstalled", "Prepared capability cannot claim runtime/policy readiness.");
            var identifiers = typeof(CapabilityPreparationFact).GetProperties()
                .Where(property => property.Name is not nameof(fact.Kind) and not nameof(fact.Status))
                .Where(property => property.GetValue(fact) is not null).Select(property => property.Name).ToHashSet();
            if (fact.Status == "NotInstalled")
            {
                Require(identifiers.Count == 0, "NotInstalled fact contains identifiers.");
                continue;
            }
            string[] allowed;
            switch (fact.Kind)
            {
                case "Agent365RegistrationBeta":
                    allowed = [nameof(fact.Agent365RegistryApiApplicationId)];
                    Require(DatabaseUpgradeAttestation.IsCanonicalGuid(fact.Agent365RegistryApiApplicationId), "Invalid registration resource identity.");
                    break;
                case "PromptShields":
                    allowed = [nameof(fact.ContentSafetyAccountResourceId), nameof(fact.ContentSafetyEndpoint), nameof(fact.GatewayApiManagedIdentityPrincipalObjectId)];
                    RequireResource(fact.ContentSafetyAccountResourceId, receipt, "Microsoft.CognitiveServices/accounts");
                    Require(fact.ContentSafetyEndpoint == $"https://{fact.ContentSafetyAccountResourceId!.Split('/')[^1]}.cognitiveservices.azure.com/" &&
                        fact.GatewayApiManagedIdentityPrincipalObjectId == receipt.ApiPrincipal.ObjectId, "Prompt Shields target identity/endpoint mismatch.");
                    requiredRoles.Add((fact.Kind, "AzureRbac", receipt.ApiPrincipal.ObjectId, fact.ContentSafetyAccountResourceId!,
                        "CognitiveServicesUser", "a97b65f3-24c7-4388-baec-2e87135dc908"));
                    break;
                case "Purview":
                    allowed = [nameof(fact.GatewayApiManagedIdentityPrincipalObjectId), nameof(fact.PurviewRuntimeManagedIdentityPrincipalObjectId),
                        nameof(fact.PurviewAutomationApplicationId), nameof(fact.PurviewAutomationServicePrincipalObjectId),
                        nameof(fact.KeyVaultResourceId), nameof(fact.KeyVaultHost), nameof(fact.CertificateName), nameof(fact.CertificateSecretUri)];
                    RequireResource(fact.KeyVaultResourceId, receipt, "Microsoft.KeyVault/vaults");
                    Require(receipt.PurviewRuntimePrincipal is not null &&
                        fact.PurviewRuntimeManagedIdentityPrincipalObjectId == receipt.PurviewRuntimePrincipal.ObjectId &&
                        fact.GatewayApiManagedIdentityPrincipalObjectId == receipt.ApiPrincipal.ObjectId &&
                        DatabaseUpgradeAttestation.IsCanonicalGuid(fact.PurviewAutomationApplicationId) &&
                        DatabaseUpgradeAttestation.IsCanonicalGuid(fact.PurviewAutomationServicePrincipalObjectId) &&
                        !new[] { receipt.ApiPrincipal.ObjectId, receipt.WorkerPrincipal.ObjectId, receipt.PurviewRuntimePrincipal!.ObjectId }
                            .Contains(fact.PurviewAutomationServicePrincipalObjectId, StringComparer.Ordinal) &&
                        !new[] { receipt.ApiPrincipal.ClientId, receipt.WorkerPrincipal.ClientId, receipt.PurviewRuntimePrincipal.ClientId }
                            .Contains(fact.PurviewAutomationApplicationId, StringComparer.Ordinal) &&
                        Regex.IsMatch(fact.CertificateName ?? "", "^[A-Za-z0-9-]{1,127}$") &&
                        fact.KeyVaultHost == $"{fact.KeyVaultResourceId!.Split('/')[^1]}.vault.azure.net" &&
                        fact.CertificateSecretUri == $"https://{fact.KeyVaultHost}/secrets/{fact.CertificateName}",
                        "Purview target certificate/identity binding mismatch.");
                    requiredRoles.Add((fact.Kind, "AzureRbac", receipt.WorkerPrincipal.ObjectId, $"{fact.KeyVaultResourceId}/secrets/{fact.CertificateName}",
                        "KeyVaultSecretsUser", "4633458b-17de-408a-b874-0445c86b69e6"));
                    foreach (var (name, applicationRoleId) in GraphApplicationRoleIds)
                        requiredRoles.Add((fact.Kind, "GraphApplication", receipt.PurviewRuntimePrincipal!.ObjectId,
                            "00000003-0000-0000-c000-000000000000", name, applicationRoleId));
                    requiredRoles.Add((fact.Kind, "GraphApplication", fact.PurviewAutomationServicePrincipalObjectId!,
                        "00000002-0000-0ff1-ce00-000000000000", "Exchange.ManageAsApp", "dc50a0fb-09a3-484d-be87-e023b12c6440"));
                    requiredRoles.Add((fact.Kind, "EntraDirectory", fact.PurviewAutomationServicePrincipalObjectId!, "/",
                        "ComplianceAdministrator", "17315797-102d-40b4-93e0-432062caca18"));
                    break;
                default: throw Invalid("Unsupported capability.");
            }
            Require(identifiers.SetEquals(allowed), "Capability contains missing or disallowed target identifiers.");
        }
        var roles = receipt.TargetSnapshot.RoleBindings;
        Require(roles.Count == requiredRoles.Count && roles.Select(value => value.AssignmentId).Distinct().Count() == roles.Count &&
            roles.Select(value => (value.Kind, value.PrincipalObjectId, value.ResourceId, value.RoleDefinitionId)).Distinct().Count() == roles.Count,
            "Partial, duplicate or excessive prepared role assignments.");
        foreach (var expected in requiredRoles)
            Require(roles.Count(actual => actual.Capability == expected.Capability && actual.Kind == expected.Kind &&
                actual.PrincipalObjectId == expected.Principal && actual.ResourceId == expected.Resource &&
                actual.RoleName == expected.Name && actual.RoleDefinitionId == expected.Definition &&
                DatabaseUpgradeAttestation.IsCanonicalGuid(actual.RoleDefinitionId) &&
                (actual.Kind == "AzureRbac" ? DatabaseUpgradeAttestation.IsCanonicalGuid(actual.AssignmentId) :
                    Regex.IsMatch(actual.AssignmentId ?? "", "^[A-Za-z0-9_+/=-]{1,256}$")) &&
                (actual.Kind == "GraphApplication" ? DatabaseUpgradeAttestation.IsCanonicalGuid(actual.ResourcePrincipalObjectId) :
                    actual.ResourcePrincipalObjectId is null)) == 1, "Role assignment is missing, foreign or outside its allowlist.");
        var graphResources = roles.Where(value => value.Kind == "GraphApplication").GroupBy(value => value.ResourceId).ToArray();
        Require(graphResources.All(group => group.Select(value => value.ResourcePrincipalObjectId).Distinct().Count() == 1) &&
            graphResources.Select(group => group.First().ResourcePrincipalObjectId).Distinct().Count() == graphResources.Length,
            "Graph resource application and service-principal bindings are ambiguous.");
        Require(facts.Single(value => value.Kind == "Purview").Status == "Installed" || receipt.PurviewRuntimePrincipal is null,
            "Uninstalled Purview cannot assert a runtime principal.");
    }

    private static void RequireResource(string? value, CapabilityPreparationReceipt receipt, string type) =>
        Require(value is not null && Regex.IsMatch(value,
            "^" + Regex.Escape($"/subscriptions/{receipt.SubscriptionId}/resourceGroups/{receipt.ResourceGroup}/providers/{type}/") +
            "[a-z0-9][a-z0-9-]{1,62}$"), "Resource is not bound to the exact approved subscription and resource group.");

    private static void ValidatePrincipal(CapabilityPreparationPrincipal? principal) =>
        Require(principal is not null && DatabaseUpgradeAttestation.IsCanonicalGuid(principal.ClientId) &&
            DatabaseUpgradeAttestation.IsCanonicalGuid(principal.ObjectId), "Invalid runtime principal.");

    private static CapabilityPreparationSnapshot CanonicalSnapshot(CapabilityPreparationSnapshot snapshot) =>
        snapshot with
        {
            Capabilities = snapshot.Capabilities.OrderBy(value => Enum.Parse<ProtectionCapabilityKind>(value.Kind, false)).ToArray(),
            RoleBindings = snapshot.RoleBindings.OrderBy(value => value.Capability, StringComparer.Ordinal)
                .ThenBy(value => value.Kind, StringComparer.Ordinal).ThenBy(value => value.PrincipalObjectId, StringComparer.Ordinal)
                .ThenBy(value => value.ResourceId, StringComparer.Ordinal).ThenBy(value => value.RoleName, StringComparer.Ordinal).ToArray()
        };

    public static CapabilityPreparationFact FromFact(BootstrapProtectionCapabilityFact fact)
    {
        var r = fact.ResourceIdentifiers;
        return new(fact.Kind.ToString(), fact.Status.ToString(), r.Agent365RegistryApiApplicationId?.Value.ToString("D"),
            r.ContentSafetyAccountResourceId, r.ContentSafetyEndpoint, r.GatewayApiManagedIdentityPrincipalObjectId?.Value.ToString("D"),
            r.PurviewRuntimeManagedIdentityPrincipalObjectId?.Value.ToString("D"), r.PurviewAutomationApplicationId?.Value.ToString("D"),
            r.PurviewAutomationServicePrincipalObjectId?.Value.ToString("D"), r.KeyVaultResourceId, r.KeyVaultHost, r.CertificateName, r.CertificateSecretUri);
    }

    private static void RejectDuplicates(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in value.EnumerateObject())
            {
                Require(names.Add(property.Name), "Duplicate receipt field.");
                RejectDuplicates(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
            foreach (var item in value.EnumerateArray()) RejectDuplicates(item);
    }
    internal static void Require(bool valid, string message)
    {
        if (!valid) throw Invalid(message);
    }
    private static InvalidOperationException Invalid(string message) => new($"CAPABILITY_PREPARATION_INVALID: {message}");
}
