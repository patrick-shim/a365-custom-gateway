using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Azure.Core;
using Gateway.DatabaseMigrator;

namespace Gateway.Tooling.Tests;

public sealed class MaintenanceArmIdentityTests
{
    [Theory]
    [InlineData("Running", false)]
    [InlineData("Running", true)]
    [InlineData("RunningAtMaxScale", false)]
    [InlineData("RunningAtMaxScale", true)]
    public async Task PrivateObserverAcceptsExactResourcesRegardlessOfArmPrefixCasing(
        string revisionState, bool lowerCase)
    {
        using var fixture = new PlatformFixture(lowerCase);
        fixture.Sentinel["properties"]!["runningState"] = revisionState;

        await fixture.ObserveAsync();

        Assert.Equal(9, fixture.Handler.Requests.Count);
        Assert.Equal(9, fixture.Credential.Requests);
        Assert.Equal(fixture.ObservedId(fixture.Contract.ApiResourceId), fixture.Api["id"]!.GetValue<string>());
        Assert.Equal("Running", fixture.SentinelReplicas["value"]![0]!["properties"]!["runningState"]!.GetValue<string>());
    }

    [Fact]
    public void OriginalRevisionBindingAcceptsObservedArmCasingButRejectsDuplicateAliases()
    {
        using var fixture = new PlatformFixture(true);
        var observed = fixture.Originals.Select(PlatformFixture.LowerPrefix).ToArray();
        DatabaseUpgradePlatformObserver.AssertContract(fixture.Contract, observed);

        Assert.Throws<ArgumentException>(() => DatabaseUpgradePlatformObserver.AssertContract(
            fixture.Contract, [.. observed, fixture.Originals[0]]));
        Assert.Throws<ArgumentException>(() => DatabaseUpgradePlatformObserver.AssertContract(
            fixture.Contract, [observed[0], observed[1] + "/../unreviewed"]));
    }

    [Fact]
    public void CanonicalControlBindingsAreNotRewrittenToMatchProviderSpelling()
    {
        using var fixture = new PlatformFixture(true);
        var different = fixture.Contract with { ApiResourceId = PlatformFixture.LowerPrefix(fixture.Contract.ApiResourceId) };

        Assert.NotEqual(DatabaseUpgradePlatformObserver.Fingerprint(fixture.Contract),
            DatabaseUpgradePlatformObserver.Fingerprint(different));
        Assert.Throws<ArgumentException>(() => DatabaseUpgradePlatformObserver.AssertContract(different));
    }

    [Theory]
    [InlineData("foreign-api")]
    [InlineData("foreign-queue")]
    [InlineData("foreign-revision")]
    [InlineData("foreign-sentinel")]
    [InlineData("missing-original")]
    [InlineData("duplicate-revision-alias")]
    [InlineData("truncated-inventory")]
    [InlineData("source-spelling")]
    [InlineData("ownership")]
    [InlineData("image")]
    [InlineData("plan-spelling")]
    [InlineData("revision-stopped")]
    [InlineData("revision-unknown-spelling")]
    [InlineData("replica-max-scale")]
    [InlineData("replica-not-ready")]
    [InlineData("replica-not-started")]
    [InlineData("foreign-replica")]
    [InlineData("duplicate-replica-alias")]
    public async Task PrivateObserverStillRejectsUnprovenClosureAndChangedBindings(string invalid)
    {
        using var fixture = new PlatformFixture(true);
        var replica = fixture.SentinelReplicas["value"]![0]!;
        switch (invalid)
        {
            case "foreign-api":
                fixture.Api["id"] = fixture.ObservedId(fixture.Contract.ApiResourceId + "-other");
                break;
            case "foreign-queue":
                fixture.Responses[fixture.Contract.ProvisioningQueueResourceId]["id"] =
                    fixture.ObservedId(fixture.Contract.ProtectionQueueResourceId);
                break;
            case "foreign-revision":
                fixture.WorkerRevisions["value"]![0]!["id"] =
                    fixture.ObservedId(fixture.Contract.WorkerResourceId + "-other/revisions/worker-old");
                break;
            case "foreign-sentinel":
                fixture.Sentinel["id"] = fixture.ObservedId(fixture.SentinelId + "-other");
                break;
            case "missing-original":
                fixture.WorkerRevisions["value"]![0]!["id"] =
                    fixture.ObservedId(fixture.Contract.WorkerResourceId + "/revisions/worker-other");
                break;
            case "duplicate-revision-alias":
                var revisionAlias = fixture.WorkerRevisions["value"]![0]!.DeepClone();
                revisionAlias["id"] = fixture.Originals[1];
                fixture.WorkerRevisions["value"]!.AsArray().Add(revisionAlias);
                break;
            case "truncated-inventory":
                fixture.WorkerRevisions["nextLink"] = "https://unfollowed.synthetic.invalid/";
                break;
            case "source-spelling":
                fixture.Api["tags"]!["bootstrapSourceFingerprint"] = ToolingFixture.OriginalSource.ToUpperInvariant();
                break;
            case "ownership":
                fixture.Api["tags"]!["bootstrapOwnershipId"] = "99999999-9999-4999-8999-999999999999";
                break;
            case "image":
                fixture.Sentinel["properties"]!["template"]!["containers"]![0]!["image"] =
                    "toolingfixture.azurecr.io/gateway-api@" + ToolingFixture.Hash('f');
                break;
            case "plan-spelling":
                fixture.Sentinel["properties"]!["template"]!["containers"]![0]!["env"]![1]!["value"] =
                    fixture.Binding.PlanFingerprint.ToUpperInvariant();
                break;
            case "revision-stopped":
                fixture.Sentinel["properties"]!["runningState"] = "Stopped";
                break;
            case "revision-unknown-spelling":
                fixture.Sentinel["properties"]!["runningState"] = "running";
                break;
            case "replica-max-scale":
                replica["properties"]!["runningState"] = "RunningAtMaxScale";
                break;
            case "replica-not-ready":
                replica["properties"]!["containers"]![0]!["ready"] = false;
                break;
            case "replica-not-started":
                replica["properties"]!["containers"]![0]!["started"] = false;
                break;
            case "foreign-replica":
                replica["id"] = fixture.ObservedId(fixture.SentinelId + "-other/replicas/replica-one");
                break;
            case "duplicate-replica-alias":
                fixture.Sentinel["properties"]!["replicas"] = 2;
                var replicaAlias = replica.DeepClone();
                replicaAlias["id"] = fixture.SentinelId + "/replicas/replica-one";
                replicaAlias["properties"]!["containers"]![0]!["containerId"] = "synthetic-container-two";
                fixture.SentinelReplicas["value"]!.AsArray().Add(replicaAlias);
                break;
            default:
                throw new InvalidOperationException("Unknown finite fixture mutation.");
        }

        var failure = await Assert.ThrowsAsync<InvalidOperationException>(fixture.ObserveAsync);
        Assert.StartsWith("UpgradeCutoverPlatformUnknown:", failure.Message, StringComparison.Ordinal);
    }

