using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Azure;
using Azure.Core;
using Azure.Identity;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Gateway.Infrastructure.Persistence;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.Infrastructure.Services;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

namespace Gateway.DatabaseMigrator;

public sealed record DatabaseUpgradeScript(string Name, string Sha256);

public sealed record DatabaseUpgradeManifest(
    int SchemaVersion,
    string PlanFingerprint,
    string UpgradeSourceFingerprint,
    string OriginalAcceptedSourceFingerprint,
    string DeploymentOwnershipId,
    string ExecutionIntentId,
    string Server,
    string Database,
    string EvidenceContainerUri,
    string BeforeSchemaFingerprint,
    string AfterSchemaFingerprint,
    string? PreviousReceiptFingerprint,
    IReadOnlyList<DatabaseUpgradeScript> Scripts,
    string? TargetModelFingerprint = null,
    string? CutoverBoundaryFingerprint = null,
    DatabaseUpgradeCutoverContract? Cutover = null,
    IReadOnlyList<string>? CutoverOriginalRevisionResourceIds = null,
    string? CutoverApiImage = null,
    string? RollbackCompatibilityReviewFingerprint = null,
    IReadOnlyDictionary<string, string>? RollbackImages = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    DatabaseUpgradeQueueQuarantineBaseline? QueueQuarantineBaseline = null);

public sealed record DatabaseUpgradeIntent(
    int SchemaVersion,
    string ManifestFingerprint,
    string OriginalMarkerFingerprint,
    string RegistrationIdentityFingerprintBefore,
    string PriorCapabilityFactsFingerprint,
    string PriorCapabilityFactsJson,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    DatabaseUpgradePurviewPreservationStart? PurviewPreservation = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    DatabaseUpgradeQueueQuarantineObservation? QueueQuarantine = null);

public sealed record DatabaseUpgradeCommit(
    int SchemaVersion,
    string ManifestFingerprint,
    string IntentFingerprint,
    string Status,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    DatabaseUpgradePurviewPreservationProof? PurviewPreservation = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    DatabaseUpgradeQueueQuarantineProof? QueueQuarantine = null);

public interface IDatabaseUpgradeStore
{
    Task AcquireAsync();
    Task ReleaseAsync();
    Task<string?> ReadMetadataAsync(string name);
    Task AddMetadataAsync(string name, string value);
    Task<string> ReadSchemaFingerprintAsync();
    Task<string> ReadRegistrationIdentityFingerprintAsync();
    Task<string> ReadCapabilityFactsAsync(DatabaseUpgradeManifest manifest);
    Task AssertOriginalMarkerBindingAsync();
    Task AssertExactCurrentSchemaAndPrincipalsAsync();
    Task AssertReceiptHistoryAsync(DatabaseUpgradeManifest manifest, string? expectedTipFingerprint);
    Task BeginPreservationWindowAsync();
    Task AssertPlatformCutoverBoundaryAsync(DatabaseUpgradeManifest manifest) =>
        throw new InvalidOperationException("UpgradeCutoverPlatformObserverMissing: private platform closure requires independent verification.");
    Task AssertDurableCutoverBoundaryAsync() =>
        throw new InvalidOperationException("UpgradeCutoverObserverMissing: durable SQL checkpoints require manual reconciliation.");
    Task AssertPostUpgradeCutoverBoundaryAsync(bool forRollback = true) =>
        throw new InvalidOperationException("UpgradePostCutoverObserverMissing: compatible rollback requires current terminal-state observation.");
    Task<DatabaseUpgradePurviewPreservationStart?> AssertSourceOnlyCutoverBoundaryAsync(DatabaseUpgradeManifest manifest) =>
        throw new InvalidOperationException("UpgradeSourceOnlyObserverMissing: explicit source-only preservation observation is required.");
    Task<DatabaseUpgradePurviewPreservationProof> AssertPurviewPreservedAsync(DatabaseUpgradePurviewPreservationStart before) =>
        throw new InvalidOperationException("UpgradePurviewPreservationMissing: exact before/after Purview preservation is required.");
    Task<DatabaseUpgradeQueueQuarantineObservation> AssertSourceOnlyQueuesAsync(DatabaseUpgradeManifest manifest, string phase) =>
        throw new InvalidOperationException("UpgradeQueueQuarantineMissing: both independent held observations are required.");
    Task CommitPreservationWindowAsync();
    Task ApplyAsync(string sql);
}

