using System.Net.Http.Headers;
using System.Net;
using System.Diagnostics.CodeAnalysis;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Azure.Core;
using Azure.Identity;
using Gateway.Infrastructure.Persistence;

namespace Gateway.DatabaseMigrator;

public sealed record DatabaseUpgradeCutoverContract(
    int SchemaVersion,
    string ApiResourceId,
    string WorkerResourceId,
    string ProvisioningQueueResourceId,
    string ProtectionQueueResourceId,
    string IngressRuleName,
    int TimeoutSeconds);

public static partial class DatabaseUpgradePlatformObserver
{
    private const string AppVersion = "2025-01-01";
    private const string QueueVersion = "2024-01-01";
    private const string ResourcePrefix = @"/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/resourceGroups/[A-Za-z0-9_.()-]+/providers/";

    public static string Fingerprint(DatabaseUpgradeCutoverContract contract)
    {
        var fields = new SortedDictionary<string, object>(StringComparer.Ordinal)
        {
            [nameof(contract.SchemaVersion)] = contract.SchemaVersion,
            [nameof(contract.ApiResourceId)] = contract.ApiResourceId,
            [nameof(contract.WorkerResourceId)] = contract.WorkerResourceId,
            [nameof(contract.ProvisioningQueueResourceId)] = contract.ProvisioningQueueResourceId,
            [nameof(contract.ProtectionQueueResourceId)] = contract.ProtectionQueueResourceId,
            [nameof(contract.IngressRuleName)] = contract.IngressRuleName,
            [nameof(contract.TimeoutSeconds)] = contract.TimeoutSeconds
        };
        return "sha256:" + Convert.ToHexString(SHA256.HashData(
            Encoding.UTF8.GetBytes(JsonSerializer.Serialize(fields)))).ToLowerInvariant();
    }

    public static void AssertContract(DatabaseUpgradeCutoverContract? contract,
        IReadOnlyList<string>? originalRevisionResourceIds = null)
    {
        if (contract is null || contract.SchemaVersion != 1 ||
            contract.IngressRuleName != "gateway-maintenance-deny" || contract.TimeoutSeconds != 600 ||
            !Exact(contract.ApiResourceId, ResourcePrefix + @"Microsoft\.App/containerApps/[a-z0-9-]+") ||
            !Exact(contract.WorkerResourceId, ResourcePrefix + @"Microsoft\.App/containerApps/[a-z0-9-]+") ||
            contract.ApiResourceId == contract.WorkerResourceId ||
            !Exact(contract.ProvisioningQueueResourceId, ResourcePrefix + @"Microsoft\.ServiceBus/namespaces/[a-z0-9-]+/queues/gateway-provisioning-v3") ||
            !Exact(contract.ProtectionQueueResourceId, ResourcePrefix + @"Microsoft\.ServiceBus/namespaces/[a-z0-9-]+/queues/gateway-protection-admin-v1"))
            throw new ArgumentException("UpgradeCutover: the typed platform binding is missing or malformed.");

        var resourceGroup = contract.ApiResourceId[..contract.ApiResourceId.IndexOf("/providers/", StringComparison.Ordinal)];
        if (new[] { contract.WorkerResourceId, contract.ProvisioningQueueResourceId, contract.ProtectionQueueResourceId }
                .Any(id => !id.StartsWith(resourceGroup + "/providers/", StringComparison.Ordinal)) ||
            contract.ProvisioningQueueResourceId[..contract.ProvisioningQueueResourceId.LastIndexOf("/queues/", StringComparison.Ordinal)] !=
            contract.ProtectionQueueResourceId[..contract.ProtectionQueueResourceId.LastIndexOf("/queues/", StringComparison.Ordinal)])
            throw new ArgumentException("UpgradeCutover: exact same-scope resources are required.");
        if (originalRevisionResourceIds is not null && (originalRevisionResourceIds.Count is < 2 or > 1000 ||
            originalRevisionResourceIds.Distinct(StringComparer.OrdinalIgnoreCase).Count() != originalRevisionResourceIds.Count ||
            originalRevisionResourceIds.Any(id => !RevisionOf(id, contract.ApiResourceId) && !RevisionOf(id, contract.WorkerResourceId)) ||
            !originalRevisionResourceIds.Any(id => RevisionOf(id, contract.ApiResourceId)) ||
            !originalRevisionResourceIds.Any(id => RevisionOf(id, contract.WorkerResourceId))))
            throw new ArgumentException("UpgradeCutover: supplied original revision identities must cover both exact workloads.");
    }

