using System.Security.Cryptography;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Azure.Core;
using Azure.Identity;
using Gateway.DatabaseMigrator;
using Gateway.Infrastructure.Persistence;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Metadata;
using Microsoft.EntityFrameworkCore.Migrations;

var options = ParseArguments(args);
var server = Required(options, "server");
var database = Required(options, "database");
var phase = Required(options, "phase").ToLowerInvariant();
var repositoryRoot = ResolveRepositoryRoot(ReadOption(options, "repository-root"));
var principalName = ReadOption(options, "principal-name");
var principalClientIdValue = ReadOption(options, "principal-client-id");
var deploymentOwnershipIdValue = ReadOption(options, "deployment-ownership-id");
var acceptedSourceFingerprint = ReadOption(options, "accepted-source-fingerprint");
var expectedApiPrincipalName = ReadOption(options, "expected-api-principal-name");
var expectedApiPrincipalClientIdValue = ReadOption(options, "expected-api-principal-client-id");
var expectedWorkerPrincipalName = ReadOption(options, "expected-worker-principal-name");
var expectedWorkerPrincipalClientIdValue = ReadOption(options, "expected-worker-principal-client-id");
var expectedPrivateEndpointIpValue = ReadOption(options, "expected-private-endpoint-ip");
var executionIntentIdValue = ReadOptionWithExactEnvironmentAgreement(
    options,
    "execution-intent-id");
var repeat = int.TryParse(ReadOption(options, "repeat") ?? "1", out var parsedRepeat)
    ? parsedRepeat
    : 0;
var pristineDiagnosticOnlyEnvironmentValue =
    Environment.GetEnvironmentVariable("DATABASE_MIGRATOR_PRISTINE_DIAGNOSTIC_ONLY");
if (!string.IsNullOrWhiteSpace(pristineDiagnosticOnlyEnvironmentValue))
{
    throw new ArgumentException(
        "DATABASE_MIGRATOR_PRISTINE_DIAGNOSTIC_ONLY is forbidden; diagnostic mode requires the explicit command-line option.");
}
var pristineDiagnosticOnly =
    options.TryGetValue("pristine-diagnostic-only", out var pristineDiagnosticOnlyValue);
var requiredRecoveryModeEnvironmentValue =
    Environment.GetEnvironmentVariable("DATABASE_MIGRATOR_REQUIRED_RECOVERY_MODE");
if (!string.IsNullOrWhiteSpace(requiredRecoveryModeEnvironmentValue))
{
    throw new ArgumentException(
        "DATABASE_MIGRATOR_REQUIRED_RECOVERY_MODE is forbidden; recovery classification requires the explicit command-line option.");
}
var requiredRecoveryModeWasProvided =
    options.TryGetValue("required-recovery-mode", out var requiredRecoveryModeValue);

if (!server.EndsWith(".database.windows.net", StringComparison.OrdinalIgnoreCase) ||
    server.Any(char.IsWhiteSpace))
{
    throw new ArgumentException("--server must be an Azure SQL logical-server FQDN.");
}

if (string.IsNullOrWhiteSpace(database) ||
    database.Equals("master", StringComparison.OrdinalIgnoreCase) ||
    database.IndexOfAny([';', '\r', '\n']) >= 0)
{
    throw new ArgumentException("--database must identify a non-system database.");
}

if (phase is not ("initialize" or "bootstrap" or "baseline" or "prepare" or "finalize" or "verify" or "principal"))
{
    throw new ArgumentException(
        "--phase must be initialize, bootstrap, baseline, prepare, finalize, verify, or principal.");
}

if (pristineDiagnosticOnly &&
    (phase != "bootstrap" ||
     !pristineDiagnosticOnlyValue!.Equals("true", StringComparison.Ordinal)))
{
    throw new ArgumentException(
        "--pristine-diagnostic-only must be the exact value true and is allowed only for the bootstrap phase.");
}

DatabaseInitializationRecoveryMode? requiredRecoveryMode = null;
if (requiredRecoveryModeWasProvided)
{
    if (phase != "bootstrap" ||
        !string.Equals(
            requiredRecoveryModeValue,
            nameof(DatabaseInitializationRecoveryMode.ResumeAfterSchemaCompleted),
            StringComparison.Ordinal))
    {
        throw new ArgumentException(
            "--required-recovery-mode must be the exact value ResumeAfterSchemaCompleted and is allowed only for the one-shot bootstrap database recovery job.");
    }
    requiredRecoveryMode = DatabaseInitializationRecoveryMode.ResumeAfterSchemaCompleted;
}

Guid? executionIntentId = null;
if (phase == "bootstrap")
{
    if (!Guid.TryParseExact(executionIntentIdValue, "D", out var parsedExecutionIntentId) ||
        parsedExecutionIntentId == Guid.Empty ||
        executionIntentIdValue != parsedExecutionIntentId.ToString("D"))
    {
        throw new ArgumentException(
            "--execution-intent-id must be the canonical lowercase non-empty GUID for this bootstrap execution.");
    }
    executionIntentId = parsedExecutionIntentId;
}
else if (options.ContainsKey("execution-intent-id") ||
         !string.IsNullOrWhiteSpace(executionIntentIdValue))
{
    throw new ArgumentException("--execution-intent-id is allowed only for the bootstrap phase.");
}

Guid? deploymentOwnershipId = null;
if (!string.IsNullOrWhiteSpace(deploymentOwnershipIdValue) ||
    !string.IsNullOrWhiteSpace(acceptedSourceFingerprint))
{
    if (!Guid.TryParseExact(deploymentOwnershipIdValue, "D", out var parsedDeploymentOwnershipId) ||
        parsedDeploymentOwnershipId == Guid.Empty ||
        deploymentOwnershipIdValue != parsedDeploymentOwnershipId.ToString("D"))
    {
        throw new ArgumentException(
            "--deployment-ownership-id must be the canonical lowercase non-empty GUID from the accepted bootstrap state.");
    }
    if (acceptedSourceFingerprint is null ||
        !Regex.IsMatch(acceptedSourceFingerprint, "^sha256:[0-9a-f]{64}$", RegexOptions.CultureInvariant))
    {
        throw new ArgumentException(
            "--accepted-source-fingerprint must be the canonical SHA-256 fingerprint from the accepted bootstrap source.");
    }
    deploymentOwnershipId = parsedDeploymentOwnershipId;
}
if (phase is "initialize" or "bootstrap" &&
    (deploymentOwnershipId is null || string.IsNullOrWhiteSpace(acceptedSourceFingerprint)))
{
    throw new ArgumentException(
        $"The {phase} phase requires --deployment-ownership-id and --accepted-source-fingerprint for durable recovery binding.");
}

var expectedPrincipalArgumentCount = new[]
{
    expectedApiPrincipalName,
    expectedApiPrincipalClientIdValue,
    expectedWorkerPrincipalName,
    expectedWorkerPrincipalClientIdValue
}.Count(value => !string.IsNullOrWhiteSpace(value));
if (expectedPrincipalArgumentCount is not (0 or 4))
{
    throw new ArgumentException(
        "The expected API and worker principal names/client IDs must be supplied together.");
}
var expectedRuntimePrincipals = new List<ExpectedDatabasePrincipal>();
if (expectedPrincipalArgumentCount == 4)
{
    expectedRuntimePrincipals.Add(ParseExpectedDatabasePrincipal(
        expectedApiPrincipalName!,
        expectedApiPrincipalClientIdValue!,
        "API",
        expectedDirectPermissionCount: 2));
    expectedRuntimePrincipals.Add(ParseExpectedDatabasePrincipal(
        expectedWorkerPrincipalName!,
        expectedWorkerPrincipalClientIdValue!,
        "worker",
        expectedDirectPermissionCount: 1));
    if (expectedRuntimePrincipals.Select(item => item.Name).Distinct(StringComparer.Ordinal).Count() != 2 ||
        expectedRuntimePrincipals.Select(item => item.ClientId).Distinct().Count() != 2)
    {
        throw new ArgumentException("The expected API and worker database principals must be distinct.");
    }
}
if (deploymentOwnershipId is not null && expectedRuntimePrincipals.Count != 2)
{
    throw new ArgumentException(
        "Bootstrap-bound database work requires both exact expected Gateway runtime principals.");
}

if (phase == "bootstrap" &&
    (!string.IsNullOrWhiteSpace(principalName) || !string.IsNullOrWhiteSpace(principalClientIdValue)))
{
    throw new ArgumentException(
        "The bootstrap phase accepts only the exact expected API and worker principal arguments; standalone --principal-name and --principal-client-id are not allowed.");
}

var requireAllExpectedPrincipalsAfterMutation = false;
if (ReadOption(options, "require-all-expected-principals-after-mutation") is { } requireAllValue &&
    (!bool.TryParse(requireAllValue, out requireAllExpectedPrincipalsAfterMutation) ||
     phase != "principal"))
{
    throw new ArgumentException(
        "--require-all-expected-principals-after-mutation must be a Boolean used only by the final principal phase.");
}

