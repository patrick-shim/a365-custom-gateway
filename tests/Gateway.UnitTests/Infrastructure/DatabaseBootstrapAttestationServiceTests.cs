using System.Text.RegularExpressions;
using FluentAssertions;
using Gateway.Infrastructure.Persistence;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Gateway.UnitTests.Infrastructure;

public sealed class DatabaseBootstrapAttestationServiceTests
{
    [Fact]
    public async Task AttestAsync_CachesTheBoundedSuccessfulProbe()
    {
        var probe = new CountingProbe(true);
        using var cache = new MemoryCache(new MemoryCacheOptions());
        var service = new DatabaseBootstrapAttestationService(
            Options.Create(ValidOptions()),
            probe,
            cache,
            NullLogger<DatabaseBootstrapAttestationService>.Instance);

        (await service.AttestAsync()).Should().BeTrue();
        (await service.AttestAsync()).Should().BeTrue();

        probe.CallCount.Should().Be(1);
    }

    [Fact]
    public async Task AttestAsync_FailsClosedWithoutCallingSql_WhenDisabled()
    {
        var probe = new CountingProbe(true);
        using var cache = new MemoryCache(new MemoryCacheOptions());
        var service = new DatabaseBootstrapAttestationService(
            Options.Create(new DatabaseAttestationOptions()),
            probe,
            cache,
            NullLogger<DatabaseBootstrapAttestationService>.Instance);

        (await service.AttestAsync()).Should().BeFalse();

        probe.CallCount.Should().Be(0);
    }

    [Fact]
    public async Task AttestAsync_FailsClosedWhenTheProviderThrows()
    {
        var probe = new ThrowingProbe();
        using var cache = new MemoryCache(new MemoryCacheOptions());
        var service = new DatabaseBootstrapAttestationService(
            Options.Create(ValidOptions()),
            probe,
            cache,
            NullLogger<DatabaseBootstrapAttestationService>.Instance);

        (await service.AttestAsync()).Should().BeFalse();
    }

    [Fact]
    public void Probe_RequiresExactRuntimeConnectAndApiViewDefinitionPermissionTuples()
    {
        var source = ReadProbeSource();

        source.Should().Contain(
            "private const string ExpectedConnectPermission = \"G|0|0|0|CONNECT|dbo\";");
        source.Should().Contain(
            "private const string ExpectedApiDirectPermission = \"G|0|0|0|VIEW DEFINITION|dbo\";");
        source.Should().Contain(
            "[ExpectedConnectPermission, ExpectedApiDirectPermission]");
        source.Should().Contain("[ExpectedConnectPermission])");
        source.Should().Contain(
            "SELECT grantees.name, permissions.state, CAST(permissions.class AS int),");
        source.Should().NotContain(
            "SELECT grantees.name, permissions.state, permissions.class,");
        source.Should().Contain(
            "permissions.permission_name, grantors.name");
        source.Should().Contain(
            "if (!observed.TryGetValue(reader.GetString(0), out var principal))");
        source.Should().Contain(
            "principal.DirectPermissions.Order(StringComparer.Ordinal).SequenceEqual(");
        source.Should().MatchRegex(
            @"permissions\.class = 0\s+AND permissions\.major_id = 0\s+AND permissions\.minor_id = 0\s+AND permissions\.permission_name = N'CONNECT'\s+AND permissions\.state = N'G'\s+AND grantees\.name = N'dbo'\s+AND grantors\.name = N'dbo'");
    }