public static class DatabaseUpgradeExecution
{
    public const string IntentPrefix = "A365GatewayUpgradeIntent:";
    public const string CommitPrefix = "A365GatewayUpgradeCommit:";
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        MaxDepth = 8
    };

    public static async Task<DatabaseUpgradeReceipt> RunPrivateAsync(
        DatabaseUpgradeManifest manifest,
        IReadOnlyDictionary<string, string> scripts,
        System.Net.IPAddress expectedPrivateEndpointIp,
        bool verifyOnly,
        Func<SqlConnection, Task> assertOriginalMarkerBinding,
        Func<SqlConnection, Task> assertExactCurrentSchemaAndPrincipals,
        DatabaseUpgradeRollbackObservation? rollbackObservation = null)
    {
        if (rollbackObservation is not null && !verifyOnly)
            throw new ArgumentException("Rollback observation is exclusively read-only.");
        rollbackObservation?.AssertBinding(manifest);
        AssertLoadedScripts(manifest, scripts);
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("IDENTITY_ENDPOINT")))
            throw new InvalidOperationException("A maintenance upgrade requires the private Container Apps managed-identity endpoint.");
        try
        {
            await SqlPrivateEndpointDnsConvergence.WaitForExactResolutionAsync(
                manifest.Server, expectedPrivateEndpointIp, CancellationToken.None);
            var credential = new ManagedIdentityCredential();
            var token = await credential.GetTokenAsync(
                new TokenRequestContext(["https://database.windows.net/.default"]), CancellationToken.None);
            var connectionString = new SqlConnectionStringBuilder
            {
                DataSource = $"tcp:{manifest.Server},1433",
                InitialCatalog = manifest.Database,
                Encrypt = SqlConnectionEncryptOption.Mandatory,
                TrustServerCertificate = false,
                ConnectTimeout = 30,
                ApplicationName = "A365GatewayDatabaseUpgrade"
            }.ConnectionString;
            await using var connection = new SqlConnection(connectionString) { AccessToken = token.Token };
            await connection.OpenAsync();
            var blobOptions = new BlobClientOptions();
            blobOptions.Retry.MaxRetries = 2;
            blobOptions.Retry.NetworkTimeout = TimeSpan.FromSeconds(30);
            var store = new SqlDatabaseUpgradeStore(
                connection,
                new BlobContainerClient(new Uri(manifest.EvidenceContainerUri), credential, blobOptions),
                () => assertOriginalMarkerBinding(connection),
                () => assertExactCurrentSchemaAndPrincipals(connection));
            return rollbackObservation is null
                ? await ExecuteAsync(store, manifest, scripts, verifyOnly)
                : await ObserveRollbackAsync(store, manifest, scripts, rollbackObservation);
        }
        catch (DatabaseUpgradeCutoverBlockedException) { throw; }
        catch
        {
            throw new InvalidOperationException(
                "Maintenance upgrade did not produce verified completion. SQL may already be committed; do not infer rollback. " +
                "Provider details were suppressed; inspect exact private intent/commit/receipt evidence without replaying SQL.");
        }
    }

    public static DatabaseUpgradeManifest ParseManifest(
        string json,
        string expectedManifestFingerprint,
        IReadOnlyCollection<string> allowedScriptNames)
    {
        if (json.Length > 32768 || !DatabaseUpgradeAttestation.IsFingerprint(expectedManifestFingerprint) ||
            !DatabaseUpgradeAttestation.Fingerprint(json).Equals(expectedManifestFingerprint, StringComparison.Ordinal))
            throw new ArgumentException("The upgrade manifest bytes do not match the approved transport fingerprint.");
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
        AssertNoDuplicateProperties(document.RootElement);
        var manifest = JsonSerializer.Deserialize<DatabaseUpgradeManifest>(json, JsonOptions)
            ?? throw new ArgumentException("The upgrade manifest is missing.");
        AssertManifest(manifest, allowedScriptNames);
        return manifest;
    }

    public static void AssertManifest(DatabaseUpgradeManifest manifest, IReadOnlyCollection<string> allowedScriptNames)
    {
        ArgumentNullException.ThrowIfNull(manifest);
        AssertMigrationMode(manifest);
        DatabaseUpgradeRollbackObservation.AssertManifestAnchor(manifest);
        DatabaseUpgradePlatformObserver.AssertContract(manifest.Cutover, manifest.CutoverOriginalRevisionResourceIds);
        GetApiMaintenanceBinding(manifest);
        if (manifest.CutoverBoundaryFingerprint != DatabaseUpgradePlatformObserver.Fingerprint(manifest.Cutover!))
            throw new ArgumentException("UpgradeCutover: the typed platform contract differs from the Plan-bound cutover fingerprint.");
        if (!DatabaseUpgradeAttestation.IsFingerprint(manifest.PlanFingerprint) ||
            !DatabaseUpgradeAttestation.IsFingerprint(manifest.CutoverBoundaryFingerprint) ||
            !DatabaseUpgradeAttestation.IsFingerprint(manifest.UpgradeSourceFingerprint) ||
            !DatabaseUpgradeAttestation.IsFingerprint(manifest.OriginalAcceptedSourceFingerprint) ||
            !DatabaseUpgradeAttestation.IsFingerprint(manifest.BeforeSchemaFingerprint) ||
            !(DatabaseUpgradeAttestation.IsFingerprint(manifest.AfterSchemaFingerprint) ||
              manifest.AfterSchemaFingerprint == "" && DatabaseUpgradeAttestation.IsFingerprint(manifest.TargetModelFingerprint)) ||
            manifest.TargetModelFingerprint is not null && !DatabaseUpgradeAttestation.IsFingerprint(manifest.TargetModelFingerprint) ||
            manifest.PreviousReceiptFingerprint is not null && !DatabaseUpgradeAttestation.IsFingerprint(manifest.PreviousReceiptFingerprint) ||
            !DatabaseUpgradeAttestation.IsCanonicalGuid(manifest.DeploymentOwnershipId) ||
            !DatabaseUpgradeAttestation.IsCanonicalGuid(manifest.ExecutionIntentId) ||
            manifest.Server is null || !Regex.IsMatch(manifest.Server, "^[a-z0-9-]+\\.database\\.windows\\.net$", RegexOptions.CultureInvariant) ||
            !string.Equals(manifest.Database, "GatewayDb", StringComparison.Ordinal) ||
            manifest.EvidenceContainerUri is null || !Regex.IsMatch(manifest.EvidenceContainerUri,
                "^https://[a-z0-9]{3,24}\\.blob\\.core\\.windows\\.net/gateway-upgrade-evidence$", RegexOptions.CultureInvariant) ||
            manifest.Scripts.Select(script => script.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != manifest.Scripts.Count)
            throw new ArgumentException("The upgrade manifest has an invalid exact target, provenance or script binding.");
        foreach (var script in manifest.Scripts)
        {
            if (!allowedScriptNames.Contains(script.Name, StringComparer.Ordinal) ||
                !Regex.IsMatch(script.Name, "^[0-9]{8}_[a-z0-9_]+\\.sql$", RegexOptions.CultureInvariant) ||
                !DatabaseUpgradeAttestation.IsFingerprint(script.Sha256))
                throw new ArgumentException("The upgrade manifest contains an unreviewed script or checksum.");
        }
        var approvedOrder = allowedScriptNames.Where(name => manifest.Scripts.Any(script => script.Name == name));
        if (!approvedOrder.SequenceEqual(manifest.Scripts.Select(script => script.Name), StringComparer.Ordinal))
            throw new ArgumentException("Upgrade scripts must retain the reviewed migrator order.");
        DatabaseUpgradeMigrationAdmission.AssertRequiredScripts(allowedScriptNames);
        if (manifest.QueueQuarantineBaseline is not null)
            DatabaseUpgradeQueueQuarantine.AssertBaseline(manifest);
    }

    private static void AssertMigrationMode(DatabaseUpgradeManifest manifest)
    {
        if (manifest.SchemaVersion is not (1 or 2) || manifest.Scripts is null ||
            manifest.Scripts.Count > 32 || manifest.Scripts.Any(script => script is null))
            throw new ArgumentException("The maintenance manifest version or SQL collection is unsupported.");
        if (manifest.SchemaVersion == 2)
        {
            if (manifest.Scripts.Count != 0 ||
                !DatabaseUpgradeAttestation.IsFingerprint(manifest.BeforeSchemaFingerprint) ||
                manifest.BeforeSchemaFingerprint != manifest.AfterSchemaFingerprint ||
                !DatabaseUpgradeAttestation.IsFingerprint(manifest.TargetModelFingerprint))
                throw new ArgumentException("SourceOnlyFull requires no SQL, an exact unchanged physical schema, and the approved target model.");
        }

        else
        {
            DatabaseUpgradeMigrationAdmission.AssertRequiredScripts(manifest.Scripts.Select(script => script.Name));
        }
    }

    internal static void AssertSourceOnlyPreservationManifest(DatabaseUpgradeManifest manifest)
    {
        AssertMigrationMode(manifest);
        if (manifest.SchemaVersion != 2)
            throw new ArgumentException("Purview human-wait preservation is only supported by explicit SourceOnlyFull forward maintenance.");
    }

    public static string SqlManifestFingerprint(DatabaseUpgradeManifest manifest) =>
        DatabaseUpgradeAttestation.Fingerprint(string.Concat(manifest.Scripts.Select(script => $"{script.Name}|{script.Sha256}\n")));

    public static IReadOnlyDictionary<string, string> LoadScripts(DatabaseUpgradeManifest manifest, string directory)
    {
        var scripts = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var entry in manifest.Scripts)
        {
            var path = Path.Combine(directory, entry.Name);
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new ArgumentException("Upgrade SQL files cannot be links.");
            var bytes = File.ReadAllBytes(path);
            var hash = $"sha256:{Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()}";
            if (!hash.Equals(entry.Sha256, StringComparison.Ordinal))
                throw new ArgumentException("Upgrade SQL bytes differ from the exact approved checksum.");
            scripts.Add(entry.Name, new UTF8Encoding(false, true).GetString(bytes));
        }
        return scripts;
    }

    public static async Task<DatabaseUpgradeReceipt> ExecuteAsync(
        IDatabaseUpgradeStore store,
        DatabaseUpgradeManifest manifest,
        IReadOnlyDictionary<string, string> scripts,
        bool verifyOnly) =>
        await ExecuteCoreAsync(store, manifest, scripts, verifyOnly, null);

    public static async Task<DatabaseUpgradeReceipt> ObserveRollbackAsync(
        IDatabaseUpgradeStore store, DatabaseUpgradeManifest manifest,
        IReadOnlyDictionary<string, string> scripts, DatabaseUpgradeRollbackObservation observation)
    {
        ArgumentNullException.ThrowIfNull(observation);
        observation.AssertBinding(manifest);
        return await ExecuteCoreAsync(store, manifest, scripts, verifyOnly: true, observation);
    }

    private static async Task<DatabaseUpgradeReceipt> ExecuteCoreAsync(
        IDatabaseUpgradeStore store, DatabaseUpgradeManifest manifest,
        IReadOnlyDictionary<string, string> scripts, bool verifyOnly,
        DatabaseUpgradeRollbackObservation? observation)
    {
        AssertLoadedScripts(manifest, scripts);
        var markerName = DatabaseUpgradeAttestation.GetReceiptName(manifest.PlanFingerprint);
        var intentName = IntentPrefix + manifest.PlanFingerprint[7..];
        var commitName = CommitPrefix + manifest.PlanFingerprint[7..];
        await store.AcquireAsync();
        try
        {
            await store.AssertOriginalMarkerBindingAsync();
            var originalMarker = await store.ReadMetadataAsync(DatabaseUpgradeAttestation.OriginalMarkerName)
                ?? throw new InvalidOperationException("The original database initialization marker is missing.");
            var originalMarkerFingerprint = DatabaseUpgradeAttestation.Fingerprint(originalMarker);
            var manifestFingerprint = DatabaseUpgradeAttestation.Fingerprint(JsonSerializer.Serialize(manifest, JsonOptions));
            var existingReceiptJson = await store.ReadMetadataAsync(markerName);
            if (existingReceiptJson is not null)
            {
                var receipt = DatabaseUpgradeAttestation.Parse(existingReceiptJson);
                AssertReceiptBinding(receipt, manifest, originalMarkerFingerprint);
                var receiptIntentJson = await store.ReadMetadataAsync(intentName);
                var receiptIntent = receiptIntentJson is null ? null :
                    ParseIntent(receiptIntentJson);
                if (receiptIntent?.ManifestFingerprint != manifestFingerprint ||
                    await store.ReadMetadataAsync(commitName) != SerializeCommit(manifestFingerprint, receiptIntentJson!, receipt.PurviewPreservation, receipt.QueueQuarantine))
                    throw new InvalidOperationException("UpgradeCutoverEvidenceMismatch: the verified receipt lacks this exact cutover boundary's intent and SQL commit.");
                await store.AssertReceiptHistoryAsync(manifest, DatabaseUpgradeAttestation.Fingerprint(existingReceiptJson));
                await store.AssertExactCurrentSchemaAndPrincipalsAsync();
                if (!receipt.AfterSchemaFingerprint.Equals(await store.ReadSchemaFingerprintAsync(), StringComparison.Ordinal))
                    throw new InvalidOperationException("The verified upgrade schema has drifted.");
                if (manifest.SchemaVersion == 2)
                {
                    var currentFacts = await store.ReadCapabilityFactsAsync(manifest);
                    AssertPriorCapabilityFacts(currentFacts, manifest);
                    if (currentFacts != receipt.PriorCapabilityFactsJson)
                        throw new InvalidOperationException("The SourceOnlyFull capability projection changed after its preservation receipt.");
                }
                if (observation is not null)
                {
                    observation.AssertBinding(manifest, receipt);
                    await store.BeginPreservationWindowAsync();
                    await store.AssertPlatformCutoverBoundaryAsync(manifest);
                    await store.AssertPostUpgradeCutoverBoundaryAsync(forRollback: true);
                    await store.CommitPreservationWindowAsync();
                    if (DatabaseUpgradeAttestation.Serialize(receipt) != existingReceiptJson ||
                        await store.ReadMetadataAsync(DatabaseUpgradeAttestation.OriginalMarkerName) != originalMarker ||
                        await store.ReadMetadataAsync(markerName) != existingReceiptJson ||
                        await store.ReadMetadataAsync(intentName) != receiptIntentJson ||
                        await store.ReadMetadataAsync(commitName) != SerializeCommit(manifestFingerprint, receiptIntentJson!, receipt.PurviewPreservation, receipt.QueueQuarantine))
                        throw new InvalidOperationException("UpgradeCutoverEvidenceMismatch: original receipt/intent/commit changed during observation.");
                }
                return receipt;
            }
            var existingIntent = await store.ReadMetadataAsync(intentName);
            var existingCommit = await store.ReadMetadataAsync(commitName);
            if (existingCommit is not null)
            {
                using var commitDocument = JsonDocument.Parse(existingCommit);
                AssertNoDuplicateProperties(commitDocument.RootElement);
                var commit = JsonSerializer.Deserialize<DatabaseUpgradeCommit>(existingCommit, JsonOptions);
                if (existingIntent is null || commit is null ||
                    existingCommit != SerializeCommit(manifestFingerprint, existingIntent, commit.PurviewPreservation, commit.QueueQuarantine))
                    throw new InvalidOperationException("UpgradeCommitEvidenceMismatch: SQL outcome requires review; no replay or rollback is authorized.");
                throw new InvalidOperationException(
                    "UpgradeSqlCommittedWithoutVerifiedReceipt: schema changes were committed but completion is unverified. No automatic SQL replay or schema rollback is authorized.");
            }
            if (verifyOnly)
                throw new InvalidOperationException("UpgradeReceiptNotObserved: read-only verification cannot create evidence or replay SQL.");
            if (existingIntent is not null)
                throw new InvalidOperationException("UpgradeOutcomeUnknown: an intent exists without a verified receipt; SQL may already be committed and is never replayed automatically.");
            if (!manifest.BeforeSchemaFingerprint.Equals(await store.ReadSchemaFingerprintAsync(), StringComparison.Ordinal))
                throw new InvalidOperationException("The database does not match the approved pre-upgrade schema.");
            await store.AssertReceiptHistoryAsync(manifest, manifest.PreviousReceiptFingerprint);
            if (manifest.SchemaVersion == 2)
                await store.AssertExactCurrentSchemaAndPrincipalsAsync();
            var priorCapabilityFacts = await store.ReadCapabilityFactsAsync(manifest);
            AssertPriorCapabilityFacts(priorCapabilityFacts, manifest);
            var priorCapabilityFingerprint = DatabaseUpgradeAttestation.Fingerprint(priorCapabilityFacts);
            await store.BeginPreservationWindowAsync();
            DatabaseUpgradeQueueQuarantineObservation? queueBefore = null;
            DatabaseUpgradePurviewPreservationStart? purviewBefore = null;
            if (manifest.SchemaVersion == 2)
            {
                queueBefore = await store.AssertSourceOnlyQueuesAsync(manifest, "SqlBefore");
                DatabaseUpgradeQueueQuarantine.AssertObservation(queueBefore, manifest, "SqlBefore");
                // Preserve current receipt/configuration history, without authorizing ApplyAsync.
                purviewBefore = await store.AssertSourceOnlyCutoverBoundaryAsync(manifest);
            }
            else
            {
                await store.AssertPlatformCutoverBoundaryAsync(manifest);
                await store.AssertDurableCutoverBoundaryAsync();
            }
            purviewBefore?.AssertValid();
            var registrationsBefore = await store.ReadRegistrationIdentityFingerprintAsync();
            var intent = new DatabaseUpgradeIntent(1, manifestFingerprint, originalMarkerFingerprint, registrationsBefore,
                priorCapabilityFingerprint, priorCapabilityFacts, purviewBefore, queueBefore);
            var intentJson = JsonSerializer.Serialize(intent, JsonOptions);
            await store.AddMetadataAsync(intentName, intentJson);
            if (!string.Equals(await store.ReadMetadataAsync(intentName), intentJson, StringComparison.Ordinal))
                throw new InvalidOperationException("The durable upgrade intent was not read back exactly; SQL was not started.");
            foreach (var script in manifest.Scripts)
            {
                if (!scripts.TryGetValue(script.Name, out var sql))
                    throw new InvalidOperationException("The approved SQL script was not loaded.");
                if (!DatabaseUpgradeAttestation.Fingerprint(sql).Equals(script.Sha256, StringComparison.Ordinal))
                    throw new InvalidOperationException("The loaded SQL checksum changed before execution.");
                await store.ApplyAsync(sql);
            }
            var registrationsAfter = await store.ReadRegistrationIdentityFingerprintAsync();
            if (!registrationsBefore.Equals(registrationsAfter, StringComparison.Ordinal))
                throw new InvalidOperationException("Registration/credential identity state changed during the bounded migration; preservation requires review.");
            var purviewProof = purviewBefore is null ? null : await store.AssertPurviewPreservedAsync(purviewBefore);
            AssertPurviewProofBinding(purviewBefore, purviewProof);
            var queueProof = queueBefore is null ? null : new DatabaseUpgradeQueueQuarantineProof(queueBefore,
                await store.AssertSourceOnlyQueuesAsync(manifest, "SqlAfter"));
            AssertQueueProofBinding(queueBefore, queueProof);
            await store.CommitPreservationWindowAsync();
            // Commit precedes Azure/platform verification. This checkpoint is not a completion receipt.
            var commitJson = SerializeCommit(manifestFingerprint, intentJson, purviewProof, queueProof);
            await store.AddMetadataAsync(commitName, commitJson);
            if (!string.Equals(await store.ReadMetadataAsync(commitName), commitJson, StringComparison.Ordinal))
                throw new InvalidOperationException("UpgradeSqlCommittedWithoutVerifiedReceipt: committed SQL checkpoint could not be read back exactly.");
            if (!string.Equals(await store.ReadCapabilityFactsAsync(manifest), priorCapabilityFacts, StringComparison.Ordinal))
                throw new InvalidOperationException("The independently observed prior capability facts changed during schema expansion.");
            await store.AssertOriginalMarkerBindingAsync();
            if (!string.Equals(await store.ReadMetadataAsync(DatabaseUpgradeAttestation.OriginalMarkerName), originalMarker, StringComparison.Ordinal))
                throw new InvalidOperationException("The original initialization marker changed during the upgrade.");
            await store.AssertExactCurrentSchemaAndPrincipalsAsync();
            var schemaAfter = await store.ReadSchemaFingerprintAsync();
            if (manifest.AfterSchemaFingerprint.Length != 0 &&
                !schemaAfter.Equals(manifest.AfterSchemaFingerprint, StringComparison.Ordinal))
                throw new InvalidOperationException("The database did not reach the exact approved target schema.");
            var completed = new DatabaseUpgradeReceipt(
                1, manifest.DeploymentOwnershipId, manifest.OriginalAcceptedSourceFingerprint,
                originalMarkerFingerprint, manifest.PlanFingerprint, manifest.UpgradeSourceFingerprint,
                manifest.PreviousReceiptFingerprint, manifest.BeforeSchemaFingerprint, schemaAfter,
                SqlManifestFingerprint(manifest), manifest.ExecutionIntentId, manifest.Server, manifest.Database,
                registrationsBefore, registrationsAfter, DateTimeOffset.UtcNow.ToString("O"), manifest.TargetModelFingerprint,
                priorCapabilityFacts, priorCapabilityFingerprint, purviewProof, queueProof);
            var completedJson = DatabaseUpgradeAttestation.Serialize(completed);
            await store.AddMetadataAsync(markerName, completedJson);
            if (!string.Equals(await store.ReadMetadataAsync(markerName), completedJson, StringComparison.Ordinal))
                throw new InvalidOperationException("The upgrade receipt was not read back exactly.");
            await store.AssertReceiptHistoryAsync(manifest, DatabaseUpgradeAttestation.Fingerprint(completedJson));
            return completed;
        }
        finally
        {
            await store.ReleaseAsync();
        }
    }

    private static void AssertLoadedScripts(DatabaseUpgradeManifest manifest, IReadOnlyDictionary<string, string> scripts)
    {
        AssertMigrationMode(manifest);
        DatabaseUpgradeRollbackObservation.AssertManifestAnchor(manifest);
        DatabaseUpgradePlatformObserver.AssertContract(manifest.Cutover, manifest.CutoverOriginalRevisionResourceIds);
        GetApiMaintenanceBinding(manifest);
        if (manifest.CutoverBoundaryFingerprint != DatabaseUpgradePlatformObserver.Fingerprint(manifest.Cutover!))
            throw new ArgumentException("UpgradeCutover: the typed platform contract differs from the Plan-bound cutover fingerprint.");
        if (!DatabaseUpgradeAttestation.IsFingerprint(manifest.CutoverBoundaryFingerprint))
            throw new ArgumentException("A canonical cutover boundary fingerprint is required before database access.");
        if (scripts.Count != manifest.Scripts.Count)
            throw new ArgumentException("Loaded SQL must match the exact manifest; SourceOnlyFull cannot load any SQL.");
        foreach (var script in manifest.Scripts)
        {
            if (!scripts.TryGetValue(script.Name, out var sql) ||
                !DatabaseUpgradeAttestation.Fingerprint(sql).Equals(script.Sha256, StringComparison.Ordinal))
                throw new InvalidOperationException("The loaded SQL checksum or required script differs from the approved manifest.");
        }
    }

    internal static void AssertPriorCapabilityFacts(string json, DatabaseUpgradeManifest manifest) =>
        CapabilityPreparationBuilder.ValidateObservedFacts(json, manifest.DeploymentOwnershipId,
            manifest.OriginalAcceptedSourceFingerprint, manifest.SchemaVersion == 2 ? manifest.Cutover : null);

    public static DatabaseUpgradeApiMaintenanceBinding GetApiMaintenanceBinding(DatabaseUpgradeManifest manifest)
    {
        var binding = new DatabaseUpgradeApiMaintenanceBinding(manifest.PlanFingerprint, manifest.UpgradeSourceFingerprint,
            DatabaseUpgradePlatformObserver.ComputeCutoverId(manifest.PlanFingerprint, manifest.CutoverBoundaryFingerprint ?? ""),
            manifest.CutoverApiImage ?? "");
        DatabaseUpgradePlatformObserver.AssertApiMaintenanceBinding(manifest.Cutover
            ?? throw new ArgumentException("UpgradeCutover: the typed platform contract is required."), binding);
        return binding;
    }

    private static string SerializeCommit(string manifestFingerprint, string intentJson,
        DatabaseUpgradePurviewPreservationProof? purviewProof = null, DatabaseUpgradeQueueQuarantineProof? queueProof = null)
    {
        var intent = ParseIntent(intentJson);
        AssertPurviewProofBinding(intent.PurviewPreservation, purviewProof);
        AssertQueueProofBinding(intent.QueueQuarantine, queueProof);
        return JsonSerializer.Serialize(new DatabaseUpgradeCommit(1, manifestFingerprint,
            DatabaseUpgradeAttestation.Fingerprint(intentJson), "SqlCommittedPostVerificationPending", purviewProof, queueProof), JsonOptions);
    }

    private static DatabaseUpgradeIntent ParseIntent(string json)
    {
        using var document = JsonDocument.Parse(json);
        AssertNoDuplicateProperties(document.RootElement);
        var intent = JsonSerializer.Deserialize<DatabaseUpgradeIntent>(json, JsonOptions)
            ?? throw new InvalidOperationException("UpgradeCutoverEvidenceMismatch: the preservation intent is absent.");
        intent.PurviewPreservation?.AssertValid();
        intent.QueueQuarantine?.AssertValid("SqlBefore");
        if (JsonSerializer.Serialize(intent, JsonOptions) != json)
            throw new InvalidOperationException("UpgradeCutoverEvidenceMismatch: the preservation intent is not canonical.");
        return intent;
    }

    internal static void AssertPurviewProofBinding(DatabaseUpgradePurviewPreservationStart? before,
        DatabaseUpgradePurviewPreservationProof? proof)
    {
        before?.AssertValid();
        proof?.AssertValid();
        if (before != proof?.Start)
            throw new InvalidOperationException("UpgradePurviewPreservationMismatch: intent, commit and receipt must bind the same mandatory proof.");
    }

    internal static void AssertQueueProofBinding(DatabaseUpgradeQueueQuarantineObservation? before,
        DatabaseUpgradeQueueQuarantineProof? proof)
    {
        before?.AssertValid("SqlBefore");
        proof?.AssertValid();
        if (before != proof?.Before)
            throw new InvalidOperationException("UpgradeQueueQuarantineMismatch: intent, commit and receipt must bind the same mandatory count-only proof.");
    }

    private static void AssertReceiptBinding(DatabaseUpgradeReceipt receipt, DatabaseUpgradeManifest manifest, string markerFingerprint)
    {
        if (receipt.PurviewPreservation is not null) AssertSourceOnlyPreservationManifest(manifest);
        if (receipt.QueueQuarantine is { } queues)
        {
            DatabaseUpgradeQueueQuarantine.AssertObservation(queues.Before, manifest, "SqlBefore");
            DatabaseUpgradeQueueQuarantine.AssertObservation(queues.After, manifest, "SqlAfter");
        }
        else if (manifest.QueueQuarantineBaseline is not null)
            throw new InvalidOperationException("UpgradeQueueQuarantineMissing: the Plan-bound quarantine proof is absent.");
        if (receipt.DeploymentOwnershipId != manifest.DeploymentOwnershipId ||
            receipt.OriginalAcceptedSourceFingerprint != manifest.OriginalAcceptedSourceFingerprint ||
            receipt.OriginalMarkerFingerprint != markerFingerprint || receipt.PlanFingerprint != manifest.PlanFingerprint ||
            receipt.UpgradeSourceFingerprint != manifest.UpgradeSourceFingerprint ||
            receipt.PreviousReceiptFingerprint != manifest.PreviousReceiptFingerprint ||
            receipt.BeforeSchemaFingerprint != manifest.BeforeSchemaFingerprint ||
            manifest.AfterSchemaFingerprint.Length != 0 && receipt.AfterSchemaFingerprint != manifest.AfterSchemaFingerprint ||
            receipt.TargetModelFingerprint != manifest.TargetModelFingerprint ||
            receipt.SqlManifestFingerprint != SqlManifestFingerprint(manifest) ||
            receipt.ExecutionIntentId != manifest.ExecutionIntentId || receipt.Server != manifest.Server ||
            receipt.Database != manifest.Database)
            throw new InvalidOperationException("An existing upgrade receipt does not match this exact approved execution.");
    }

    internal static void AssertNoDuplicateProperties(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in element.EnumerateObject())
            {
                if (!names.Add(property.Name))
                    throw new ArgumentException("The upgrade manifest contains duplicate properties.");
                AssertNoDuplicateProperties(property.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
            foreach (var item in element.EnumerateArray())
                AssertNoDuplicateProperties(item);
    }
}