Guid? principalClientId = null;
if (phase == "principal")
{
    if (string.IsNullOrWhiteSpace(principalName) ||
        !Regex.IsMatch(principalName, @"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
    {
        throw new ArgumentException(
            "--principal-name is required for the principal phase and must use only letters, numbers, dots, underscores, or hyphens.");
    }

    if (!Guid.TryParse(principalClientIdValue, out var parsedPrincipalClientId))
        throw new ArgumentException("--principal-client-id must be a valid managed-identity application/client ID.");
    principalClientId = parsedPrincipalClientId;
}

if (repeat is < 1 or > 2)
    throw new ArgumentException("--repeat must be 1 or 2.");
if (phase == "bootstrap" && repeat != 1)
    throw new ArgumentException("The bootstrap phase requires --repeat 1.");
var stayAliveRequested = bool.TryParse(
    ReadOption(options, "stay-alive") ?? "false",
    out var stayAlive) && stayAlive;
if (phase == "bootstrap" && stayAliveRequested)
    throw new ArgumentException("The one-shot bootstrap phase does not allow --stay-alive true.");

System.Net.IPAddress? expectedPrivateEndpointIp = null;
if (phase == "bootstrap")
{
    expectedPrivateEndpointIp =
        SqlPrivateEndpointDnsConvergence.ParseCanonicalPrivateIpv4(expectedPrivateEndpointIpValue);
}
else if (options.ContainsKey("expected-private-endpoint-ip") ||
         !string.IsNullOrWhiteSpace(expectedPrivateEndpointIpValue))
{
    throw new ArgumentException(
        "--expected-private-endpoint-ip is allowed only for the bootstrap phase.");
}

var scripts = phase switch
{
    "prepare" or "bootstrap" => GetPrepareScriptNames(),
    "finalize" => new[] { "20260825_scoped_idempotency_finalize.sql" },
    _ => Array.Empty<string>()
};

var scriptDirectory = Path.Combine(repositoryRoot, "infrastructure", "sql");
var scriptEvidence = scripts.Select(name =>
{
    var path = Path.Combine(scriptDirectory, name);
    if (!File.Exists(path))
        throw new FileNotFoundException($"Required migration script was not found: {name}");

    var bytes = File.ReadAllBytes(path);
    return new ScriptEvidence(
        name,
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
        File.ReadAllText(path));
}).ToArray();

var managedIdentityEndpoint = Environment.GetEnvironmentVariable("IDENTITY_ENDPOINT");
if (phase == "bootstrap" && string.IsNullOrWhiteSpace(managedIdentityEndpoint))
{
    throw new InvalidOperationException(
        "The bootstrap phase requires the Container Apps managed-identity endpoint and never falls back to Azure CLI credentials.");
}
if (phase == "bootstrap")
{
    await SqlPrivateEndpointDnsConvergence.WaitForExactResolutionAsync(
        server,
        expectedPrivateEndpointIp!,
        CancellationToken.None);
}
TokenCredential credential = string.IsNullOrWhiteSpace(managedIdentityEndpoint)
    ? new AzureCliCredential()
    : new ManagedIdentityCredential();
var accessToken = await credential.GetTokenAsync(
    new TokenRequestContext(["https://database.windows.net/.default"]),
    CancellationToken.None);

var connectionString = new SqlConnectionStringBuilder
{
    DataSource = $"tcp:{server},1433",
    InitialCatalog = database,
    Encrypt = SqlConnectionEncryptOption.Mandatory,
    TrustServerCertificate = false,
    ConnectTimeout = 30,
    ApplicationName = "A365GatewayDatabaseMigrator"
}.ConnectionString;

await using var connection = new SqlConnection(connectionString)
{
    AccessToken = accessToken.Token
};
await connection.OpenAsync();

if (pristineDiagnosticOnly)
{
    var diagnosticLockResource = $"A365Gateway:DatabaseInitialize:{database}";
    await AcquireDatabaseInitializationLockAsync(connection, diagnosticLockResource);
    try
    {
        var platformDiagnostic = await ReadAzureSqlPristinePlatformDiagnosticAsync(connection);
        Console.WriteLine(
            $"Pristine Azure SQL platform diagnostic=[{platformDiagnostic.ToSafeSummary()}].");
        var auditSpecificationNameFingerprint =
            await ReadSingleAuditSpecificationNameFingerprintAsync(connection);
        Console.WriteLine(
            $"Pristine Azure SQL audit-specification name fingerprint={auditSpecificationNameFingerprint}.");
        var pristineSurface = await ReadPristineDatabaseSurfaceAfterAuditConvergenceAsync(connection);
        DatabaseBootstrapRecoveryContract.AssertPristine(pristineSurface);
        Console.WriteLine(
            "Pristine database diagnostic passed the exact count-only contract; no database mutation was attempted.");
    }
    finally
    {
        await ReleaseDatabaseInitializationLockAsync(connection, diagnosticLockResource);
    }
    return;
}

RuntimePrincipalEvidence? runtimePrincipalEvidence = null;
InitializationIntentEvidence? initializationIntentEvidence = null;
IReadOnlyList<MigrationEvidence>? bootstrapEvidence = null;
var currentEfModelReady = false;
if (phase == "initialize")
{
    initializationIntentEvidence = await EnsureEmptyDatabaseInitializedAsync(
        connection,
        server,
        database,
        deploymentOwnershipId!.Value,
        acceptedSourceFingerprint!,
        expectedRuntimePrincipals);
}
if (phase == "bootstrap")
{
    bootstrapEvidence = await BootstrapDatabaseAsync(
        connection,
        server,
        database,
        executionIntentId!.Value,
        deploymentOwnershipId!.Value,
        acceptedSourceFingerprint!,
        expectedRuntimePrincipals,
        scriptEvidence,
        requiredRecoveryMode);
}
if (phase == "principal")
{
    var principalLockResource = $"A365Gateway:DatabaseInitialize:{database}";
    await AcquireDatabaseInitializationLockAsync(connection, principalLockResource);
    try
    {
        if (deploymentOwnershipId is not null && acceptedSourceFingerprint is not null)
        {
            await AssertDatabaseInitializationMarkerBindingAsync(
                connection,
                server,
                database,
                deploymentOwnershipId.Value,
                acceptedSourceFingerprint);
        }
        await AssertCurrentEfModelSchemaAsync(
            connection,
            expectedRuntimePrincipals,
            allowAllRecoverablePrincipalPrefixes: true);
        runtimePrincipalEvidence = await EnsureRuntimePrincipalAsync(
            connection,
            principalName!,
            principalClientId!.Value,
            requireViewDefinition: expectedRuntimePrincipals
                .Single(item => item.Name.Equals(principalName, StringComparison.Ordinal))
                .ExpectedDirectPermissionCount == 2);
        await AssertCurrentEfModelSchemaAsync(
            connection,
            expectedRuntimePrincipals,
            allowAllRecoverablePrincipalPrefixes: !requireAllExpectedPrincipalsAfterMutation,
            requireAllExpectedPrincipals: requireAllExpectedPrincipalsAfterMutation);
        currentEfModelReady = true;
    }
    finally
    {
        await ReleaseDatabaseInitializationLockAsync(connection, principalLockResource);
    }
}

if (phase != "bootstrap")
{
    await ApplyMigrationScriptsAsync(connection, scriptEvidence, repeat);
}

if (phase is "initialize" or "finalize" or "verify")
{
    if (phase is "finalize" or "verify" &&
        deploymentOwnershipId is not null && acceptedSourceFingerprint is not null)
    {
        await AssertDatabaseInitializationMarkerBindingAsync(
            connection,
            server,
            database,
            deploymentOwnershipId.Value,
            acceptedSourceFingerprint);
    }
    await AssertCurrentEfModelSchemaAsync(
        connection,
        expectedRuntimePrincipals,
        allowAllRecoverablePrincipalPrefixes: phase == "initialize",
        requireAllExpectedPrincipals: expectedRuntimePrincipals.Count > 0 && phase is "finalize" or "verify");
    currentEfModelReady = true;
}

var currentSchemaFingerprint = currentEfModelReady
    ? await DatabaseSchemaFingerprintReader.ReadFingerprintAsync(connection)
    : string.Empty;
string evidenceJson;
SchemaVerification finalVerification;
if (bootstrapEvidence is not null)
{
    if (bootstrapEvidence.Count != 3)
        throw new InvalidOperationException("The combined bootstrap phase did not produce exactly three evidence records.");
    finalVerification = bootstrapEvidence[^1].Verification;
    evidenceJson = JsonSerializer.Serialize(
        bootstrapEvidence,
        new JsonSerializerOptions { WriteIndented = true });
}
else
{
    finalVerification = await VerifyAsync(
        connection,
        currentEfModelReady,
        currentSchemaFingerprint);
    AssertVerificationReachedRequiredState(phase, finalVerification);

    var evidence = new MigrationEvidence(
        DateTimeOffset.UtcNow,
        server,
        database,
        phase,
        repeat,
        scriptEvidence.Select(item => new MigrationScriptEvidence(item.Name, item.Sha256)).ToArray(),
        finalVerification,
        runtimePrincipalEvidence,
        initializationIntentEvidence,
        ExecutionIntentId: null);

    evidenceJson = JsonSerializer.Serialize(
        evidence,
        new JsonSerializerOptions { WriteIndented = true });
}
var evidencePath = ReadOption(options, "evidence");
if (!string.IsNullOrWhiteSpace(evidencePath))
{
    var absoluteEvidencePath = Path.GetFullPath(evidencePath);
    Directory.CreateDirectory(Path.GetDirectoryName(absoluteEvidencePath)!);
    await File.WriteAllTextAsync(
        absoluteEvidencePath,
        evidenceJson);
    Console.WriteLine($"Wrote non-secret migration evidence to {absoluteEvidencePath}.");
}

var evidenceStdoutRequested = bool.TryParse(
    ReadOption(options, "evidence-stdout") ?? "false",
    out var evidenceStdout) && evidenceStdout;
if (phase == "bootstrap")
{
    foreach (var line in DatabaseBootstrapEvidenceChunkProtocol.Encode(
                 evidenceJson,
                 executionIntentId!.Value))
    {
        Console.WriteLine(line);
    }
}
else if (evidenceStdoutRequested)
{
    Console.WriteLine(
        $"EVIDENCE_BASE64={Convert.ToBase64String(Encoding.UTF8.GetBytes(evidenceJson))}");
}

Console.WriteLine(
    $"Schema verification passed (current-ef-model={finalVerification.CurrentEfModelReady}, workflow-v2={finalVerification.WorkflowV2Ready}, " +
    $"legacy-global-indexes={finalVerification.LegacyGlobalIdempotencyUniqueIndexCount}).");

if (stayAliveRequested)
{
    Console.WriteLine("Migration completed; the diagnostic container will remain alive for evidence collection.");
    await Task.Delay(Timeout.InfiniteTimeSpan);
}

static async Task<IReadOnlyList<MigrationEvidence>> BootstrapDatabaseAsync(
    SqlConnection connection,
    string server,
    string database,
    Guid executionIntentId,
    Guid deploymentOwnershipId,
    string acceptedSourceFingerprint,
    IReadOnlyCollection<ExpectedDatabasePrincipal> expectedRuntimePrincipals,
    IReadOnlyList<ScriptEvidence> prepareScripts,
    DatabaseInitializationRecoveryMode? requiredRecoveryMode)
{
    if (expectedRuntimePrincipals.Count != 2 ||
        expectedRuntimePrincipals.Count(item => item.ExpectedDirectPermissionCount == 2) != 1 ||
        expectedRuntimePrincipals.Count(item => item.ExpectedDirectPermissionCount == 1) != 1)
    {
        throw new InvalidOperationException(
            "The combined bootstrap phase requires the exact reviewed API and worker database-principal contract.");
    }
    if (!prepareScripts.Select(item => item.Name).SequenceEqual(
            GetPrepareScriptNames(),
            StringComparer.Ordinal))
    {
        throw new InvalidOperationException(
            "The combined bootstrap phase requires the exact reviewed prepare-script allowlist.");
    }

    var apiPrincipal = expectedRuntimePrincipals.Single(
        item => item.ExpectedDirectPermissionCount == 2);
    var workerPrincipal = expectedRuntimePrincipals.Single(
        item => item.ExpectedDirectPermissionCount == 1);
    var lockResource = $"A365Gateway:DatabaseInitialize:{database}";
    await AcquireDatabaseInitializationLockAsync(connection, lockResource);
    try
    {
        var initializationIntent = await EnsureEmptyDatabaseInitializedUnderLockAsync(
            connection,
            server,
            database,
            deploymentOwnershipId,
            acceptedSourceFingerprint,
            expectedRuntimePrincipals,
            requiredRecoveryMode);
        await AssertCurrentEfModelSchemaAsync(
            connection,
            expectedRuntimePrincipals,
            allowAllRecoverablePrincipalPrefixes: true);

        await AssertDatabaseInitializationMarkerBindingAsync(
            connection,
            server,
            database,
            deploymentOwnershipId,
            acceptedSourceFingerprint);
        await AssertCurrentEfModelSchemaAsync(
            connection,
            expectedRuntimePrincipals,
            allowAllRecoverablePrincipalPrefixes: true);
        var apiPrincipalEvidence = await EnsureRuntimePrincipalAsync(
            connection,
            apiPrincipal.Name,
            apiPrincipal.ClientId,
            requireViewDefinition: true);
        await AssertCurrentEfModelSchemaAsync(
            connection,
            expectedRuntimePrincipals,
            allowAllRecoverablePrincipalPrefixes: true);

        await AssertDatabaseInitializationMarkerBindingAsync(
            connection,
            server,
            database,
            deploymentOwnershipId,
            acceptedSourceFingerprint);
        await AssertCurrentEfModelSchemaAsync(
            connection,
            expectedRuntimePrincipals,
            allowAllRecoverablePrincipalPrefixes: true);
        var workerPrincipalEvidence = await EnsureRuntimePrincipalAsync(
            connection,
            workerPrincipal.Name,
            workerPrincipal.ClientId,
            requireViewDefinition: false);
        await AssertCurrentEfModelSchemaAsync(
            connection,
            expectedRuntimePrincipals,
            requireAllExpectedPrincipals: true);

        await AssertDatabaseInitializationMarkerBindingAsync(
            connection,
            server,
            database,
            deploymentOwnershipId,
            acceptedSourceFingerprint);
        await ApplyMigrationScriptsAsync(connection, prepareScripts, repeat: 1);
        await AssertExpectedDatabaseAuthorityAsync(
            connection,
            expectedRuntimePrincipals,
            recoverableIncompletePrincipalName: null,
            allowAllRecoverablePrincipalPrefixes: false,
            requireAllExpectedPrincipals: true);

        var currentSchemaFingerprint =
            await DatabaseSchemaFingerprintReader.ReadFingerprintAsync(connection);
        var finalVerification = await VerifyAsync(
            connection,
            currentEfModelReady: true,
            currentSchemaFingerprint);
        AssertVerificationReachedRequiredState("bootstrap", finalVerification);
        var verifiedAtUtc = DateTimeOffset.UtcNow;
        var appliedScripts = prepareScripts
            .Select(item => new MigrationScriptEvidence(item.Name, item.Sha256))
            .ToArray();
        var canonicalExecutionIntentId = executionIntentId.ToString("D");

        return
        [
            new MigrationEvidence(
                verifiedAtUtc,
                server,
                database,
                "initialize",
                1,
                appliedScripts,
                finalVerification,
                RuntimePrincipal: null,
                InitializationIntent: initializationIntent,
                ExecutionIntentId: canonicalExecutionIntentId),
            new MigrationEvidence(
                verifiedAtUtc,
                server,
                database,
                "principal",
                1,
                appliedScripts,
                finalVerification,
                RuntimePrincipal: apiPrincipalEvidence,
                InitializationIntent: null,
                ExecutionIntentId: canonicalExecutionIntentId),
            new MigrationEvidence(
                verifiedAtUtc,
                server,
                database,
                "principal",
                1,
                appliedScripts,
                finalVerification,
                RuntimePrincipal: workerPrincipalEvidence,
                InitializationIntent: null,
                ExecutionIntentId: canonicalExecutionIntentId)
        ];
    }
    finally
    {
        await ReleaseDatabaseInitializationLockAsync(connection, lockResource);
    }
}

static async Task ApplyMigrationScriptsAsync(
    SqlConnection connection,
    IReadOnlyList<ScriptEvidence> scripts,
    int repeat)
{
    for (var pass = 1; pass <= repeat; pass++)
    {
        foreach (var script in scripts)
        {
            foreach (var batch in SplitSqlBatches(script.Sql))
            {
                await using var command = connection.CreateCommand();
                command.CommandTimeout = 300;
                command.CommandText = batch;
                await command.ExecuteNonQueryAsync();
            }
            Console.WriteLine($"Applied {script.Name} (pass {pass}/{repeat}).");
        }
    }
}

static void AssertVerificationReachedRequiredState(
    string phase,
    SchemaVerification verification)
{
    var verificationFailed = phase == "baseline"
        ? verification.WorkflowV2Ready || verification.LegacyGlobalIdempotencyUniqueIndexCount != 1
        : !verification.WorkflowV2Ready ||
          (phase is "initialize" or "bootstrap" or "principal" or "finalize" or "verify") && !verification.CurrentEfModelReady ||
          (phase == "finalize" && verification.LegacyGlobalIdempotencyUniqueIndexCount != 0);
    if (verificationFailed)
    {
        throw new InvalidOperationException("Database schema verification did not reach the required state.");
    }
}

static async Task<InitializationIntentEvidence> EnsureEmptyDatabaseInitializedAsync(
    SqlConnection connection,
    string server,
    string database,
    Guid deploymentOwnershipId,
    string acceptedSourceFingerprint,
    IReadOnlyCollection<ExpectedDatabasePrincipal> expectedRuntimePrincipals)
{
    var lockResource = $"A365Gateway:DatabaseInitialize:{database}";
    await AcquireDatabaseInitializationLockAsync(connection, lockResource);
    try
    {
        return await EnsureEmptyDatabaseInitializedUnderLockAsync(
            connection,
            server,
            database,
            deploymentOwnershipId,
            acceptedSourceFingerprint,
            expectedRuntimePrincipals,
            requiredRecoveryMode: null);
    }
    finally
    {
        await ReleaseDatabaseInitializationLockAsync(connection, lockResource);
    }
}

static async Task<InitializationIntentEvidence> EnsureEmptyDatabaseInitializedUnderLockAsync(
    SqlConnection connection,
    string server,
    string database,
    Guid deploymentOwnershipId,
    string acceptedSourceFingerprint,
    IReadOnlyCollection<ExpectedDatabasePrincipal> expectedRuntimePrincipals,
    DatabaseInitializationRecoveryMode? requiredRecoveryMode)
{
    var databaseIdentity = await ReadDatabaseIdentityBindingAsync(connection);
    var marker = CreateDatabaseInitializationIntent(
        server,
        database,
        deploymentOwnershipId,
        acceptedSourceFingerprint,
        databaseIdentity);
    var expectedMarker = JsonSerializer.Serialize(marker);
    var tableCount = await GetUserTableCountAsync(connection);
    var observedMarker = await ReadDatabaseInitializationMarkerAsync(connection);
    var exactCurrentSchema = false;
    if (tableCount > 0)
    {
        if (observedMarker is not null &&
            observedMarker.Equals(expectedMarker, StringComparison.Ordinal))
        {
            await AssertCurrentEfModelSchemaAsync(
                connection,
                expectedRuntimePrincipals,
                allowAllRecoverablePrincipalPrefixes: true);
            exactCurrentSchema = true;
        }
    }

    var recoveryMode = DatabaseBootstrapRecoveryContract.Classify(
        tableCount,
        observedMarker,
        expectedMarker,
        exactCurrentSchema);
    AssertRequiredDatabaseInitializationRecoveryMode(recoveryMode, requiredRecoveryMode);

    if (recoveryMode is DatabaseInitializationRecoveryMode.Fresh or
        DatabaseInitializationRecoveryMode.ResumeBeforeSchemaMutation)
    {
        var pristineSurface = await ReadPristineDatabaseSurfaceAfterAuditConvergenceAsync(connection);
        DatabaseBootstrapRecoveryContract.AssertPristine(pristineSurface);
    }

    if (recoveryMode == DatabaseInitializationRecoveryMode.Fresh)
    {
        await WriteDatabaseInitializationMarkerAsync(connection, expectedMarker);
        observedMarker = await ReadDatabaseInitializationMarkerAsync(connection);
        if (!string.Equals(observedMarker, expectedMarker, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "The durable database initialization marker was not read back exactly before schema mutation.");
        }
    }

    if (recoveryMode is DatabaseInitializationRecoveryMode.Fresh or
        DatabaseInitializationRecoveryMode.ResumeBeforeSchemaMutation)
    {
        var options = new DbContextOptionsBuilder<GatewayDbContext>()
            .UseSqlServer(connection)
            .Options;
        await using var context = new GatewayDbContext(options);
        if (!await context.Database.EnsureCreatedAsync())
        {
            throw new InvalidOperationException(
                "The marked zero-table Gateway database was not initialized from the reviewed current EF model.");
        }
        await AssertCurrentEfModelSchemaAsync(
            connection,
            expectedRuntimePrincipals,
            allowAllRecoverablePrincipalPrefixes: true);
    }

    var finalMarker = await ReadDatabaseInitializationMarkerAsync(connection);
    if (!string.Equals(finalMarker, expectedMarker, StringComparison.Ordinal))
    {
        throw new InvalidOperationException(
            "The durable database initialization marker changed before initialization verification completed.");
    }

    Console.WriteLine(
        recoveryMode == DatabaseInitializationRecoveryMode.Fresh
            ? "Initialized the empty Gateway database from the reviewed current EF model."
            : "Recovered the exactly marked Gateway database initialization without adopting partial state.");
    return new InitializationIntentEvidence(
        DatabaseBootstrapRecoveryContract.MarkerName,
        marker.SchemaVersion,
        marker.DeploymentOwnershipId,
        marker.AcceptedSourceFingerprint,
        marker.Server,
        marker.Database,
        marker.DatabaseCollation,
        marker.CatalogCollation,
        marker.DatabaseOwnerSidSha256,
        recoveryMode.ToString(),
        true);
}

static void AssertRequiredDatabaseInitializationRecoveryMode(
    DatabaseInitializationRecoveryMode actualRecoveryMode,
    DatabaseInitializationRecoveryMode? requiredRecoveryMode)
{
    if (requiredRecoveryMode is not null && actualRecoveryMode != requiredRecoveryMode.Value)
    {
        throw new InvalidOperationException(
            $"Database recovery classified the persisted database as {actualRecoveryMode}, not the exact required {requiredRecoveryMode.Value}; no schema, seed, or principal mutation was attempted.");
    }
}

static DatabaseInitializationIntent CreateDatabaseInitializationIntent(
    string server,
    string database,
    Guid deploymentOwnershipId,
    string acceptedSourceFingerprint,
    DatabaseIdentityBinding databaseIdentity) =>
    new(
        1,
        deploymentOwnershipId.ToString("D"),
        acceptedSourceFingerprint,
        server,
        database,
        databaseIdentity.Collation,
        databaseIdentity.CatalogCollation,
        databaseIdentity.OwnerSidSha256);

static async Task AssertDatabaseInitializationMarkerBindingAsync(
    SqlConnection connection,
    string server,
    string database,
    Guid deploymentOwnershipId,
    string acceptedSourceFingerprint)
{
    var databaseIdentity = await ReadDatabaseIdentityBindingAsync(connection);
    var expected = JsonSerializer.Serialize(CreateDatabaseInitializationIntent(
        server,
        database,
        deploymentOwnershipId,
        acceptedSourceFingerprint,
        databaseIdentity));
    var observed = await ReadDatabaseInitializationMarkerAsync(connection);
    if (!string.Equals(observed, expected, StringComparison.Ordinal))
    {
        throw new InvalidOperationException(
            "The database initialization marker does not match the exact accepted bootstrap deployment before principal mutation.");
    }
}

static async Task<DatabaseIdentityBinding> ReadDatabaseIdentityBindingAsync(SqlConnection connection)
{
    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = """
        SELECT collation_name, catalog_collation_type_desc, owner_sid
        FROM sys.databases
        WHERE name = DB_NAME();
        """;
    await using var reader = await command.ExecuteReaderAsync();
    if (!await reader.ReadAsync() || reader.IsDBNull(0) || reader.IsDBNull(1) || reader.IsDBNull(2))
        throw new InvalidOperationException("Azure SQL returned no exact database identity binding.");
    var binding = new DatabaseIdentityBinding(
        reader.GetString(0),
        reader.GetString(1),
        $"sha256:{Convert.ToHexString(SHA256.HashData(reader.GetFieldValue<byte[]>(2))).ToLowerInvariant()}");
    if (await reader.ReadAsync())
        throw new InvalidOperationException("Azure SQL returned duplicate database identity bindings.");
    if (!binding.Collation.Equals("SQL_Latin1_General_CP1_CI_AS", StringComparison.Ordinal) ||
        !binding.CatalogCollation.Equals("SQL_Latin1_General_CP1_CI_AS", StringComparison.Ordinal))
    {
        throw new InvalidOperationException("GatewayDb does not use the exact reviewed data and catalog collations.");
    }
    return binding;
}

static async Task<int> GetUserTableCountAsync(SqlConnection connection)
{
    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = """
        SELECT COUNT(*)
        FROM sys.tables
        WHERE is_ms_shipped = 0;
        """;
    return Convert.ToInt32(await command.ExecuteScalarAsync());
}

static string GetUnexpectedDatabaseSurfaceProjectionSql() =>
    """
      (SELECT COUNT(*) FROM sys.objects
       WHERE is_ms_shipped = 0
         AND type IN (N'V', N'P', N'PC', N'FN', N'IF', N'TF', N'FS', N'FT', N'AF')) AS programmableObjects,
      (SELECT COUNT(*) FROM sys.triggers WHERE is_ms_shipped = 0) AS triggers,
      (SELECT COUNT(*) FROM sys.synonyms) AS synonyms,
      (SELECT COUNT(*) FROM sys.sequences) AS sequences,
      (SELECT COUNT(*) FROM sys.external_tables) AS externalTables,
      (SELECT COUNT(*) FROM sys.external_data_sources) AS externalDataSources,
      (SELECT COUNT(*) FROM sys.external_file_formats) AS externalFileFormats,
      (SELECT COUNT(*) FROM sys.database_scoped_credentials) AS databaseScopedCredentials,
      (SELECT COUNT(*) FROM sys.column_master_keys) AS columnMasterKeys,
      (SELECT COUNT(*) FROM sys.column_encryption_keys) AS columnEncryptionKeys,
      (SELECT COUNT(*) FROM sys.assemblies WHERE is_user_defined = 1) AS userAssemblies,
      (SELECT COUNT(*) FROM sys.types WHERE is_user_defined = 1 OR is_table_type = 1) AS userDefinedOrTableTypes,
      (SELECT COUNT(*) FROM sys.partition_functions) AS partitionFunctions,
      (SELECT COUNT(*) FROM sys.partition_schemes) AS partitionSchemes,
      (SELECT COUNT(*) FROM sys.fulltext_catalogs) AS fullTextCatalogs,
      (SELECT COUNT(*) FROM sys.fulltext_indexes) AS fullTextIndexes,
      (SELECT COUNT(*) FROM sys.xml_schema_collections WHERE xml_collection_id > 1) AS userXmlSchemaCollections,
      (
          SELECT CASE
              WHEN COUNT(*) = 1
               AND COUNT
                   (
                       CASE WHEN
                           HASHBYTES(N'SHA2_256', CONVERT(varbinary(max), name)) =
                               0xe0f4f7f5e21d49507cf14e0bf1bc6f6b43e7085aaf424fc68e81b33e4ff2ec26
                           AND is_state_enabled = 1
                           AND audit_guid IS NOT NULL
                           AND audit_guid <> CAST(N'00000000-0000-0000-0000-000000000000' AS uniqueidentifier)
                       THEN 1 END
                   ) = 1
               AND NOT EXISTS (SELECT 1 FROM sys.database_audit_specification_details)
              THEN 0 ELSE 1
          END
          FROM sys.database_audit_specifications
      ) AS databaseAuditSpecifications,
      (SELECT COUNT(*) FROM sys.security_policies WHERE is_ms_shipped = 0) AS securityPolicies,
      (SELECT COUNT(*) FROM sys.database_firewall_rules) AS databaseFirewallRules,
      (SELECT COUNT(*) FROM sys.change_tracking_tables) AS changeTrackingTables,
      (SELECT COUNT(*) FROM sys.periods) AS temporalPeriods,
      (SELECT COUNT(*) FROM sys.sensitivity_classifications) AS sensitivityClassifications,
      (SELECT COUNT(*)
       FROM sys.extended_properties
       WHERE NOT
       (
           class = 0 AND major_id = 0 AND minor_id = 0
           AND name = @markerName
       )) AS extendedProperties,
      (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type = N'V') AS views,
      (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type = N'P') AS sqlStoredProcedures,
      (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type = N'PC') AS clrStoredProcedures,
      (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type = N'FN') AS sqlScalarFunctions,
      (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type = N'IF') AS sqlInlineTableValuedFunctions,
      (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type = N'TF') AS sqlTableValuedFunctions,
      (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type = N'FS') AS clrScalarFunctions,
      (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type = N'FT') AS clrTableValuedFunctions,
      (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type = N'AF') AS aggregateFunctions
    """;

static string GetDatabasePermissionTelemetryCteSql() =>
    """
    WITH databasePermissionTelemetry AS
    (
        SELECT
            permission_shape.is_raw_non_whitelisted,
            permission_shape.is_positive_id_public_select,
            CASE
                WHEN permission_shape.is_positive_id_public_select = 1
                 AND EXISTS
                 (
                     SELECT 1
                     FROM sys.all_objects AS shipped_objects
                     WHERE shipped_objects.object_id = permissions.major_id
                       AND shipped_objects.is_ms_shipped = 1
                 )
                THEN 1 ELSE 0
            END AS is_positive_ms_shipped_object,
            CASE
                WHEN permission_shape.is_positive_id_public_select = 1
                 AND EXISTS
                 (
                     SELECT 1
                     FROM sys.objects AS programmable_objects
                     WHERE programmable_objects.object_id = permissions.major_id
                       AND programmable_objects.is_ms_shipped = 0
                       AND programmable_objects.type IN
                           (N'V', N'P', N'PC', N'FN', N'IF', N'TF', N'FS', N'FT', N'AF')
                 )
                THEN 1 ELSE 0
            END AS is_positive_non_ms_shipped_programmable_object,
            CASE
                WHEN permission_shape.is_positive_id_public_select = 0 THEN 0
                WHEN EXISTS
                (
                    SELECT 1
                    FROM sys.system_objects AS system_catalog_objects
                    WHERE system_catalog_objects.object_id = permissions.major_id
                      AND system_catalog_objects.is_ms_shipped = 1
                ) THEN 1
                WHEN EXISTS
                (
                    SELECT 1
                    FROM sys.objects AS shipped_database_objects
                    WHERE shipped_database_objects.object_id = permissions.major_id
                      AND shipped_database_objects.is_ms_shipped = 1
                ) THEN 2
                ELSE 3
            END AS positive_target_origin_bucket,
            CASE
                WHEN permissions.class = 0 THEN 1
                WHEN permissions.class = 1 THEN 2
                ELSE 3
            END AS raw_class_bucket,
            CASE permissions.state
                WHEN N'G' THEN 1
                WHEN N'W' THEN 2
                WHEN N'D' THEN 3
                WHEN N'R' THEN 4
                ELSE 5
            END AS raw_state_bucket,
            CASE
                WHEN grantees.name = N'public' THEN 1
                WHEN grantees.name = N'guest' THEN 2
                WHEN grantees.name = N'dbo' THEN 3
                WHEN grantees.is_fixed_role = 1 THEN 4
                ELSE 5
            END AS raw_grantee_bucket,
            CASE permissions.permission_name
                WHEN N'CONNECT' THEN 1
                WHEN N'SELECT' THEN 2
                WHEN N'VIEW DEFINITION' THEN 3
                WHEN N'VIEW ANY COLUMN MASTER KEY DEFINITION' THEN 4
                WHEN N'VIEW ANY COLUMN ENCRYPTION KEY DEFINITION' THEN 5
                ELSE 6
            END AS raw_permission_name_bucket,
            CASE
                WHEN permissions.class = 0
                 AND permissions.major_id = 0
                 AND permissions.minor_id = 0 THEN 1
                WHEN permissions.class = 1
                 AND permissions.major_id < 0
                 AND permissions.minor_id = 0 THEN 2
                WHEN permissions.class = 1
                 AND permissions.major_id = 0
                 AND permissions.minor_id = 0 THEN 3
                WHEN permissions.class = 1
                 AND permissions.major_id > 0
                 AND permissions.minor_id = 0 THEN 4
                WHEN permissions.class = 1
                 AND permissions.minor_id > 0 THEN 5
                ELSE 6
            END AS raw_address_bucket,
            CASE
                WHEN permissions.grantor_principal_id = DATABASE_PRINCIPAL_ID(N'dbo') THEN 1
                ELSE 2
            END AS raw_grantor_bucket,
            CASE
                WHEN permission_shape.is_positive_id_public_select = 0 THEN 0
                ELSE COALESCE
                (
                    (
                        SELECT CASE target_type_objects.type
                            WHEN N'AF' THEN 1
                            WHEN N'C' THEN 2
                            WHEN N'D' THEN 3
                            WHEN N'EC' THEN 4
                            WHEN N'ET' THEN 5
                            WHEN N'F' THEN 6
                            WHEN N'FN' THEN 7
                            WHEN N'FS' THEN 8
                            WHEN N'FT' THEN 9
                            WHEN N'IF' THEN 10
                            WHEN N'IT' THEN 11
                            WHEN N'P' THEN 12
                            WHEN N'PC' THEN 13
                            WHEN N'PG' THEN 14
                            WHEN N'PK' THEN 15
                            WHEN N'R' THEN 16
                            WHEN N'RF' THEN 17
                            WHEN N'S' THEN 18
                            WHEN N'SN' THEN 19
                            WHEN N'SO' THEN 20
                            WHEN N'SQ' THEN 21
                            WHEN N'ST' THEN 22
                            WHEN N'TA' THEN 23
                            WHEN N'TF' THEN 24
                            WHEN N'TR' THEN 25
                            WHEN N'TT' THEN 26
                            WHEN N'U' THEN 27
                            WHEN N'UQ' THEN 28
                            WHEN N'V' THEN 29
                            WHEN N'X' THEN 30
                            ELSE 31
                        END
                        FROM sys.all_objects AS target_type_objects
                        WHERE target_type_objects.object_id = permissions.major_id
                    ),
                    31
                )
            END AS positive_target_type_bucket,
            CASE
                WHEN permission_shape.is_positive_id_public_select = 0 THEN 0
                ELSE COALESCE
                (
                    (
                        SELECT CASE target_schemas.name
                            WHEN N'sys' THEN 1
                            WHEN N'dbo' THEN 2
                            ELSE 3
                        END
                        FROM sys.all_objects AS target_schema_objects
                        INNER JOIN sys.schemas AS target_schemas
                          ON target_schemas.schema_id = target_schema_objects.schema_id
                        WHERE target_schema_objects.object_id = permissions.major_id
                    ),
                    3
                )
            END AS positive_target_schema_bucket,
            CASE
                WHEN permission_shape.is_positive_id_public_select = 0 THEN 0
                ELSE COALESCE
                (
                    (
                        SELECT CASE WHEN target_parent_objects.parent_object_id = 0 THEN 1 ELSE 2 END
                        FROM sys.all_objects AS target_parent_objects
                        WHERE target_parent_objects.object_id = permissions.major_id
                    ),
                    3
                )
            END AS positive_target_parent_bucket,
            CASE WHEN permission_shape.is_positive_id_public_select = 1
                       AND EXISTS (SELECT 1 FROM sys.views WHERE object_id = permissions.major_id)
                 THEN 1 ELSE 0 END AS positive_target_in_views,
            CASE WHEN permission_shape.is_positive_id_public_select = 1
                       AND EXISTS (SELECT 1 FROM sys.procedures WHERE object_id = permissions.major_id)
                 THEN 1 ELSE 0 END AS positive_target_in_procedures,
            CASE WHEN permission_shape.is_positive_id_public_select = 1
                       AND EXISTS (SELECT 1 FROM sys.sql_modules WHERE object_id = permissions.major_id)
                 THEN 1 ELSE 0 END AS positive_target_in_sql_modules,
            CASE WHEN permission_shape.is_positive_id_public_select = 1
                       AND EXISTS (SELECT 1 FROM sys.tables WHERE object_id = permissions.major_id)
                 THEN 1 ELSE 0 END AS positive_target_in_tables,
            CASE WHEN permission_shape.is_positive_id_public_select = 1
                       AND EXISTS (SELECT 1 FROM sys.internal_tables WHERE object_id = permissions.major_id)
                 THEN 1 ELSE 0 END AS positive_target_in_internal_tables,
            CASE WHEN permission_shape.is_positive_id_public_select = 1
                       AND EXISTS (SELECT 1 FROM sys.sequences WHERE object_id = permissions.major_id)
                 THEN 1 ELSE 0 END AS positive_target_in_sequences,
            CASE WHEN permission_shape.is_positive_id_public_select = 1
                       AND EXISTS (SELECT 1 FROM sys.synonyms WHERE object_id = permissions.major_id)
                 THEN 1 ELSE 0 END AS positive_target_in_synonyms,
            CASE WHEN permission_shape.is_positive_id_public_select = 1
                       AND EXISTS (SELECT 1 FROM sys.triggers WHERE object_id = permissions.major_id)
                 THEN 1 ELSE 0 END AS positive_target_in_triggers,
            CASE
                WHEN permission_shape.is_positive_id_public_select = 1
                 AND
                 (
                     EXISTS (SELECT 1 FROM sys.views WHERE object_id = permissions.major_id)
                     OR EXISTS (SELECT 1 FROM sys.procedures WHERE object_id = permissions.major_id)
                     OR EXISTS (SELECT 1 FROM sys.sql_modules WHERE object_id = permissions.major_id)
                     OR EXISTS (SELECT 1 FROM sys.tables WHERE object_id = permissions.major_id)
                     OR EXISTS (SELECT 1 FROM sys.internal_tables WHERE object_id = permissions.major_id)
                     OR EXISTS (SELECT 1 FROM sys.sequences WHERE object_id = permissions.major_id)
                     OR EXISTS (SELECT 1 FROM sys.synonyms WHERE object_id = permissions.major_id)
                     OR EXISTS (SELECT 1 FROM sys.triggers WHERE object_id = permissions.major_id)
                 )
                THEN 1 ELSE 0
            END AS has_positive_target_specialized_catalog_membership
        FROM sys.database_permissions AS permissions
        INNER JOIN sys.database_principals AS grantees
          ON grantees.principal_id = permissions.grantee_principal_id
        CROSS APPLY
        (
            SELECT
                CASE
                    WHEN NOT
                    (
                        (
                            permissions.class = 0
                            AND permissions.major_id = 0
                            AND permissions.minor_id = 0
                            AND permissions.permission_name = N'CONNECT'
                            AND permissions.state IN (N'G', N'W')
                            AND grantees.name IN (N'public', N'guest')
                        )
                        OR
                        (
                            permissions.class = 0
                            AND permissions.major_id = 0
                            AND permissions.minor_id = 0
                            AND permissions.permission_name = N'CONNECT'
                            AND permissions.state = N'G'
                            AND grantees.name = N'dbo'
                            AND permissions.grantor_principal_id = DATABASE_PRINCIPAL_ID(N'dbo')
                        )
                        OR
                        (
                            permissions.class = 0
                            AND permissions.major_id = 0
                            AND permissions.minor_id = 0
                            AND permissions.permission_name = N'CONNECT'
                            AND permissions.state = N'G'
                            AND grantees.name IN (@runtimePrincipalName1, @runtimePrincipalName2)
                            AND permissions.grantor_principal_id = DATABASE_PRINCIPAL_ID(N'dbo')
                        )
                        OR
                        (
                            permissions.class = 1
                            AND permissions.minor_id = 0
                            AND permissions.permission_name = N'SELECT'
                            AND permissions.state = N'G'
                            AND grantees.name = N'public'
                            AND permissions.major_id < 0
                        )
                        OR
                        (
                            permissions.class = 1
                            AND permissions.minor_id = 0
                            AND permissions.permission_name = N'SELECT'
                            AND permissions.state = N'G'
                            AND grantees.name = N'public'
                            AND permissions.major_id = OBJECT_ID(N'sys.database_firewall_rules')
                            AND permissions.grantor_principal_id = DATABASE_PRINCIPAL_ID(N'sys')
                            AND EXISTS
                            (
                                SELECT 1
                                FROM sys.all_objects AS allowed_shipped_objects
                                WHERE allowed_shipped_objects.object_id = permissions.major_id
                                  AND allowed_shipped_objects.is_ms_shipped = 1
                                  AND allowed_shipped_objects.schema_id = SCHEMA_ID(N'sys')
                                  AND allowed_shipped_objects.type = N'V'
                            )
                        )
                        OR
                        (
                            @allowMetadataPrincipalViewDefinition = 1
                            AND permissions.class = 0
                            AND permissions.major_id = 0
                            AND permissions.minor_id = 0
                            AND permissions.permission_name = N'VIEW DEFINITION'
                            AND permissions.state = N'G'
                            AND grantees.name = @metadataPrincipalName
                            AND permissions.grantor_principal_id = DATABASE_PRINCIPAL_ID(N'dbo')
                            AND EXISTS
                            (
                                SELECT 1
                                FROM sys.database_permissions AS required_connect
                                WHERE required_connect.grantee_principal_id = permissions.grantee_principal_id
                                  AND required_connect.class = 0
                                  AND required_connect.major_id = 0
                                  AND required_connect.minor_id = 0
                                  AND required_connect.permission_name = N'CONNECT'
                                  AND required_connect.state = N'G'
                                  AND required_connect.grantor_principal_id = DATABASE_PRINCIPAL_ID(N'dbo')
                            )
                        )
                    )
                    THEN 1 ELSE 0
                END AS is_raw_non_whitelisted,
                CASE
                    WHEN permissions.class = 1
                     AND permissions.minor_id = 0
                     AND permissions.permission_name = N'SELECT'
                     AND permissions.state = N'G'
                     AND grantees.name = N'public'
                     AND permissions.major_id > 0
                    THEN 1 ELSE 0
                END AS is_positive_id_public_select
        ) AS permission_shape
    )
    """;

static string GetDatabasePermissionTelemetryProjectionSql() =>
    """
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 THEN 1 END) AS rawNonWhitelistedDirectPermissions,
      COUNT(CASE WHEN is_positive_id_public_select = 1 THEN 1 END) AS positiveIdPublicSelectTargets,
      COUNT(CASE WHEN is_positive_ms_shipped_object = 1 THEN 1 END) AS positiveIdPublicSelectMsShippedObjectTargets,
      COUNT(CASE WHEN is_positive_non_ms_shipped_programmable_object = 1 THEN 1 END) AS positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelations,
      COUNT(CASE WHEN positive_target_origin_bucket = 1 THEN 1 END) AS positiveIdPublicSelectMsShippedSystemCatalogTargets,
      COUNT(CASE WHEN positive_target_origin_bucket = 2 THEN 1 END) AS positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargets,
      COUNT(CASE WHEN positive_target_origin_bucket = 3 THEN 1 END) AS positiveIdPublicSelectNonMsShippedOrUnresolvedTargets,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_class_bucket = 1 THEN 1 END) AS rawClassDatabasePermissions,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_class_bucket = 2 THEN 1 END) AS rawClassObjectOrColumnPermissions,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_class_bucket = 3 THEN 1 END) AS rawClassOtherPermissions,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_state_bucket = 1 THEN 1 END) AS rawStateGrantPermissions,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_state_bucket = 2 THEN 1 END) AS rawStateGrantWithGrantOptionPermissions,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_state_bucket = 3 THEN 1 END) AS rawStateDenyPermissions,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_state_bucket = 4 THEN 1 END) AS rawStateRevokePermissions,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_state_bucket = 5 THEN 1 END) AS rawStateOtherPermissions,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_grantee_bucket = 1 THEN 1 END) AS rawGranteePublicPermissions,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_grantee_bucket = 2 THEN 1 END) AS rawGranteeGuestPermissions,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_grantee_bucket = 3 THEN 1 END) AS rawGranteeDboPermissions,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_grantee_bucket = 4 THEN 1 END) AS rawGranteeFixedRolePermissions,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_grantee_bucket = 5 THEN 1 END) AS rawGranteeOtherPermissions,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_permission_name_bucket = 1 THEN 1 END) AS rawPermissionNameConnect,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_permission_name_bucket = 2 THEN 1 END) AS rawPermissionNameSelect,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_permission_name_bucket = 3 THEN 1 END) AS rawPermissionNameViewDefinition,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_permission_name_bucket = 4 THEN 1 END) AS rawPermissionNameViewAnyColumnMasterKeyDefinition,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_permission_name_bucket = 5 THEN 1 END) AS rawPermissionNameViewAnyColumnEncryptionKeyDefinition,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_permission_name_bucket = 6 THEN 1 END) AS rawPermissionNameOther,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_address_bucket = 1 THEN 1 END) AS rawAddressDatabase,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_address_bucket = 2 THEN 1 END) AS rawAddressNegativeObject,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_address_bucket = 3 THEN 1 END) AS rawAddressZeroObject,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_address_bucket = 4 THEN 1 END) AS rawAddressPositiveObject,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_address_bucket = 5 THEN 1 END) AS rawAddressColumn,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_address_bucket = 6 THEN 1 END) AS rawAddressOther,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_grantor_bucket = 1 THEN 1 END) AS rawGrantorDbo,
      COUNT(CASE WHEN is_raw_non_whitelisted = 1 AND raw_grantor_bucket = 2 THEN 1 END) AS rawGrantorOther,
      COUNT(CASE WHEN positive_target_type_bucket = 1 THEN 1 END) AS positiveIdPublicSelectTypeAggregateFunctions,
      COUNT(CASE WHEN positive_target_type_bucket = 2 THEN 1 END) AS positiveIdPublicSelectTypeCheckConstraints,
      COUNT(CASE WHEN positive_target_type_bucket = 3 THEN 1 END) AS positiveIdPublicSelectTypeDefaultConstraints,
      COUNT(CASE WHEN positive_target_type_bucket = 4 THEN 1 END) AS positiveIdPublicSelectTypeEdgeConstraints,
      COUNT(CASE WHEN positive_target_type_bucket = 5 THEN 1 END) AS positiveIdPublicSelectTypeExternalTables,
      COUNT(CASE WHEN positive_target_type_bucket = 6 THEN 1 END) AS positiveIdPublicSelectTypeForeignKeys,
      COUNT(CASE WHEN positive_target_type_bucket = 7 THEN 1 END) AS positiveIdPublicSelectTypeSqlScalarFunctions,
      COUNT(CASE WHEN positive_target_type_bucket = 8 THEN 1 END) AS positiveIdPublicSelectTypeClrScalarFunctions,
      COUNT(CASE WHEN positive_target_type_bucket = 9 THEN 1 END) AS positiveIdPublicSelectTypeClrTableValuedFunctions,
      COUNT(CASE WHEN positive_target_type_bucket = 10 THEN 1 END) AS positiveIdPublicSelectTypeSqlInlineTableValuedFunctions,
      COUNT(CASE WHEN positive_target_type_bucket = 11 THEN 1 END) AS positiveIdPublicSelectTypeInternalTables,
      COUNT(CASE WHEN positive_target_type_bucket = 12 THEN 1 END) AS positiveIdPublicSelectTypeSqlStoredProcedures,
      COUNT(CASE WHEN positive_target_type_bucket = 13 THEN 1 END) AS positiveIdPublicSelectTypeClrStoredProcedures,
      COUNT(CASE WHEN positive_target_type_bucket = 14 THEN 1 END) AS positiveIdPublicSelectTypePlanGuides,
      COUNT(CASE WHEN positive_target_type_bucket = 15 THEN 1 END) AS positiveIdPublicSelectTypePrimaryKeys,
      COUNT(CASE WHEN positive_target_type_bucket = 16 THEN 1 END) AS positiveIdPublicSelectTypeRules,
      COUNT(CASE WHEN positive_target_type_bucket = 17 THEN 1 END) AS positiveIdPublicSelectTypeReplicationFilterProcedures,
      COUNT(CASE WHEN positive_target_type_bucket = 18 THEN 1 END) AS positiveIdPublicSelectTypeSystemTables,
      COUNT(CASE WHEN positive_target_type_bucket = 19 THEN 1 END) AS positiveIdPublicSelectTypeSynonyms,
      COUNT(CASE WHEN positive_target_type_bucket = 20 THEN 1 END) AS positiveIdPublicSelectTypeSequences,
      COUNT(CASE WHEN positive_target_type_bucket = 21 THEN 1 END) AS positiveIdPublicSelectTypeServiceQueues,
      COUNT(CASE WHEN positive_target_type_bucket = 22 THEN 1 END) AS positiveIdPublicSelectTypeStatisticsTrees,
      COUNT(CASE WHEN positive_target_type_bucket = 23 THEN 1 END) AS positiveIdPublicSelectTypeClrDmlTriggers,
      COUNT(CASE WHEN positive_target_type_bucket = 24 THEN 1 END) AS positiveIdPublicSelectTypeSqlTableValuedFunctions,
      COUNT(CASE WHEN positive_target_type_bucket = 25 THEN 1 END) AS positiveIdPublicSelectTypeSqlDmlTriggers,
      COUNT(CASE WHEN positive_target_type_bucket = 26 THEN 1 END) AS positiveIdPublicSelectTypeTableTypes,
      COUNT(CASE WHEN positive_target_type_bucket = 27 THEN 1 END) AS positiveIdPublicSelectTypeUserTables,
      COUNT(CASE WHEN positive_target_type_bucket = 28 THEN 1 END) AS positiveIdPublicSelectTypeUniqueConstraints,
      COUNT(CASE WHEN positive_target_type_bucket = 29 THEN 1 END) AS positiveIdPublicSelectTypeViews,
      COUNT(CASE WHEN positive_target_type_bucket = 30 THEN 1 END) AS positiveIdPublicSelectTypeExtendedStoredProcedures,
      COUNT(CASE WHEN positive_target_type_bucket = 31 THEN 1 END) AS positiveIdPublicSelectTypeOtherOrUnresolved,
      COUNT(CASE WHEN positive_target_schema_bucket = 1 THEN 1 END) AS positiveIdPublicSelectSchemaSys,
      COUNT(CASE WHEN positive_target_schema_bucket = 2 THEN 1 END) AS positiveIdPublicSelectSchemaDbo,
      COUNT(CASE WHEN positive_target_schema_bucket = 3 THEN 1 END) AS positiveIdPublicSelectSchemaOtherOrUnresolved,
      COUNT(CASE WHEN positive_target_parent_bucket = 1 THEN 1 END) AS positiveIdPublicSelectParentless,
      COUNT(CASE WHEN positive_target_parent_bucket = 2 THEN 1 END) AS positiveIdPublicSelectParented,
      COUNT(CASE WHEN positive_target_parent_bucket = 3 THEN 1 END) AS positiveIdPublicSelectParentUnresolved,
      COUNT(CASE WHEN positive_target_in_views = 1 THEN 1 END) AS positiveIdPublicSelectInViews,
      COUNT(CASE WHEN positive_target_in_procedures = 1 THEN 1 END) AS positiveIdPublicSelectInProcedures,
      COUNT(CASE WHEN positive_target_in_sql_modules = 1 THEN 1 END) AS positiveIdPublicSelectInSqlModules,
      COUNT(CASE WHEN positive_target_in_tables = 1 THEN 1 END) AS positiveIdPublicSelectInTables,
      COUNT(CASE WHEN positive_target_in_internal_tables = 1 THEN 1 END) AS positiveIdPublicSelectInInternalTables,
      COUNT(CASE WHEN positive_target_in_sequences = 1 THEN 1 END) AS positiveIdPublicSelectInSequences,
      COUNT(CASE WHEN positive_target_in_synonyms = 1 THEN 1 END) AS positiveIdPublicSelectInSynonyms,
      COUNT(CASE WHEN positive_target_in_triggers = 1 THEN 1 END) AS positiveIdPublicSelectInTriggers,
      COUNT(CASE WHEN has_positive_target_specialized_catalog_membership = 1 THEN 1 END) AS positiveIdPublicSelectWithSpecializedCatalogMembership,
      COUNT(CASE WHEN is_positive_id_public_select = 1 AND has_positive_target_specialized_catalog_membership = 0 THEN 1 END) AS positiveIdPublicSelectWithoutSpecializedCatalogMembership
    """;

static async Task<UnexpectedDatabaseSurfaceTelemetry> ReadUnexpectedDatabaseSurfaceTelemetryAsync(
    SqlConnection connection)
{
    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = $"SELECT{Environment.NewLine}{GetUnexpectedDatabaseSurfaceProjectionSql()};";
    command.Parameters.AddWithValue("@markerName", DatabaseBootstrapRecoveryContract.MarkerName);
    await using var reader = await command.ExecuteReaderAsync();
    var expectedFieldCount = checked(
        UnexpectedDatabaseSurfaceTelemetry.ExpectedCategoryCount +
        UnexpectedDatabaseSurfaceTelemetry.ExpectedProgrammableObjectTypeCount);
    var expectedFieldNames = UnexpectedDatabaseSurfaceTelemetry.SqlFieldNames;
    if (expectedFieldNames.Count != expectedFieldCount)
        throw new InvalidOperationException("The fixed database-surface telemetry field contract is inconsistent.");
    AssertExactSqlFieldContract(reader, expectedFieldNames, "database-surface");
    if (!await reader.ReadAsync())
        throw new InvalidOperationException("Azure SQL returned no database-surface telemetry row.");
    var telemetry = ReadUnexpectedDatabaseSurfaceTelemetry(reader, startOrdinal: 0);
    if (await reader.ReadAsync())
        throw new InvalidOperationException("Azure SQL returned duplicate database-surface telemetry rows.");
    return telemetry;
}

static UnexpectedDatabaseSurfaceTelemetry ReadUnexpectedDatabaseSurfaceTelemetry(
    SqlDataReader reader,
    int startOrdinal)
{
    var categoryCounts = Enumerable
        .Range(startOrdinal, UnexpectedDatabaseSurfaceTelemetry.ExpectedCategoryCount)
        .Select(reader.GetInt32)
        .ToArray();
    var programmableObjectTypeCounts = Enumerable
        .Range(
            checked(startOrdinal + UnexpectedDatabaseSurfaceTelemetry.ExpectedCategoryCount),
            UnexpectedDatabaseSurfaceTelemetry.ExpectedProgrammableObjectTypeCount)
        .Select(reader.GetInt32)
        .ToArray();
    return UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
        categoryCounts,
        programmableObjectTypeCounts);
}

static void AssertExactSqlFieldContract(
    SqlDataReader reader,
    IReadOnlyList<string> expectedFieldNames,
    string safeContractLabel)
{
    if (reader.FieldCount != expectedFieldNames.Count)
    {
        throw new InvalidOperationException(
            $"Azure SQL returned {reader.FieldCount} {safeContractLabel} fields; exactly {expectedFieldNames.Count} are required.");
    }
    var unexpectedFieldNameCount = Enumerable.Range(0, expectedFieldNames.Count)
        .Count(index => !reader.GetName(index).Equals(expectedFieldNames[index], StringComparison.Ordinal));
    if (unexpectedFieldNameCount != 0)
    {
        throw new InvalidOperationException(
            $"Azure SQL returned {unexpectedFieldNameCount} unexpected {safeContractLabel} field labels.");
    }
}

static async Task<PristineDatabaseSurfaceSnapshot>
    ReadPristineDatabaseSurfaceAfterAuditConvergenceAsync(SqlConnection connection)
{
    var initialSurface = await ReadPristineDatabaseSurfaceAsync(connection);
    var readiness = DatabaseBootstrapRecoveryContract.ClassifyPristineReadiness(initialSurface);
    if (readiness == PristineDatabaseSurfaceReadiness.Ready)
        return initialSurface;

    await WaitForAzureSqlAuditSpecificationReadinessAsync(connection);
    return await ReadPristineDatabaseSurfaceAsync(connection);
}

static async Task<PristineDatabaseSurfaceSnapshot> ReadPristineDatabaseSurfaceAsync(
    SqlConnection connection)
{
    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = $"""
        {GetDatabasePermissionTelemetryCteSql()}
        SELECT
        {GetUnexpectedDatabaseSurfaceProjectionSql()},
          (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0) AS userTables,
          (
              SELECT COUNT(*)
              FROM sys.schemas AS schemas
              LEFT JOIN sys.database_principals AS principals
                ON principals.principal_id = schemas.principal_id
              WHERE schemas.name NOT IN
                    (
                        N'dbo', N'guest', N'sys', N'INFORMATION_SCHEMA',
                        N'db_owner', N'db_accessadmin', N'db_securityadmin', N'db_ddladmin',
                        N'db_backupoperator', N'db_datareader', N'db_datawriter',
                        N'db_denydatareader', N'db_denydatawriter'
                    )
                 OR principals.name IS NULL
                 OR principals.name <> schemas.name
          ) AS unexpectedSchemas,
          (
              SELECT COUNT(*)
              FROM sys.database_principals
              WHERE principal_id > 4
                AND is_fixed_role = 0
          ) AS unexpectedPrincipals,
          (
              (
                  SELECT COUNT(*)
                  FROM sys.database_role_members AS memberships
                  INNER JOIN sys.database_principals AS roles
                    ON roles.principal_id = memberships.role_principal_id
                  INNER JOIN sys.database_principals AS members
                    ON members.principal_id = memberships.member_principal_id
                  WHERE NOT
                  (
                      roles.name = N'db_owner'
                      AND roles.is_fixed_role = 1
                      AND members.name = N'dbo'
                      AND members.principal_id = DATABASE_PRINCIPAL_ID(N'dbo')
                  )
              ) +
              (
                  SELECT CASE WHEN COUNT(*) = 1 THEN 0 ELSE 1 END
                  FROM sys.database_role_members AS memberships
                  INNER JOIN sys.database_principals AS roles
                    ON roles.principal_id = memberships.role_principal_id
                  INNER JOIN sys.database_principals AS members
                    ON members.principal_id = memberships.member_principal_id
                  WHERE roles.name = N'db_owner'
                    AND roles.is_fixed_role = 1
                    AND members.name = N'dbo'
                    AND members.principal_id = DATABASE_PRINCIPAL_ID(N'dbo')
              )
          ) AS unexpectedRoleMemberships,
        {GetDatabasePermissionTelemetryProjectionSql()},
          (
              SELECT COUNT(*)
              FROM sys.databases
              WHERE name = DB_NAME()
                AND
                (
                    state_desc <> N'ONLINE'
                    OR user_access_desc <> N'MULTI_USER'
                    OR is_read_only <> 0
                    OR is_auto_close_on <> 0
                    OR is_auto_shrink_on <> 0
                    OR is_in_standby <> 0
                    OR source_database_id IS NOT NULL
                    OR containment_desc <> N'NONE'
                    OR is_trustworthy_on <> 0
                    OR is_db_chaining_on <> 0
                    OR collation_name <> N'SQL_Latin1_General_CP1_CI_AS'
                    OR catalog_collation_type_desc <> N'SQL_Latin1_General_CP1_CI_AS'
                )
          ) AS unsafeDatabaseOptions,
          (
              SELECT CASE
                  WHEN COUNT(*) = 1
                   AND MAX(CASE WHEN databases.owner_sid = dbo_principal.sid THEN 1 ELSE 0 END) = 1
                  THEN 0 ELSE 1 END
              FROM sys.databases AS databases
              LEFT JOIN sys.database_principals AS dbo_principal
                ON dbo_principal.name = N'dbo'
              WHERE databases.name = DB_NAME()
          ) AS databaseOwnerMismatches
        FROM databasePermissionTelemetry;
        """;
    command.Parameters.AddWithValue("@markerName", DatabaseBootstrapRecoveryContract.MarkerName);
    command.Parameters.AddWithValue("@allowMetadataPrincipalViewDefinition", 0);
    command.Parameters.AddWithValue("@metadataPrincipalName", string.Empty);
    command.Parameters.AddWithValue("@runtimePrincipalName1", string.Empty);
    command.Parameters.AddWithValue("@runtimePrincipalName2", string.Empty);
    await using var reader = await command.ExecuteReaderAsync();
    AssertExactSqlFieldContract(
        reader,
        PristineDatabaseSurfaceSnapshot.SqlFieldNames,
        "pristine database-surface");
    if (!await reader.ReadAsync())
        throw new InvalidOperationException("Azure SQL returned no pristine database-surface row.");
    var catalogSurface = ReadUnexpectedDatabaseSurfaceTelemetry(reader, startOrdinal: 0);
    var remainingStartOrdinal = UnexpectedDatabaseSurfaceTelemetry.SqlFieldNames.Count;
    var permissionStartOrdinal = checked(remainingStartOrdinal + 4);
    var permissionCounts = Enumerable
        .Range(permissionStartOrdinal, DatabaseDirectPermissionTelemetry.ExpectedFieldCount)
        .Select(reader.GetInt32)
        .ToArray();
    var optionStartOrdinal = checked(
        permissionStartOrdinal + DatabaseDirectPermissionTelemetry.ExpectedFieldCount);
    var snapshot = new PristineDatabaseSurfaceSnapshot(
        reader.GetInt32(remainingStartOrdinal),
        catalogSurface,
        reader.GetInt32(remainingStartOrdinal + 1),
        reader.GetInt32(remainingStartOrdinal + 2),
        reader.GetInt32(remainingStartOrdinal + 3),
        DatabaseDirectPermissionTelemetry.FromOrderedCounts(permissionCounts),
        reader.GetInt32(optionStartOrdinal),
        reader.GetInt32(optionStartOrdinal + 1));
    if (await reader.ReadAsync())
        throw new InvalidOperationException("Azure SQL returned duplicate pristine database-surface rows.");
    return snapshot;
}

static Task WaitForAzureSqlAuditSpecificationReadinessAsync(
    SqlConnection connection,
    CancellationToken cancellationToken = default) =>
    AzureSqlAuditSpecificationConvergence.WaitAsync(
        token => ReadAzureSqlAuditSpecificationReadinessAsync(connection, token),
        timeout: TimeSpan.FromMinutes(10),
        retryDelay: TimeSpan.FromSeconds(5),
        cancellationToken);

static async Task<AzureSqlAuditSpecificationReadinessSnapshot>
    ReadAzureSqlAuditSpecificationReadinessAsync(
        SqlConnection connection,
        CancellationToken cancellationToken)
{
    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = """
        SELECT
          COUNT(*) AS auditSpecificationsTotal,
          COUNT(CASE WHEN
              HASHBYTES(N'SHA2_256', CONVERT(varbinary(max), name)) =
                  0xe0f4f7f5e21d49507cf14e0bf1bc6f6b43e7085aaf424fc68e81b33e4ff2ec26
              THEN 1 END) AS auditSpecificationsExpectedNameHashMatches,
          COUNT(CASE WHEN is_state_enabled = 1 THEN 1 END) AS auditSpecificationsEnabled,
          COUNT(CASE WHEN is_state_enabled = 0 THEN 1 END) AS auditSpecificationsDisabled,
          COUNT(CASE WHEN audit_guid IS NULL THEN 1 END) AS auditSpecificationsNullGuid,
          COUNT(CASE WHEN
              audit_guid = CAST(N'00000000-0000-0000-0000-000000000000' AS uniqueidentifier)
              THEN 1 END) AS auditSpecificationsZeroGuid,
          COUNT(CASE WHEN
              audit_guid IS NOT NULL
              AND audit_guid <> CAST(N'00000000-0000-0000-0000-000000000000' AS uniqueidentifier)
              THEN 1 END) AS auditSpecificationsNonzeroGuid,
          (SELECT COUNT(*) FROM sys.database_audit_specification_details) AS auditDetailsTotal
        FROM sys.database_audit_specifications;
        """;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    AssertExactSqlFieldContract(
        reader,
        AzureSqlAuditSpecificationReadinessSnapshot.SqlFieldNames,
        "Azure SQL audit-specification readiness");
    if (!await reader.ReadAsync(cancellationToken))
        throw new InvalidOperationException("Azure SQL returned no audit-specification readiness row.");
    var snapshot = new AzureSqlAuditSpecificationReadinessSnapshot(
        reader.GetInt32(0),
        reader.GetInt32(1),
        reader.GetInt32(2),
        reader.GetInt32(3),
        reader.GetInt32(4),
        reader.GetInt32(5),
        reader.GetInt32(6),
        reader.GetInt32(7));
    if (await reader.ReadAsync(cancellationToken))
        throw new InvalidOperationException("Azure SQL returned duplicate audit-specification readiness rows.");
    return snapshot;
}

static async Task<AzureSqlPristinePlatformDiagnostic> ReadAzureSqlPristinePlatformDiagnosticAsync(
    SqlConnection connection)
{
    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = """
        SELECT
          (SELECT COUNT(*) FROM sys.database_audit_specifications) AS auditSpecificationsTotal,
          (SELECT COUNT(*) FROM sys.database_audit_specifications
           WHERE name = N'SqlDbAuditing_ServerAuditSpec') AS auditSpecificationsServerNameMatches,
          (SELECT COUNT(*) FROM sys.database_audit_specifications
           WHERE name = N'SqlDbAuditing_AuditSpec') AS auditSpecificationsDatabaseNameMatches,
          (SELECT COUNT(*) FROM sys.database_audit_specifications
           WHERE name NOT IN (N'SqlDbAuditing_ServerAuditSpec', N'SqlDbAuditing_AuditSpec')) AS auditSpecificationsOtherName,
          (SELECT COUNT(*) FROM sys.database_audit_specifications
           WHERE is_state_enabled = 1) AS auditSpecificationsEnabled,
          (SELECT COUNT(*) FROM sys.database_audit_specifications
           WHERE is_state_enabled = 0) AS auditSpecificationsDisabled,
          (SELECT COUNT(*) FROM sys.database_audit_specifications
           WHERE audit_guid IS NULL) AS auditSpecificationsNullGuid,
          (SELECT COUNT(*) FROM sys.database_audit_specifications
           WHERE audit_guid IS NOT NULL) AS auditSpecificationsNonNullGuid,
          (SELECT COUNT(*) FROM sys.database_audit_specification_details) AS auditDetailsTotal,
          (SELECT COUNT(*) FROM sys.database_audit_specification_details
           WHERE audit_action_name = N'BATCH_COMPLETED_GROUP') AS auditDetailsBatchCompleted,
          (SELECT COUNT(*) FROM sys.database_audit_specification_details
           WHERE audit_action_name = N'SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP') AS auditDetailsSuccessfulAuthentication,
          (SELECT COUNT(*) FROM sys.database_audit_specification_details
           WHERE audit_action_name = N'FAILED_DATABASE_AUTHENTICATION_GROUP') AS auditDetailsFailedAuthentication,
          (SELECT COUNT(*) FROM sys.database_audit_specification_details
           WHERE audit_action_name NOT IN
                 (N'BATCH_COMPLETED_GROUP', N'SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP',
                  N'FAILED_DATABASE_AUTHENTICATION_GROUP')) AS auditDetailsOtherAction,
          (SELECT COUNT(*) FROM sys.database_audit_specification_details
           WHERE is_group = 1) AS auditDetailsGroup,
          (SELECT COUNT(*) FROM sys.database_audit_specification_details
           WHERE is_group = 0) AS auditDetailsNonGroup,
          (SELECT COUNT(*) FROM sys.database_audit_specification_details
           WHERE class = 0 AND major_id = 0 AND minor_id = 0) AS auditDetailsDatabaseAddress,
          (SELECT COUNT(*) FROM sys.database_audit_specification_details
           WHERE NOT (class = 0 AND major_id = 0 AND minor_id = 0)) AS auditDetailsOtherAddress,
          (SELECT COUNT(*) FROM sys.database_audit_specification_details
           WHERE audited_principal_id = 0) AS auditDetailsZeroPrincipal,
          (SELECT COUNT(*) FROM sys.database_audit_specification_details
           WHERE audited_principal_id = DATABASE_PRINCIPAL_ID(N'public')) AS auditDetailsPublicPrincipal,
          (SELECT COUNT(*) FROM sys.database_audit_specification_details
           WHERE audited_principal_id <> 0
             AND audited_principal_id <> DATABASE_PRINCIPAL_ID(N'public')) AS auditDetailsOtherPrincipal,
          (SELECT COUNT(*)
           FROM sys.all_objects
           WHERE object_id = OBJECT_ID(N'sys.database_firewall_rules')
             AND schema_id = SCHEMA_ID(N'sys')
             AND type = N'V'
             AND is_ms_shipped = 1) AS databaseFirewallRulesExactObject,
          (SELECT COUNT(*)
           FROM sys.database_permissions AS permissions
           INNER JOIN sys.database_principals AS grantees
             ON grantees.principal_id = permissions.grantee_principal_id
           WHERE permissions.class = 1
             AND permissions.major_id = OBJECT_ID(N'sys.database_firewall_rules')
             AND permissions.minor_id = 0
             AND permissions.permission_name = N'SELECT'
             AND permissions.state = N'G'
             AND grantees.name = N'public') AS databaseFirewallRulesPublicSelect,
          (SELECT COUNT(*)
           FROM sys.database_permissions AS permissions
           WHERE permissions.class = 1
             AND permissions.major_id = OBJECT_ID(N'sys.database_firewall_rules')
             AND permissions.minor_id = 0
             AND permissions.permission_name = N'SELECT'
             AND permissions.state = N'G'
             AND permissions.grantor_principal_id = DATABASE_PRINCIPAL_ID(N'dbo')) AS databaseFirewallRulesGrantorDbo,
          (SELECT COUNT(*)
           FROM sys.database_permissions AS permissions
           WHERE permissions.class = 1
             AND permissions.major_id = OBJECT_ID(N'sys.database_firewall_rules')
             AND permissions.minor_id = 0
             AND permissions.permission_name = N'SELECT'
             AND permissions.state = N'G'
             AND permissions.grantor_principal_id = DATABASE_PRINCIPAL_ID(N'sys')) AS databaseFirewallRulesGrantorSys,
          (SELECT COUNT(*)
           FROM sys.database_permissions AS permissions
           WHERE permissions.class = 1
             AND permissions.major_id = OBJECT_ID(N'sys.database_firewall_rules')
             AND permissions.minor_id = 0
             AND permissions.permission_name = N'SELECT'
             AND permissions.state = N'G'
             AND permissions.grantor_principal_id = DATABASE_PRINCIPAL_ID(N'public')) AS databaseFirewallRulesGrantorPublic,
          (SELECT COUNT(*)
           FROM sys.database_permissions AS permissions
           WHERE permissions.class = 1
             AND permissions.major_id = OBJECT_ID(N'sys.database_firewall_rules')
             AND permissions.minor_id = 0
             AND permissions.permission_name = N'SELECT'
             AND permissions.state = N'G'
             AND permissions.grantor_principal_id = DATABASE_PRINCIPAL_ID(N'guest')) AS databaseFirewallRulesGrantorGuest,
          (SELECT COUNT(*)
           FROM sys.database_permissions AS permissions
           WHERE permissions.class = 1
             AND permissions.major_id = OBJECT_ID(N'sys.database_firewall_rules')
             AND permissions.minor_id = 0
             AND permissions.permission_name = N'SELECT'
             AND permissions.state = N'G'
             AND permissions.grantor_principal_id NOT IN
                 (DATABASE_PRINCIPAL_ID(N'dbo'), DATABASE_PRINCIPAL_ID(N'sys'),
                  DATABASE_PRINCIPAL_ID(N'public'), DATABASE_PRINCIPAL_ID(N'guest'))) AS databaseFirewallRulesGrantorOther,
          (SELECT COUNT(*)
           FROM sys.database_permissions AS permissions
           INNER JOIN sys.database_principals AS grantees
             ON grantees.principal_id = permissions.grantee_principal_id
           WHERE permissions.class = 1
             AND permissions.major_id > 0
             AND permissions.minor_id = 0
             AND permissions.permission_name = N'SELECT'
             AND permissions.state = N'G'
             AND grantees.name = N'public'
             AND permissions.major_id <> OBJECT_ID(N'sys.database_firewall_rules')) AS otherPositivePublicSelect,
          (SELECT COUNT(*)
           FROM sys.database_permissions AS permissions
           INNER JOIN sys.database_principals AS grantees
             ON grantees.principal_id = permissions.grantee_principal_id
           WHERE permissions.class = 0
             AND permissions.major_id = 0
             AND permissions.minor_id = 0
             AND permissions.permission_name = N'CONNECT'
             AND permissions.state = N'G'
             AND grantees.name = N'dbo'
             AND permissions.grantor_principal_id = DATABASE_PRINCIPAL_ID(N'dbo')) AS dboConnectExact;
        """;
    await using var reader = await command.ExecuteReaderAsync();
    AssertExactSqlFieldContract(
        reader,
        AzureSqlPristinePlatformDiagnostic.SqlFieldNames,
        "Azure SQL pristine-platform diagnostic");
    if (!await reader.ReadAsync())
        throw new InvalidOperationException("Azure SQL returned no pristine-platform diagnostic row.");
    var counts = Enumerable.Range(0, AzureSqlPristinePlatformDiagnostic.SqlFieldNames.Count)
        .Select(reader.GetInt32)
        .ToArray();
    if (await reader.ReadAsync())
        throw new InvalidOperationException("Azure SQL returned duplicate pristine-platform diagnostic rows.");
    return AzureSqlPristinePlatformDiagnostic.FromOrderedCounts(counts);
}

static async Task<string> ReadSingleAuditSpecificationNameFingerprintAsync(SqlConnection connection)
{
    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = """
        SELECT
          CONVERT(varchar(64),
              HASHBYTES(N'SHA2_256', CONVERT(varbinary(max), name)),
              2) AS auditSpecificationNameSha256
        FROM sys.database_audit_specifications;
        """;
    await using var reader = await command.ExecuteReaderAsync();
    AssertExactSqlFieldContract(
        reader,
        ["auditSpecificationNameSha256"],
        "Azure SQL audit-specification fingerprint");
    if (!await reader.ReadAsync() || reader.IsDBNull(0))
        throw new InvalidOperationException("Azure SQL returned no audit-specification name fingerprint.");
    var fingerprint = $"sha256:{reader.GetString(0).ToLowerInvariant()}";
    if (!Regex.IsMatch(fingerprint, "^sha256:[0-9a-f]{64}$", RegexOptions.CultureInvariant))
        throw new InvalidOperationException("Azure SQL returned a malformed audit-specification name fingerprint.");
    if (await reader.ReadAsync())
        throw new InvalidOperationException("Azure SQL returned more than one audit-specification name fingerprint.");
    return fingerprint;
}

static async Task AcquireDatabaseInitializationLockAsync(
    SqlConnection connection,
    string resource)
{
    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = """
        DECLARE @result int;
        EXEC @result = sys.sp_getapplock
            @Resource = @resource,
            @LockMode = N'Exclusive',
            @LockOwner = N'Session',
            @LockTimeout = 0,
            @DbPrincipal = N'public';
        SELECT @result;
        """;
    command.Parameters.AddWithValue("@resource", resource);
    var result = Convert.ToInt32(await command.ExecuteScalarAsync());
    if (result < 0)
    {
        throw new InvalidOperationException(
            "Another database initialization session holds the exact Gateway bootstrap lock.");
    }
}

static async Task ReleaseDatabaseInitializationLockAsync(
    SqlConnection connection,
    string resource)
{
    if (connection.State != System.Data.ConnectionState.Open)
        return;

    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = """
        DECLARE @result int;
        EXEC @result = sys.sp_releaseapplock
            @Resource = @resource,
            @LockOwner = N'Session',
            @DbPrincipal = N'public';
        SELECT @result;
        """;
    command.Parameters.AddWithValue("@resource", resource);
    var result = Convert.ToInt32(await command.ExecuteScalarAsync());
    if (result < 0)
        throw new InvalidOperationException("The Gateway database initialization lock was not released cleanly.");
}

static async Task<string?> ReadDatabaseInitializationMarkerAsync(SqlConnection connection)
{
    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = """
        SELECT name, CONVERT(nvarchar(4000), value)
        FROM sys.extended_properties
        WHERE class = 0
          AND major_id = 0
          AND minor_id = 0
          AND name = @name
        ORDER BY name;
        """;
    command.Parameters.AddWithValue("@name", DatabaseBootstrapRecoveryContract.MarkerName);
    await using var reader = await command.ExecuteReaderAsync();
    var matches = new List<(string Name, string Value)>();
    while (await reader.ReadAsync())
        matches.Add((reader.GetString(0), reader.GetString(1)));
    if (matches.Count > 1)
        throw new InvalidOperationException("Azure SQL returned duplicate database initialization markers.");
    if (matches.Count == 0)
        return null;
    if (!matches[0].Name.Equals(DatabaseBootstrapRecoveryContract.MarkerName, StringComparison.Ordinal))
        throw new InvalidOperationException("Azure SQL returned a case-conflicting database initialization marker.");
    return matches[0].Value;
}

static async Task WriteDatabaseInitializationMarkerAsync(
    SqlConnection connection,
    string markerValue)
{
    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = """
        EXEC sys.sp_addextendedproperty
            @name = @name,
            @value = @value;
        """;
    command.Parameters.AddWithValue("@name", DatabaseBootstrapRecoveryContract.MarkerName);
    command.Parameters.AddWithValue("@value", markerValue);
    await command.ExecuteNonQueryAsync();
}

static async Task AssertCurrentEfModelSchemaAsync(
    SqlConnection connection,
    IReadOnlyCollection<ExpectedDatabasePrincipal>? expectedRuntimePrincipals = null,
    string? recoverableIncompletePrincipalName = null,
    bool allowAllRecoverablePrincipalPrefixes = false,
    bool requireAllExpectedPrincipals = false)
{
    var databaseCollation = await ReadDatabaseCollationAsync(connection);
    var options = new DbContextOptionsBuilder<GatewayDbContext>()
        .UseSqlServer(connection)
        .Options;
    await using var context = new GatewayDbContext(options);
    var expected = GetExpectedSchemaContract(context, databaseCollation);
    var actual = await GetActualSchemaContractAsync(connection);
    ExactDatabaseSchemaContract.AssertExact(expected, actual);
    if (expectedRuntimePrincipals is { Count: > 0 })
    {
        await AssertExpectedDatabaseAuthorityAsync(
            connection,
            expectedRuntimePrincipals,
            recoverableIncompletePrincipalName,
            allowAllRecoverablePrincipalPrefixes,
            requireAllExpectedPrincipals);
    }
}

static async Task AssertExpectedDatabaseAuthorityAsync(
    SqlConnection connection,
    IReadOnlyCollection<ExpectedDatabasePrincipal> expectedRuntimePrincipals,
    string? recoverableIncompletePrincipalName,
    bool allowAllRecoverablePrincipalPrefixes,
    bool requireAllExpectedPrincipals)
{
    var metadataPrincipal = expectedRuntimePrincipals.SingleOrDefault(
        item => item.ExpectedDirectPermissionCount == 2);
    if (metadataPrincipal is null ||
        expectedRuntimePrincipals.Count(item => item.ExpectedDirectPermissionCount == 2) != 1 ||
        expectedRuntimePrincipals.Count(item => item.ExpectedDirectPermissionCount == 1) != 1 ||
        expectedRuntimePrincipals.Any(item => item.ExpectedDirectPermissionCount is < 1 or > 2))
    {
        throw new InvalidOperationException(
            "The reviewed runtime-principal metadata-attestation permission contract is malformed.");
    }
    var principals = new Dictionary<string, MutableObservedPrincipal>(StringComparer.Ordinal);
    await using (var command = connection.CreateCommand())
    {
        command.CommandTimeout = 60;
        command.CommandText = """
            SELECT principals.principal_id, principals.name, principals.type,
                   TRY_CONVERT(uniqueidentifier, principals.sid),
                   (SELECT COUNT(*) FROM sys.database_permissions AS permissions
                    WHERE permissions.grantee_principal_id = principals.principal_id),
                   (SELECT COUNT(*) FROM sys.schemas AS schemas
                    WHERE schemas.principal_id = principals.principal_id),
                   (SELECT COUNT(*) FROM sys.database_principals AS owned
                    WHERE owned.owning_principal_id = principals.principal_id)
            FROM sys.database_principals AS principals
            WHERE principals.principal_id > 4
              AND principals.is_fixed_role = 0
            ORDER BY principals.principal_id;
            """;
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var name = reader.GetString(1);
            if (!principals.TryAdd(
                    name,
                    new MutableObservedPrincipal(
                        reader.GetInt32(0),
                        name,
                        reader.IsDBNull(3) ? null : reader.GetGuid(3),
                        reader.GetString(2),
                        reader.GetInt32(4),
                        reader.GetInt32(5),
                        reader.GetInt32(6),
                        [])))
            {
                throw new InvalidOperationException("Azure SQL returned duplicate exact-name database principals.");
            }
        }
    }

    var unexpectedRoleMembershipCount = 0;
    var builtInDboOwnerMembershipCount = 0;
    await using (var command = connection.CreateCommand())
    {
        command.CommandTimeout = 60;
        command.CommandText = """
            SELECT roles.name, members.name, roles.is_fixed_role,
                   members.principal_id, DATABASE_PRINCIPAL_ID(N'dbo')
            FROM sys.database_role_members AS memberships
            INNER JOIN sys.database_principals AS roles
              ON roles.principal_id = memberships.role_principal_id
            INNER JOIN sys.database_principals AS members
              ON members.principal_id = memberships.member_principal_id
            ORDER BY members.name, roles.name;
            """;
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var roleName = reader.GetString(0);
            var memberName = reader.GetString(1);
            if (roleName.Equals("db_owner", StringComparison.Ordinal) &&
                memberName.Equals("dbo", StringComparison.Ordinal) &&
                reader.GetBoolean(2) &&
                reader.GetInt32(3) == reader.GetInt32(4))
            {
                builtInDboOwnerMembershipCount++;
                continue;
            }
            if (!principals.TryGetValue(memberName, out var principal))
            {
                unexpectedRoleMembershipCount++;
                continue;
            }
            principal.Roles.Add(roleName);
        }
    }
    if (builtInDboOwnerMembershipCount != 1)
    {
        unexpectedRoleMembershipCount++;
    }

    int unexpectedDirectPermissionCount;
    await using (var command = connection.CreateCommand())
    {
        command.CommandTimeout = 60;
        command.CommandText = $"""
            {GetDatabasePermissionTelemetryCteSql()}
            SELECT
            {GetDatabasePermissionTelemetryProjectionSql()}
            FROM databasePermissionTelemetry;
            """;
        command.Parameters.AddWithValue("@allowMetadataPrincipalViewDefinition", 1);
        command.Parameters.AddWithValue("@metadataPrincipalName", metadataPrincipal.Name);
        command.Parameters.AddWithValue("@runtimePrincipalName1", metadataPrincipal.Name);
        command.Parameters.AddWithValue(
            "@runtimePrincipalName2",
            expectedRuntimePrincipals.Single(item => item.ExpectedDirectPermissionCount == 1).Name);
        await using var reader = await command.ExecuteReaderAsync();
        AssertExactSqlFieldContract(
            reader,
            DatabaseDirectPermissionTelemetry.SqlFieldNames,
            "post-schema database-permission telemetry");
        if (!await reader.ReadAsync())
            throw new InvalidOperationException("Azure SQL returned no post-schema database-permission telemetry row.");
        var permissionCounts = Enumerable
            .Range(0, DatabaseDirectPermissionTelemetry.ExpectedFieldCount)
            .Select(reader.GetInt32)
            .ToArray();
        unexpectedDirectPermissionCount =
            DatabaseDirectPermissionTelemetry.FromOrderedCounts(permissionCounts).UnexpectedCount;
        if (await reader.ReadAsync())
        {
            throw new InvalidOperationException(
                "Azure SQL returned duplicate post-schema database-permission telemetry rows.");
        }
    }

    var observed = principals.Values
        .Select(item => new ObservedDatabasePrincipal(
            item.Name,
            item.ClientId,
            item.Type,
            item.Roles,
            item.DirectPermissionCount,
            item.OwnedSchemaCount,
            item.OwnedPrincipalCount))
        .ToArray();
    ExactDatabaseAuthorityContract.AssertExactOrRecoverablePrefix(
        expectedRuntimePrincipals,
        observed,
        recoverableIncompletePrincipalName,
        allowAllRecoverablePrincipalPrefixes,
        requireAllExpectedPrincipals,
        unexpectedRoleMembershipCount,
        unexpectedDirectPermissionCount);
}

