using System.Text.Json.Nodes;
using Gateway.DatabaseMigrator;
using Gateway.Infrastructure.Persistence;

namespace Gateway.Tooling.Tests;

public sealed class SourceOnlyManifestTests
{
    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    public void CurrentManifestTransportIsCallable(int version)
    {
        var manifest = ToolingFixture.Manifest(version);
        var json = ToolingFixture.ManifestJson(manifest);
        var parsed = DatabaseUpgradeExecution.ParseManifest(json, DatabaseUpgradeAttestation.Fingerprint(json),
            ToolingFixture.CurrentScriptNames());
        Assert.Equal(version, parsed.SchemaVersion);
        Assert.Equal(version == 2 ? 0 : 4, parsed.Scripts.Count);
        Assert.Equal(manifest.TargetModelFingerprint, parsed.TargetModelFingerprint);
    }

    [Theory]
    [InlineData("schema")]
    [InlineData("model")]
    [InlineData("sql")]
    [InlineData("version")]
    [InlineData("cutover")]
    public void SourceOnlyRejectsAnythingOtherThanExactPreservation(string invalid)
    {
        var manifest = ToolingFixture.Manifest();
        manifest = invalid switch
        {
            "schema" => manifest with { AfterSchemaFingerprint = ToolingFixture.Hash('b') },
            "model" => manifest with { TargetModelFingerprint = null },
            "sql" => manifest with { Scripts = ToolingFixture.Manifest(1).Scripts },
            "version" => manifest with { SchemaVersion = 3 },
            "cutover" => manifest with { CutoverBoundaryFingerprint = ToolingFixture.Hash('b') },
            _ => throw new InvalidOperationException()
        };
        Assert.Throws<ArgumentException>(() =>
            DatabaseUpgradeExecution.AssertManifest(manifest, ToolingFixture.CurrentScriptNames()));
    }

    [Fact]
    public void SourceOnlyDoesNotRelaxCoreRequiredMigrations()
    {
        var sourceOnly = ToolingFixture.Manifest();
        Assert.Throws<ArgumentException>(() => DatabaseUpgradeExecution.AssertManifest(
            sourceOnly with { SchemaVersion = 1 }, ToolingFixture.CurrentScriptNames()));
        Assert.Throws<ArgumentException>(() => DatabaseUpgradeExecution.AssertManifest(sourceOnly,
            ToolingFixture.CurrentScriptNames().SkipLast(1).ToArray()));
    }

    [Fact]
    public void ManifestRejectsDuplicateAndUnapprovedTransportFields()
    {
        var json = ToolingFixture.ManifestJson(ToolingFixture.Manifest());
        foreach (var changed in new[] { "{\"SchemaVersion\":2," + json[1..], "{\"Unknown\":true," + json[1..] })
            Assert.ThrowsAny<Exception>(() => DatabaseUpgradeExecution.ParseManifest(changed,
                DatabaseUpgradeAttestation.Fingerprint(changed), ToolingFixture.CurrentScriptNames()));
        Assert.Throws<ArgumentException>(() => DatabaseUpgradeExecution.ParseManifest(json,
            ToolingFixture.Hash('0'), ToolingFixture.CurrentScriptNames()));
    }

    [Fact]
    public void FullFactsAreAdmittedOnlyForSourceOnlyAndRemainUnchanged()
    {
        var full = ToolingFixture.Facts(true);
        var core = ToolingFixture.Facts(false);
        var cutover = ToolingFixture.Manifest().Cutover!;
        Assert.Equal(3, CapabilityPreparationBuilder.ValidateObservedFacts(full,
            ToolingFixture.Ownership, ToolingFixture.OriginalSource, cutover).Capabilities.Count);
        Assert.Equal(3, CapabilityPreparationBuilder.ValidateObservedFacts(core,
            ToolingFixture.Ownership, ToolingFixture.OriginalSource).Capabilities.Count);
        Assert.Throws<ArgumentException>(() => CapabilityPreparationBuilder.ValidateObservedFacts(full,
            ToolingFixture.Ownership, ToolingFixture.OriginalSource));
        Assert.Throws<ArgumentException>(() => CapabilityPreparationBuilder.ValidateObservedFacts(core,
            ToolingFixture.Ownership, ToolingFixture.OriginalSource, cutover));
    }