    [Fact]
    public void Probe_SkipsOnlyTheExactBuiltInRoleMembershipAndAzurePlatformPermissionRows()
    {
        var source = ReadProbeSource();
        var runtimeAuthorityBody = Regex.Match(
            source,
            @"private static async Task<bool> HasExactRuntimeAuthorityAsync\([\s\S]*?(?=\n    private sealed record DatabaseIdentity)",
            RegexOptions.CultureInvariant).Value;

        runtimeAuthorityBody.Should().NotBeEmpty();
        runtimeAuthorityBody.Should().Contain(
            "SELECT roles.name, members.name, roles.is_fixed_role,");
        runtimeAuthorityBody.Should().Contain(
            "members.principal_id, DATABASE_PRINCIPAL_ID(N'dbo')");
        runtimeAuthorityBody.Should().Contain(
            "reader.GetString(0).Equals(\"db_owner\", StringComparison.Ordinal)");
        runtimeAuthorityBody.Should().Contain(
            "reader.GetString(1).Equals(\"dbo\", StringComparison.Ordinal)");
        runtimeAuthorityBody.Should().Contain("reader.GetBoolean(2)");
        runtimeAuthorityBody.Should().Contain(
            "reader.GetInt32(3) == reader.GetInt32(4)");
        runtimeAuthorityBody.Should().Contain(
            "if (builtInDboOwnerMembershipCount != 1)");

        runtimeAuthorityBody.Should().MatchRegex(
            @"permissions\.class = 0\s+AND permissions\.major_id = 0\s+AND permissions\.minor_id = 0\s+AND permissions\.permission_name = N'CONNECT'\s+AND permissions\.state IN \(N'G', N'W'\)\s+AND grantees\.name IN \(N'public', N'guest'\)");
        runtimeAuthorityBody.Should().MatchRegex(
            @"permissions\.class = 0\s+AND permissions\.major_id = 0\s+AND permissions\.minor_id = 0\s+AND permissions\.permission_name = N'CONNECT'\s+AND permissions\.state = N'G'\s+AND grantees\.name = N'dbo'\s+AND grantors\.name = N'dbo'");
        runtimeAuthorityBody.Should().MatchRegex(
            @"permissions\.class = 1\s+AND permissions\.minor_id = 0\s+AND permissions\.permission_name = N'SELECT'\s+AND permissions\.state = N'G'\s+AND grantees\.name = N'public'\s+AND permissions\.major_id < 0");
        runtimeAuthorityBody.Should().MatchRegex(
            @"permissions\.class = 1\s+AND permissions\.minor_id = 0\s+AND permissions\.permission_name = N'SELECT'\s+AND permissions\.state = N'G'\s+AND grantees\.name = N'public'\s+AND permissions\.major_id = OBJECT_ID\(N'sys\.database_firewall_rules'\)\s+AND grantors\.name = N'sys'[\s\S]*allowed_shipped_objects\.is_ms_shipped = 1[\s\S]*allowed_shipped_objects\.schema_id = SCHEMA_ID\(N'sys'\)[\s\S]*allowed_shipped_objects\.type = N'V'");

        runtimeAuthorityBody.Should().Contain(
            "if (!observed.TryGetValue(reader.GetString(1), out var principal))");
        runtimeAuthorityBody.Should().Contain(
            "if (!observed.TryGetValue(reader.GetString(0), out var principal))");
    }

    private static DatabaseAttestationOptions ValidOptions() => new()
    {
        Enabled = true,
        DeploymentOwnershipId = "11111111-1111-1111-1111-111111111111",
        AcceptedSourceFingerprint = $"sha256:{new string('a', 64)}",
        ExpectedSchemaFingerprint = $"sha256:{new string('b', 64)}",
        SqlServerFqdn = "sql-gateway-dev.database.windows.net",
        DatabaseName = "GatewayDb",
        ApiPrincipalName = "ca-gateway-api-dev",
        ApiPrincipalClientId = "22222222-2222-2222-2222-222222222222",
        WorkerPrincipalName = "ca-gateway-worker-dev-v3",
        WorkerPrincipalClientId = "33333333-3333-3333-3333-333333333333"
    };

    private sealed class CountingProbe(bool result) : IDatabaseBootstrapAttestationProbe
    {
        public int CallCount { get; private set; }

        public Task<bool> AttestAsync(
            DatabaseAttestationOptions options,
            CancellationToken cancellationToken)
        {
            CallCount++;
            return Task.FromResult(result);
        }
    }

    private sealed class ThrowingProbe : IDatabaseBootstrapAttestationProbe
    {
        public Task<bool> AttestAsync(
            DatabaseAttestationOptions options,
            CancellationToken cancellationToken) =>
            throw new InvalidOperationException("provider detail that must be suppressed");
    }

    private static string ReadProbeSource() =>
        File.ReadAllText(Path.Combine(
            FindRepositoryRoot(),
            "src",
            "Gateway.Infrastructure",
            "Persistence",
            "DatabaseBootstrapAttestationService.cs"));

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
            "Could not resolve the repository root from the unit test output directory.");
    }
}