public interface IDatabaseUpgradeEvidenceStore
{
    Task<string?> ReadAsync(string name);
    Task CreateAsync(string name, string value);
    IAsyncEnumerable<KeyValuePair<string, string>> ReadReceiptsAsync();
}

public sealed class BlobDatabaseUpgradeEvidenceStore(BlobContainerClient container) : IDatabaseUpgradeEvidenceStore
{
    public async Task<string?> ReadAsync(string name)
    {
        try
        {
            var response = await container.GetBlobClient(name).DownloadContentAsync();
            var bytes = response.Value.Content.ToArray();
            if (bytes.Length > 16384)
                throw new InvalidOperationException("The private upgrade evidence is oversized.");
            return new UTF8Encoding(false, true).GetString(bytes);
        }
        catch (RequestFailedException exception) when (exception.Status == 404 && exception.ErrorCode == "BlobNotFound")
        {
            return null;
        }
    }

    public async Task CreateAsync(string name, string value) =>
        await container.GetBlobClient(name).UploadAsync(BinaryData.FromString(value), new BlobUploadOptions
        {
            Conditions = new BlobRequestConditions { IfNoneMatch = ETag.All },
            HttpHeaders = new BlobHttpHeaders { ContentType = "application/json" }
        });

    public async IAsyncEnumerable<KeyValuePair<string, string>> ReadReceiptsAsync()
    {
        await foreach (var blob in container.GetBlobsAsync(prefix: "receipts/"))
        {
            var value = await ReadAsync(blob.Name)
                ?? throw new InvalidOperationException("A listed upgrade receipt disappeared.");
            yield return new(blob.Name, value);
        }
    }
}

