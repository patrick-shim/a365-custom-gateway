using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Services;

namespace Gateway.DatabaseMigrator;

public sealed record CapabilityPreparationBuildInput(
    CapabilityPreparationReceipt Receipt,
    string DatabaseUpgradeReceiptJson);

internal sealed record ObservedCapabilityFacts(
    string DeploymentOwnershipId,
    string OriginalBootstrapSourceFingerprint,
    string AttestedAtUtc,
    IReadOnlyList<CapabilityPreparationFact> Capabilities);

public static class CapabilityPreparationBuilder
{
    public static string GetGraphApplicationRoleId(string roleName)
    {
        ArgumentNullException.ThrowIfNull(roleName);
        if (!CapabilityPreparationContract.GraphApplicationRoleIds.TryGetValue(roleName, out var roleId))
            throw new ArgumentException("The role name is not an exact reviewed Microsoft Graph application permission.", nameof(roleName));
        return roleId;
    }

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        MaxDepth = 10
    };

    public static string Build(string inputJson)
    {
        if (inputJson.Length > 65536)
            throw new ArgumentException("Capability preparation input exceeds its bound.");
        using var document = JsonDocument.Parse(inputJson, new JsonDocumentOptions { MaxDepth = 10 });
        RejectDuplicates(document.RootElement);
        var input = JsonSerializer.Deserialize<CapabilityPreparationBuildInput>(inputJson, Json)
            ?? throw new ArgumentException("Capability preparation input is absent.");
        ArgumentNullException.ThrowIfNull(input.Receipt);
        var database = DatabaseUpgradeAttestation.Parse(input.DatabaseUpgradeReceiptJson);
        if (database.PriorCapabilityFactsJson is null ||
            database.PriorCapabilityFactsFingerprint is null ||
            database.DeploymentOwnershipId != input.Receipt.DeploymentOwnershipId ||
            database.OriginalAcceptedSourceFingerprint != input.Receipt.OriginalBootstrapSourceFingerprint ||
            database.PlanFingerprint != input.Receipt.ApprovedPlanFingerprint ||
            database.UpgradeSourceFingerprint != input.Receipt.CandidateSourceFingerprint ||
            input.Receipt.PreviousReceiptFingerprint is not null)
            throw new ArgumentException("Capability preparation requires the independently observed same-Plan private database baseline.");
        var originalSnapshot = ValidateObservedFacts(database.PriorCapabilityFactsJson,
            database.DeploymentOwnershipId, database.OriginalAcceptedSourceFingerprint);
        var original = ToAttestation(input.Receipt.DeploymentOwnershipId, input.Receipt.OriginalBootstrapSourceFingerprint, originalSnapshot);
        var originalHash = CapabilityPreparationContract.FactsHash(original);
        if (originalHash != database.PriorCapabilityFactsFingerprint)
            throw new ArgumentException("The private database baseline fingerprint differs from its exact observed facts.");
        var receipt = input.Receipt with
        {
            OriginalCapabilityFactsHash = originalHash,
            ExpectedPriorCapabilityFactsHash = originalHash,
            TargetSnapshotHash = CapabilityPreparationContract.SnapshotHash(input.Receipt.TargetSnapshot)
        };
        var json = CapabilityPreparationContract.Serialize(receipt);
        var pins = new CapabilityPreparationOptions
        {
            ReceiptJson = json,
            ReceiptFingerprint = DatabaseUpgradeAttestation.Fingerprint(json),
            ApprovedPlanFingerprint = receipt.ApprovedPlanFingerprint,
            CandidateSourceFingerprint = receipt.CandidateSourceFingerprint,
            TenantId = receipt.TenantId,
            SubscriptionId = receipt.SubscriptionId,
            ResourceGroup = receipt.ResourceGroup,
            OriginalStateReference = receipt.OriginalStateReference,
            OriginalStateFingerprint = receipt.OriginalStateFingerprint,
            OriginalConfigurationReference = receipt.OriginalConfigurationReference,
            OriginalConfigurationFingerprint = receipt.OriginalConfigurationFingerprint,
            ApiPrincipal = receipt.ApiPrincipal,
            WorkerPrincipal = receipt.WorkerPrincipal,
            PurviewRuntimePrincipal = receipt.PurviewRuntimePrincipal
        };
        CapabilityPreparationContract.Authorize(pins,
            ToAttestation(receipt.DeploymentOwnershipId, receipt.OriginalBootstrapSourceFingerprint, receipt.TargetSnapshot),
            DateTime.UtcNow);
        return json;
    }

    public static CapabilityPreparationSnapshot ValidateObservedFacts(
        string factsJson, string ownership, string source,
        DatabaseUpgradeCutoverContract? sourceOnlyCutover = null)
    {
        if (string.IsNullOrEmpty(factsJson) || factsJson.Length > 4096 ||
            !DatabaseUpgradeAttestation.IsCanonicalGuid(ownership) ||
            !DatabaseUpgradeAttestation.IsFingerprint(source))
            throw new ArgumentException("The independently observed capability baseline is absent or oversized.");
        if (sourceOnlyCutover is not null)
            DatabaseUpgradePlatformObserver.AssertContract(sourceOnlyCutover);
        using var document = JsonDocument.Parse(factsJson, new JsonDocumentOptions { MaxDepth = 8 });
        RejectDuplicates(document.RootElement);
        var facts = JsonSerializer.Deserialize<ObservedCapabilityFacts>(factsJson, Json)
            ?? throw new ArgumentException("The observed capability facts are absent.");
        if (facts.DeploymentOwnershipId != ownership || facts.OriginalBootstrapSourceFingerprint != source ||
            facts.Capabilities is null || facts.Capabilities.Count != 3 ||
            facts.Capabilities.Any(value => value is null) ||
            !facts.Capabilities.Select(value => value.Kind).SequenceEqual(
                new[] { "Agent365RegistrationBeta", "PromptShields", "Purview" }, StringComparer.Ordinal) ||
            facts.Capabilities.Any(value => value.Status is not ("Installed" or "NotInstalled")) ||
            (sourceOnlyCutover is null
                ? facts.Capabilities[1].Status != "NotInstalled" || facts.Capabilities[2].Status != "NotInstalled"
                : facts.Capabilities.Any(value => value.Status != "Installed")))
            throw new ArgumentException("The private database baseline is not the exact same-deployment capability profile required by this manifest.");
        if (sourceOnlyCutover is not null)
        {
            AssertFullCapabilityFacts(facts.Capabilities, sourceOnlyCutover);
        }
        else
        {
            foreach (var fact in facts.Capabilities)
            {
                var identifiers = IdentifierNames(fact);
                if (fact.Status == "NotInstalled" && identifiers.Count != 0 ||
                    fact.Status == "Installed" && (fact.Kind != "Agent365RegistrationBeta" ||
                        !identifiers.SetEquals([nameof(fact.Agent365RegistryApiApplicationId)]) ||
                        !DatabaseUpgradeAttestation.IsCanonicalGuid(fact.Agent365RegistryApiApplicationId)))
                    throw new ArgumentException("The private capability baseline contains foreign or partial identifiers.");
            }
        }
        var snapshot = new CapabilityPreparationSnapshot(facts.AttestedAtUtc, facts.Capabilities, []);
        var attestation = ToAttestation(ownership, source, snapshot);
        if (attestation.AttestedAtUtc > DateTime.UtcNow.AddMinutes(2) ||
            CapabilityPreparationContract.FactsJson(attestation) != factsJson)
            throw new ArgumentException("The private capability baseline is not canonical independently observed data.");
        return snapshot;
    }

    private static HashSet<string> IdentifierNames(CapabilityPreparationFact fact) =>
        typeof(CapabilityPreparationFact).GetProperties()
            .Where(property => property.Name is not "Kind" and not "Status")
            .Where(property => property.GetValue(fact) is not null)
            .Select(property => property.Name).ToHashSet(StringComparer.Ordinal);

    private static void AssertFullCapabilityFacts(
        IReadOnlyList<CapabilityPreparationFact> facts, DatabaseUpgradeCutoverContract cutover)
    {
        var registry = facts[0];
        var shields = facts[1];
        var purview = facts[2];
        var scope = cutover.ApiResourceId[..cutover.ApiResourceId.IndexOf("/providers/", StringComparison.Ordinal)];
        bool Resource(string? value, string type) =>
            value is not null && Regex.IsMatch(value,
                @"\A" + Regex.Escape($"{scope}/providers/{type}/") + @"[a-z0-9][a-z0-9-]{1,62}\z",
                RegexOptions.CultureInvariant);

        if (!IdentifierNames(registry).SetEquals([nameof(registry.Agent365RegistryApiApplicationId)]) ||
            !DatabaseUpgradeAttestation.IsCanonicalGuid(registry.Agent365RegistryApiApplicationId) ||
            !IdentifierNames(shields).SetEquals([
                nameof(shields.ContentSafetyAccountResourceId), nameof(shields.ContentSafetyEndpoint),
                nameof(shields.GatewayApiManagedIdentityPrincipalObjectId)]) ||
            !Resource(shields.ContentSafetyAccountResourceId, "Microsoft.CognitiveServices/accounts") ||
            shields.ContentSafetyEndpoint != $"https://{shields.ContentSafetyAccountResourceId!.Split('/')[^1]}.cognitiveservices.azure.com/" ||
            !DatabaseUpgradeAttestation.IsCanonicalGuid(shields.GatewayApiManagedIdentityPrincipalObjectId) ||
            !IdentifierNames(purview).SetEquals([
                nameof(purview.GatewayApiManagedIdentityPrincipalObjectId), nameof(purview.PurviewRuntimeManagedIdentityPrincipalObjectId),
                nameof(purview.PurviewAutomationApplicationId), nameof(purview.PurviewAutomationServicePrincipalObjectId),
                nameof(purview.KeyVaultResourceId), nameof(purview.KeyVaultHost),
                nameof(purview.CertificateName), nameof(purview.CertificateSecretUri)]) ||
            purview.GatewayApiManagedIdentityPrincipalObjectId != shields.GatewayApiManagedIdentityPrincipalObjectId ||
            !DatabaseUpgradeAttestation.IsCanonicalGuid(purview.PurviewRuntimeManagedIdentityPrincipalObjectId) ||
            !DatabaseUpgradeAttestation.IsCanonicalGuid(purview.PurviewAutomationApplicationId) ||
            !DatabaseUpgradeAttestation.IsCanonicalGuid(purview.PurviewAutomationServicePrincipalObjectId) ||
            new[] { purview.GatewayApiManagedIdentityPrincipalObjectId, purview.PurviewRuntimeManagedIdentityPrincipalObjectId,
                purview.PurviewAutomationServicePrincipalObjectId }.Distinct(StringComparer.Ordinal).Count() != 3 ||
            !Resource(purview.KeyVaultResourceId, "Microsoft.KeyVault/vaults") ||
            !Regex.IsMatch(purview.CertificateName ?? "", @"\A[A-Za-z0-9-]{1,127}\z", RegexOptions.CultureInvariant) ||
            purview.KeyVaultHost != $"{purview.KeyVaultResourceId!.Split('/')[^1]}.vault.azure.net" ||
            purview.CertificateSecretUri != $"https://{purview.KeyVaultHost}/secrets/{purview.CertificateName}")
            throw new ArgumentException("SourceOnlyFull requires complete, isolated, same-scope installed capability identities and exact endpoints.");
    }

    private static BootstrapProtectionCapabilityAttestation ToAttestation(
        string ownership,
        string source,
        CapabilityPreparationSnapshot snapshot)
    {
        var time = DateTime.ParseExact(snapshot.AttestedAtUtc, "O", CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
        if (time.Kind != DateTimeKind.Utc)
            throw new ArgumentException("Capability fact timestamps must be canonical UTC timestamps.");
        var facts = snapshot.Capabilities
            .OrderBy(fact => Enum.Parse<ProtectionCapabilityKind>(fact.Kind, false))
            .Select(fact => new BootstrapProtectionCapabilityFact(
                Enum.Parse<ProtectionCapabilityKind>(fact.Kind, false),
                Enum.Parse<ProtectionCapabilityStatus>(fact.Status, false),
                new ProtectionCapabilityResourceIdentifiers(
                    Client(fact.Agent365RegistryApiApplicationId),
                    fact.ContentSafetyAccountResourceId,
                    fact.ContentSafetyEndpoint,
                    Principal(fact.GatewayApiManagedIdentityPrincipalObjectId),
                    Principal(fact.PurviewRuntimeManagedIdentityPrincipalObjectId),
                    Client(fact.PurviewAutomationApplicationId),
                    Principal(fact.PurviewAutomationServicePrincipalObjectId),
                    fact.KeyVaultResourceId,
                    fact.CertificateName,
                    Guid.ParseExact(ownership, "D"),
                    source,
                    fact.KeyVaultHost,
                    fact.CertificateSecretUri))).ToArray();
        return new BootstrapProtectionCapabilityAttestation(
            Guid.ParseExact(ownership, "D"),
            source, time, facts);
    }

    private static ApplicationClientId? Client(string? value) =>
        value is null ? null : new ApplicationClientId(Guid.ParseExact(value, "D"));

    private static ServicePrincipalObjectId? Principal(string? value) =>
        value is null ? null : new ServicePrincipalObjectId(Guid.ParseExact(value, "D"));

    private static void RejectDuplicates(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in element.EnumerateObject())
            {
                if (!names.Add(property.Name))
                    throw new ArgumentException("Capability preparation input contains duplicate fields.");
                RejectDuplicates(property.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
            foreach (var item in element.EnumerateArray())
                RejectDuplicates(item);
    }
}
