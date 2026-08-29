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
}
