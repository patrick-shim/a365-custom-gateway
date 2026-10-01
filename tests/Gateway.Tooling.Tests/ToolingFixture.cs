using System.Text.Json;
using System.Text.RegularExpressions;
using Gateway.DatabaseMigrator;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Services;

namespace Gateway.Tooling.Tests;

internal static class ToolingFixture
{
    internal const string Ownership = "11111111-1111-4111-8111-111111111111";
    internal const string Subscription = "22222222-2222-4222-8222-222222222222";
    internal const string ApiPrincipal = "33333333-3333-4333-8333-333333333333";
    internal const string RuntimePrincipal = "44444444-4444-4444-8444-444444444444";
    internal const string AutomationClient = "55555555-5555-4555-8555-555555555555";
    internal const string AutomationPrincipal = "66666666-6666-4666-8666-666666666666";
    internal const string RegistryClient = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    internal static string OriginalSource => Hash('d');
    internal static string ResourceScope => $"/subscriptions/{Subscription}/resourceGroups/rg-tooling-fixture";

    internal static string Root => FindRoot(AppContext.BaseDirectory);

    internal static string FindRoot(string outputDirectory)
    {
        for (var directory = new DirectoryInfo(outputDirectory); directory is not null; directory = directory.Parent)
        {
            if (directory.Name != "Gateway.Tooling.Tests" || directory.Parent?.Name != "tests")
                continue;
            var root = directory.Parent.Parent?.FullName
                ?? throw new InvalidOperationException("The tooling test source root is absent.");
            if (!File.Exists(Path.Combine(directory.FullName, "Gateway.Tooling.Tests.csproj")) ||
                !File.Exists(Path.Combine(root, "tools", "Gateway.DatabaseMigrator", "Gateway.DatabaseMigrator.csproj")) ||
                !Directory.Exists(Path.Combine(root, "infrastructure", "sql")))
                throw new InvalidOperationException("The current tooling test copy is incomplete; falling back to another checkout is forbidden.");
            return root;
        }
        throw new InvalidOperationException("The tooling tests require their own authored project and standard build output layout.");
    }

    internal static string Hash(char value) => "sha256:" + new string(value, 64);
    internal static string Sql(string name) => $"SELECT 1; -- offline transport fixture for {name}";

    internal static IReadOnlyList<string> CurrentScriptNames()
    {
        var source = File.ReadAllText(Path.Combine(Root, "tools", "Gateway.DatabaseMigrator", "Program.cs"));
        var declarations = Regex.Matches(source, @"static string\[\] GetPrepareScriptNames\(\) =>\s*\[(?<scripts>[\s\S]*?)\];");
        Assert.Single(declarations.Cast<Match>());
        return Regex.Matches(declarations[0].Groups["scripts"].Value, "\"(?<name>[0-9]{8}_[a-z0-9_]+\\.sql)\"")
            .Select(match => match.Groups["name"].Value).ToArray();
    }

    internal static DatabaseUpgradeManifest Manifest(int version = 2)
    {
        var cutover = new DatabaseUpgradeCutoverContract(1,
            $"{ResourceScope}/providers/Microsoft.App/containerApps/ca-api-fixture",
            $"{ResourceScope}/providers/Microsoft.App/containerApps/ca-worker-fixture",
            $"{ResourceScope}/providers/Microsoft.ServiceBus/namespaces/sb-fixture/queues/gateway-provisioning-v3",
            $"{ResourceScope}/providers/Microsoft.ServiceBus/namespaces/sb-fixture/queues/gateway-protection-admin-v1",
            "gateway-maintenance-deny", 600);
        var scripts = version == 2 ? [] : DatabaseUpgradeMigrationAdmission.RequiredCurrentScripts
            .Select(name => new DatabaseUpgradeScript(name, DatabaseUpgradeAttestation.Fingerprint(Sql(name)))).ToArray();
        return new(version, Hash('e'), Hash('c'), OriginalSource, Ownership,
            "77777777-7777-4777-8777-777777777777", "sql-tooling-fixture.database.windows.net",
            "GatewayDb", "https://toolingfixture.blob.core.windows.net/gateway-upgrade-evidence",
            Hash('a'), version == 2 ? Hash('a') : Hash('b'), null, scripts, Hash('f'),
            DatabaseUpgradePlatformObserver.Fingerprint(cutover), cutover,
            [cutover.ApiResourceId + "/revisions/api-fixture-old", cutover.WorkerResourceId + "/revisions/worker-fixture-old"],
            "toolingfixture.azurecr.io/gateway-api@" + Hash('a'));
    }

    internal static IReadOnlyDictionary<string, string> Scripts(DatabaseUpgradeManifest manifest) =>
        manifest.Scripts.ToDictionary(script => script.Name, script => Sql(script.Name), StringComparer.Ordinal);