static async Task<string> ReadDatabaseCollationAsync(SqlConnection connection)
{
    const string expectedCollation = "SQL_Latin1_General_CP1_CI_AS";
    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = "SELECT collation_name FROM sys.databases WHERE name = DB_NAME();";
    var value = await command.ExecuteScalarAsync();
    if (value is not string collation || string.IsNullOrWhiteSpace(collation))
        throw new InvalidOperationException("Azure SQL returned no exact database collation.");
    if (!collation.Equals(expectedCollation, StringComparison.Ordinal))
        throw new InvalidOperationException("GatewayDb does not use the exact reviewed SQL collation.");
    return collation;
}

static ExactDatabaseSchemaSnapshot GetExpectedSchemaContract(
    GatewayDbContext context,
    string databaseCollation)
{
    var tables = new HashSet<string>(StringComparer.Ordinal);
    var columns = new HashSet<string>(StringComparer.Ordinal);
    var primaryKeys = new HashSet<string>(StringComparer.Ordinal);
    var uniqueConstraints = new HashSet<string>(StringComparer.Ordinal);
    var foreignKeys = new HashSet<string>(StringComparer.Ordinal);
    var checkConstraints = new HashSet<string>(StringComparer.Ordinal);
    var indexes = new HashSet<string>(StringComparer.Ordinal);

    var designTimeModel = context.GetService<IDesignTimeModel>().Model;
    foreach (var table in designTimeModel.GetRelationalModel().Tables)
    {
        if (table.IsExcludedFromMigrations)
            continue;
        var schema = table.Schema ?? "dbo";
        var tableKey = $"{schema}.{table.Name}";
        var hasLobData = table.Columns.Any(column => IsLargeObjectStoreType(column.StoreType));
        tables.Add(
            $"{tableKey}|temporal:0|memory:0|durability:SCHEMA_AND_DATA|" +
            $"lobspace:{(hasLobData ? "PRIMARY" : "-")}|filestreamspace:-|external:0|filetable:0|" +
            "node:0|edge:0|ledger:0|lock:TABLE|lockbulk:0|largeout:0|replicated:0|" +
            "merge:0|syncrepl:0|cdc:0|archive:0|ansinulls:1|replfilter:0");

        foreach (var column in table.Columns)
        {
            var propertyMappings = column.PropertyMappings
                .Select(mapping =>
                {
                    var mappedTable = mapping.TableMapping.Table;
                    var mappedStoreObject = StoreObjectIdentifier.Table(mappedTable.Name, mappedTable.Schema);
                    return (
                        Property: mapping.Property,
                        StoreObject: mappedStoreObject,
                        Strategy: mapping.Property.GetValueGenerationStrategy(mappedStoreObject));
                })
                .Distinct()
                .ToArray();
            var strategies = propertyMappings
                .Select(mapping => mapping.Strategy)
                .Distinct()
                .ToArray();
            if (strategies.Length > 1)
                throw new InvalidOperationException("The EF relational model returned conflicting value-generation strategies for one column.");
            var identity = strategies.SingleOrDefault() == SqlServerValueGenerationStrategy.IdentityColumn;
            var identityMapping = identity
                ? propertyMappings.First(mapping => mapping.Strategy == SqlServerValueGenerationStrategy.IdentityColumn)
                : default;
            var identitySeed = identity
                ? Convert.ToString(identityMapping.Property!.GetIdentitySeed(identityMapping.StoreObject) ?? 1L, CultureInfo.InvariantCulture)!
                : "-";
            var identityIncrement = identity
                ? Convert.ToString(identityMapping.Property!.GetIdentityIncrement(identityMapping.StoreObject) ?? 1, CultureInfo.InvariantCulture)!
                : "-";
            var defaultValue = GetExpectedDefaultContract(column);
            var computedSql = column.ComputedColumnSql is null
                ? "-"
                : NormalizeSqlExpression(column.ComputedColumnSql);
            var storeType = NormalizeStoreType(column.StoreType);
            var collation = SupportsCollation(storeType)
                ? column.Collation ?? databaseCollation
                : "-";
            columns.Add(
                $"{tableKey}|{column.Name}|{storeType}|{(column.IsNullable ? 1 : 0)}|" +
                $"default:{defaultValue}|computed:{computedSql}|stored:{(column.IsStored == true ? 1 : 0)}|" +
                $"identity:{(identity ? 1 : 0)}:{identitySeed}:{identityIncrement}:nfr:0|rowversion:{(column.IsRowVersion ? 1 : 0)}|" +
                $"generated:0|sparse:0|columnset:0|filestream:0|collation:{collation}|" +
                "encrypted:0:-:-|masked:0:-|hidden:0|xml:0:0|rule:0");
        }

        foreach (var constraint in table.UniqueConstraints)
        {
            var clustered = GetExpectedConstraintClustered(constraint);
            var keyColumns = constraint.Columns
                .Select(column => $"{column.Name}:A")
                .ToArray();
            var value =
                $"{tableKey}|{constraint.Name}|{string.Join(',', keyColumns)}|" +
                $"type:{(clustered ? "CLUSTERED" : "NONCLUSTERED")}|space:PRIMARY|" +
                "disabled:0|hypothetical:0|fill:0|padded:0|ignoredup:0|rowlocks:1|pagelocks:1|seq:0|statsnorecompute:0";
            if (constraint.GetIsPrimaryKey())
                primaryKeys.Add(value);
            else
                uniqueConstraints.Add(value);
        }

        foreach (var foreignKey in table.ForeignKeyConstraints)
        {
            var principalKey = $"{foreignKey.PrincipalTable.Schema ?? "dbo"}.{foreignKey.PrincipalTable.Name}";
            foreignKeys.Add(
                $"{tableKey}|{foreignKey.Name}|{string.Join(',', foreignKey.Columns.Select(column => column.Name))}|" +
                $"{principalKey}|{string.Join(',', foreignKey.PrincipalColumns.Select(column => column.Name))}|" +
                $"delete:{NormalizeReferentialAction(foreignKey.OnDeleteAction)}|update:NO_ACTION|disabled:0|untrusted:0");
        }

        foreach (var checkConstraint in table.CheckConstraints)
        {
            checkConstraints.Add(
                $"{tableKey}|{checkConstraint.Name}|{NormalizeSqlExpression(checkConstraint.Sql)}|disabled:0|untrusted:0");
        }

        foreach (var index in table.Indexes)
        {
            var descending = index.IsDescending ?? Enumerable.Repeat(false, index.Columns.Count).ToArray();
            if (descending.Count != index.Columns.Count)
                throw new InvalidOperationException("The EF relational model returned an invalid index sort-order contract.");
            var keyColumns = index.Columns
                .Select((column, position) => $"K:{column.Name}:{(descending[position] ? "D" : "A")}")
                .ToArray();
            var includedColumns = GetExpectedIncludedIndexColumns(index)
                .Order(StringComparer.Ordinal)
                .Select(name => $"I:{name}");
            var clustered = GetExpectedIndexClustered(index);
            indexes.Add(
                $"{tableKey}|{index.Name}|unique:{(index.IsUnique ? 1 : 0)}|filter:{NormalizeOptionalSqlExpression(index.Filter)}|" +
                $"type:{(clustered ? "CLUSTERED" : "NONCLUSTERED")}|space:PRIMARY|disabled:0|hypothetical:0|" +
                "fill:0|padded:0|ignoredup:0|rowlocks:1|pagelocks:1|seq:0|statsnorecompute:0|" +
                $"{string.Join(',', keyColumns.Concat(includedColumns))}");
        }
    }

    return new ExactDatabaseSchemaSnapshot(
        tables.Order(StringComparer.Ordinal).ToArray(),
        columns.Order(StringComparer.Ordinal).ToArray(),
        primaryKeys.Order(StringComparer.Ordinal).ToArray(),
        uniqueConstraints.Order(StringComparer.Ordinal).ToArray(),
        foreignKeys.Order(StringComparer.Ordinal).ToArray(),
        checkConstraints.Order(StringComparer.Ordinal).ToArray(),
        indexes.Order(StringComparer.Ordinal).ToArray(),
        0);
}