    public static async Task<DatabaseUpgradeQueueQuarantineObservation?> AssertPrivateAsync(DatabaseUpgradeCutoverContract contract,
        string deploymentOwnershipId, string originalAcceptedSourceFingerprint,
        IReadOnlyList<string>? originalRevisionResourceIds = null, CancellationToken cancellationToken = default,
        DatabaseUpgradeApiMaintenanceBinding? apiMaintenance = null, DatabaseUpgradeQueueQuarantineCheck? quarantine = null)
    {
        AssertContract(contract, originalRevisionResourceIds);
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("IDENTITY_ENDPOINT")))
            throw Unknown();
        var credential = new ManagedIdentityCredential();
        using var handler = new HttpClientHandler { AllowAutoRedirect = false };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) };
        return await AssertWithTransportAsync(contract, deploymentOwnershipId, originalAcceptedSourceFingerprint,
            client, credential, originalRevisionResourceIds, cancellationToken, apiMaintenance, quarantine);
    }

    // Only HTTP and token transport are replaceable; resource selection, requests and classification
    // remain fixed here. The private-job entry point always uses ManagedIdentityCredential.
    public static async Task<DatabaseUpgradeQueueQuarantineObservation?> AssertWithTransportAsync(DatabaseUpgradeCutoverContract contract,
        string deploymentOwnershipId, string originalAcceptedSourceFingerprint,
        HttpClient client, TokenCredential credential,
        IReadOnlyList<string>? originalRevisionResourceIds = null, CancellationToken cancellationToken = default,
        DatabaseUpgradeApiMaintenanceBinding? apiMaintenance = null, DatabaseUpgradeQueueQuarantineCheck? quarantine = null)
    {
        AssertContract(contract, originalRevisionResourceIds);
        var baseline = quarantine is null ? null : DatabaseUpgradeQueueQuarantine.AssertBaseline(quarantine.Manifest);
        if (quarantine is not null && (quarantine.Manifest.Cutover != contract ||
            quarantine.Manifest.DeploymentOwnershipId != deploymentOwnershipId ||
            quarantine.Manifest.OriginalAcceptedSourceFingerprint != originalAcceptedSourceFingerprint))
            throw Unknown();
        if (apiMaintenance is not null) AssertApiMaintenanceBinding(contract, apiMaintenance);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(contract.TimeoutSeconds));
        async Task<JsonDocument> ReadAsync(string id, string version)
        {
            var token = await credential.GetTokenAsync(
                new TokenRequestContext(["https://management.azure.com/.default"]), deadline.Token);
            using var request = new HttpRequestMessage(HttpMethod.Get,
                "https://management.azure.com" + id + "?api-version=" + version);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            if (response.StatusCode != HttpStatusCode.OK || response.Content.Headers.ContentLength > 4 * 1024 * 1024)
                throw Unknown();
            await using var body = await response.Content.ReadAsStreamAsync(deadline.Token);
            using var bounded = new MemoryStream();
            var buffer = new byte[8192];
            int count;
            while ((count = await body.ReadAsync(buffer, deadline.Token)) != 0)
            {
                if (bounded.Length + count > 4 * 1024 * 1024) throw Unknown();
                bounded.Write(buffer, 0, count);
            }
            return JsonDocument.Parse(bounded.ToArray(), new JsonDocumentOptions { MaxDepth = 64 });
        }

        try
        {
            foreach (var queue in new[] { contract.ProvisioningQueueResourceId, contract.ProtectionQueueResourceId })
            {
                using var observed = await ReadAsync(queue, QueueVersion);
                AssertQueue(observed.RootElement, queue);
                if (baseline is not null)
                    DatabaseUpgradeQueueQuarantine.AssertState(observed.RootElement,
                        baseline.Queues.Single(state => state.ResourceId == queue));
            }
            foreach (var app in new[] { contract.ApiResourceId, contract.WorkerResourceId })
            {
                using var observed = await ReadAsync(app, AppVersion);
                if (app == contract.ApiResourceId && apiMaintenance is not null)
                {
                    using var apiRevisions = await ReadAsync(app + "/revisions", AppVersion);
                    if (CompleteList(apiRevisions.RootElement).EnumerateArray().Any(revision =>
                        Property(Property(revision, "properties"), "active").ValueKind == JsonValueKind.True))
                    {
                        var sentinel = AssertApiSentinel(observed.RootElement, apiRevisions.RootElement, contract,
                            apiMaintenance, deploymentOwnershipId, originalAcceptedSourceFingerprint, originalRevisionResourceIds);
                        foreach (var revision in sentinel.RevisionResourceIds)
                        {
                            using var replicas = await ReadAsync(revision + "/replicas", AppVersion);
                            if (ResourceIdEquals(revision, sentinel.ActiveRevisionResourceId))
                                AssertReadyApiReplicas(replicas.RootElement, revision, sentinel.ContainerName, sentinel.ReplicaCount);
                            else
                                AssertNoReplicas(replicas.RootElement);
                        }
                        continue;
                    }
                    AssertApp(observed.RootElement, app, true, contract.IngressRuleName,
                        deploymentOwnershipId, originalAcceptedSourceFingerprint);
                    foreach (var revision in AssertRevisions(apiRevisions.RootElement, app, originalRevisionResourceIds))
                    {
                        using var replicas = await ReadAsync(revision + "/replicas", AppVersion);
                        AssertNoReplicas(replicas.RootElement);
                    }
                    continue;
                }
                AssertApp(observed.RootElement, app, app == contract.ApiResourceId, contract.IngressRuleName,
                    deploymentOwnershipId, originalAcceptedSourceFingerprint);
                using var revisions = await ReadAsync(app + "/revisions", AppVersion);
                var identities = AssertRevisions(revisions.RootElement, app, originalRevisionResourceIds);
                foreach (var revision in identities)
                {
                    using var replicas = await ReadAsync(revision + "/replicas", AppVersion);
                    AssertNoReplicas(replicas.RootElement);
                }
            }
            return quarantine is null ? null : DatabaseUpgradeQueueQuarantine.Observation(quarantine);
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException or OperationCanceledException or Azure.Identity.AuthenticationFailedException or
                                       InvalidOperationException or KeyNotFoundException or FormatException)
        {
            throw Unknown();
        }
    }

    public static void AssertQueue(JsonElement observed, string resourceId)
    {
        Unique(observed);
        if (!ResourceIdEquals(Text(observed, "id"), resourceId) ||
            Text(Property(observed, "properties"), "status") != "ReceiveDisabled")
            throw Unknown();
    }

    public static void AssertApp(JsonElement observed, string resourceId, bool ingressRequired, string ruleName,
        string deploymentOwnershipId, string originalAcceptedSourceFingerprint)
        => AssertAppCore(observed, resourceId, ingressRequired, ruleName, deploymentOwnershipId,
            originalAcceptedSourceFingerprint, requireDeny: true);

    private static void AssertAppCore(JsonElement observed, string resourceId, bool ingressRequired, string ruleName,
        string deploymentOwnershipId, string originalAcceptedSourceFingerprint, bool requireDeny)
    {
        Unique(observed);
        if (!ResourceIdEquals(Text(observed, "id"), resourceId) ||
            string.IsNullOrWhiteSpace(deploymentOwnershipId) || string.IsNullOrWhiteSpace(originalAcceptedSourceFingerprint))
            throw Unknown();
        var tags = Property(observed, "tags");
        if (Text(tags, "bootstrapOwnershipId") != deploymentOwnershipId ||
            Text(tags, "bootstrapSourceFingerprint") != originalAcceptedSourceFingerprint)
            throw Unknown();
        var properties = Property(observed, "properties");
        if (Text(properties, "provisioningState") != "Succeeded") throw Unknown();
        var configuration = Property(properties, "configuration");
        if (Text(configuration, "activeRevisionsMode") != "Multiple") throw Unknown();
        if (configuration.TryGetProperty("dapr", out var dapr) && dapr.ValueKind != JsonValueKind.Null &&
            Property(dapr, "enabled").ValueKind != JsonValueKind.False)
            throw Unknown();
        if (!configuration.TryGetProperty("ingress", out var ingress) || ingress.ValueKind == JsonValueKind.Null)
        {
            if (ingressRequired) throw Unknown();
            return;
        }
        if (ingress.TryGetProperty("transport", out var transport) &&
            (transport.ValueKind != JsonValueKind.String ||
                (!string.Equals(transport.GetString(), "auto", StringComparison.OrdinalIgnoreCase) &&
                 !string.Equals(transport.GetString(), "http", StringComparison.OrdinalIgnoreCase) &&
                 !string.Equals(transport.GetString(), "http2", StringComparison.OrdinalIgnoreCase))))
            throw Unknown();
        if (ingress.TryGetProperty("additionalPortMappings", out var mappings) &&
            mappings.ValueKind != JsonValueKind.Null &&
            (mappings.ValueKind != JsonValueKind.Array || mappings.GetArrayLength() != 0))
            throw Unknown();
        if (!requireDeny) return;
        var rules = Property(ingress, "ipSecurityRestrictions");
        if (rules.ValueKind != JsonValueKind.Array || rules.GetArrayLength() != 1) throw Unknown();
        var rule = rules[0];
        if (rule.ValueKind != JsonValueKind.Object || rule.EnumerateObject().Count() != 4 ||
            Text(rule, "name") != ruleName || Text(rule, "description") != "Plan-bound gateway cutover" ||
            Text(rule, "action") != "Deny" ||
            Text(rule, "ipAddressRange") != "0.0.0.0/0")
            throw Unknown();
    }

    public static IReadOnlyList<string> AssertRevisions(JsonElement observed, string appId,
        IReadOnlyList<string>? originalRevisionResourceIds = null)
    {
        var revisions = CompleteList(observed);
        if (revisions.GetArrayLength() is < 1 or > 1000) throw Unknown();
        var identities = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var revision in revisions.EnumerateArray())
        {
            var id = Text(revision, "id");
            var properties = Property(revision, "properties");
            if (!RevisionOf(id, appId) || !identities.Add(id!) ||
                Property(properties, "active").ValueKind != JsonValueKind.False ||
                !Property(properties, "replicas").TryGetInt32(out var replicas) || replicas != 0)
                throw Unknown();
        }
        if (originalRevisionResourceIds?.Where(id => RevisionOf(id, appId)).Any(id => !identities.Contains(id)) == true)
            throw Unknown();
        return identities.ToArray();
    }

    public static void AssertNoReplicas(JsonElement observed)
    {
        if (CompleteList(observed).GetArrayLength() != 0) throw Unknown();
    }

    private static JsonElement CompleteList(JsonElement observed)
    {
        Unique(observed);
        if (observed.TryGetProperty("nextLink", out var next) &&
            next.ValueKind != JsonValueKind.Null &&
            (next.ValueKind != JsonValueKind.String || next.GetString() != ""))
            throw Unknown();
        var values = Property(observed, "value");
        if (values.ValueKind != JsonValueKind.Array) throw Unknown();
        return values;
    }

    private static JsonElement Property(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var found) ? found : throw Unknown();
    private static string? Text(JsonElement value, string name) =>
        Property(value, name).ValueKind == JsonValueKind.String ? Property(value, name).GetString() : null;
    private static bool Exact(string? value, string pattern) =>
        value is not null && !value.Contains("/../", StringComparison.Ordinal) &&
        !value.Contains("/./", StringComparison.Ordinal) &&
        Regex.IsMatch(value, @"\A" + pattern + @"\z", RegexOptions.CultureInvariant);
    internal static bool ResourceIdEquals([NotNullWhen(true)] string? actual, string expected) =>
        actual is not null && string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase);

    private static bool RevisionOf(string? id, string appId)
    {
        var prefix = appId + "/revisions/";
        return id is not null && id.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) &&
            Exact(id[prefix.Length..], "[a-z0-9-]+");
    }

    private static void Unique(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in value.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw Unknown();
                Unique(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
            foreach (var element in value.EnumerateArray()) Unique(element);
    }

    private static InvalidOperationException Unknown() => new(
        "UpgradeCutoverPlatformUnknown: private managed-identity readback did not prove an exact PreSchemaClosed API sentinel " +
        "or denied zero-replica API, receive-disabled queues and inactive zero-replica excluded revisions. " +
        "Source-only preservation additionally requires exact Plan-bound normal-DLQ quarantine counts and zero executable/transfer work. " +
        "No schema migration or checkpoint repair is authorized.");
}
