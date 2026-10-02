using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Gateway.Infrastructure.Persistence;

namespace Gateway.DatabaseMigrator;

public sealed record DatabaseUpgradeQueueCounters(
    [property: JsonRequired] long ActiveMessageCount,
    [property: JsonRequired] long ScheduledMessageCount,
    [property: JsonRequired] long TransferMessageCount,
    [property: JsonRequired] long TransferDeadLetterMessageCount,
    [property: JsonRequired] long DeadLetterMessageCount,
    [property: JsonRequired] long MessageCount);

public sealed record DatabaseUpgradeQueueQuarantineState(
    string ResourceId, string CreatedAtUtc, string ConfigurationFingerprint, DatabaseUpgradeQueueCounters Counters);

public sealed record DatabaseUpgradeQueueQuarantineBaseline(
    int SchemaVersion, string EvidenceKind, string Phase, string ReceiverSubQueue, string ObservedAtUtc,
    string DeploymentOwnershipId, string OriginalAcceptedSourceFingerprint, string UpgradeSourceFingerprint,
    IReadOnlyList<DatabaseUpgradeQueueQuarantineState> Queues);

public sealed record DatabaseUpgradeQueueQuarantineCheck(DatabaseUpgradeManifest Manifest, string Phase);

public static class DatabaseUpgradeQueueQuarantine
{
    public static DatabaseUpgradeQueueQuarantineBaseline AssertBaseline(DatabaseUpgradeManifest manifest)
    {
        DatabaseUpgradeExecution.AssertSourceOnlyPreservationManifest(manifest);
        DatabaseUpgradePlatformObserver.AssertContract(manifest.Cutover, manifest.CutoverOriginalRevisionResourceIds);
        var baseline = manifest.QueueQuarantineBaseline;
        if (baseline is null || baseline.SchemaVersion != 1 ||
            baseline.EvidenceKind != DatabaseUpgradeQueueQuarantineObservation.CountOnly ||
            baseline.Phase != "PlanReadOnlyBaseline" || baseline.ReceiverSubQueue != "None" ||
            !DatabaseUpgradeQueueQuarantineObservation.IsCanonicalUtc(baseline.ObservedAtUtc) ||
            baseline.DeploymentOwnershipId != manifest.DeploymentOwnershipId ||
            baseline.OriginalAcceptedSourceFingerprint != manifest.OriginalAcceptedSourceFingerprint ||
            baseline.UpgradeSourceFingerprint != manifest.UpgradeSourceFingerprint ||
            baseline.Queues is not { Count: 2 })
            throw Invalid();
        var ids = new[] { manifest.Cutover!.ProvisioningQueueResourceId, manifest.Cutover.ProtectionQueueResourceId };
        for (var index = 0; index < ids.Length; index++)
        {
            var state = baseline.Queues[index];
            if (state is null || state.ResourceId != ids[index] ||
                !DatabaseUpgradeQueueQuarantineObservation.IsCanonicalUtc(state.CreatedAtUtc) ||
                string.CompareOrdinal(state.CreatedAtUtc, baseline.ObservedAtUtc) > 0 ||
                !DatabaseUpgradeAttestation.IsFingerprint(state.ConfigurationFingerprint))
                throw Invalid();
            AssertCounters(state.Counters);
        }
        return baseline;
    }

    public static void AssertCounters(DatabaseUpgradeQueueCounters? counts)
    {
        if (counts is null || counts.ActiveMessageCount != 0 || counts.ScheduledMessageCount != 0 ||
            counts.TransferMessageCount != 0 || counts.TransferDeadLetterMessageCount != 0 ||
            counts.DeadLetterMessageCount < 0 || counts.MessageCount != counts.DeadLetterMessageCount)
            throw Invalid();
    }