    internal static string Facts(bool full)
    {
        var resources = new ProtectionCapabilityResourceIdentifiers(
            BootstrapDeploymentOwnershipId: Guid.Parse(Ownership), BootstrapSourceFingerprint: OriginalSource);
        var attestation = new BootstrapProtectionCapabilityAttestation(
            Guid.Parse(Ownership), OriginalSource, new DateTime(2026, 9, 1, 0, 0, 0, DateTimeKind.Utc),
            [
                new(ProtectionCapabilityKind.Agent365RegistrationBeta, ProtectionCapabilityStatus.Installed,
                    resources with { Agent365RegistryApiApplicationId = new ApplicationClientId(Guid.Parse(RegistryClient)) }),
                new(ProtectionCapabilityKind.PromptShields,
                    full ? ProtectionCapabilityStatus.Installed : ProtectionCapabilityStatus.NotInstalled,
                    full ? resources with
                    {
                        ContentSafetyAccountResourceId = $"{ResourceScope}/providers/Microsoft.CognitiveServices/accounts/cs-fixture",
                        ContentSafetyEndpoint = "https://cs-fixture.cognitiveservices.azure.com/",
                        GatewayApiManagedIdentityPrincipalObjectId = new ServicePrincipalObjectId(Guid.Parse(ApiPrincipal))
                    } : resources),
                new(ProtectionCapabilityKind.Purview,
                    full ? ProtectionCapabilityStatus.Installed : ProtectionCapabilityStatus.NotInstalled,
                    full ? resources with
                    {
                        GatewayApiManagedIdentityPrincipalObjectId = new ServicePrincipalObjectId(Guid.Parse(ApiPrincipal)),
                        PurviewRuntimeManagedIdentityPrincipalObjectId = new ServicePrincipalObjectId(Guid.Parse(RuntimePrincipal)),
                        PurviewAutomationApplicationId = new ApplicationClientId(Guid.Parse(AutomationClient)),
                        PurviewAutomationServicePrincipalObjectId = new ServicePrincipalObjectId(Guid.Parse(AutomationPrincipal)),
                        KeyVaultResourceId = $"{ResourceScope}/providers/Microsoft.KeyVault/vaults/kv-fixture",
                        KeyVaultHost = "kv-fixture.vault.azure.net", CertificateName = "automation-fixture",
                        CertificateSecretUri = "https://kv-fixture.vault.azure.net/secrets/automation-fixture"
                    } : resources)
            ]);
        return CapabilityPreparationContract.FactsJson(attestation);
    }

    internal static string ManifestJson(DatabaseUpgradeManifest manifest) => JsonSerializer.Serialize(manifest);
}

// This store exercises only the coordinator's preservation/receipt protocol.
// It has no SQL, Azure SDK, HTTP, DNS, credential, or provider implementation.
internal sealed class RecordingUpgradeStore(DatabaseUpgradeManifest manifest) : IDatabaseUpgradeStore
{
    internal Dictionary<string, string> Metadata { get; } = new(StringComparer.Ordinal)
    {
        [DatabaseUpgradeAttestation.OriginalMarkerName] = "offline-original-marker"
    };
    internal List<string> Calls { get; } = [];
    internal string FactsJson { get; set; } = ToolingFixture.Facts(manifest.SchemaVersion == 2);
    internal string? FailAt { get; set; }
    internal bool RegistrationDrift { get; set; }
    internal int AppliedCount { get; private set; }
    private int _registrationReads;

    private void Record(string call)
    {
        Calls.Add(call);
        if (FailAt == call)
            throw new InvalidOperationException("Offline fixture rejected " + call);
    }

    public Task AcquireAsync() { Record("Acquire"); return Task.CompletedTask; }
    public Task ReleaseAsync() { Record("Release"); return Task.CompletedTask; }
    public Task<string?> ReadMetadataAsync(string name) => Task.FromResult(Metadata.GetValueOrDefault(name));
    public Task AddMetadataAsync(string name, string value)
    {
        Record(name.StartsWith(DatabaseUpgradeExecution.IntentPrefix, StringComparison.Ordinal) ? "Intent" :
            name.StartsWith(DatabaseUpgradeExecution.CommitPrefix, StringComparison.Ordinal) ? "CommitRecord" : "Receipt");
        Metadata.Add(name, value);
        return Task.CompletedTask;
    }
    public Task<string> ReadSchemaFingerprintAsync() =>
        Task.FromResult(AppliedCount > 0 ? manifest.AfterSchemaFingerprint : manifest.BeforeSchemaFingerprint);
    public Task<string> ReadRegistrationIdentityFingerprintAsync()
    {
        Record("Registrations");
        return Task.FromResult(ToolingFixture.Hash(RegistrationDrift && ++_registrationReads > 1 ? 'b' : 'a'));
    }
    public Task<string> ReadCapabilityFactsAsync(DatabaseUpgradeManifest _) => Task.FromResult(FactsJson);
    public Task AssertOriginalMarkerBindingAsync() { Record("OriginalMarker"); return Task.CompletedTask; }
    public Task AssertExactCurrentSchemaAndPrincipalsAsync() { Record("ExactSchemaAndPrincipals"); return Task.CompletedTask; }
    public Task AssertReceiptHistoryAsync(DatabaseUpgradeManifest _, string? tip) { Record("History"); return Task.CompletedTask; }
    public Task BeginPreservationWindowAsync() { Record("Begin"); return Task.CompletedTask; }
    public Task AssertPlatformCutoverBoundaryAsync(DatabaseUpgradeManifest _) { Record("Platform"); return Task.CompletedTask; }
    public Task AssertDurableCutoverBoundaryAsync() { Record("AdditiveContracts"); return Task.CompletedTask; }
    public Task AssertPostUpgradeCutoverBoundaryAsync() { Record("RetainedContracts"); return Task.CompletedTask; }
    public Task CommitPreservationWindowAsync() { Record("Commit"); return Task.CompletedTask; }
    public Task ApplyAsync(string sql)
    {
        if (manifest.SchemaVersion == 2)
            throw new InvalidOperationException("SourceOnlyFull attempted SQL.");
        Record("Sql");
        AppliedCount++;
        return Task.CompletedTask;
    }
}
