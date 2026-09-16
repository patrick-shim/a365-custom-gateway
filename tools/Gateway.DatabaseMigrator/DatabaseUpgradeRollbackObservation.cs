using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Gateway.Infrastructure.Persistence;

namespace Gateway.DatabaseMigrator;

public sealed record DatabaseUpgradeRollbackObservation(
    int SchemaVersion,
    string PlanFingerprint,
    string UpgradeSourceFingerprint,
    string ReceiptFingerprint,
    string ModelFingerprint,
    string CompatibilityReviewFingerprint,
    string CompatibilityReviewJson,
    IReadOnlyDictionary<string, string> Images)
{
    public static DatabaseUpgradeRollbackObservation Parse(string json, string fingerprint, DatabaseUpgradeManifest manifest)
    {
        if (json.Length > 32768 || DatabaseUpgradeAttestation.Fingerprint(json) != fingerprint)
            throw Invalid();
        using var document = JsonDocument.Parse(json);
        DatabaseUpgradeExecution.AssertNoDuplicateProperties(document.RootElement);
        var value = JsonSerializer.Deserialize<DatabaseUpgradeRollbackObservation>(json,
            new JsonSerializerOptions { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow, MaxDepth = 12 })
            ?? throw Invalid();
        value.AssertBinding(manifest);
        return value;
    }

    public void AssertBinding(DatabaseUpgradeManifest manifest, DatabaseUpgradeReceipt? receipt = null)
    {
        AssertManifestAnchor(manifest);
        if (SchemaVersion != 1 || PlanFingerprint != manifest.PlanFingerprint ||
            UpgradeSourceFingerprint != manifest.UpgradeSourceFingerprint ||
            ModelFingerprint != manifest.TargetModelFingerprint ||
            !DatabaseUpgradeAttestation.IsFingerprint(ReceiptFingerprint) ||
            !DatabaseUpgradeAttestation.IsFingerprint(ModelFingerprint) ||
            !DatabaseUpgradeAttestation.IsFingerprint(CompatibilityReviewFingerprint) ||
            CompatibilityReviewJson is null || CompatibilityReviewJson.Length > 16384 ||
            DatabaseUpgradeAttestation.Fingerprint(CompatibilityReviewJson) != CompatibilityReviewFingerprint ||
            CompatibilityReviewFingerprint != manifest.RollbackCompatibilityReviewFingerprint ||
            Images is null || Images.Count != 3 || manifest.RollbackImages is null ||
            Images.Any(pair => !manifest.RollbackImages.TryGetValue(pair.Key, out var expected) || expected != pair.Value))
            throw Invalid();
        var registry = manifest.CutoverApiImage?.Split('/')[0] ?? throw Invalid();
        foreach (var (component, repository) in new[] { ("api", "gateway-api"), ("worker", "gateway-worker"), ("adminUi", "gateway-admin") })
            if (!Images.TryGetValue(component, out var image) ||
                !Regex.IsMatch(image, @"\A" + Regex.Escape(registry + "/" + repository + "@") + @"sha256:[0-9a-f]{64}\z"))
                throw Invalid();
        // Keep the original UTF-8 bytes in the hash binding; match the accepted
        // PowerShell review reader when parsing a BOM-prefixed document.
        using var document = JsonDocument.Parse(CompatibilityReviewJson.TrimStart('\uFEFF'));
        var review = document.RootElement;
        DatabaseUpgradeExecution.AssertNoDuplicateProperties(review);
        if (review.ValueKind != JsonValueKind.Object ||
            review.GetProperty("schemaVersion").GetInt32() != 1 ||
            review.GetProperty("decision").GetString() != "BackwardCompatible" ||
            review.GetProperty("reviewerModel").GetString() != "gpt-6-astra" ||
            review.GetProperty("modelFingerprint").GetString() != ModelFingerprint)
            throw Invalid();
        var images = review.GetProperty("images");
        if (images.ValueKind != JsonValueKind.Object || images.EnumerateObject().Count() != 3 ||
            Images.Any(pair => !images.TryGetProperty(pair.Key, out var image) || image.GetString() != pair.Value))
            throw Invalid();
        var evidence = review.GetProperty("testEvidence");
        if (evidence.ValueKind != JsonValueKind.Array || evidence.GetArrayLength() is < 1 or > 100)
            throw Invalid();
        foreach (var item in evidence.EnumerateArray())
            if (item.ValueKind != JsonValueKind.Object ||
                item.GetProperty("path").GetString() is not { Length: > 0 and <= 4096 } ||
                !DatabaseUpgradeAttestation.IsFingerprint(item.GetProperty("sha256").GetString()))
                throw Invalid();
        if (receipt is not null &&
            (DatabaseUpgradeAttestation.Fingerprint(DatabaseUpgradeAttestation.Serialize(receipt)) != ReceiptFingerprint ||
             receipt.TargetModelFingerprint != ModelFingerprint))
            throw Invalid();
    }

    public static void AssertManifestAnchor(DatabaseUpgradeManifest manifest)
    {
        if (manifest.RollbackCompatibilityReviewFingerprint is null && manifest.RollbackImages is null) return;
        if (!DatabaseUpgradeAttestation.IsFingerprint(manifest.RollbackCompatibilityReviewFingerprint) ||
            !DatabaseUpgradeAttestation.IsFingerprint(manifest.TargetModelFingerprint) ||
            manifest.RollbackImages is null || manifest.RollbackImages.Count != 3)
            throw Invalid();
        var registry = manifest.CutoverApiImage?.Split('/')[0] ?? throw Invalid();
        foreach (var (component, repository) in new[] { ("api", "gateway-api"), ("worker", "gateway-worker"), ("adminUi", "gateway-admin") })
            if (!manifest.RollbackImages.TryGetValue(component, out var image) || image is null ||
                !Regex.IsMatch(image, @"\A" + Regex.Escape(registry + "/" + repository + "@") + @"sha256:[0-9a-f]{64}\z"))
                throw Invalid();
    }

    private static ArgumentException Invalid() => new(
        "UpgradeRollbackObservationBindingInvalid: exact Plan/source/verified receipt/model and independent compatible-image review are required.");
}
