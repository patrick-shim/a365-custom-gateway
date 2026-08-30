using System.Net;
using System.Net.Sockets;
using FluentAssertions;
using Gateway.DatabaseMigrator;

namespace Gateway.UnitTests.Infrastructure;

public sealed class SqlPrivateEndpointDnsConvergenceTests
{
    private static readonly IPAddress ExpectedAddress = IPAddress.Parse("10.42.2.4");

    [Fact]
    public void Defaults_ProvideAtLeastTenMinutesOfBoundedConvergenceTime()
    {
        SqlPrivateEndpointDnsConvergence.DefaultMaximumAttempts.Should().Be(121);
        SqlPrivateEndpointDnsConvergence.DefaultRetryDelay.Should().Be(TimeSpan.FromSeconds(5));
        ((SqlPrivateEndpointDnsConvergence.DefaultMaximumAttempts - 1) *
         SqlPrivateEndpointDnsConvergence.DefaultRetryDelay).Should().BeGreaterThanOrEqualTo(TimeSpan.FromMinutes(10));
    }

    [Fact]
    public void ParseCanonicalPrivateIpv4_AcceptsExactPrivateIpv4()
    {
        SqlPrivateEndpointDnsConvergence.ParseCanonicalPrivateIpv4("10.42.2.4")
            .Should().Be(ExpectedAddress);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData(" 10.42.2.4")]
    [InlineData("10.42.2.004")]
    [InlineData("203.0.113.7")]
    [InlineData("127.0.0.1")]
    [InlineData("::1")]
    [InlineData("::ffff:10.42.2.4")]
    public void ParseCanonicalPrivateIpv4_RejectsMissingNoncanonicalPublicOrIpv6(string? value)
    {
        var action = () => SqlPrivateEndpointDnsConvergence.ParseCanonicalPrivateIpv4(value);

        action.Should().Throw<ArgumentException>()
            .WithMessage("--expected-private-endpoint-ip must be one canonical private IPv4 address*");
    }

    [Fact]
    public async Task WaitForExactResolutionAsync_AcceptsOnlyTheDistinctExpectedIpv4()
    {
        var resolverCalls = 0;
        var delayCalls = 0;

        await SqlPrivateEndpointDnsConvergence.WaitForExactResolutionAsync(
            "sql-test.database.windows.net",
            ExpectedAddress,
            (_, _) =>
            {
                resolverCalls++;
                return Task.FromResult(new[] { ExpectedAddress, ExpectedAddress });
            },
            (_, _) =>
            {
                delayCalls++;
                return Task.CompletedTask;
            },
            maximumAttempts: 3,
            retryDelay: TimeSpan.FromSeconds(1));

        resolverCalls.Should().Be(1);
        delayCalls.Should().Be(0);
    }

    [Fact]
    public async Task WaitForExactResolutionAsync_RetriesUntilEveryDistinctResultIsTheExpectedIpv4()
    {
        var results = new Queue<IPAddress[]>(
        [
            [IPAddress.Parse("203.0.113.7")],
            [ExpectedAddress, IPAddress.IPv6Loopback],
            [ExpectedAddress, ExpectedAddress]
        ]);
        var delayCalls = 0;

        await SqlPrivateEndpointDnsConvergence.WaitForExactResolutionAsync(
            "sql-test.database.windows.net",
            ExpectedAddress,
            (_, _) => Task.FromResult(results.Dequeue()),
            (_, _) =>
            {
                delayCalls++;
                return Task.CompletedTask;
            },
            maximumAttempts: 3,
            retryDelay: TimeSpan.FromSeconds(1));

        results.Should().BeEmpty();
        delayCalls.Should().Be(2);
    }

    public static TheoryData<IPAddress[]> NonConvergedResults => new()
    {
        Array.Empty<IPAddress>(),
        new[] { IPAddress.Parse("203.0.113.7") },
        new[] { IPAddress.Parse("10.42.2.5") },
        new[] { ExpectedAddress, IPAddress.Parse("10.42.2.5") },
        new[] { ExpectedAddress, IPAddress.IPv6Loopback },
        new[] { IPAddress.IPv6Loopback }
    };

    [Theory]
    [MemberData(nameof(NonConvergedResults))]
    public async Task WaitForExactResolutionAsync_TimesOutClosedWithoutRenderingResolvedAddresses(
        IPAddress[] addresses)
    {
        var resolverCalls = 0;
        var delayCalls = 0;
        var action = () => SqlPrivateEndpointDnsConvergence.WaitForExactResolutionAsync(
            "sql-test.database.windows.net",
            ExpectedAddress,
            (_, _) =>
            {
                resolverCalls++;
                return Task.FromResult(addresses);
            },
            (_, _) =>
            {
                delayCalls++;
                return Task.CompletedTask;
            },
            maximumAttempts: 3,
            retryDelay: TimeSpan.FromSeconds(1));

        var exception = await action.Should().ThrowAsync<InvalidOperationException>();
        exception.Which.Message.Should().Be(
            "Private SQL DNS did not converge to the exact reviewed private endpoint within the bounded wait.");
        exception.Which.Message.Should().NotContain("10.42").And.NotContain("203.0.113").And.NotContain("::1");
        resolverCalls.Should().Be(3);
        delayCalls.Should().Be(2);
    }

    [Fact]
    public async Task WaitForExactResolutionAsync_RetriesResolverSocketFailuresWithoutLeakingThem()
    {
        var action = () => SqlPrivateEndpointDnsConvergence.WaitForExactResolutionAsync(
            "sql-test.database.windows.net",
            ExpectedAddress,
            (_, _) => throw new SocketException((int)SocketError.HostNotFound),
            (_, _) => Task.CompletedTask,
            maximumAttempts: 2,
            retryDelay: TimeSpan.FromSeconds(1));

        var exception = await action.Should().ThrowAsync<InvalidOperationException>();
        exception.Which.Message.Should().Be(
            "Private SQL DNS did not converge to the exact reviewed private endpoint within the bounded wait.");
    }

    [Fact]
    public async Task WaitForExactResolutionAsync_PropagatesCallerCancellationBeforeResolution()
    {
        var resolverCalls = 0;
        using var cancellation = new CancellationTokenSource();
        await cancellation.CancelAsync();
        var action = () => SqlPrivateEndpointDnsConvergence.WaitForExactResolutionAsync(
            "sql-test.database.windows.net",
            ExpectedAddress,
            (_, _) =>
            {
                resolverCalls++;
                return Task.FromResult(new[] { ExpectedAddress });
            },
            (_, _) => Task.CompletedTask,
            maximumAttempts: 3,
            retryDelay: TimeSpan.FromSeconds(1),
            cancellationToken: cancellation.Token);

        await action.Should().ThrowAsync<OperationCanceledException>();
        resolverCalls.Should().Be(0);
    }
}