static async Task<ExactDatabaseSchemaSnapshot> GetActualSchemaContractAsync(SqlConnection connection)
{
    var tables = new List<string>();
    await using (var command = connection.CreateCommand())
    {
        command.CommandTimeout = 60;
        command.CommandText = """
            SELECT schemas.name, tables.name, tables.temporal_type, tables.is_memory_optimized,
                   tables.durability_desc, lob_space.name, filestream_space.name,
                   tables.is_external, tables.is_filetable, tables.is_node, tables.is_edge,
                   tables.ledger_type, tables.lock_escalation_desc, tables.lock_on_bulk_load,
                   tables.large_value_types_out_of_row, tables.is_replicated,
                   tables.is_merge_published, tables.is_sync_tran_subscribed,
                   tables.is_tracked_by_cdc, tables.is_remote_data_archive_enabled,
                   tables.uses_ansi_nulls, tables.has_replication_filter
            FROM sys.tables AS tables
            INNER JOIN sys.schemas AS schemas ON schemas.schema_id = tables.schema_id
            LEFT JOIN sys.data_spaces AS lob_space
              ON lob_space.data_space_id = tables.lob_data_space_id
             AND tables.lob_data_space_id <> 0
            LEFT JOIN sys.data_spaces AS filestream_space
              ON filestream_space.data_space_id = tables.filestream_data_space_id
             AND tables.filestream_data_space_id <> 0
            WHERE tables.is_ms_shipped = 0
            ORDER BY schemas.name, tables.name;
            """;
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            tables.Add(
                $"{reader.GetString(0)}.{reader.GetString(1)}|temporal:{Convert.ToInt32(reader.GetValue(2))}|" +
                $"memory:{(reader.GetBoolean(3) ? 1 : 0)}|durability:{reader.GetString(4)}|" +
                $"lobspace:{(reader.IsDBNull(5) ? "-" : reader.GetString(5))}|" +
                $"filestreamspace:{(reader.IsDBNull(6) ? "-" : reader.GetString(6))}|" +
                $"external:{(reader.GetBoolean(7) ? 1 : 0)}|filetable:{(reader.GetBoolean(8) ? 1 : 0)}|" +
                $"node:{(reader.GetBoolean(9) ? 1 : 0)}|edge:{(reader.GetBoolean(10) ? 1 : 0)}|" +
                $"ledger:{Convert.ToInt32(reader.GetValue(11))}|lock:{reader.GetString(12)}|lockbulk:{(reader.GetBoolean(13) ? 1 : 0)}|" +
                $"largeout:{(reader.GetBoolean(14) ? 1 : 0)}|replicated:{(reader.GetBoolean(15) ? 1 : 0)}|" +
                $"merge:{(reader.GetBoolean(16) ? 1 : 0)}|syncrepl:{(reader.GetBoolean(17) ? 1 : 0)}|" +
                $"cdc:{(reader.GetBoolean(18) ? 1 : 0)}|archive:{(reader.GetBoolean(19) ? 1 : 0)}|" +
                $"ansinulls:{(reader.GetBoolean(20) ? 1 : 0)}|replfilter:{(reader.GetBoolean(21) ? 1 : 0)}");
        }
    }

    var columns = new List<string>();
    await using (var command = connection.CreateCommand())
    {
        command.CommandTimeout = 60;
        command.CommandText = """
            SELECT schemas.name, tables.name, columns.name, types.name,
                   columns.max_length, columns.precision, columns.scale, columns.is_nullable,
                   defaults.definition, computed.definition, computed.is_persisted,
                   columns.is_identity,
                   CONVERT(nvarchar(100), identities.seed_value),
                   CONVERT(nvarchar(100), identities.increment_value),
                   columns.generated_always_type, columns.is_sparse, columns.is_column_set,
                   columns.is_filestream, columns.collation_name, columns.encryption_type,
                   columns.encryption_algorithm_name, columns.column_encryption_key_id,
                   masked.is_masked, masked.masking_function, columns.is_hidden,
                   columns.xml_collection_id, columns.is_xml_document, columns.rule_object_id,
                   identities.is_not_for_replication
            FROM sys.tables AS tables
            INNER JOIN sys.schemas AS schemas ON schemas.schema_id = tables.schema_id
            INNER JOIN sys.columns AS columns ON columns.object_id = tables.object_id
            INNER JOIN sys.types AS types ON types.user_type_id = columns.user_type_id
            LEFT JOIN sys.default_constraints AS defaults
                ON defaults.parent_object_id = columns.object_id
               AND defaults.parent_column_id = columns.column_id
            LEFT JOIN sys.computed_columns AS computed
                ON computed.object_id = columns.object_id
               AND computed.column_id = columns.column_id
            LEFT JOIN sys.identity_columns AS identities
                ON identities.object_id = columns.object_id
               AND identities.column_id = columns.column_id
            LEFT JOIN sys.masked_columns AS masked
                ON masked.object_id = columns.object_id
               AND masked.column_id = columns.column_id
            WHERE tables.is_ms_shipped = 0
            ORDER BY schemas.name, tables.name, columns.column_id;
            """;
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var tableKey = $"{reader.GetString(0)}.{reader.GetString(1)}";
            var storeType = GetActualStoreType(reader.GetString(3), reader.GetInt16(4), reader.GetByte(5), reader.GetByte(6));
            var defaultValue = reader.IsDBNull(8)
                ? "-"
                : CanonicalizeDefaultExpression(reader.GetString(8), storeType);
            var computedSql = reader.IsDBNull(9)
                ? "-"
                : NormalizeSqlExpression(reader.GetString(9));
            var identity = reader.GetBoolean(11);
            var identitySeed = reader.IsDBNull(12) ? "-" : NormalizeNumericMetadata(reader.GetString(12));
            var identityIncrement = reader.IsDBNull(13) ? "-" : NormalizeNumericMetadata(reader.GetString(13));
            var rowVersion = storeType == "rowversion";
            var encryptionType = reader.IsDBNull(19) ? 0 : Convert.ToInt32(reader.GetValue(19));
            var encryptionAlgorithm = CanonicalizeMetadataValue(reader.IsDBNull(20) ? null : reader.GetString(20));
            var encryptionKeyId = reader.IsDBNull(21)
                ? "-"
                : Convert.ToString(reader.GetValue(21), CultureInfo.InvariantCulture)!;
            var isMasked = !reader.IsDBNull(22) && reader.GetBoolean(22);
            var maskingFunction = CanonicalizeMetadataValue(reader.IsDBNull(23) ? null : reader.GetString(23));
            columns.Add(
                $"{tableKey}|{reader.GetString(2)}|{storeType}|{(reader.GetBoolean(7) ? 1 : 0)}|" +
                $"default:{defaultValue}|computed:{computedSql}|stored:{(!reader.IsDBNull(10) && reader.GetBoolean(10) ? 1 : 0)}|" +
                $"identity:{(identity ? 1 : 0)}:{identitySeed}:{identityIncrement}:nfr:{(!reader.IsDBNull(28) && reader.GetBoolean(28) ? 1 : 0)}|" +
                $"rowversion:{(rowVersion ? 1 : 0)}|" +
                $"generated:{reader.GetByte(14)}|sparse:{(reader.GetBoolean(15) ? 1 : 0)}|" +
                $"columnset:{(reader.GetBoolean(16) ? 1 : 0)}|filestream:{(reader.GetBoolean(17) ? 1 : 0)}|" +
                $"collation:{(reader.IsDBNull(18) ? "-" : reader.GetString(18))}|" +
                $"encrypted:{encryptionType}:{encryptionAlgorithm}:{encryptionKeyId}|" +
                $"masked:{(isMasked ? 1 : 0)}:{maskingFunction}|hidden:{(reader.GetBoolean(24) ? 1 : 0)}|" +
                $"xml:{Convert.ToInt32(reader.GetValue(25))}:{(reader.GetBoolean(26) ? 1 : 0)}|" +
                $"rule:{Convert.ToInt32(reader.GetValue(27))}");
        }
    }

    var primaryKeys = new List<string>();
    var uniqueConstraints = new List<string>();
    await using (var command = connection.CreateCommand())
    {
        command.CommandTimeout = 60;
        command.CommandText = """
            SELECT schemas.name, tables.name, constraints.name, constraints.type,
                   columns.name, index_columns.is_descending_key, indexes.type_desc,
                   data_spaces.name, indexes.is_disabled, indexes.is_hypothetical,
                   indexes.fill_factor, indexes.is_padded, indexes.ignore_dup_key,
                   indexes.allow_row_locks, indexes.allow_page_locks,
                   indexes.optimize_for_sequential_key, CAST(COALESCE(stats.no_recompute, 0) AS bit)
            FROM sys.key_constraints AS constraints
            INNER JOIN sys.tables AS tables ON tables.object_id = constraints.parent_object_id
            INNER JOIN sys.schemas AS schemas ON schemas.schema_id = tables.schema_id
            INNER JOIN sys.index_columns AS index_columns
                ON index_columns.object_id = constraints.parent_object_id
               AND index_columns.index_id = constraints.unique_index_id
               AND index_columns.key_ordinal > 0
            INNER JOIN sys.indexes AS indexes
                ON indexes.object_id = constraints.parent_object_id
               AND indexes.index_id = constraints.unique_index_id
            INNER JOIN sys.data_spaces AS data_spaces
                ON data_spaces.data_space_id = indexes.data_space_id
            LEFT JOIN sys.stats AS stats
                ON stats.object_id = indexes.object_id
               AND stats.stats_id = indexes.index_id
            INNER JOIN sys.columns AS columns
                ON columns.object_id = index_columns.object_id
               AND columns.column_id = index_columns.column_id
            WHERE tables.is_ms_shipped = 0
            ORDER BY schemas.name, tables.name, constraints.name, index_columns.key_ordinal;
            """;
        await using var reader = await command.ExecuteReaderAsync();
        var parts = new Dictionary<string, KeyConstraintParts>(StringComparer.Ordinal);
        while (await reader.ReadAsync())
        {
            var key = $"{reader.GetString(0)}.{reader.GetString(1)}|{reader.GetString(2)}";
            if (!parts.TryGetValue(key, out var part))
            {
                part = new KeyConstraintParts(
                    reader.GetString(3),
                    reader.GetString(6),
                    reader.GetString(7),
                    reader.GetBoolean(8),
                    reader.GetBoolean(9),
                    reader.GetByte(10),
                    reader.GetBoolean(11),
                    reader.GetBoolean(12),
                    reader.GetBoolean(13),
                    reader.GetBoolean(14),
                    reader.GetBoolean(15),
                    reader.GetBoolean(16),
                    []);
                parts.Add(key, part);
            }
            if (!part.Type.Equals(reader.GetString(3), StringComparison.Ordinal) ||
                !part.IndexType.Equals(reader.GetString(6), StringComparison.Ordinal) ||
                !part.DataSpace.Equals(reader.GetString(7), StringComparison.Ordinal) ||
                part.Disabled != reader.GetBoolean(8) ||
                part.Hypothetical != reader.GetBoolean(9) ||
                part.FillFactor != reader.GetByte(10) ||
                part.Padded != reader.GetBoolean(11) ||
                part.IgnoreDuplicateKey != reader.GetBoolean(12) ||
                part.AllowRowLocks != reader.GetBoolean(13) ||
                part.AllowPageLocks != reader.GetBoolean(14) ||
                part.OptimizeForSequentialKey != reader.GetBoolean(15) ||
                part.StatisticsNoRecompute != reader.GetBoolean(16))
                throw new InvalidOperationException("Azure SQL returned inconsistent key-constraint metadata.");
            part.Columns.Add($"{reader.GetString(4)}:{(reader.GetBoolean(5) ? "D" : "A")}");
        }
        foreach (var entry in parts)
        {
            var value =
                $"{entry.Key}|{string.Join(',', entry.Value.Columns)}|" +
                $"type:{entry.Value.IndexType}|space:{entry.Value.DataSpace}|" +
                $"disabled:{(entry.Value.Disabled ? 1 : 0)}|hypothetical:{(entry.Value.Hypothetical ? 1 : 0)}|" +
                $"fill:{entry.Value.FillFactor}|padded:{(entry.Value.Padded ? 1 : 0)}|" +
                $"ignoredup:{(entry.Value.IgnoreDuplicateKey ? 1 : 0)}|rowlocks:{(entry.Value.AllowRowLocks ? 1 : 0)}|" +
                $"pagelocks:{(entry.Value.AllowPageLocks ? 1 : 0)}|seq:{(entry.Value.OptimizeForSequentialKey ? 1 : 0)}|" +
                $"statsnorecompute:{(entry.Value.StatisticsNoRecompute ? 1 : 0)}";
            if (entry.Value.Type.Equals("PK", StringComparison.Ordinal))
                primaryKeys.Add(value);
            else if (entry.Value.Type.Equals("UQ", StringComparison.Ordinal))
                uniqueConstraints.Add(value);
            else
                throw new InvalidOperationException("Azure SQL returned an unsupported key-constraint type.");
        }
    }

    var foreignKeys = new List<string>();
    await using (var command = connection.CreateCommand())
    {
        command.CommandTimeout = 60;
        command.CommandText = """
            SELECT schemas.name, tables.name, foreign_keys.name,
                   columns.name, principal_schemas.name, principal_tables.name,
                   principal_columns.name, foreign_keys.delete_referential_action_desc,
                   foreign_keys.update_referential_action_desc,
                   foreign_keys.is_disabled, foreign_keys.is_not_trusted
            FROM sys.foreign_keys AS foreign_keys
            INNER JOIN sys.tables AS tables ON tables.object_id = foreign_keys.parent_object_id
            INNER JOIN sys.schemas AS schemas ON schemas.schema_id = tables.schema_id
            INNER JOIN sys.tables AS principal_tables ON principal_tables.object_id = foreign_keys.referenced_object_id
            INNER JOIN sys.schemas AS principal_schemas ON principal_schemas.schema_id = principal_tables.schema_id
            INNER JOIN sys.foreign_key_columns AS foreign_key_columns
                ON foreign_key_columns.constraint_object_id = foreign_keys.object_id
            INNER JOIN sys.columns AS columns
                ON columns.object_id = foreign_key_columns.parent_object_id
               AND columns.column_id = foreign_key_columns.parent_column_id
            INNER JOIN sys.columns AS principal_columns
                ON principal_columns.object_id = foreign_key_columns.referenced_object_id
               AND principal_columns.column_id = foreign_key_columns.referenced_column_id
            WHERE tables.is_ms_shipped = 0
            ORDER BY schemas.name, tables.name, foreign_keys.name, foreign_key_columns.constraint_column_id;
            """;
        await using var reader = await command.ExecuteReaderAsync();
        var parts = new Dictionary<string, (string Principal, string DeleteAction, string UpdateAction, bool Disabled, bool Untrusted, List<string> Columns, List<string> PrincipalColumns)>(StringComparer.Ordinal);
        while (await reader.ReadAsync())
        {
            var key = $"{reader.GetString(0)}.{reader.GetString(1)}|{reader.GetString(2)}";
            var principal = $"{reader.GetString(4)}.{reader.GetString(5)}";
            if (!parts.TryGetValue(key, out var part))
            {
                part = (principal, reader.GetString(7), reader.GetString(8), reader.GetBoolean(9), reader.GetBoolean(10), [], []);
                parts.Add(key, part);
            }
            if (!part.Principal.Equals(principal, StringComparison.Ordinal) ||
                !part.DeleteAction.Equals(reader.GetString(7), StringComparison.Ordinal) ||
                !part.UpdateAction.Equals(reader.GetString(8), StringComparison.Ordinal) ||
                part.Disabled != reader.GetBoolean(9) || part.Untrusted != reader.GetBoolean(10))
            {
                throw new InvalidOperationException("Azure SQL returned inconsistent foreign-key metadata.");
            }
            part.Columns.Add(reader.GetString(3));
            part.PrincipalColumns.Add(reader.GetString(6));
        }
        foreignKeys.AddRange(parts.Select(entry =>
            $"{entry.Key}|{string.Join(',', entry.Value.Columns)}|{entry.Value.Principal}|" +
            $"{string.Join(',', entry.Value.PrincipalColumns)}|delete:{entry.Value.DeleteAction}|" +
            $"update:{entry.Value.UpdateAction}|" +
            $"disabled:{(entry.Value.Disabled ? 1 : 0)}|untrusted:{(entry.Value.Untrusted ? 1 : 0)}"));
    }

    var checkConstraints = new List<string>();
    await using (var command = connection.CreateCommand())
    {
        command.CommandTimeout = 60;
        command.CommandText = """
            SELECT schemas.name, tables.name, checks.name, checks.definition,
                   checks.is_disabled, checks.is_not_trusted
            FROM sys.check_constraints AS checks
            INNER JOIN sys.tables AS tables ON tables.object_id = checks.parent_object_id
            INNER JOIN sys.schemas AS schemas ON schemas.schema_id = tables.schema_id
            WHERE tables.is_ms_shipped = 0
            ORDER BY schemas.name, tables.name, checks.name;
            """;
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            checkConstraints.Add(
                $"{reader.GetString(0)}.{reader.GetString(1)}|{reader.GetString(2)}|" +
                $"{NormalizeSqlExpression(reader.GetString(3))}|disabled:{(reader.GetBoolean(4) ? 1 : 0)}|" +
                $"untrusted:{(reader.GetBoolean(5) ? 1 : 0)}");
        }
    }

    var indexParts = new Dictionary<string, IndexParts>(StringComparer.Ordinal);
    await using (var command = connection.CreateCommand())
    {
        command.CommandTimeout = 60;
        command.CommandText = """
            SELECT schemas.name, tables.name, indexes.name, indexes.is_unique,
                   columns.name, index_columns.is_included_column,
                   index_columns.is_descending_key, indexes.filter_definition,
                   indexes.type_desc, data_spaces.name,
                   indexes.is_disabled, indexes.is_hypothetical,
                   indexes.fill_factor, indexes.is_padded, indexes.ignore_dup_key,
                   indexes.allow_row_locks, indexes.allow_page_locks,
                   indexes.optimize_for_sequential_key,
                   CAST(COALESCE(stats.no_recompute, 0) AS bit)
            FROM sys.indexes AS indexes
            INNER JOIN sys.tables AS tables ON tables.object_id = indexes.object_id
            INNER JOIN sys.schemas AS schemas ON schemas.schema_id = tables.schema_id
            INNER JOIN sys.data_spaces AS data_spaces ON data_spaces.data_space_id = indexes.data_space_id
            LEFT JOIN sys.stats AS stats
                ON stats.object_id = indexes.object_id
               AND stats.stats_id = indexes.index_id
            INNER JOIN sys.index_columns AS index_columns
                ON index_columns.object_id = indexes.object_id AND index_columns.index_id = indexes.index_id
            INNER JOIN sys.columns AS columns
                ON columns.object_id = index_columns.object_id AND columns.column_id = index_columns.column_id
            WHERE tables.is_ms_shipped = 0
              AND indexes.name IS NOT NULL
              AND indexes.is_primary_key = 0
              AND indexes.is_unique_constraint = 0
            ORDER BY schemas.name, tables.name, indexes.name,
                     index_columns.is_included_column, index_columns.key_ordinal, index_columns.index_column_id;
            """;
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            var key = $"{reader.GetString(0)}.{reader.GetString(1)}|{reader.GetString(2)}";
            if (!indexParts.TryGetValue(key, out var part))
            {
                part = new IndexParts(
                    reader.GetBoolean(3),
                    reader.IsDBNull(7) ? null : reader.GetString(7),
                    reader.GetString(8),
                    reader.GetString(9),
                    reader.GetBoolean(10),
                    reader.GetBoolean(11),
                    reader.GetByte(12),
                    reader.GetBoolean(13),
                    reader.GetBoolean(14),
                    reader.GetBoolean(15),
                    reader.GetBoolean(16),
                    reader.GetBoolean(17),
                    reader.GetBoolean(18),
                    [],
                    []);
                indexParts.Add(key, part);
            }
            var filter = reader.IsDBNull(7) ? null : reader.GetString(7);
            if (part.Unique != reader.GetBoolean(3) ||
                !string.Equals(part.Filter, filter, StringComparison.Ordinal) ||
                !part.IndexType.Equals(reader.GetString(8), StringComparison.Ordinal) ||
                !part.DataSpace.Equals(reader.GetString(9), StringComparison.Ordinal) ||
                part.Disabled != reader.GetBoolean(10) ||
                part.Hypothetical != reader.GetBoolean(11) ||
                part.FillFactor != reader.GetByte(12) ||
                part.Padded != reader.GetBoolean(13) ||
                part.IgnoreDuplicateKey != reader.GetBoolean(14) ||
                part.AllowRowLocks != reader.GetBoolean(15) ||
                part.AllowPageLocks != reader.GetBoolean(16) ||
                part.OptimizeForSequentialKey != reader.GetBoolean(17) ||
                part.StatisticsNoRecompute != reader.GetBoolean(18))
                throw new InvalidOperationException("Azure SQL returned inconsistent index metadata.");
            if (reader.GetBoolean(5))
                part.Includes.Add(reader.GetString(4));
            else
                part.Keys.Add($"{reader.GetString(4)}:{(reader.GetBoolean(6) ? "D" : "A")}");
        }
    }
    var indexes = indexParts.Select(entry =>
        $"{entry.Key}|unique:{(entry.Value.Unique ? 1 : 0)}|filter:{NormalizeOptionalSqlExpression(entry.Value.Filter)}|" +
        $"type:{entry.Value.IndexType}|space:{entry.Value.DataSpace}|" +
        $"disabled:{(entry.Value.Disabled ? 1 : 0)}|hypothetical:{(entry.Value.Hypothetical ? 1 : 0)}|" +
        $"fill:{entry.Value.FillFactor}|padded:{(entry.Value.Padded ? 1 : 0)}|" +
        $"ignoredup:{(entry.Value.IgnoreDuplicateKey ? 1 : 0)}|rowlocks:{(entry.Value.AllowRowLocks ? 1 : 0)}|" +
        $"pagelocks:{(entry.Value.AllowPageLocks ? 1 : 0)}|seq:{(entry.Value.OptimizeForSequentialKey ? 1 : 0)}|" +
        $"statsnorecompute:{(entry.Value.StatisticsNoRecompute ? 1 : 0)}|" +
        $"{string.Join(',', entry.Value.Keys.Select(value => $"K:{value}").Concat(entry.Value.Includes.Order(StringComparer.Ordinal).Select(name => $"I:{name}")))}")
        .ToArray();

    var catalogSurface = await ReadUnexpectedDatabaseSurfaceTelemetryAsync(connection);
    int supplementalUnexpectedSurfaceCount;
    await using (var command = connection.CreateCommand())
    {
        command.CommandTimeout = 60;
        command.CommandText = """
            SELECT
              (
                  (SELECT COUNT(*)
                   FROM sys.schemas AS schemas
                   LEFT JOIN sys.database_principals AS principals
                     ON principals.principal_id = schemas.principal_id
                   WHERE schemas.name NOT IN
                         (
                             N'dbo', N'guest', N'sys', N'INFORMATION_SCHEMA',
                             N'db_owner', N'db_accessadmin', N'db_securityadmin', N'db_ddladmin',
                             N'db_backupoperator', N'db_datareader', N'db_datawriter',
                             N'db_denydatareader', N'db_denydatawriter'
                         )
                      OR principals.name IS NULL
                      OR principals.name <> schemas.name) +
                  (SELECT COUNT(*)
                   FROM sys.partitions AS partitions
                   INNER JOIN sys.indexes AS indexes
                     ON indexes.object_id = partitions.object_id
                    AND indexes.index_id = partitions.index_id
                   INNER JOIN sys.tables AS tables ON tables.object_id = indexes.object_id
                   LEFT JOIN sys.data_spaces AS data_spaces
                     ON data_spaces.data_space_id = indexes.data_space_id
                   WHERE tables.is_ms_shipped = 0
                     AND
                     (
                         partitions.partition_number <> 1
                         OR partitions.data_compression_desc <> N'NONE'
                         OR indexes.type_desc NOT IN (N'HEAP', N'CLUSTERED', N'NONCLUSTERED')
                         OR data_spaces.name IS NULL
                         OR data_spaces.name <> N'PRIMARY'
                     )) +
                  (SELECT COUNT(*)
                   FROM sys.databases
                   WHERE name = DB_NAME()
                     AND
                     (
                         state_desc <> N'ONLINE'
                         OR user_access_desc <> N'MULTI_USER'
                         OR is_read_only <> 0
                         OR is_auto_close_on <> 0
                         OR is_auto_shrink_on <> 0
                         OR is_in_standby <> 0
                         OR source_database_id IS NOT NULL
                         OR containment_desc <> N'NONE'
                         OR is_trustworthy_on <> 0
                         OR is_db_chaining_on <> 0
                         OR collation_name <> N'SQL_Latin1_General_CP1_CI_AS'
                         OR catalog_collation_type_desc <> N'SQL_Latin1_General_CP1_CI_AS'
                     )) +
                  (SELECT CASE
                       WHEN COUNT(*) = 1
                        AND MAX(CASE WHEN databases.owner_sid = dbo_principal.sid THEN 1 ELSE 0 END) = 1
                       THEN 0 ELSE 1 END
                   FROM sys.databases AS databases
                   LEFT JOIN sys.database_principals AS dbo_principal
                     ON dbo_principal.name = N'dbo'
                   WHERE databases.name = DB_NAME())
              );
            """;
        supplementalUnexpectedSurfaceCount = Convert.ToInt32(await command.ExecuteScalarAsync());
    }
    var unexpectedSurfaceCount = checked(
        catalogSurface.TotalCount + supplementalUnexpectedSurfaceCount);

    return new ExactDatabaseSchemaSnapshot(
        tables.Distinct(StringComparer.Ordinal).ToArray(),
        columns.ToArray(),
        primaryKeys,
        uniqueConstraints,
        foreignKeys,
        checkConstraints,
        indexes,
        unexpectedSurfaceCount);
}

