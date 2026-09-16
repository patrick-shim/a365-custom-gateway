using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Gateway.Domain.Entities;
using Gateway.Infrastructure.Services;

namespace Gateway.Infrastructure.Persistence;

public sealed class DatabaseUpgradeAttestationOptions
{
    public bool Enabled { get; set; }
    public string PlanFingerprint { get; set; } = string.Empty;
    public string UpgradeSourceFingerprint { get; set; } = string.Empty;
    public string ReceiptFingerprint { get; set; } = string.Empty;
    public string BeforeSchemaFingerprint { get; set; } = string.Empty;
    public string SqlManifestFingerprint { get; set; } = string.Empty;
    public string ReceiptJson { get; set; } = string.Empty;
}

public sealed record DatabaseUpgradeReceipt(
    int SchemaVersion,
    string DeploymentOwnershipId,
    string OriginalAcceptedSourceFingerprint,
    string OriginalMarkerFingerprint,
    string PlanFingerprint,
    string UpgradeSourceFingerprint,
    string? PreviousReceiptFingerprint,
    string BeforeSchemaFingerprint,
    string AfterSchemaFingerprint,
    string SqlManifestFingerprint,
    string ExecutionIntentId,
    string Server,
    string Database,
    string RegistrationIdentityFingerprintBefore,
    string RegistrationIdentityFingerprintAfter,
    string VerifiedAtUtc,
    string? TargetModelFingerprint = null,
    string? PriorCapabilityFactsJson = null,
    string? PriorCapabilityFactsFingerprint = null);