    [Theory]
    [InlineData("partial")]
    [InlineData("foreign-scope")]
    [InlineData("shared-principal")]
    [InlineData("endpoint")]
    [InlineData("certificate")]
    [InlineData("noncanonical-id")]
    [InlineData("wrong-source")]
    public void FullFactsRetainExactIdentityAndResourceGuards(string invalid)
    {
        var document = JsonNode.Parse(ToolingFixture.Facts(true))!;
        var facts = document["capabilities"]!;
        switch (invalid)
        {
            case "partial": facts[2]!["purviewRuntimeManagedIdentityPrincipalObjectId"] = null; break;
            case "foreign-scope": facts[2]!["keyVaultResourceId"] =
                $"{ToolingFixture.ResourceScope}-other/providers/Microsoft.KeyVault/vaults/kv-fixture"; break;
            case "shared-principal": facts[2]!["purviewRuntimeManagedIdentityPrincipalObjectId"] = ToolingFixture.ApiPrincipal; break;
            case "endpoint": facts[1]!["contentSafetyEndpoint"] = "https://example.invalid/"; break;
            case "certificate": facts[2]!["certificateSecretUri"] =
                "https://kv-fixture.vault.azure.net/secrets/automation-fixture/unapproved-version"; break;
            case "noncanonical-id": facts[0]!["agent365RegistryApiApplicationId"] = ToolingFixture.RegistryClient.ToUpperInvariant(); break;
            case "wrong-source": document["originalBootstrapSourceFingerprint"] = ToolingFixture.Hash('0'); break;
        }
        Assert.Throws<ArgumentException>(() => CapabilityPreparationBuilder.ValidateObservedFacts(document.ToJsonString(),
            ToolingFixture.Ownership, ToolingFixture.OriginalSource, ToolingFixture.Manifest().Cutover));
    }

    [Fact]
    public async Task SourceOnlyPreservesSchemaIdentitiesAndFactsWithoutSql()
    {
        var manifest = ToolingFixture.Manifest();
        var store = new RecordingUpgradeStore(manifest);
        var original = store.Metadata[DatabaseUpgradeAttestation.OriginalMarkerName];
        var receipt = await DatabaseUpgradeExecution.ExecuteAsync(store, manifest, ToolingFixture.Scripts(manifest), false);
        Assert.Equal(0, store.AppliedCount);
        Assert.DoesNotContain("Sql", store.Calls);
        Assert.DoesNotContain("AdditiveContracts", store.Calls);
        Assert.Contains("Platform", store.Calls);
        Assert.Contains("RetainedContracts", store.Calls);
        Assert.True(store.Calls.IndexOf("ExactSchemaAndPrincipals") < store.Calls.IndexOf("Intent"));
        Assert.True(store.Calls.IndexOf("RetainedContracts") < store.Calls.IndexOf("Intent"));
        Assert.Equal(receipt.BeforeSchemaFingerprint, receipt.AfterSchemaFingerprint);
        Assert.Equal(receipt.RegistrationIdentityFingerprintBefore, receipt.RegistrationIdentityFingerprintAfter);
        Assert.Equal(store.FactsJson, receipt.PriorCapabilityFactsJson);
        Assert.Equal(DatabaseUpgradeAttestation.Fingerprint(""), receipt.SqlManifestFingerprint);
        Assert.Equal(original, store.Metadata[DatabaseUpgradeAttestation.OriginalMarkerName]);
        var writes = store.Metadata.Count;
        var observed = await DatabaseUpgradeExecution.ExecuteAsync(store, manifest, ToolingFixture.Scripts(manifest), true);
        Assert.Equal(receipt, observed);
        Assert.Equal(writes, store.Metadata.Count);
    }