static IReadOnlyCollection<string> GetExpectedIncludedIndexColumns(ITableIndex index)
{
    var storeObject = StoreObjectIdentifier.Table(index.Table.Name, index.Table.Schema);
    var included = new HashSet<string>(StringComparer.Ordinal);
    foreach (var mappedIndex in index.MappedIndexes)
    {
        var propertyNames = mappedIndex.FindAnnotation("SqlServer:Include")?.Value as IEnumerable<string> ?? [];
        foreach (var propertyName in propertyNames)
        {
            var property = mappedIndex.DeclaringEntityType.FindProperty(propertyName) ??
                throw new InvalidOperationException("The EF included-index property mapping was absent.");
            var columnName = property.GetColumnName(storeObject) ??
                throw new InvalidOperationException("The EF included-index column mapping was absent.");
            included.Add(columnName);
        }
    }
    return included;
}

static bool GetExpectedConstraintClustered(IUniqueConstraint constraint) =>
    GetExpectedClusteredAnnotation(
        constraint.MappedKeys.Cast<IReadOnlyAnnotatable>(),
        constraint.GetIsPrimaryKey());

static bool GetExpectedIndexClustered(ITableIndex index) =>
    GetExpectedClusteredAnnotation(index.MappedIndexes.Cast<IReadOnlyAnnotatable>(), defaultValue: false);