    private sealed class PlatformFixture : IDisposable
    {
        private readonly bool lowerCase;
        private readonly HttpClient client;
        public DatabaseUpgradeCutoverContract Contract { get; } = ToolingFixture.Manifest().Cutover!;
        public DatabaseUpgradeApiMaintenanceBinding Binding { get; }
        public string[] Originals { get; }
        public string SentinelId { get; }
        public Dictionary<string, JsonObject> Responses { get; } = new(StringComparer.OrdinalIgnoreCase);
        public FiniteArmHandler Handler { get; }
        public SyntheticCredential Credential { get; } = new();
        public JsonObject Api => Responses[Contract.ApiResourceId];
        public JsonObject WorkerRevisions => Responses[Contract.WorkerResourceId + "/revisions"];
        public JsonObject Sentinel => Responses[Contract.ApiResourceId + "/revisions"]["value"]![1]!.AsObject();
        public JsonObject SentinelReplicas => Responses[SentinelId + "/replicas"];

        public PlatformFixture(bool lowerCase)
        {
            this.lowerCase = lowerCase;
            var plan = ToolingFixture.Hash('e');
            Binding = new(plan, ToolingFixture.Hash('c'),
                DatabaseUpgradePlatformObserver.ComputeCutoverId(plan, DatabaseUpgradePlatformObserver.Fingerprint(Contract)),
                "toolingfixture.azurecr.io/gateway-api@" + ToolingFixture.Hash('a'));
            Originals = [Contract.ApiResourceId + "/revisions/api-old", Contract.WorkerResourceId + "/revisions/worker-old"];
            SentinelId = Contract.ApiResourceId + "/revisions/" +
                DatabaseUpgradePlatformObserver.ApiSentinelRevisionName(Contract.ApiResourceId, Binding);
            foreach (var queue in new[] { Contract.ProvisioningQueueResourceId, Contract.ProtectionQueueResourceId })
                Responses.Add(queue, new() { ["id"] = ObservedId(queue), ["properties"] = new JsonObject { ["status"] = "ReceiveDisabled" } });
            Responses.Add(Contract.ApiResourceId, App(Contract.ApiResourceId, true));
            Responses.Add(Contract.WorkerResourceId, App(Contract.WorkerResourceId, false));
            Responses.Add(Contract.WorkerResourceId + "/revisions", List(Revision(Originals[1], false, 0)));
            var sentinel = Revision(SentinelId, true, 1);
            sentinel["name"] = DatabaseUpgradePlatformObserver.ApiSentinelRevisionName(Contract.ApiResourceId, Binding);
            sentinel["properties"]!["healthState"] = "Healthy";
            sentinel["properties"]!["runningState"] = "Running";
            sentinel["properties"]!["template"] = SentinelTemplate();
            Responses.Add(Contract.ApiResourceId + "/revisions", List(Revision(Originals[0], false, 0), sentinel));
            foreach (var revision in Originals) Responses.Add(revision + "/replicas", List());
            Responses.Add(SentinelId + "/replicas", List(new JsonObject
            {
                ["id"] = ObservedId(SentinelId + "/replicas/replica-one"), ["name"] = "replica-one",
                ["properties"] = new JsonObject
                {
                    ["runningState"] = "Running",
                    ["containers"] = new JsonArray(new JsonObject
                    {
                        ["name"] = "api", ["containerId"] = "synthetic-container-one",
                        ["ready"] = true, ["started"] = true
                    })
                }
            }));
            Handler = new(Responses);
            client = new(Handler);
        }

