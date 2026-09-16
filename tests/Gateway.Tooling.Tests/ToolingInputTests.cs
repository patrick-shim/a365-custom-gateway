using System.Net;
using System.Text;
using System.Text.Json;
using Gateway.DatabaseMigrator;
using Gateway.Infrastructure.Persistence;
using Microsoft.SqlServer.TransactSql.ScriptDom;

namespace Gateway.Tooling.Tests;

public sealed class ToolingInputTests
{
    [Fact]
    public void IncompleteCleanCopyCannotFallBackToAnAncestorCheckout()
    {
        var incompleteCopy = Path.Combine(ToolingFixture.Root, ".test-work", Guid.NewGuid().ToString("N"),
            "source", "tests", "Gateway.Tooling.Tests", "bin", "Release", "net10.0");
        var exception = Assert.Throws<InvalidOperationException>(() => ToolingFixture.FindRoot(incompleteCopy));
        Assert.Contains("falling back to another checkout is forbidden", exception.Message);
    }

    [Fact]
    public void EveryRegisteredSqlInputExistsAndParsesWithoutDatabaseAccess()
    {
        var names = ToolingFixture.CurrentScriptNames();
        Assert.Equal(13, names.Count);
        Assert.Equal(names.Count, names.Distinct(StringComparer.Ordinal).Count());
        DatabaseUpgradeMigrationAdmission.AssertRequiredScripts(names);
        foreach (var name in names.Append("20260825_scoped_idempotency_finalize.sql"))
        {
            var path = Path.Combine(ToolingFixture.Root, "infrastructure", "sql", name);
            using var source = File.OpenText(path);
            var parsed = new TSql160Parser(true).Parse(source, out var errors);
            Assert.NotNull(parsed);
            Assert.True(errors.Count == 0, name + ": " + string.Join("; ", errors.Select(error => error.Message)));
        }
    }

    [Fact]
    public void SqlLoaderChecksExactAuthoredBytesButSourceOnlyLoadsNothing()
    {
        var directory = Path.Combine(ToolingFixture.Root, "infrastructure", "sql");
        var manifest = ToolingFixture.Manifest(1) with
        {
            Scripts = DatabaseUpgradeMigrationAdmission.RequiredCurrentScripts.Select(name =>
                new DatabaseUpgradeScript(name, DatabaseUpgradeAttestation.Fingerprint(
                    File.ReadAllText(Path.Combine(directory, name))))).ToArray()
        };
        Assert.Equal(4, DatabaseUpgradeExecution.LoadScripts(manifest, directory).Count);
        Assert.Throws<ArgumentException>(() => DatabaseUpgradeExecution.LoadScripts(manifest with
        {
            Scripts = [manifest.Scripts[0] with { Sha256 = ToolingFixture.Hash('0') }]
        }, directory));
        Assert.Empty(DatabaseUpgradeExecution.LoadScripts(ToolingFixture.Manifest(),
            Path.Combine(ToolingFixture.Root, "tests", "Gateway.Tooling.Tests", "absent-sql-fixture")));
    }

    [Fact]
    public void CheckConstraintCanonicalizerPreservesSemantics()
    {
        Assert.Equal(SqlCheckConstraintCanonicalizer.Normalize("[Status] IN (N'Allowed', N'Blocked')"),
            SqlCheckConstraintCanonicalizer.Normalize("([Status]=N'Blocked' OR [Status]=N'Allowed')"));
        Assert.NotEqual(SqlCheckConstraintCanonicalizer.Normalize("[A] = 1 AND ([B] = 2 OR [C] = 3)"),
            SqlCheckConstraintCanonicalizer.Normalize("([A] = 1 AND [B] = 2) OR [C] = 3"));
        Assert.Throws<InvalidOperationException>(() => SqlCheckConstraintCanonicalizer.Normalize("[A] = 1; DROP TABLE dbo.Example"));
    }

    [Fact]
    public void RecoveryNeverAdoptsUnmarkedOrPartialState()
    {
        Assert.Equal(DatabaseInitializationRecoveryMode.Fresh,
            DatabaseBootstrapRecoveryContract.Classify(0, null, "exact-marker", false));
        Assert.Equal(DatabaseInitializationRecoveryMode.ResumeBeforeSchemaMutation,
            DatabaseBootstrapRecoveryContract.Classify(0, "exact-marker", "exact-marker", false));
        Assert.Equal(DatabaseInitializationRecoveryMode.ResumeAfterSchemaCompleted,
            DatabaseBootstrapRecoveryContract.Classify(5, "exact-marker", "exact-marker", true));
        Assert.Throws<InvalidOperationException>(() =>
            DatabaseBootstrapRecoveryContract.Classify(5, null, "exact-marker", true));
        Assert.Throws<InvalidOperationException>(() =>
            DatabaseBootstrapRecoveryContract.Classify(5, "different-marker", "exact-marker", true));
        Assert.Throws<InvalidOperationException>(() =>
            DatabaseBootstrapRecoveryContract.Classify(5, "exact-marker", "exact-marker", false));
    }

