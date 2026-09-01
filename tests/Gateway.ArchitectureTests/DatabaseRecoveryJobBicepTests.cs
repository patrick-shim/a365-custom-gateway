using FluentAssertions;
using System.Text.RegularExpressions;

namespace Gateway.ArchitectureTests;

/// <summary>
/// Guards the distinct one-time database recovery job. Compilation is covered by
/// the Bicep source gate; these tests protect its identity, provenance, and
/// non-replay contracts.
/// </summary>
public class DatabaseRecoveryJobBicepTests
{
    private static readonly string RepositoryRoot = FindRepositoryRoot();

    [Fact]
    public void RecoveryJob_ShouldBeDistinctManualAndRetryDisabled()
    {
        var source = ReadRecoveryJobSource();

        source.Should().Contain("var recoveryAttemptSuffix = recoveryAttemptNumber == 1 ? '' : '2'");
        source.Should().Contain("var recoveryJobStem = recoveryAttemptNumber == 1 ? 'db-recover' : 'db-recov2'");
        source.Should().Contain("var jobName = 'job-${projectName}-${recoveryJobStem}-${environment}'");
        source.Should().Contain("resource databaseRecoveryJob 'Microsoft.App/jobs@2025-01-01'");
        source.Should().Contain("triggerType: 'Manual'");
        source.Should().Contain("replicaRetryLimit: 0");
        source.Should().Contain("param replicaTimeoutSeconds int = 1800");
        source.Should().Contain("parallelism: 1");
        source.Should().Contain("replicaCompletionCount: 1");
        source.Should().NotContain("db-init-${environment}");
        source.Should().NotContain("scheduleTriggerConfig:");
        source.Should().NotContain("eventTriggerConfig:");
        source.Should().NotContain("cronExpression:");
        source.Should().Contain("param recoveryAttemptNumber int = 1");
        source.Should().Contain("param originalFailedDatabaseBoundaryFingerprint string");
        source.Should().Contain("param priorFailedRecoveryBoundaryFingerprint string = ''");
    }

    [Fact]
    public void RecoveryJob_ShouldUseTransientSystemIdentityAndPullOnlyUamiWithoutSecrets()
    {
        var source = ReadRecoveryJobSource();

        source.Should().Contain("type: 'SystemAssigned,UserAssigned'");
        source.Should().Contain("'${imagePullIdentityResourceId}': {}");
        source.Should().Contain("identity: 'system'\n          lifecycle: 'Main'");
        source.Should().Contain("identity: imagePullIdentityResourceId\n          lifecycle: 'None'");
        Regex.Matches(source, "identity: imagePullIdentityResourceId", RegexOptions.CultureInvariant)
            .Count.Should().Be(2);
        source.Should().Contain("secrets: []");
        source.Should().Contain("probes: []");
        source.Should().NotContain("secretRef:");
        source.Should().NotContain("passwordSecretRef:");
        source.Should().NotContain("AZURE_CLIENT_ID");
        source.Should().NotContain("Authentication=Active Directory");
    }