static bool GetExpectedClusteredAnnotation(
    IEnumerable<IReadOnlyAnnotatable> mappedObjects,
    bool defaultValue)
{
    var values = mappedObjects
        .Select(mapped => mapped.FindAnnotation("SqlServer:Clustered")?.Value)
        .Where(value => value is not null)
        .Select(value => value is bool boolean
            ? boolean
            : throw new InvalidOperationException("The EF relational model returned malformed clustered-index metadata."))
        .Distinct()
        .ToArray();
    if (values.Length > 1)
        throw new InvalidOperationException("The EF relational model returned conflicting clustered-index metadata.");
    return values.SingleOrDefault(defaultValue);
}

static bool IsLargeObjectStoreType(string storeType)
{
    var normalized = NormalizeStoreType(storeType);
    return normalized is "nvarchar(max)" or "varchar(max)" or "varbinary(max)" or
        "text" or "ntext" or "image" or "xml" or "geometry" or "geography";
}

static bool SupportsCollation(string storeType) =>
    storeType.StartsWith("char(", StringComparison.Ordinal) ||
    storeType.StartsWith("varchar(", StringComparison.Ordinal) ||
    storeType.StartsWith("nchar(", StringComparison.Ordinal) ||
    storeType.StartsWith("nvarchar(", StringComparison.Ordinal) ||
    storeType is "text" or "ntext";

