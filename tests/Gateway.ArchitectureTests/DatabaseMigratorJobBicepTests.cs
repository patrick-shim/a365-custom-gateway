using FluentAssertions;
using System.Text.RegularExpressions;

namespace Gateway.ArchitectureTests;

/// <summary>
/// Guards the dormant private-network database bootstrap job. Bicep compilation
/// remains a separate source gate; these assertions protect the security-critical
/// identity, trigger, image, and argument contracts from accidental broadening.
/// </summary>
public class DatabaseMigratorJobBicepTests
{
    private static readonly string RepositoryRoot = FindRepositoryRoot();

    [Fact]
    public void DatabaseBootstrapJob_ShouldBeManualDormantAndSingleExecution()
    {
        var source = ReadJobSource();

        source.Should().Contain("resource databaseBootstrapJob 'Microsoft.App/jobs@2025-01-01'");
        source.Should().NotContain("Microsoft.App/jobs@2025-01-01-preview");
        source.Should().Contain("triggerType: 'Manual'");
        source.Should().Contain("replicaRetryLimit: 0");
        source.Should().Contain("parallelism: 1");
        source.Should().Contain("replicaCompletionCount: 1");
        source.Should().Contain("@minValue(300)");
        source.Should().Contain("@maxValue(3600)");
        source.Should().NotContain("scheduleTriggerConfig:");
        source.Should().NotContain("eventTriggerConfig:");
        source.Should().NotContain("cronExpression:");
        source.Should().NotContain("scale:");
    }

    [Fact]
    public void DatabaseBootstrapJob_ShouldUseSystemIdentityForSqlAndDedicatedUamiOnlyForAcrPull()
    {
        var source = ReadJobSource();

        source.Should().Contain("type: 'SystemAssigned,UserAssigned'");
        source.Should().Contain("'${imagePullIdentityResourceId}': {}");
        source.Should().Contain("identity: 'system'\n          lifecycle: 'Main'");
        source.Should().Contain(
            "identity: imagePullIdentityResourceId\n          lifecycle: 'None'");
        source.Should().Contain("identity: imagePullIdentityResourceId");
        Regex.Matches(source, "identity: imagePullIdentityResourceId", RegexOptions.CultureInvariant)
            .Count.Should().Be(2);
        source.Should().Contain("secrets: []");
        source.Should().Contain("env: []");
        source.Should().Contain("probes: []");
        source.Should().NotContain("initContainers:");
        source.Should().NotContain("volumes:");
        source.Should().NotContain("volumeMounts:");
        source.Should().NotContain("secretRef:");
        source.Should().NotContain("passwordSecretRef:");
        source.Should().NotContain("AZURE_CLIENT_ID");
        source.Should().NotContain("Authentication=Active Directory");
    }

    [Fact]
    public void DatabaseBootstrapJob_ShouldPinExactDeploymentAcrDigestAndBootstrapBindings()
    {
        var source = ReadJobSource();

        source.Should().Contain(
            "var databaseMigratorImage = '${acrLoginServer}/gateway-db-migrator@${databaseMigratorImageDigest}'");
        source.Should().MatchRegex(
            @"@minLength\(71\)\s+@maxLength\(71\)\s+param databaseMigratorImageDigest string");
        source.Should().Contain("image: databaseMigratorImage");
        source.Should().NotContain(":latest");
        source.Should().Contain("'--phase'\n            'bootstrap'");
        source.Should().Contain("'--repeat'\n            '1'");
        source.Should().Contain("'--database'\n            databaseName");
        source.Should().Contain("'--deployment-ownership-id'\n            deploymentOwnershipId");
        source.Should().Contain("'--accepted-source-fingerprint'\n            bootstrapSourceFingerprint");
        source.Should().Contain("'--expected-api-principal-name'\n            apiDatabasePrincipalName");
        source.Should().Contain("'--expected-api-principal-client-id'\n            apiDatabasePrincipalClientId");
        source.Should().Contain("'--expected-worker-principal-name'\n            workerDatabasePrincipalName");
        source.Should().Contain("'--expected-worker-principal-client-id'\n            workerDatabasePrincipalClientId");
        source.Should().Contain("'--evidence-stdout'\n            'true'");
    }

    [Fact]
    public void DatabaseBootstrapJob_ShouldExposeOnlySafeRecoveryOutputs()
    {
        var source = ReadJobSource();

        source.Should().Contain("output databaseBootstrapJobId string = databaseBootstrapJob.id");
        source.Should().Contain("output databaseBootstrapJobName string = databaseBootstrapJob.name");
        source.Should().Contain(
            "output databaseBootstrapJobSystemPrincipalId string = databaseBootstrapJob.identity.principalId");
        source.Should().Contain("output databaseMigratorImage string = databaseMigratorImage");
        source.Should().Contain("output deploymentOwnershipId string = deploymentOwnershipId");
        source.Should().Contain("output bootstrapSourceFingerprint string = bootstrapSourceFingerprint");
        source.Should().NotContain("output sql");
        source.Should().NotContain("output apiDatabasePrincipal");
        source.Should().NotContain("output workerDatabasePrincipal");
    }

    private static string ReadJobSource() =>
        File.ReadAllText(Path.Combine(
            RepositoryRoot,
            "bootstrap",
            "infra",
            "database-migrator-job.bicep"));

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