        public static string LowerPrefix(string id) => id
            .Replace("/resourceGroups/", "/resourcegroups/", StringComparison.Ordinal)
            .Replace("/providers/Microsoft.App/containerApps/", "/providers/microsoft.app/containerapps/", StringComparison.Ordinal)
            .Replace("/providers/Microsoft.ServiceBus/", "/providers/microsoft.servicebus/", StringComparison.Ordinal);

        public string ObservedId(string id) => lowerCase ? LowerPrefix(id) : id;

        public Task ObserveAsync() => DatabaseUpgradePlatformObserver.AssertWithTransportAsync(Contract,
            ToolingFixture.Ownership, ToolingFixture.OriginalSource, client, Credential, Originals, apiMaintenance: Binding);

        private JsonObject App(string id, bool ingress) => new()
        {
            ["id"] = ObservedId(id),
            ["tags"] = new JsonObject
            {
                ["bootstrapOwnershipId"] = ToolingFixture.Ownership,
                ["bootstrapSourceFingerprint"] = ToolingFixture.OriginalSource
            },
            ["properties"] = new JsonObject
            {
                ["provisioningState"] = "Succeeded",
                ["configuration"] = new JsonObject
                {
                    ["activeRevisionsMode"] = "Multiple",
                    ["ingress"] = ingress ? new JsonObject { ["targetPort"] = 8080, ["transport"] = "auto" } : null
                }
            }
        };

        private JsonObject Revision(string id, bool active, int replicas) => new()
        {
            ["id"] = ObservedId(id),
            ["properties"] = new JsonObject { ["active"] = active, ["replicas"] = replicas }
        };

        private JsonObject SentinelTemplate()
        {
            var probes = new JsonArray();
            foreach (var type in new[] { "Startup", "Liveness", "Readiness" })
                probes.Add(new JsonObject
                {
                    ["type"] = type, ["httpGet"] = new JsonObject { ["path"] = "/health/maintenance", ["port"] = 8080 }
                });
            var environment = new JsonArray();
            foreach (var entry in new Dictionary<string, string>
            {
                ["MaintenanceCutover__Phase"] = "PreSchemaClosed",
                ["MaintenanceCutover__PlanFingerprint"] = Binding.PlanFingerprint,
                ["MaintenanceCutover__CandidateSourceFingerprint"] = Binding.CandidateSourceFingerprint,
                ["MaintenanceCutover__CutoverId"] = Binding.CutoverId
            })
                environment.Add(new JsonObject { ["name"] = entry.Key, ["value"] = entry.Value });
            return new JsonObject
            {
                ["containers"] = new JsonArray(new JsonObject
                {
                    ["name"] = "api", ["image"] = Binding.ApiImage, ["env"] = environment, ["probes"] = probes
                })
            };
        }

        private static JsonObject List(params JsonNode?[] values) => new() { ["value"] = new JsonArray(values) };
        public void Dispose() => client.Dispose();
    }

    private sealed class FiniteArmHandler(IReadOnlyDictionary<string, JsonObject> responses) : HttpMessageHandler
    {
        public List<string> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var uri = request.RequestUri ?? throw new InvalidOperationException("A fixture URI is required.");
            var version = uri.AbsolutePath.Contains("/queues/", StringComparison.OrdinalIgnoreCase) ? "2024-01-01" : "2025-01-01";
            if (request.Method != HttpMethod.Get || uri.Scheme != "https" || uri.Host != "management.azure.com" ||
                uri.Query != "?api-version=" + version || uri.Fragment.Length != 0 || uri.UserInfo.Length != 0 ||
                request.Headers.Authorization?.Scheme != "Bearer" || request.Headers.Authorization.Parameter != "synthetic-arm-token" ||
                !responses.TryGetValue(uri.AbsolutePath, out var response))
                throw new InvalidOperationException("Unscripted ARM request is forbidden.");
            Requests.Add(uri.AbsolutePath + uri.Query);
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(response.ToJsonString(), Encoding.UTF8, "application/json")
            });
        }
    }

    private sealed class SyntheticCredential : TokenCredential
    {
        public int Requests { get; private set; }

        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            Assert.Equal(["https://management.azure.com/.default"], requestContext.Scopes);
            Requests++;
            return new("synthetic-arm-token", DateTimeOffset.UtcNow.AddMinutes(5));
        }

        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }
}