static string CanonicalizeMetadataValue(string? value) =>
    string.IsNullOrEmpty(value)
        ? "-"
        : Convert.ToBase64String(Encoding.UTF8.GetBytes(value));

static string GetExpectedDefaultContract(IColumn column)
{
    if (!string.IsNullOrWhiteSpace(column.DefaultValueSql))
        return CanonicalizeDefaultExpression(column.DefaultValueSql, NormalizeStoreType(column.StoreType));
    if (!column.TryGetDefaultValue(out var defaultValue))
        return "-";
    if (defaultValue is null || defaultValue == DBNull.Value)
        return "null";
    var literal = column.StoreTypeMapping.GenerateSqlLiteral(defaultValue);
    return CanonicalizeDefaultExpression(literal, NormalizeStoreType(column.StoreType));
}

static string CanonicalizeDefaultExpression(string expression, string storeType)
{
    var normalized = NormalizeSqlExpression(expression);
    if (storeType == "bit")
    {
        var bit = Regex.Match(
            normalized,
            @"^(?:convert\(bit,\(?)?([01])\)?\)?$|^cast\(([01])asbit\)$",
            RegexOptions.CultureInvariant);
        if (bit.Success)
        {
            var value = bit.Groups[1].Success ? bit.Groups[1].Value : bit.Groups[2].Value;
            return $"literal:bit:{value}";
        }
    }

    var stringLiteral = Regex.Match(normalized, @"^n?'((?:''|[^'])*)'$", RegexOptions.CultureInvariant);
    if (stringLiteral.Success)
    {
        var value = stringLiteral.Groups[1].Value.Replace("''", "'", StringComparison.Ordinal);
        return $"literal:string:{Convert.ToBase64String(Encoding.UTF8.GetBytes(value))}";
    }

    if (Regex.IsMatch(normalized, @"^[+-]?[0-9]+(?:\.[0-9]+)?$", RegexOptions.CultureInvariant))
        return $"literal:number:{NormalizeNumericMetadata(normalized)}";

    return $"sql:{normalized}";
}

static string NormalizeNumericMetadata(string value)
{
    if (!decimal.TryParse(value, NumberStyles.Number, CultureInfo.InvariantCulture, out var parsed))
        throw new InvalidOperationException("Azure SQL returned malformed numeric schema metadata.");
    return parsed.ToString("0.############################", CultureInfo.InvariantCulture);
}

static string NormalizeOptionalSqlExpression(string? expression) =>
    string.IsNullOrWhiteSpace(expression) ? "-" : NormalizeSqlExpression(expression);

static string NormalizeSqlExpression(string expression)
{
    if (string.IsNullOrWhiteSpace(expression))
        throw new InvalidOperationException("A required relational SQL expression was empty.");

    var builder = new StringBuilder(expression.Length);
    var inString = false;
    for (var index = 0; index < expression.Length; index++)
    {
        var character = expression[index];
        if (character == '\'' && inString && index + 1 < expression.Length && expression[index + 1] == '\'')
        {
            builder.Append("''");
            index++;
            continue;
        }
        if (character == '\'')
        {
            inString = !inString;
            builder.Append(character);
            continue;
        }
        if (!inString && char.IsWhiteSpace(character))
            continue;
        if (!inString && character is '[' or ']')
            continue;
        builder.Append(inString ? character : char.ToLowerInvariant(character));
    }
    if (inString)
        throw new InvalidOperationException("A relational SQL expression contained an unterminated string literal.");

    var normalized = builder.ToString();
    while (HasOneBalancedOuterParenthesisPair(normalized))
        normalized = normalized[1..^1];
    string previous;
    do
    {
        previous = normalized;
        normalized = Regex.Replace(
            normalized,
            @"\(([+-]?[0-9]+(?:\.[0-9]+)?)\)",
            "$1",
            RegexOptions.CultureInvariant);
    }
    while (!normalized.Equals(previous, StringComparison.Ordinal));
    return normalized;
}

static bool HasOneBalancedOuterParenthesisPair(string value)
{
    if (value.Length < 2 || value[0] != '(' || value[^1] != ')')
        return false;
    var depth = 0;
    var inString = false;
    for (var index = 0; index < value.Length; index++)
    {
        var character = value[index];
        if (character == '\'' && inString && index + 1 < value.Length && value[index + 1] == '\'')
        {
            index++;
            continue;
        }
        if (character == '\'')
        {
            inString = !inString;
            continue;
        }
        if (inString)
            continue;
        if (character == '(')
            depth++;
        else if (character == ')' && --depth == 0 && index != value.Length - 1)
            return false;
        if (depth < 0)
            return false;
    }
    return depth == 0 && !inString;
}

static string NormalizeReferentialAction(ReferentialAction action) => action switch
{
    ReferentialAction.NoAction => "NO_ACTION",
    ReferentialAction.Cascade => "CASCADE",
    ReferentialAction.SetNull => "SET_NULL",
    ReferentialAction.SetDefault => "SET_DEFAULT",
    ReferentialAction.Restrict => "NO_ACTION",
    _ => throw new InvalidOperationException("The EF relational model returned an unsupported delete action.")
};

static string GetActualStoreType(string typeName, short maxLength, byte precision, byte scale)
{
    var lower = typeName.ToLowerInvariant();
    var value = lower switch
    {
        "nvarchar" or "nchar" => $"{lower}({(maxLength == -1 ? "max" : (maxLength / 2).ToString())})",
        "varchar" or "char" or "varbinary" or "binary" => $"{lower}({(maxLength == -1 ? "max" : maxLength.ToString())})",
        "decimal" or "numeric" => $"{lower}({precision},{scale})",
        "datetime2" or "datetimeoffset" or "time" => $"{lower}({scale})",
        "timestamp" => "rowversion",
        _ => lower
    };
    return NormalizeStoreType(value);
}

static string NormalizeStoreType(string storeType)
{
    var normalized = storeType.Replace(" ", string.Empty, StringComparison.Ordinal).ToLowerInvariant();
    return Regex.Replace(normalized, @"^(datetime2|datetimeoffset|time)\(7\)$", "$1", RegexOptions.CultureInvariant);
}

static async Task<RuntimePrincipalEvidence> EnsureRuntimePrincipalAsync(
    SqlConnection connection,
    string principalName,
    Guid principalClientId,
    bool requireViewDefinition)
{
    var principal = await ReadRuntimePrincipalAsync(connection, principalName);
    if (principal is not null &&
        (principal.ClientId != principalClientId || !principal.Type.Equals("E", StringComparison.Ordinal)))
    {
        throw new InvalidOperationException(
            $"Database principal {principalName} exists but is not the exact reviewed Microsoft Entra service principal.");
    }

    var expectedRoles = new[] { "db_datareader", "db_datawriter" };
    if (principal is null)
    {
        var escapedName = principalName.Replace("]", "]]", StringComparison.Ordinal);
        await using var create = connection.CreateCommand();
        create.CommandTimeout = 120;
        create.CommandText = $"""
            DECLARE @clientId uniqueidentifier = '{principalClientId:D}';
            DECLARE @sid nvarchar(34) =
                CONVERT(varchar(34), CONVERT(varbinary(16), @clientId), 1);
            EXEC(N'CREATE USER [{escapedName}] WITH SID = ' + @sid + N', TYPE = E;');
            """;
        await create.ExecuteNonQueryAsync();
        principal = await ReadRuntimePrincipalAsync(connection, principalName);
        if (principal is null || principal.ClientId != principalClientId ||
            !principal.Type.Equals("E", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"Database principal {principalName} was not observed with its exact Entra SID and type after creation.");
        }
    }

    var escapedPrincipalName = principalName.Replace("]", "]]", StringComparison.Ordinal);
    if (requireViewDefinition)
    {
        await using var grantMetadata = connection.CreateCommand();
        grantMetadata.CommandTimeout = 60;
        grantMetadata.CommandText = $"GRANT VIEW DEFINITION TO [{escapedPrincipalName}];";
        await grantMetadata.ExecuteNonQueryAsync();
    }

    var observedBefore = await ReadAndAssertRuntimePrincipalAuthorityAsync(
        connection,
        principal,
        expectedRoles,
        expectedDirectPermissions: requireViewDefinition
            ? ["G|0|0|0|CONNECT|dbo", "G|0|0|0|VIEW DEFINITION|dbo"]
            : ["G|0|0|0|CONNECT|dbo"],
        requireCompleteRoleSet: false);
    foreach (var roleName in expectedRoles.Except(observedBefore, StringComparer.Ordinal))
    {
        await using var grant = connection.CreateCommand();
        grant.CommandTimeout = 60;
        grant.CommandText = $"ALTER ROLE [{roleName}] ADD MEMBER [{escapedPrincipalName}];";
        await grant.ExecuteNonQueryAsync();
    }

    var observedRoles = await ReadAndAssertRuntimePrincipalAuthorityAsync(
        connection,
        principal,
        expectedRoles,
        expectedDirectPermissions: requireViewDefinition
            ? ["G|0|0|0|CONNECT|dbo", "G|0|0|0|VIEW DEFINITION|dbo"]
            : ["G|0|0|0|CONNECT|dbo"],
        requireCompleteRoleSet: true);
    return new RuntimePrincipalEvidence(
        principalName,
        principalClientId,
        observedRoles,
        // The receipt records only explicit grants emitted by this migrator. The exact
        // CREATE USER CONNECT tuple is independently required by the catalog guard above.
        requireViewDefinition ? ["VIEW DEFINITION"] : []);
}

static async Task<RuntimePrincipalSnapshot?> ReadRuntimePrincipalAsync(
    SqlConnection connection,
    string principalName)
{
    await using var lookup = connection.CreateCommand();
    lookup.CommandTimeout = 60;
    lookup.CommandText = """
        SELECT principal_id, CAST(sid AS uniqueidentifier), type
        FROM sys.database_principals
        WHERE name = @principalName
        ORDER BY principal_id;
        """;
    lookup.Parameters.AddWithValue("@principalName", principalName);
    await using var reader = await lookup.ExecuteReaderAsync();
    var matches = new List<RuntimePrincipalSnapshot>();
    while (await reader.ReadAsync())
    {
        matches.Add(new RuntimePrincipalSnapshot(
            reader.GetInt32(0),
            reader.GetGuid(1),
            reader.GetString(2)));
    }
    if (matches.Count > 1)
        throw new InvalidOperationException("Azure SQL returned duplicate exact-name runtime principals.");
    return matches.Count == 1 ? matches[0] : null;
}