    [Theory]
    [InlineData("127.0.0.1")]
    [InlineData("8.8.8.8")]
    [InlineData("10.1.1")]
    [InlineData("10.01.0.1")]
    [InlineData("::1")]
    public void PrivateEndpointParserRejectsUnapprovedAddresses(string value) =>
        Assert.Throws<ArgumentException>(() => SqlPrivateEndpointDnsConvergence.ParseCanonicalPrivateIpv4(value));

    [Fact]
    public async Task DnsConvergenceUsesBoundedExactResolutionWithOfflineTransport()
    {
        var expected = SqlPrivateEndpointDnsConvergence.ParseCanonicalPrivateIpv4("10.20.0.4");
        var calls = 0;
        await SqlPrivateEndpointDnsConvergence.WaitForExactResolutionAsync("sql-fixture.database.windows.net",
            expected, (_, _) => Task.FromResult(++calls == 2 ? new[] { expected } : Array.Empty<IPAddress>()),
            (_, _) => Task.CompletedTask, 2, TimeSpan.FromSeconds(1));
        Assert.Equal(2, calls);
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            SqlPrivateEndpointDnsConvergence.WaitForExactResolutionAsync("sql-fixture.database.windows.net",
                expected, (_, _) => Task.FromResult(new[] { expected, IPAddress.Parse("10.20.0.5") }),
                (_, _) => Task.CompletedTask, 2, TimeSpan.FromSeconds(1)));
    }

    [Fact]
    public void BootstrapEvidenceRetainsExactChunkAndIntentBinding()
    {
        var json = JsonSerializer.Serialize(new { offlineFixture = new string('x', 10_000) });
        var intent = Guid.Parse(ToolingFixture.Ownership);
        var chunks = DatabaseBootstrapEvidenceChunkProtocol.Encode(json, intent);
        Assert.True(chunks.Count > 1);
        var payload = new StringBuilder();
        for (var index = 0; index < chunks.Count; index++)
        {
            var fields = chunks[index].Split('|');
            Assert.Equal(6, fields.Length);
            Assert.Equal(DatabaseBootstrapEvidenceChunkProtocol.Marker, fields[0]);
            Assert.Equal(intent.ToString("D"), fields[1]);
            Assert.Equal((index + 1).ToString(), fields[2]);
            Assert.Equal(chunks.Count.ToString(), fields[3]);
            Assert.Equal(DatabaseUpgradeAttestation.Fingerprint(json), fields[4]);
            Assert.True(fields[5].Length <= DatabaseBootstrapEvidenceChunkProtocol.MaximumChunkLength);
            payload.Append(fields[5]);
        }
        Assert.Equal(json, Encoding.UTF8.GetString(Convert.FromBase64String(payload.ToString())));
    }

    [Fact]
    public void DockerRestoreIncludesCurrentProjectReferenceClosureAndSafeDefaults()
    {
        var migrator = File.ReadAllText(Path.Combine(ToolingFixture.Root, "tools", "Gateway.DatabaseMigrator", "Dockerfile"));
        var beforeRestore = migrator[..migrator.IndexOf("RUN dotnet restore", StringComparison.Ordinal)];
        foreach (var project in new[] { "Gateway.Infrastructure", "Gateway.Application", "Gateway.Domain", "Gateway.Contracts" })
            Assert.Contains($"src/{project}/{project}.csproj", beforeRestore);
        foreach (var tool in new[] { "Gateway.DatabaseMigrator", "Gateway.LiveVerification" })
        {
            var dockerfile = File.ReadAllText(Path.Combine(ToolingFixture.Root, "tools", tool, "Dockerfile"));
            Assert.Contains("COPY [\"Directory.Build.props\"", dockerfile[..dockerfile.IndexOf("RUN dotnet restore", StringComparison.Ordinal)]);
            Assert.Contains("CMD [\"--help\"]", dockerfile);
        }
    }
}