    public static DatabaseUpgradeQueueQuarantineState ReadState(JsonElement queue, string resourceId, string status)
    {
        DatabaseUpgradeExecution.AssertNoDuplicateProperties(queue);
        var properties = queue.GetProperty("properties");
        if (!DatabaseUpgradePlatformObserver.ResourceIdEquals(queue.GetProperty("id").GetString(), resourceId) ||
            properties.GetProperty("status").GetString() != status)
            throw Invalid();
        foreach (var name in new[] { "forwardTo", "forwardDeadLetteredMessagesTo" })
            if (properties.TryGetProperty(name, out var forwarding) && forwarding.ValueKind != JsonValueKind.Null)
                throw Invalid();
        if (!DateTimeOffset.TryParse(properties.GetProperty("createdAt").GetString(), CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var created) || created.Offset != TimeSpan.Zero)
            throw Invalid();
        var details = properties.GetProperty("countDetails");
        static long Count(JsonElement value, string name)
        {
            var number = value.GetProperty(name);
            if (number.ValueKind != JsonValueKind.Number || !number.TryGetInt64(out var count) || count < 0)
                throw Invalid();
            return count;
        }
        var counts = new DatabaseUpgradeQueueCounters(
            Count(details, "activeMessageCount"), Count(details, "scheduledMessageCount"),
            Count(details, "transferMessageCount"), Count(details, "transferDeadLetterMessageCount"),
            Count(details, "deadLetterMessageCount"), Count(properties, "messageCount"));
        AssertCounters(counts);
        var configuration = JsonNode.Parse(properties.GetRawText())!.AsObject();
        foreach (var name in new[] { "createdAt", "updatedAt", "accessedAt", "sizeInBytes", "messageCount", "countDetails" })
            configuration.Remove(name);
        configuration["status"] = "Active";
        return new(resourceId, created.ToString("O", CultureInfo.InvariantCulture),
            Fingerprint(JsonSerializer.SerializeToElement(configuration)), counts);
    }

    public static void AssertState(JsonElement queue, DatabaseUpgradeQueueQuarantineState expected)
    {
        if (ReadState(queue, expected.ResourceId, "ReceiveDisabled") != expected)
            throw new InvalidOperationException(
                "UpgradeQueueQuarantineMismatch: exact queue creation, configuration and per-queue quarantine counts changed.");
    }

    public static DatabaseUpgradeQueueQuarantineObservation Observation(DatabaseUpgradeQueueQuarantineCheck check)
    {
        var baseline = AssertBaseline(check.Manifest);
        if (check.Phase is not ("SqlBefore" or "SqlAfter"))
            throw Invalid();
        var observation = new DatabaseUpgradeQueueQuarantineObservation(1,
            DatabaseUpgradeQueueQuarantineObservation.CountOnly, check.Manifest.PlanFingerprint,
            check.Manifest.UpgradeSourceFingerprint, Fingerprint(JsonSerializer.SerializeToElement(baseline)),
            DateTimeOffset.UtcNow.ToString("O"), check.Phase);
        AssertObservation(observation, check.Manifest, check.Phase);
        return observation;
    }

    public static void AssertObservation(DatabaseUpgradeQueueQuarantineObservation observation,
        DatabaseUpgradeManifest manifest, string phase)
    {
        var baseline = AssertBaseline(manifest);
        observation.AssertValid(phase);
        if (observation.PlanFingerprint != manifest.PlanFingerprint ||
            observation.UpgradeSourceFingerprint != manifest.UpgradeSourceFingerprint ||
            observation.BaselineFingerprint != Fingerprint(JsonSerializer.SerializeToElement(baseline)) ||
            string.CompareOrdinal(observation.ObservedAtUtc, baseline.ObservedAtUtc) < 0)
            throw Invalid();
    }

    // Matches the existing PowerShell ordinal-key canonical JSON without changing any historical hash contract.
    public static string Fingerprint(JsonElement value)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
            Write(writer, value);
        return "sha256:" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream.ToArray())).ToLowerInvariant();
    }

    private static void Write(Utf8JsonWriter writer, JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            writer.WriteStartObject();
            foreach (var property in value.EnumerateObject().OrderBy(property => property.Name, StringComparer.Ordinal))
            {
                writer.WritePropertyName(property.Name);
                Write(writer, property.Value);
            }
            writer.WriteEndObject();
        }
        else if (value.ValueKind == JsonValueKind.Array)
        {
            writer.WriteStartArray();
            foreach (var item in value.EnumerateArray()) Write(writer, item);
            writer.WriteEndArray();
        }
        else value.WriteTo(writer);
    }

    private static InvalidOperationException Invalid() => new(
        "UpgradeQueueQuarantineInvalid: an immutable source-only Plan baseline and exact nonnegative counters with no executable or forwarded work are required.");
}
