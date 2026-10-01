using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Gateway.DatabaseMigrator;

public sealed record DatabaseUpgradeApiMaintenanceBinding(
    string PlanFingerprint, string CandidateSourceFingerprint, string CutoverId, string ApiImage);

public static partial class DatabaseUpgradePlatformObserver
{
    public static string ComputeCutoverId(string planFingerprint, string boundaryFingerprint)
    {
        var canonical = new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["purpose"] = "GatewayUpgradeCutover",
            ["planFingerprint"] = planFingerprint,
            ["boundaryFingerprint"] = boundaryFingerprint
        };
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(canonical))));
        return Guid.ParseExact(hash[..32], "N").ToString("D");
    }

    public static void AssertApiMaintenanceBinding(DatabaseUpgradeCutoverContract contract,
        DatabaseUpgradeApiMaintenanceBinding binding)
    {
        if (!Exact(binding.PlanFingerprint, "sha256:[0-9a-f]{64}") ||
            !Exact(binding.CandidateSourceFingerprint, "sha256:[0-9a-f]{64}") ||
            !Guid.TryParseExact(binding.CutoverId, "D", out var cutoverId) || cutoverId == Guid.Empty ||
            binding.CutoverId != ComputeCutoverId(binding.PlanFingerprint, Fingerprint(contract)) ||
            !Exact(binding.ApiImage, @"[a-z0-9]+\.azurecr\.io/[a-z0-9]+(?:[._/-][a-z0-9]+)*@sha256:[0-9a-f]{64}"))
            throw new ArgumentException("UpgradeCutover: an exact Plan/source/image-bound API maintenance identity is required.");
    }

    public static string ApiSentinelRevisionName(string apiResourceId, DatabaseUpgradeApiMaintenanceBinding binding) =>
        apiResourceId.Split('/')[^1] + "--upg-" + binding.PlanFingerprint.Substring(7, 16) + "-api-pre";

    private sealed record ApiSentinelObservation(
        IReadOnlyList<string> RevisionResourceIds, string ActiveRevisionResourceId, string ContainerName, int ReplicaCount);

    private static ApiSentinelObservation AssertApiSentinel(JsonElement app, JsonElement observedRevisions,
        DatabaseUpgradeCutoverContract contract, DatabaseUpgradeApiMaintenanceBinding binding,
        string ownership, string originalSource, IReadOnlyList<string>? originals)
    {
        AssertAppCore(app, contract.ApiResourceId, true, contract.IngressRuleName, ownership, originalSource, requireDeny: false);
        var configuration = Property(Property(app, "properties"), "configuration");
        var ingress = Property(configuration, "ingress");
        if (Property(ingress, "targetPort").ValueKind != JsonValueKind.Number ||
            !Property(ingress, "targetPort").TryGetInt32(out var targetPort) || targetPort is < 1 or > 65535)
            throw Unknown();
        var sentinelId = contract.ApiResourceId + "/revisions/" + ApiSentinelRevisionName(contract.ApiResourceId, binding);
        var revisions = CompleteList(observedRevisions);
        if (revisions.GetArrayLength() is < 1 or > 1000) throw Unknown();
        var identities = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        int? activeReplicas = null;
        string? containerName = null;
        foreach (var revision in revisions.EnumerateArray())
        {
            var id = Text(revision, "id");
            var properties = Property(revision, "properties");
            if (!RevisionOf(id, contract.ApiResourceId) || !identities.Add(id!) ||
                Property(properties, "replicas").ValueKind != JsonValueKind.Number ||
                !Property(properties, "replicas").TryGetInt32(out var replicas))
                throw Unknown();
            if (!ResourceIdEquals(id, sentinelId))
            {
                if (Property(properties, "active").ValueKind != JsonValueKind.False || replicas != 0) throw Unknown();
                continue;
            }
            if (Text(revision, "name") != ApiSentinelRevisionName(contract.ApiResourceId, binding) ||
                Property(properties, "active").ValueKind != JsonValueKind.True || replicas is < 1 or > 1000 ||
                Text(properties, "healthState") != "Healthy" ||
                Text(properties, "runningState") is not ("Running" or "RunningAtMaxScale"))
                throw Unknown();
            var revisionTemplate = Property(properties, "template");
            containerName = AssertSentinelTemplate(revisionTemplate, binding, targetPort);
            activeReplicas = replicas;
        }
        if (activeReplicas is null || containerName is null || originals?.Where(id => RevisionOf(id, contract.ApiResourceId))
                .Any(id => !identities.Contains(id)) == true)
            throw Unknown();
        return new(identities.ToArray(), sentinelId, containerName, activeReplicas.Value);
    }

    private static string AssertSentinelTemplate(JsonElement template, DatabaseUpgradeApiMaintenanceBinding binding, int targetPort)
    {
        Unique(template);
        foreach (var name in new[] { "initContainers", "volumes", "serviceBinds" }) AssertAbsentOrEmptyArray(template, name);
        var containers = Property(template, "containers");
        if (containers.ValueKind != JsonValueKind.Array || containers.GetArrayLength() != 1) throw Unknown();
        var container = containers[0];
        var allowedContainerFields = new[] { "name", "image", "env", "resources", "probes", "command", "args", "volumeMounts" };
        if (container.ValueKind != JsonValueKind.Object ||
            container.EnumerateObject().Any(field => !allowedContainerFields.Contains(field.Name, StringComparer.Ordinal)) ||
            !Exact(Text(container, "name"), "[a-z0-9][a-z0-9-]{0,62}") || Text(container, "image") != binding.ApiImage)
            throw Unknown();
        foreach (var name in new[] { "command", "args", "volumeMounts" }) AssertAbsentOrEmptyArray(container, name);
        var env = Property(container, "env");
        if (env.ValueKind != JsonValueKind.Array || env.GetArrayLength() is < 4 or > 512) throw Unknown();
        var pins = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["MaintenanceCutover__Phase"] = "PreSchemaClosed",
            ["MaintenanceCutover__PlanFingerprint"] = binding.PlanFingerprint,
            ["MaintenanceCutover__CandidateSourceFingerprint"] = binding.CandidateSourceFingerprint,
            ["MaintenanceCutover__CutoverId"] = binding.CutoverId
        };
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var variable in env.EnumerateArray())
        {
            var name = Text(variable, "name");
            if (string.IsNullOrWhiteSpace(name) || !seen.Add(name.Replace("__", ":", StringComparison.Ordinal))) throw Unknown();
            var normalized = name.Replace("__", ":", StringComparison.Ordinal);
            if (!normalized.Equals("MaintenanceCutover", StringComparison.OrdinalIgnoreCase) &&
                !normalized.StartsWith("MaintenanceCutover:", StringComparison.OrdinalIgnoreCase)) continue;
            if (!pins.TryGetValue(name, out var expected) || variable.EnumerateObject().Count() != 2 ||
                Text(variable, "value") != expected)
                throw Unknown();
        }
        if (pins.Keys.Any(name => !seen.Contains(name.Replace("__", ":", StringComparison.Ordinal)))) throw Unknown();
        var probes = Property(container, "probes");
        if (probes.ValueKind != JsonValueKind.Array || probes.GetArrayLength() != 3) throw Unknown();
        var probeTypes = new HashSet<string>(StringComparer.Ordinal);
        foreach (var probe in probes.EnumerateArray())
        {
            var type = Text(probe, "type");
            if (type is not ("Startup" or "Liveness" or "Readiness") || !probeTypes.Add(type)) throw Unknown();
            AssertMaintenanceProbe(probe, targetPort);
        }
        return Text(container, "name")!;
    }

    private static void AssertMaintenanceProbe(JsonElement probe, int targetPort)
    {
        var allowedProbeFields = new[]
        {
            "type", "httpGet", "initialDelaySeconds", "periodSeconds", "timeoutSeconds",
            "failureThreshold", "successThreshold", "terminationGracePeriodSeconds"
        };
        if (probe.ValueKind != JsonValueKind.Object ||
            probe.EnumerateObject().Any(field => !allowedProbeFields.Contains(field.Name, StringComparer.Ordinal)))
            throw Unknown();
        foreach (var timing in probe.EnumerateObject().Where(field => field.Name is not ("type" or "httpGet")))
            if (timing.Value.ValueKind != JsonValueKind.Number || !timing.Value.TryGetInt32(out var value) ||
                value < (timing.Name == "initialDelaySeconds" ? 0 : 1))
                throw Unknown();
        var http = Property(probe, "httpGet");
        if (http.ValueKind != JsonValueKind.Object ||
            http.EnumerateObject().Any(field => field.Name is not ("path" or "port" or "scheme" or "httpHeaders")) ||
            Text(http, "path") != "/health/maintenance" ||
            Property(http, "port").ValueKind != JsonValueKind.Number ||
            !Property(http, "port").TryGetInt32(out var port) || port != targetPort ||
            http.TryGetProperty("scheme", out var scheme) &&
                (scheme.ValueKind != JsonValueKind.String || scheme.GetString() != "HTTP"))
            throw Unknown();
        AssertAbsentOrEmptyArray(http, "httpHeaders");
    }

    private static void AssertReadyApiReplicas(JsonElement observed, string revisionId, string containerName, int expectedCount)
    {
        var replicas = CompleteList(observed);
        if (replicas.GetArrayLength() != expectedCount) throw Unknown();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var containerIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var replica in replicas.EnumerateArray())
        {
            var id = Text(replica, "id");
            var name = Text(replica, "name");
            if (!Exact(name, "[a-z0-9-]+") || !ResourceIdEquals(id, revisionId + "/replicas/" + name) || !seen.Add(id))
                throw Unknown();
            var properties = Property(replica, "properties");
            if (Text(properties, "runningState") != "Running") throw Unknown();
            AssertAbsentOrEmptyArray(properties, "initContainers");
            var containers = Property(properties, "containers");
            if (containers.ValueKind != JsonValueKind.Array || containers.GetArrayLength() != 1) throw Unknown();
            var container = containers[0];
            var containerId = Text(container, "containerId");
            if (Text(container, "name") != containerName || string.IsNullOrWhiteSpace(containerId) ||
                !containerIds.Add(containerId) || Property(container, "ready").ValueKind != JsonValueKind.True ||
                Property(container, "started").ValueKind != JsonValueKind.True)
                throw Unknown();
        }
    }

    private static void AssertAbsentOrEmptyArray(JsonElement value, string name)
    {
        if (value.TryGetProperty(name, out var found) && found.ValueKind != JsonValueKind.Null &&
            (found.ValueKind != JsonValueKind.Array || found.GetArrayLength() != 0))
            throw Unknown();
    }
}