static async Task<IReadOnlyList<string>> ReadAndAssertRuntimePrincipalAuthorityAsync(
    SqlConnection connection,
    RuntimePrincipalSnapshot principal,
    IReadOnlyCollection<string> expectedRoles,
    IReadOnlyCollection<string> expectedDirectPermissions,
    bool requireCompleteRoleSet)
{
    var roles = new List<string>();
    await using (var membership = connection.CreateCommand())
    {
        membership.CommandTimeout = 60;
        membership.CommandText = """
            SELECT roles.name
            FROM sys.database_role_members AS memberships
            INNER JOIN sys.database_principals AS roles
                ON roles.principal_id = memberships.role_principal_id
            WHERE memberships.member_principal_id = @principalId
            ORDER BY roles.name;
            """;
        membership.Parameters.AddWithValue("@principalId", principal.PrincipalId);
        await using var reader = await membership.ExecuteReaderAsync();
        while (await reader.ReadAsync())
            roles.Add(reader.GetString(0));
    }

    var directPermissions = new List<string>();
    await using (var permissions = connection.CreateCommand())
    {
        permissions.CommandTimeout = 60;
        permissions.CommandText = """
            SELECT permissions.state, CAST(permissions.class AS int), permissions.major_id,
                   permissions.minor_id, permissions.permission_name, grantors.name
            FROM sys.database_permissions AS permissions
            INNER JOIN sys.database_principals AS grantors
              ON grantors.principal_id = permissions.grantor_principal_id
            WHERE permissions.grantee_principal_id = @principalId
            ORDER BY permissions.state, permissions.class, permissions.major_id,
                     permissions.minor_id, permissions.permission_name, grantors.name;
            """;
        permissions.Parameters.AddWithValue("@principalId", principal.PrincipalId);
        await using var reader = await permissions.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            directPermissions.Add(
                $"{reader.GetString(0)}|{reader.GetInt32(1)}|{reader.GetInt32(2)}|" +
                $"{reader.GetInt32(3)}|{reader.GetString(4)}|{reader.GetString(5)}");
        }
    }

    await using var authority = connection.CreateCommand();
    authority.CommandTimeout = 60;
    authority.CommandText = """
        SELECT
          (SELECT COUNT(*) FROM sys.schemas WHERE principal_id = @principalId),
          (SELECT COUNT(*) FROM sys.database_principals WHERE owning_principal_id = @principalId);
        """;
    authority.Parameters.AddWithValue("@principalId", principal.PrincipalId);
    await using var authorityReader = await authority.ExecuteReaderAsync();
    if (!await authorityReader.ReadAsync())
        throw new InvalidOperationException("Azure SQL returned no runtime-principal authority row.");
    var ownedSchemaCount = authorityReader.GetInt32(0);
    var ownedPrincipalCount = authorityReader.GetInt32(1);
    if (await authorityReader.ReadAsync())
        throw new InvalidOperationException("Azure SQL returned duplicate runtime-principal authority rows.");

    DatabaseBootstrapContract.AssertRuntimePrincipalAuthority(
        roles,
        expectedRoles,
        directPermissions,
        expectedDirectPermissions,
        ownedSchemaCount,
        ownedPrincipalCount,
        requireCompleteRoleSet);

    return roles;
}

static async Task<SchemaVerification> VerifyAsync(
    SqlConnection connection,
    bool currentEfModelReady,
    string currentSchemaFingerprint)
{
    const string sql = """
        SELECT
          CAST(CASE WHEN COL_LENGTH(N'dbo.AgentRegistrations', N'BlueprintSelectionMode') IS NOT NULL
                     AND COL_LENGTH(N'dbo.AgentRegistrations', N'AgentIdentityObjectId') IS NOT NULL
                     AND COL_LENGTH(N'dbo.AgentRegistrations', N'BlueprintObjectId') IS NOT NULL
                     AND COL_LENGTH(N'dbo.ProvisioningJobs', N'WorkflowVersion') IS NOT NULL
                     AND OBJECT_ID(N'dbo.AgentIngressCredentials', N'U') IS NOT NULL
                     AND OBJECT_ID(N'dbo.IngressRateLimitBuckets', N'U') IS NOT NULL
                     AND EXISTS
                     (
                         SELECT 1 FROM sys.indexes
                         WHERE object_id = OBJECT_ID(N'dbo.IdempotencyRecords', N'U')
                           AND name = N'IX_IdempotencyRecords_AgentRegistrationId_Endpoint_IdempotencyKey'
                           AND is_unique = 1
                           AND has_filter = 1
                     )
                    THEN 1 ELSE 0 END AS bit) AS WorkflowV2Ready,
          CAST
          (
              (
                  SELECT COUNT(*)
                  FROM sys.indexes AS indexes
                  WHERE indexes.object_id = OBJECT_ID(N'dbo.IdempotencyRecords', N'U')
                    AND indexes.is_unique = 1
                    AND indexes.is_primary_key = 0
                    AND 1 =
                    (
                        SELECT COUNT(*)
                        FROM sys.index_columns AS key_columns
                        WHERE key_columns.object_id = indexes.object_id
                          AND key_columns.index_id = indexes.index_id
                          AND key_columns.key_ordinal > 0
                    )
                    AND EXISTS
                    (
                        SELECT 1
                        FROM sys.index_columns AS key_columns
                        INNER JOIN sys.columns AS columns
                            ON columns.object_id = key_columns.object_id
                           AND columns.column_id = key_columns.column_id
                        WHERE key_columns.object_id = indexes.object_id
                          AND key_columns.index_id = indexes.index_id
                          AND key_columns.key_ordinal = 1
                          AND columns.name = N'IdempotencyKey'
                    )
              ) AS int
          ) AS LegacyGlobalIdempotencyUniqueIndexCount;
        """;

    await using var command = connection.CreateCommand();
    command.CommandTimeout = 60;
    command.CommandText = sql;
    await using var reader = await command.ExecuteReaderAsync();
    if (!await reader.ReadAsync())
        throw new InvalidOperationException("Database schema verification returned no result.");

    var workflowV2Ready = reader.GetBoolean(0);
    var legacyGlobalIndexCount = reader.GetInt32(1);
    await reader.DisposeAsync();

    var publishableOutboxMessageCount = -1;
    var activeWorkflowV2JobCount = -1;
    var activeWorkflowV3JobCount = -1;
    var awaitingAdministratorActionWorkflowV3JobCount = -1;
    var activeLegacyJobCount = -1;
    if (workflowV2Ready)
    {
        await using var stateCommand = connection.CreateCommand();
        stateCommand.CommandTimeout = 60;
        stateCommand.CommandText = """
            SELECT
              (SELECT COUNT(*)
               FROM dbo.OutboxMessages
               WHERE Status IN (N'Pending', N'Processing')) AS PublishableOutboxMessageCount,
              (SELECT COUNT(*)
               FROM dbo.ProvisioningJobs
               WHERE WorkflowVersion = 2
                 AND Status IN (N'Pending', N'Running', N'RequiresManualIntervention'))
                AS ActiveWorkflowV2JobCount,
              (SELECT COUNT(*)
               FROM dbo.ProvisioningJobs
               WHERE WorkflowVersion >= 3
                 AND Status IN
                 (
                     N'Pending',
                     N'Running',
                     N'AwaitingAdministratorAction',
                     N'RequiresManualIntervention'
                 )) AS ActiveWorkflowV3JobCount,
              (SELECT COUNT(*)
               FROM dbo.ProvisioningJobs
               WHERE WorkflowVersion >= 3
                 AND Status = N'AwaitingAdministratorAction')
                AS AwaitingAdministratorActionWorkflowV3JobCount,
              (SELECT COUNT(*)
               FROM dbo.ProvisioningJobs
               WHERE WorkflowVersion < 2
                 AND Status IN (N'Pending', N'Running', N'RequiresManualIntervention'))
                AS ActiveLegacyJobCount;
            """;
        await using var stateReader = await stateCommand.ExecuteReaderAsync();
        if (!await stateReader.ReadAsync())
            throw new InvalidOperationException("Database execution-state verification returned no result.");
        publishableOutboxMessageCount = stateReader.GetInt32(0);
        activeWorkflowV2JobCount = stateReader.GetInt32(1);
        activeWorkflowV3JobCount = stateReader.GetInt32(2);
        awaitingAdministratorActionWorkflowV3JobCount = stateReader.GetInt32(3);
        activeLegacyJobCount = stateReader.GetInt32(4);
    }

    return new SchemaVerification(
        currentEfModelReady,
        currentSchemaFingerprint,
        workflowV2Ready,
        legacyGlobalIndexCount,
        publishableOutboxMessageCount,
        activeWorkflowV2JobCount,
        activeWorkflowV3JobCount,
        awaitingAdministratorActionWorkflowV3JobCount,
        activeLegacyJobCount);
}

static Dictionary<string, string> ParseArguments(string[] arguments)
{
    var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    for (var index = 0; index < arguments.Length; index += 2)
    {
        if (index + 1 >= arguments.Length || !arguments[index].StartsWith("--", StringComparison.Ordinal))
            throw new ArgumentException("Arguments must be supplied as --name value pairs.");
        result[arguments[index][2..]] = arguments[index + 1];
    }
    return result;
}

static IEnumerable<string> SplitSqlBatches(string sql)
{
    return Regex
        .Split(sql, @"^\s*GO\s*(?:--.*)?$", RegexOptions.Multiline | RegexOptions.IgnoreCase)
        .Where(batch => !string.IsNullOrWhiteSpace(batch));
}

static string[] GetPrepareScriptNames() =>
[
    "20260824_agent_identity_workflow_v2.sql",
    "20260825_agent_ingress_credentials.sql",
    "20260825_scoped_idempotency.sql",
    "20260825_ingress_rate_limit_buckets.sql",
    "20260829_purview_policy_profiles.sql",
    "20260829_prompt_protection.sql"
];

static string Required(IReadOnlyDictionary<string, string> options, string key) =>
    ReadOption(options, key) is { Length: > 0 } value
        ? value
        : throw new ArgumentException($"--{key} is required.");

static string? ReadOption(IReadOnlyDictionary<string, string> options, string key)
{
    if (options.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
        return value;

    var environmentName = GetOptionEnvironmentName(key);
    return Environment.GetEnvironmentVariable(environmentName);
}

static string? ReadOptionWithExactEnvironmentAgreement(
    IReadOnlyDictionary<string, string> options,
    string key)
{
    var environmentName = GetOptionEnvironmentName(key);
    var hasCommandLineValue = options.TryGetValue(key, out var commandLineValue);
    var environmentValue = Environment.GetEnvironmentVariable(environmentName);
    if (hasCommandLineValue && !string.IsNullOrWhiteSpace(environmentValue) &&
        !string.Equals(commandLineValue, environmentValue, StringComparison.Ordinal))
    {
        throw new ArgumentException(
            $"--{key} and {environmentName} must match exactly when both are supplied.");
    }

    if (hasCommandLineValue && !string.IsNullOrWhiteSpace(commandLineValue))
        return commandLineValue;
    return environmentValue;
}

static string GetOptionEnvironmentName(string key) =>
    "DATABASE_MIGRATOR_" + key
        .Replace('-', '_')
        .ToUpperInvariant();

static ExpectedDatabasePrincipal ParseExpectedDatabasePrincipal(
    string name,
    string clientIdValue,
    string category,
    int expectedDirectPermissionCount)
{
    if (!Regex.IsMatch(name, @"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", RegexOptions.CultureInvariant))
        throw new ArgumentException($"The expected {category} database principal name is invalid.");
    if (!Guid.TryParseExact(clientIdValue, "D", out var clientId) ||
        clientId == Guid.Empty ||
        !clientIdValue.Equals(clientId.ToString("D"), StringComparison.Ordinal))
    {
        throw new ArgumentException(
            $"The expected {category} database principal client ID must be a canonical lowercase non-empty GUID.");
    }
    if (expectedDirectPermissionCount is < 1 or > 2)
        throw new ArgumentOutOfRangeException(nameof(expectedDirectPermissionCount));
    return new ExpectedDatabasePrincipal(name, clientId, expectedDirectPermissionCount);
}

static string ResolveRepositoryRoot(string? explicitRoot)
{
    var current = new DirectoryInfo(
        string.IsNullOrWhiteSpace(explicitRoot) ? Directory.GetCurrentDirectory() : explicitRoot);
    while (current is not null)
    {
        if (Directory.Exists(Path.Combine(current.FullName, "infrastructure", "sql")))
            return current.FullName;
        current = current.Parent;
    }
    throw new DirectoryNotFoundException("Could not resolve the repository root containing infrastructure/sql.");
}

internal sealed record ScriptEvidence(string Name, string Sha256, string Sql);
internal sealed record MigrationScriptEvidence(string Name, string Sha256);
internal sealed record SchemaVerification(
    bool CurrentEfModelReady,
    string CurrentSchemaFingerprint,
    bool WorkflowV2Ready,
    int LegacyGlobalIdempotencyUniqueIndexCount,
    int PublishableOutboxMessageCount,
    int ActiveWorkflowV2JobCount,
    int ActiveWorkflowV3JobCount,
    int AwaitingAdministratorActionWorkflowV3JobCount,
    int ActiveLegacyJobCount);
internal sealed record MigrationEvidence(
    DateTimeOffset VerifiedAtUtc,
    string Server,
    string Database,
    string Phase,
    int Repeat,
    IReadOnlyList<MigrationScriptEvidence> Scripts,
    SchemaVerification Verification,
    RuntimePrincipalEvidence? RuntimePrincipal,
    InitializationIntentEvidence? InitializationIntent,
    string? ExecutionIntentId);
internal sealed record RuntimePrincipalEvidence(
    string Name,
    Guid ClientId,
    IReadOnlyList<string> DatabaseRoles,
    IReadOnlyList<string> DirectPermissions);
internal sealed record RuntimePrincipalSnapshot(
    int PrincipalId,
    Guid ClientId,
    string Type);
internal sealed record MutableObservedPrincipal(
    int PrincipalId,
    string Name,
    Guid? ClientId,
    string Type,
    int DirectPermissionCount,
    int OwnedSchemaCount,
    int OwnedPrincipalCount,
    List<string> Roles);
internal sealed record KeyConstraintParts(
    string Type,
    string IndexType,
    string DataSpace,
    bool Disabled,
    bool Hypothetical,
    byte FillFactor,
    bool Padded,
    bool IgnoreDuplicateKey,
    bool AllowRowLocks,
    bool AllowPageLocks,
    bool OptimizeForSequentialKey,
    bool StatisticsNoRecompute,
    List<string> Columns);
internal sealed record IndexParts(
    bool Unique,
    string? Filter,
    string IndexType,
    string DataSpace,
    bool Disabled,
    bool Hypothetical,
    byte FillFactor,
    bool Padded,
    bool IgnoreDuplicateKey,
    bool AllowRowLocks,
    bool AllowPageLocks,
    bool OptimizeForSequentialKey,
    bool StatisticsNoRecompute,
    List<string> Keys,
    List<string> Includes);
internal sealed record DatabaseInitializationIntent(
    int SchemaVersion,
    string DeploymentOwnershipId,
    string AcceptedSourceFingerprint,
    string Server,
    string Database,
    string DatabaseCollation,
    string CatalogCollation,
    string DatabaseOwnerSidSha256);
internal sealed record DatabaseIdentityBinding(
    string Collation,
    string CatalogCollation,
    string OwnerSidSha256);
internal sealed record InitializationIntentEvidence(
    string MarkerName,
    int SchemaVersion,
    string DeploymentOwnershipId,
    string AcceptedSourceFingerprint,
    string Server,
    string Database,
    string DatabaseCollation,
    string CatalogCollation,
    string DatabaseOwnerSidSha256,
    string RecoveryMode,
    bool ExactReadbackVerified);

internal sealed class AzureSqlPristinePlatformDiagnostic
{
    private static readonly string[] FixedSqlFieldNames =
    [
        "auditSpecificationsTotal",
        "auditSpecificationsServerNameMatches",
        "auditSpecificationsDatabaseNameMatches",
        "auditSpecificationsOtherName",
        "auditSpecificationsEnabled",
        "auditSpecificationsDisabled",
        "auditSpecificationsNullGuid",
        "auditSpecificationsNonNullGuid",
        "auditDetailsTotal",
        "auditDetailsBatchCompleted",
        "auditDetailsSuccessfulAuthentication",
        "auditDetailsFailedAuthentication",
        "auditDetailsOtherAction",
        "auditDetailsGroup",
        "auditDetailsNonGroup",
        "auditDetailsDatabaseAddress",
        "auditDetailsOtherAddress",
        "auditDetailsZeroPrincipal",
        "auditDetailsPublicPrincipal",
        "auditDetailsOtherPrincipal",
        "databaseFirewallRulesExactObject",
        "databaseFirewallRulesPublicSelect",
        "databaseFirewallRulesGrantorDbo",
        "databaseFirewallRulesGrantorSys",
        "databaseFirewallRulesGrantorPublic",
        "databaseFirewallRulesGrantorGuest",
        "databaseFirewallRulesGrantorOther",
        "otherPositivePublicSelect",
        "dboConnectExact"
    ];

    private AzureSqlPristinePlatformDiagnostic(IReadOnlyList<int> counts) => Counts = counts;

    public static IReadOnlyList<string> SqlFieldNames => Array.AsReadOnly(FixedSqlFieldNames);

    public IReadOnlyList<int> Counts { get; }

    public static AzureSqlPristinePlatformDiagnostic FromOrderedCounts(IReadOnlyList<int> counts)
    {
        ArgumentNullException.ThrowIfNull(counts);
        if (counts.Count != FixedSqlFieldNames.Length)
        {
            throw new InvalidOperationException(
                $"Azure SQL returned {counts.Count} pristine-platform counters; exactly {FixedSqlFieldNames.Length} are required.");
        }
        if (counts.Any(count => count < 0))
            throw new InvalidOperationException("Azure SQL returned a negative pristine-platform counter.");
        return new AzureSqlPristinePlatformDiagnostic(Array.AsReadOnly(counts.ToArray()));
    }

    public string ToSafeSummary() =>
        string.Join(',', FixedSqlFieldNames.Select((name, index) => $"{name}={Counts[index]}"));
}

namespace Gateway.DatabaseMigrator
{
    public static class DatabaseBootstrapEvidenceChunkProtocol
    {
        public const int MaximumChunkLength = 6000;
        public const int MaximumChunkCount = 128;
        public const string Marker = "A365GW_DB_EVIDENCE";

        public static IReadOnlyList<string> Encode(string evidenceJson, Guid executionIntentId)
        {
            ArgumentException.ThrowIfNullOrEmpty(evidenceJson);
            if (executionIntentId == Guid.Empty)
                throw new ArgumentException("The evidence execution-intent ID must be non-empty.", nameof(executionIntentId));

            var jsonBytes = Encoding.UTF8.GetBytes(evidenceJson);
            var encodedEvidence = Convert.ToBase64String(jsonBytes);
            var chunkCount = checked(
                (encodedEvidence.Length + MaximumChunkLength - 1) / MaximumChunkLength);
            if (chunkCount is < 1 or > MaximumChunkCount)
            {
                throw new InvalidOperationException(
                    $"Bootstrap evidence exceeds the exact {MaximumChunkCount}-chunk durable-log boundary.");
            }

            var fingerprint =
                $"sha256:{Convert.ToHexString(SHA256.HashData(jsonBytes)).ToLowerInvariant()}";
            var canonicalIntentId = executionIntentId.ToString("D");
            var lines = new string[chunkCount];
            for (var index = 0; index < chunkCount; index++)
            {
                var offset = index * MaximumChunkLength;
                var length = Math.Min(MaximumChunkLength, encodedEvidence.Length - offset);
                var chunk = encodedEvidence.Substring(offset, length);
                lines[index] =
                    $"{Marker}|{canonicalIntentId}|{index + 1}|{chunkCount}|{fingerprint}|{chunk}";
            }
            return lines;
        }
    }
}