public static partial class DatabaseUpgradeAttestation
{
    public const int ContractVersion = 1;
    public const string OriginalMarkerName = "A365GatewayBootstrapInitializationIntent";
    public const string ReceiptPrefix = "A365GatewayUpgradeReceipt:";
    public const int MaximumReceiptCharacters = 8192;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        MaxDepth = 8
    };

    public static bool IsFingerprint(string? value) =>
        value is not null && FingerprintPattern().IsMatch(value);

    public static bool IsCanonicalGuid(string? value) =>
        Guid.TryParseExact(value, "D", out var parsed) &&
        parsed != Guid.Empty &&
        value!.Equals(parsed.ToString("D"), StringComparison.Ordinal);

    public static string Fingerprint(string text) =>
        $"sha256:{Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant()}";

    public static bool HasExpectedCapabilityIdentity(ProtectionCapability capability, Guid ownership) =>
        capability.Id == BootstrapProtectionCapabilityStore.CreateDeterministicId(ownership, capability.Kind);

    public static string GetReceiptName(string planFingerprint)
    {
        if (!IsFingerprint(planFingerprint))
            throw new ArgumentException("A canonical upgrade plan fingerprint is required.");
        return ReceiptPrefix + planFingerprint[7..];
    }

    public static bool HasValidOptions(DatabaseUpgradeAttestationOptions? options) =>
        options is not null &&
        (!options.Enabled ||
         IsFingerprint(options.PlanFingerprint) &&
         IsFingerprint(options.UpgradeSourceFingerprint) &&
         IsFingerprint(options.ReceiptFingerprint) &&
         IsFingerprint(options.BeforeSchemaFingerprint) &&
         IsFingerprint(options.SqlManifestFingerprint) &&
         options.ReceiptJson is { Length: > 0 and <= MaximumReceiptCharacters } &&
         Fingerprint(options.ReceiptJson).Equals(options.ReceiptFingerprint, StringComparison.Ordinal));

    public static string Serialize(DatabaseUpgradeReceipt receipt)
    {
        AssertValid(receipt);
        var json = JsonSerializer.Serialize(receipt, JsonOptions);
        if (json.Length > MaximumReceiptCharacters)
            throw new InvalidOperationException("The database upgrade receipt exceeds its bounded metadata contract.");
        return json;
    }

    public static DatabaseUpgradeReceipt Parse(string json)
    {
        if (string.IsNullOrWhiteSpace(json) || json.Length > MaximumReceiptCharacters)
            throw new InvalidOperationException("The database upgrade receipt is empty or oversized.");
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
        if (document.RootElement.ValueKind != JsonValueKind.Object)
            throw new InvalidOperationException("The database upgrade receipt must be an object.");
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in document.RootElement.EnumerateObject())
            if (!names.Add(property.Name))
                throw new InvalidOperationException("The database upgrade receipt contains duplicate properties.");
        var receipt = JsonSerializer.Deserialize<DatabaseUpgradeReceipt>(json, JsonOptions)
            ?? throw new InvalidOperationException("The database upgrade receipt is absent.");
        if (!Serialize(receipt).Equals(json, StringComparison.Ordinal))
            throw new InvalidOperationException("The database upgrade receipt is not canonical.");
        return receipt;
    }

    public static void AssertValid(DatabaseUpgradeReceipt receipt)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        if (receipt.SchemaVersion != ContractVersion ||
            !IsCanonicalGuid(receipt.DeploymentOwnershipId) ||
            !IsCanonicalGuid(receipt.ExecutionIntentId) ||
            !IsFingerprint(receipt.OriginalAcceptedSourceFingerprint) ||
            !IsFingerprint(receipt.OriginalMarkerFingerprint) ||
            !IsFingerprint(receipt.PlanFingerprint) ||
            !IsFingerprint(receipt.UpgradeSourceFingerprint) ||
            receipt.PreviousReceiptFingerprint is not null && !IsFingerprint(receipt.PreviousReceiptFingerprint) ||
            !IsFingerprint(receipt.BeforeSchemaFingerprint) ||
            !IsFingerprint(receipt.AfterSchemaFingerprint) ||
            !IsFingerprint(receipt.SqlManifestFingerprint) ||
            receipt.TargetModelFingerprint is not null && !IsFingerprint(receipt.TargetModelFingerprint) ||
            (receipt.PriorCapabilityFactsJson is not null || receipt.PriorCapabilityFactsFingerprint is not null) &&
                (receipt.PriorCapabilityFactsJson is null || receipt.PriorCapabilityFactsJson.Length > 4096 ||
                 !IsFingerprint(receipt.PriorCapabilityFactsFingerprint) ||
                 Fingerprint(receipt.PriorCapabilityFactsJson) != receipt.PriorCapabilityFactsFingerprint) ||
            !IsFingerprint(receipt.RegistrationIdentityFingerprintBefore) ||
            !receipt.RegistrationIdentityFingerprintBefore.Equals(receipt.RegistrationIdentityFingerprintAfter, StringComparison.Ordinal) ||
            receipt.Server is null || !ServerPattern().IsMatch(receipt.Server) ||
            !string.Equals(receipt.Database, "GatewayDb", StringComparison.Ordinal) ||
            !DateTimeOffset.TryParseExact(receipt.VerifiedAtUtc, "O",
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None, out _))
        {
            throw new InvalidOperationException("The database upgrade receipt has an invalid preservation or provenance binding.");
        }
    }

    public static bool Matches(
        DatabaseUpgradeReceipt receipt,
        DatabaseAttestationOptions options,
        string originalMarker,
        string currentSchemaFingerprint)
    {
        try
        {
            var json = Serialize(receipt);
            return options.Upgrade.Enabled && HasValidOptions(options.Upgrade) &&
                receipt.DeploymentOwnershipId.Equals(options.DeploymentOwnershipId, StringComparison.Ordinal) &&
                receipt.OriginalAcceptedSourceFingerprint.Equals(options.AcceptedSourceFingerprint, StringComparison.Ordinal) &&
                receipt.OriginalMarkerFingerprint.Equals(Fingerprint(originalMarker), StringComparison.Ordinal) &&
                receipt.PlanFingerprint.Equals(options.Upgrade.PlanFingerprint, StringComparison.Ordinal) &&
                receipt.UpgradeSourceFingerprint.Equals(options.Upgrade.UpgradeSourceFingerprint, StringComparison.Ordinal) &&
                Fingerprint(json).Equals(options.Upgrade.ReceiptFingerprint, StringComparison.Ordinal) &&
                receipt.BeforeSchemaFingerprint.Equals(options.Upgrade.BeforeSchemaFingerprint, StringComparison.Ordinal) &&
                receipt.AfterSchemaFingerprint.Equals(options.ExpectedSchemaFingerprint, StringComparison.Ordinal) &&
                receipt.AfterSchemaFingerprint.Equals(currentSchemaFingerprint, StringComparison.Ordinal) &&
                receipt.SqlManifestFingerprint.Equals(options.Upgrade.SqlManifestFingerprint, StringComparison.Ordinal) &&
                receipt.Server.Equals(options.SqlServerFqdn, StringComparison.Ordinal) &&
                receipt.Database.Equals(options.DatabaseName, StringComparison.Ordinal);
        }
        catch
        {
            return false;
        }
    }

    [GeneratedRegex("^sha256:[0-9a-f]{64}$", RegexOptions.CultureInvariant)]
    private static partial Regex FingerprintPattern();

    [GeneratedRegex("^[a-z0-9-]+\\.database\\.windows\\.net$", RegexOptions.CultureInvariant)]
    private static partial Regex ServerPattern();
}