public sealed class SqlDatabaseUpgradeStore(
    SqlConnection connection,
    IDatabaseUpgradeEvidenceStore evidence,
    Func<Task> assertOriginalMarkerBinding,
    Func<Task> assertExactCurrentSchemaAndPrincipals,
    HttpClient? platformClient = null,
    TokenCredential? platformCredential = null) : IDatabaseUpgradeStore
{
    private SqlTransaction? _preservationTransaction;
    private bool _cutoverObserved;
    private bool _platformCutoverObserved;
    private DatabaseUpgradeManifest? _observedManifest;
    private DateTimeOffset? _platformDeadline;
    private DatabaseUpgradePurviewScope? _purviewScope;
    private DatabaseUpgradePurviewPreservationStart? _purviewBefore;
    private bool _purviewPreservationVerified;
    private DatabaseUpgradeQueueQuarantineObservation? _queueBefore;
    private bool _queuePreservationVerified;
    private string? _registrationProjection;
    private string? _credentialProjection;

    public SqlDatabaseUpgradeStore(SqlConnection connection, BlobContainerClient container,
        Func<Task> assertOriginalMarkerBinding, Func<Task> assertExactCurrentSchemaAndPrincipals)
        : this(connection, new BlobDatabaseUpgradeEvidenceStore(container), assertOriginalMarkerBinding, assertExactCurrentSchemaAndPrincipals)
    {
    }

    public async Task AcquireAsync()
    {
        await using var command = connection.CreateCommand();
        command.CommandTimeout = 60;
        command.CommandText = """
            DECLARE @result int;
            EXEC @result = sys.sp_getapplock @Resource=N'A365Gateway:MaintenanceUpgrade',
                @LockMode=N'Exclusive', @LockOwner=N'Session', @LockTimeout=0;
            SELECT @result;
            """;
        if (Convert.ToInt32(await command.ExecuteScalarAsync()) < 0)
            throw new InvalidOperationException("Another maintenance upgrade owns the database lock.");
    }

    public async Task ReleaseAsync()
    {
        _cutoverObserved = false;
        _platformCutoverObserved = false;
        _observedManifest = null;
        _platformDeadline = null;
        _purviewScope = null;
        _purviewBefore = null;
        _purviewPreservationVerified = false;
        _queueBefore = null;
        _queuePreservationVerified = false;
        if (_preservationTransaction is not null)
        {
            await _preservationTransaction.RollbackAsync();
            await _preservationTransaction.DisposeAsync();
            _preservationTransaction = null;
        }
        if (connection.State != System.Data.ConnectionState.Open) return;
        await using var command = connection.CreateCommand();
        command.CommandTimeout = 30;
        command.CommandText = "EXEC sys.sp_releaseapplock @Resource=N'A365Gateway:MaintenanceUpgrade', @LockOwner=N'Session';";
        await command.ExecuteNonQueryAsync();
    }

    public async Task<string?> ReadMetadataAsync(string name)
    {
        AssertMetadataName(name, allowOriginal: true);
        if (name != DatabaseUpgradeAttestation.OriginalMarkerName)
            return await evidence.ReadAsync(GetBlobName(name));
        await using var command = connection.CreateCommand();
        command.CommandTimeout = 30;
        command.CommandText = """
            SELECT name, CONVERT(nvarchar(max), value) FROM sys.extended_properties
            WHERE class=0 AND major_id=0 AND minor_id=0 AND name=@name;
            """;
        command.Parameters.AddWithValue("@name", name);
        await using var reader = await command.ExecuteReaderAsync();
        if (!await reader.ReadAsync()) return null;
        if (reader.GetString(0) != name || reader.IsDBNull(1))
            throw new InvalidOperationException("Database maintenance metadata is not exact.");
        var value = reader.GetString(1);
        if (await reader.ReadAsync())
            throw new InvalidOperationException("Database maintenance metadata is ambiguous.");
        return value;
    }

    public async Task AddMetadataAsync(string name, string value)
    {
        AssertMetadataName(name, allowOriginal: false);
        if (value.Length > DatabaseUpgradeAttestation.MaximumReceiptCharacters)
            throw new ArgumentException("Database maintenance metadata exceeds its bound.");
        await evidence.CreateAsync(GetBlobName(name), value);
    }

    public Task<string> ReadSchemaFingerprintAsync() => DatabaseSchemaFingerprintReader.ReadFingerprintAsync(connection);
    public Task AssertOriginalMarkerBindingAsync() => assertOriginalMarkerBinding();
    public Task AssertExactCurrentSchemaAndPrincipalsAsync() => assertExactCurrentSchemaAndPrincipals();

    public async Task<string> ReadCapabilityFactsAsync(DatabaseUpgradeManifest manifest)
    {
        if (_preservationTransaction is not null)
            throw new InvalidOperationException("Capability baseline read must occur outside the schema-write transaction.");
        var options = new DbContextOptionsBuilder<GatewayDbContext>().UseSqlServer(connection).Options;
        await using var context = new GatewayDbContext(options);
        var rows = await context.ProtectionCapabilities.AsNoTracking().ToArrayAsync();
        if (rows.Length != 3 ||
            !rows.Select(row => row.Kind).Order().SequenceEqual(Enum.GetValues<ProtectionCapabilityKind>()) ||
            rows.Any(row => row.LastReadbackAtUtc is null || row.LastFailureCode is not null ||
                !DatabaseUpgradeAttestation.HasExpectedCapabilityIdentity(row, Guid.ParseExact(manifest.DeploymentOwnershipId, "D")) ||
                row.ResourceIdentifiers.BootstrapDeploymentOwnershipId?.ToString("D") != manifest.DeploymentOwnershipId ||
                row.ResourceIdentifiers.BootstrapSourceFingerprint != manifest.OriginalAcceptedSourceFingerprint) ||
            rows.Select(row => row.LastReadbackAtUtc).Distinct().Count() != 1)
            throw new InvalidOperationException("The private database did not expose three exact verified same-deployment capability facts.");
        var attestation = new BootstrapProtectionCapabilityAttestation(
            Guid.ParseExact(manifest.DeploymentOwnershipId, "D"),
            manifest.OriginalAcceptedSourceFingerprint,
            DateTime.SpecifyKind(rows[0].LastReadbackAtUtc!.Value, DateTimeKind.Utc),
            rows.OrderBy(row => row.Kind).Select(row =>
                new BootstrapProtectionCapabilityFact(row.Kind, row.Status, row.ResourceIdentifiers)).ToArray());
        var json = CapabilityPreparationContract.FactsJson(attestation);
        DatabaseUpgradeExecution.AssertPriorCapabilityFacts(json, manifest);
        return json;
    }

    public async Task BeginPreservationWindowAsync()
    {
        if (_preservationTransaction is not null)
            throw new InvalidOperationException("The upgrade already owns a preservation transaction.");
        _cutoverObserved = false;
        _platformCutoverObserved = false;
        _observedManifest = null;
        _platformDeadline = null;
        _purviewScope = null;
        _purviewBefore = null;
        _purviewPreservationVerified = false;
        _queueBefore = null;
        _queuePreservationVerified = false;
        _preservationTransaction = (SqlTransaction)await connection.BeginTransactionAsync(System.Data.IsolationLevel.Serializable);
    }

    public async Task AssertPlatformCutoverBoundaryAsync(DatabaseUpgradeManifest manifest)
        => await AssertPlatformCutoverBoundaryAsync(manifest, quarantine: null);

    private async Task<DatabaseUpgradeQueueQuarantineObservation?> AssertPlatformCutoverBoundaryAsync(
        DatabaseUpgradeManifest manifest, DatabaseUpgradeQueueQuarantineCheck? quarantine)
    {
        _platformCutoverObserved = false;
        _cutoverObserved = false;
        DatabaseUpgradePlatformObserver.AssertContract(manifest.Cutover, manifest.CutoverOriginalRevisionResourceIds);
        _platformDeadline ??= DateTimeOffset.UtcNow.AddSeconds(manifest.Cutover!.TimeoutSeconds);
        var remaining = _platformDeadline.Value - DateTimeOffset.UtcNow;
        if (remaining <= TimeSpan.Zero)
            throw new InvalidOperationException("UpgradeCutoverPlatformUnknown: the held observation deadline expired.");
        using var deadline = new CancellationTokenSource(remaining);
        var maintenance = DatabaseUpgradeExecution.GetApiMaintenanceBinding(manifest);
        if ((platformClient is null) != (platformCredential is null))
            throw new InvalidOperationException("Both native platform transports must be supplied together.");
        var observation = platformClient is not null
            ? await DatabaseUpgradePlatformObserver.AssertWithTransportAsync(manifest.Cutover!, manifest.DeploymentOwnershipId,
                manifest.OriginalAcceptedSourceFingerprint, platformClient, platformCredential!, manifest.CutoverOriginalRevisionResourceIds,
                cancellationToken: deadline.Token, apiMaintenance: maintenance, quarantine: quarantine)
            : await DatabaseUpgradePlatformObserver.AssertPrivateAsync(manifest.Cutover!, manifest.DeploymentOwnershipId,
                manifest.OriginalAcceptedSourceFingerprint, manifest.CutoverOriginalRevisionResourceIds,
                cancellationToken: deadline.Token, apiMaintenance: maintenance, quarantine: quarantine);
        _observedManifest = manifest;
        _platformCutoverObserved = true;
        return observation;
    }

    public async Task<DatabaseUpgradeQueueQuarantineObservation> AssertSourceOnlyQueuesAsync(DatabaseUpgradeManifest manifest, string phase)
    {
        DatabaseUpgradeQueueQuarantine.AssertBaseline(manifest);
        if (_preservationTransaction is null || phase is not ("SqlBefore" or "SqlAfter") ||
            (phase == "SqlBefore" ? _queueBefore is not null : _queueBefore is null || _queuePreservationVerified))
            throw new InvalidOperationException("UpgradeQueueQuarantineInvalid: an active held transaction and one immutable before/after observation are required.");
        var observation = await AssertPlatformCutoverBoundaryAsync(manifest, new(manifest, phase))
            ?? throw new InvalidOperationException("UpgradeQueueQuarantineMissing: private queue observation is absent.");
        if (phase == "SqlBefore") _queueBefore = observation;
        else
        {
            new DatabaseUpgradeQueueQuarantineProof(_queueBefore!, observation).AssertValid();
            _queuePreservationVerified = true;
            _platformCutoverObserved = false;
        }
        return observation;
    }

    public async Task<DatabaseUpgradePurviewPreservationStart?> AssertSourceOnlyCutoverBoundaryAsync(DatabaseUpgradeManifest manifest)
    {
        DatabaseUpgradeExecution.AssertSourceOnlyPreservationManifest(manifest);
        _cutoverObserved = false;
        if (_queueBefore is null || !_platformCutoverObserved || !ReferenceEquals(_observedManifest, manifest))
            throw new InvalidOperationException("UpgradeCutoverPlatformObserverMissing: SourceOnlyFull requires its exact privately observed manifest.");
        if (_purviewScope is not null)
            throw new InvalidOperationException("UpgradePurviewPreservationInvalid: an existing before observation cannot be replaced.");
        _platformCutoverObserved = false;
        var transaction = _preservationTransaction
            ?? throw new InvalidOperationException("SourceOnlyFull observation requires the preservation transaction.");
        _purviewScope = await DatabaseUpgradeCutoverObserver.AssertSourceOnlySafeAsync(connection, transaction, manifest);
        if (_purviewScope is null) return null;
        _purviewBefore = new(1, "SafePreservedHumanWaits", _purviewScope.OperationIds.Length,
            await DatabaseUpgradePurviewPreservation.FingerprintAsync(connection, transaction, _purviewScope));
        return _purviewBefore;
    }

    public async Task<DatabaseUpgradePurviewPreservationProof> AssertPurviewPreservedAsync(DatabaseUpgradePurviewPreservationStart before)
    {
        if (_purviewBefore != before || _purviewScope is null || _observedManifest is null || _preservationTransaction is null)
            throw new InvalidOperationException("UpgradePurviewPreservationMissing: no matching held before observation exists.");
        var afterScope = await DatabaseUpgradeCutoverObserver.AssertSourceOnlySafeAsync(connection, _preservationTransaction, _observedManifest);
        if (afterScope is null || !_purviewScope.OperationIds.SequenceEqual(afterScope.OperationIds) ||
            !_purviewScope.ConnectionIds.SequenceEqual(afterScope.ConnectionIds))
            throw new InvalidOperationException("UpgradePurviewPreservationMismatch: admitted record membership changed.");
        var proof = new DatabaseUpgradePurviewPreservationProof(1, "SafePreservedHumanWaits", before.OperationCount,
            before.BeforeFingerprint, await DatabaseUpgradePurviewPreservation.FingerprintAsync(connection, _preservationTransaction, _purviewScope));
        proof.AssertValid();
        _purviewPreservationVerified = true;
        return proof;
    }

    public async Task AssertDurableCutoverBoundaryAsync()
    {
        _cutoverObserved = false;
        if (!_platformCutoverObserved)
            throw new InvalidOperationException("UpgradeCutoverPlatformObserverMissing: SQL classification requires private platform closure verification.");
        _platformCutoverObserved = false;
        await DatabaseUpgradeCutoverObserver.AssertSafeAsync(connection, _preservationTransaction
            ?? throw new InvalidOperationException("The durable cutover observer requires the preservation transaction."));
        _cutoverObserved = true;
    }

    public async Task AssertPostUpgradeCutoverBoundaryAsync(bool forRollback = true)
    {
        _cutoverObserved = false;
        if (!_platformCutoverObserved)
            throw new InvalidOperationException("UpgradeCutoverPlatformObserverMissing: post-upgrade classification requires private platform closure verification.");
        _platformCutoverObserved = false;
        await DatabaseUpgradeCutoverObserver.AssertPostUpgradeSafeAsync(connection, _preservationTransaction
            ?? throw new InvalidOperationException("Post-upgrade observation requires the preservation transaction."), forRollback);
        // This read-only classification deliberately does not authorize ApplyAsync.
    }

    public async Task CommitPreservationWindowAsync()
    {
        if (_purviewScope is not null && !_purviewPreservationVerified)
            throw new InvalidOperationException("UpgradePurviewPreservationMissing: commit requires exact after proof.");
        if (_queueBefore is not null && !_queuePreservationVerified)
            throw new InvalidOperationException("UpgradeQueueQuarantineMissing: commit requires its own matching after observation.");
        await using var transaction = _preservationTransaction
            ?? throw new InvalidOperationException("The upgrade preservation transaction is absent.");
        // Never ask ReleaseAsync to roll back an acknowledged or indeterminate commit.
        _preservationTransaction = null;
        _cutoverObserved = false;
        _platformCutoverObserved = false;
        _observedManifest = null;
        _platformDeadline = null;
        _purviewScope = null;
        _purviewBefore = null;
        _purviewPreservationVerified = false;
        _queueBefore = null;
        _queuePreservationVerified = false;
        await transaction.CommitAsync();
    }

    public async Task AssertReceiptHistoryAsync(DatabaseUpgradeManifest manifest, string? expectedTipFingerprint)
    {
        var originalMarker = await ReadMetadataAsync(DatabaseUpgradeAttestation.OriginalMarkerName)
            ?? throw new InvalidOperationException("The original initialization marker is missing.");
        var originalMarkerFingerprint = DatabaseUpgradeAttestation.Fingerprint(originalMarker);
        var receipts = new Dictionary<string, DatabaseUpgradeReceipt>(StringComparer.Ordinal);
        await foreach (var entry in evidence.ReadReceiptsAsync())
        {
            if (receipts.Count >= 64 || !Regex.IsMatch(entry.Key, "^receipts/[0-9a-f]{64}\\.json$", RegexOptions.CultureInvariant))
                throw new InvalidOperationException("The bounded database upgrade receipt history is malformed or oversized.");
            if (entry.Value.Length > DatabaseUpgradeAttestation.MaximumReceiptCharacters)
                throw new InvalidOperationException("An upgrade history receipt is oversized.");
            var json = entry.Value;
            var receipt = DatabaseUpgradeAttestation.Parse(json);
            if (receipt.DeploymentOwnershipId != manifest.DeploymentOwnershipId ||
                receipt.OriginalAcceptedSourceFingerprint != manifest.OriginalAcceptedSourceFingerprint ||
                receipt.OriginalMarkerFingerprint != originalMarkerFingerprint ||
                receipt.Server != manifest.Server || receipt.Database != manifest.Database ||
                entry.Key != $"receipts/{receipt.PlanFingerprint[7..]}.json" ||
                !receipts.TryAdd(DatabaseUpgradeAttestation.Fingerprint(json), receipt))
                throw new InvalidOperationException("An upgrade history receipt has a conflicting deployment binding.");
        }
        if (expectedTipFingerprint is null)
        {
            if (receipts.Count != 0)
                throw new InvalidOperationException("A previous verified upgrade exists and must be bound explicitly.");
            return;
        }
        if (!receipts.ContainsKey(expectedTipFingerprint))
            throw new InvalidOperationException("The expected previous upgrade receipt is unavailable.");
        var referenced = new HashSet<string>(StringComparer.Ordinal);
        foreach (var receipt in receipts.Values)
        {
            if (receipt.PreviousReceiptFingerprint is not { } previous) continue;
            if (!receipts.TryGetValue(previous, out var parent) ||
                parent.AfterSchemaFingerprint != receipt.BeforeSchemaFingerprint ||
                parent.OriginalMarkerFingerprint != receipt.OriginalMarkerFingerprint ||
                !referenced.Add(previous))
                throw new InvalidOperationException("Upgrade receipt history is broken or branched.");
        }
        var tips = receipts.Keys.Where(key => !referenced.Contains(key)).ToArray();
        if (tips.Length != 1 || tips[0] != expectedTipFingerprint)
            throw new InvalidOperationException("The requested receipt is not the unique current upgrade history tip.");
        var tip = receipts[expectedTipFingerprint];
        var expectedTipSchema = tip.PlanFingerprint == manifest.PlanFingerprint
            ? (manifest.AfterSchemaFingerprint.Length == 0 ? tip.AfterSchemaFingerprint : manifest.AfterSchemaFingerprint)
            : manifest.BeforeSchemaFingerprint;
        if (tip.AfterSchemaFingerprint != expectedTipSchema)
            throw new InvalidOperationException("The current upgrade history tip does not match the expected schema boundary.");
        var visited = new HashSet<string>(StringComparer.Ordinal);
        string? cursor = expectedTipFingerprint;
        while (cursor is not null)
        {
            if (!visited.Add(cursor))
                throw new InvalidOperationException("Upgrade receipt history contains a cycle.");
            cursor = receipts[cursor].PreviousReceiptFingerprint;
        }
        if (visited.Count != receipts.Count)
            throw new InvalidOperationException("Upgrade receipt history contains disconnected evidence.");
    }

    public async Task<string> ReadRegistrationIdentityFingerprintAsync()
    {
        _registrationProjection ??= await ReadOriginalColumnProjectionAsync("dbo.AgentRegistrations");
        _credentialProjection ??= await ReadOriginalColumnProjectionAsync("dbo.AgentIngressCredentials");
        await using var command = connection.CreateCommand();
        command.CommandTimeout = 60;
        command.Transaction = _preservationTransaction
            ?? throw new InvalidOperationException("Registration preservation requires its serialized transaction.");
        command.CommandText = $"""
            SELECT (SELECT
              JSON_QUERY((SELECT {_registrationProjection}
                FROM dbo.AgentRegistrations WITH (TABLOCKX, HOLDLOCK) ORDER BY Id FOR JSON PATH, INCLUDE_NULL_VALUES)) AS registrations,
              JSON_QUERY((SELECT {_credentialProjection}
                FROM dbo.AgentIngressCredentials WITH (TABLOCKX, HOLDLOCK) ORDER BY Id FOR JSON PATH, INCLUDE_NULL_VALUES)) AS credentials
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
            """;
        var value = await command.ExecuteScalarAsync();
        if (value is not string json)
            throw new InvalidOperationException("Registration-preservation metadata was not available.");
        return DatabaseUpgradeAttestation.Fingerprint(json);
    }

    private async Task<string> ReadOriginalColumnProjectionAsync(string table)
    {
        if (table is not ("dbo.AgentRegistrations" or "dbo.AgentIngressCredentials"))
            throw new ArgumentException("Preservation projection is outside the exact Gateway tables.");
        await using var command = connection.CreateCommand();
        command.Transaction = _preservationTransaction
            ?? throw new InvalidOperationException("Preservation metadata requires the serialized transaction.");
        command.CommandTimeout = 30;
        command.CommandText = """
            SELECT name FROM sys.columns
            WHERE object_id=OBJECT_ID(@table, N'U') AND system_type_id <> 189
            ORDER BY column_id;
            """;
        command.Parameters.AddWithValue("@table", table);
        var columns = new List<string>();
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var column = reader.GetString(0);
            columns.Add("[" + column.Replace("]", "]]", StringComparison.Ordinal) + "]");
        }
        if (columns.Count is < 1 or > 128 || !columns.Contains("[Id]", StringComparer.Ordinal))
            throw new InvalidOperationException("The original registration preservation projection is incomplete.");
        return string.Join(", ", columns);
    }

    public async Task ApplyAsync(string sql)
    {
        if (!_cutoverObserved)
            throw new InvalidOperationException("Upgrade SQL requires a successful durable cutover observation in this preservation transaction.");
        foreach (var batch in Regex.Split(sql, @"^\s*GO\s*(?:--.*)?$", RegexOptions.Multiline | RegexOptions.IgnoreCase))
        {
            if (string.IsNullOrWhiteSpace(batch)) continue;
            await using var command = connection.CreateCommand();
            command.CommandTimeout = 300;
            command.Transaction = _preservationTransaction
                ?? throw new InvalidOperationException("Upgrade SQL requires the preservation transaction.");
            command.CommandText = batch;
            await command.ExecuteNonQueryAsync();
        }
    }

    private static void AssertMetadataName(string name, bool allowOriginal)
    {
        if (allowOriginal && name == DatabaseUpgradeAttestation.OriginalMarkerName) return;
        if (!Regex.IsMatch(name, "^A365GatewayUpgrade(?:Intent|Commit|Receipt):[0-9a-f]{64}$", RegexOptions.CultureInvariant))
            throw new ArgumentException("Only separate versioned maintenance metadata may be created.");
    }

    private static string GetBlobName(string name) =>
        (name.StartsWith(DatabaseUpgradeExecution.IntentPrefix, StringComparison.Ordinal) ? "intents/" :
            name.StartsWith(DatabaseUpgradeExecution.CommitPrefix, StringComparison.Ordinal) ? "commits/" : "receipts/") +
        name[(name.IndexOf(':') + 1)..] + ".json";
}
