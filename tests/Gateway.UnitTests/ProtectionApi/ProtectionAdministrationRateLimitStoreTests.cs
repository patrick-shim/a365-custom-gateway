using FluentAssertions;
using Gateway.Api.Middleware;

namespace Gateway.UnitTests.ProtectionApi;

public sealed class ProtectionAdministrationRateLimitStoreTests
{
    [Fact]
    public void LimitsBothUserAndIpWithinABoundedWindow()
    {
        var clock = new TestTimeProvider(
            new DateTimeOffset(
                2026,
                9,
                5,
                11,
                0,
                0,
                TimeSpan.Zero));
        var store = new ProtectionAdministrationRateLimitStore(
            clock,
            userLimit: 2,
            ipLimit: 3,
            maximumPartitions: 16);

        store.TryAcquire("user-a", "192.0.2.1").Allowed.Should().BeTrue();
        store.TryAcquire("user-a", "192.0.2.1").Allowed.Should().BeTrue();
        store.TryAcquire("user-a", "192.0.2.1").Allowed.Should().BeFalse();
        store.PartitionCount.Should().BeLessThanOrEqualTo(16);

        clock.Advance(TimeSpan.FromMinutes(1));
        store.TryAcquire("user-a", "192.0.2.1").Allowed.Should().BeTrue();
    }

    [Fact]
    public void PartitionCapacityFailsClosedInsteadOfGrowingWithoutBound()
    {
        var store = new ProtectionAdministrationRateLimitStore(
            TimeProvider.System,
            userLimit: 10,
            ipLimit: 10,
            maximumPartitions: 2);

        store.TryAcquire("user-a", "192.0.2.1").Allowed.Should().BeTrue();
        store.TryAcquire("user-b", "192.0.2.2").Allowed.Should().BeFalse();
        store.PartitionCount.Should().Be(2);
    }

    private sealed class TestTimeProvider : TimeProvider
    {
        private DateTimeOffset _utcNow;

        public TestTimeProvider(DateTimeOffset utcNow)
        {
            _utcNow = utcNow;
        }

        public override DateTimeOffset GetUtcNow() => _utcNow;

        public void Advance(TimeSpan value) => _utcNow += value;
    }
}