    [Theory]
    [InlineData("ExactSchemaAndPrincipals")]
    [InlineData("Platform")]
    [InlineData("RetainedContracts")]
    public async Task SourceOnlyNeverBypassesMissingSafetyEvidence(string failure)
    {
        var manifest = ToolingFixture.Manifest();
        var store = new RecordingUpgradeStore(manifest) { FailAt = failure };
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            DatabaseUpgradeExecution.ExecuteAsync(store, manifest, ToolingFixture.Scripts(manifest), false));
        Assert.Equal(0, store.AppliedCount);
        Assert.Single(store.Metadata);
        Assert.Equal("Release", store.Calls[^1]);
    }

    [Fact]
    public async Task SourceOnlyCannotLoadExtraSqlOrUsePartialCapabilities()
    {
        var manifest = ToolingFixture.Manifest();
        var store = new RecordingUpgradeStore(manifest);
        await Assert.ThrowsAsync<ArgumentException>(() => DatabaseUpgradeExecution.ExecuteAsync(store, manifest,
            new Dictionary<string, string> { ["unexpected.sql"] = "SELECT 1;" }, false));
        Assert.Empty(store.Calls);
        store.FactsJson = ToolingFixture.Facts(false);
        await Assert.ThrowsAsync<ArgumentException>(() =>
            DatabaseUpgradeExecution.ExecuteAsync(store, manifest, ToolingFixture.Scripts(manifest), false));
        Assert.Single(store.Metadata);
    }

    [Fact]
    public async Task UnknownIntentAndMissingReceiptNeverPermitReplayOrFakeVerification()
    {
        var manifest = ToolingFixture.Manifest();
        var store = new RecordingUpgradeStore(manifest);
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            DatabaseUpgradeExecution.ExecuteAsync(store, manifest, ToolingFixture.Scripts(manifest), true));
        Assert.Single(store.Metadata);
        store.Metadata.Add(DatabaseUpgradeExecution.IntentPrefix + manifest.PlanFingerprint[7..], "unknown-outcome");
        var exception = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            DatabaseUpgradeExecution.ExecuteAsync(store, manifest, ToolingFixture.Scripts(manifest), false));
        Assert.Contains("UpgradeOutcomeUnknown", exception.Message);
        Assert.Equal(0, store.AppliedCount);
        Assert.Equal(2, store.Metadata.Count);
    }

    [Fact]
    public async Task RegistrationDriftProducesNoCompletionReceipt()
    {
        var manifest = ToolingFixture.Manifest();
        var store = new RecordingUpgradeStore(manifest) { RegistrationDrift = true };
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            DatabaseUpgradeExecution.ExecuteAsync(store, manifest, ToolingFixture.Scripts(manifest), false));
        Assert.DoesNotContain(DatabaseUpgradeAttestation.GetReceiptName(manifest.PlanFingerprint), store.Metadata.Keys);
        Assert.DoesNotContain("Commit", store.Calls);
        Assert.Equal(0, store.AppliedCount);
    }

    [Fact]
    public async Task SourceOnlyVerificationRejectsChangedFullProjection()
    {
        var manifest = ToolingFixture.Manifest();
        var store = new RecordingUpgradeStore(manifest);
        await DatabaseUpgradeExecution.ExecuteAsync(store, manifest, ToolingFixture.Scripts(manifest), false);
        store.FactsJson = store.FactsJson.Replace(ToolingFixture.RegistryClient,
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", StringComparison.Ordinal);
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            DatabaseUpgradeExecution.ExecuteAsync(store, manifest, ToolingFixture.Scripts(manifest), true));
    }

    [Fact]
    public async Task CoreToFullStillUsesAllRequiredSqlAndAdditiveGuards()
    {
        var manifest = ToolingFixture.Manifest(1);
        var store = new RecordingUpgradeStore(manifest);
        var receipt = await DatabaseUpgradeExecution.ExecuteAsync(store, manifest, ToolingFixture.Scripts(manifest), false);
        Assert.Equal(4, store.AppliedCount);
        Assert.Contains("AdditiveContracts", store.Calls);
        Assert.DoesNotContain("RetainedContracts", store.Calls);
        Assert.Equal(manifest.AfterSchemaFingerprint, receipt.AfterSchemaFingerprint);
        Assert.NotEqual(receipt.BeforeSchemaFingerprint, receipt.AfterSchemaFingerprint);
    }
}