    [Fact]
    public void RecoveryJob_ShouldKeepOriginalMarkerBindingSeparateFromRecoveryProvenance()
    {
        var source = ReadRecoveryJobSource();

        source.Should().Contain("'--accepted-source-fingerprint'\n            originalAcceptedSourceFingerprint");
        source.Should().Contain("name: 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID'\n              value: recoveryExecutionIntentId");
        Regex.Matches(source, "name: 'DATABASE_MIGRATOR_EXECUTION_INTENT_ID'", RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        source.Should().NotContain("DATABASE_MIGRATOR_RECOVERY_SOURCE_FINGERPRINT");
        source.Should().Contain("bootstrapSourceFingerprint: originalAcceptedSourceFingerprint");
        source.Should().Contain("recoverySourceFingerprint: recoverySourceFingerprint");
        source.Should().Contain("recoveryPlanFingerprint: recoveryPlanFingerprint");
        source.Should().Contain("recoveryAttempt: string(recoveryAttemptNumber)");
        source.Should().Contain("originalFailedDatabaseBoundaryFingerprint: originalFailedDatabaseBoundaryFingerprint");
        source.Should().Contain("priorFailedRecoveryBoundaryFingerprint: priorFailedRecoveryBoundaryFingerprint");
        Regex.Matches(source, "'--accepted-source-fingerprint'", RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        source.Should().NotContain("'--accepted-source-fingerprint'\n            recoverySourceFingerprint");
    }

    [Fact]
    public void RecoveryJob_ShouldPinCorrectedDigestAndReuseReviewedBootstrapArguments()
    {
        var source = ReadRecoveryJobSource();

        source.Should().Contain("var databaseRecoveryJobImage = '${acrLoginServer}/gateway-db-migrator@${databaseMigratorImageDigest}'");
        source.Should().Contain("image: databaseRecoveryJobImage");
        source.Should().NotContain(":latest");
        source.Should().Contain("'dotnet'\n            'Gateway.DatabaseMigrator.dll'");
        source.Should().Contain("'--phase'\n            'bootstrap'");
        source.Should().Contain(
            "'--required-recovery-mode'\n            'ResumeAfterSchemaCompleted'");
        Regex.Matches(source, "'--required-recovery-mode'", RegexOptions.CultureInvariant)
            .Count.Should().Be(1);
        source.Should().Contain("'--repeat'\n            '1'");
        source.Should().Contain("'--expected-private-endpoint-ip'\n            expectedPrivateEndpointIp");
        source.Should().Contain("'--deployment-ownership-id'\n            deploymentOwnershipId");
        source.Should().Contain("'--expected-api-principal-name'\n            apiDatabasePrincipalName");
        source.Should().Contain("'--expected-api-principal-client-id'\n            apiDatabasePrincipalClientId");
        source.Should().Contain("'--expected-worker-principal-name'\n            workerDatabasePrincipalName");
        source.Should().Contain("'--expected-worker-principal-client-id'\n            workerDatabasePrincipalClientId");
        source.Should().Contain("'--evidence-stdout'\n            'true'");
    }

    [Fact]
    public void RecoveryJob_ShouldExposeOnlySafeExactProvenanceOutputs()
    {
        var source = ReadRecoveryJobSource();

        source.Should().Contain("output databaseRecoveryJobId string = databaseRecoveryJob.id");
        source.Should().Contain("output databaseRecoveryJobName string = databaseRecoveryJob.name");
        source.Should().Contain("output databaseRecoveryJobPrincipalId string = databaseRecoveryJob.identity.principalId");
        source.Should().Contain("output databaseRecoveryJobImage string = databaseRecoveryJobImage");
        source.Should().Contain("output originalAcceptedSourceFingerprint string = originalAcceptedSourceFingerprint");
        source.Should().Contain("output recoverySourceFingerprint string = recoverySourceFingerprint");
        source.Should().Contain("output recoveryPlanFingerprint string = recoveryPlanFingerprint");
        source.Should().Contain("output recoveryExecutionIntentId string = recoveryExecutionIntentId");
        source.Should().Contain("output recoveryAttemptNumber int = recoveryAttemptNumber");
        source.Should().Contain("output originalFailedDatabaseBoundaryFingerprint string = originalFailedDatabaseBoundaryFingerprint");
        source.Should().Contain("output priorFailedRecoveryBoundaryFingerprint string = priorFailedRecoveryBoundaryFingerprint");
        source.Should().NotContain("output sql");
        source.Should().NotContain("output apiDatabasePrincipal");
        source.Should().NotContain("output workerDatabasePrincipal");
    }

    private static string ReadRecoveryJobSource() =>
        File.ReadAllText(Path.Combine(
            RepositoryRoot,
            "bootstrap",
            "infra",
            "database-migrator-recovery-job.bicep"))
            .Replace("\r\n", "\n", StringComparison.Ordinal);

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (Directory.Exists(Path.Combine(directory.FullName, "infrastructure")) &&
                Directory.Exists(Path.Combine(directory.FullName, "bootstrap")) &&
                Directory.Exists(Path.Combine(directory.FullName, "src")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        throw new DirectoryNotFoundException(
            "Could not resolve the repository root from the architecture test output directory.");
    }
}
