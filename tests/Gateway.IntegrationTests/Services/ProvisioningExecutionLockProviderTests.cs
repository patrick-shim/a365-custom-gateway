using FluentAssertions;
using Gateway.Infrastructure.Services;
using Gateway.IntegrationTests.Fixtures;

namespace Gateway.IntegrationTests.Services;

public class ProvisioningExecutionLockProviderTests
{
    [Fact]
    public async Task AcquireAsync_ShouldSerializeTheSameProvisioningJob()
    {
        var databaseName = Guid.NewGuid().ToString("N");
        await using var firstContext = TestDbContextFactory.Create(databaseName);
        await using var secondContext = TestDbContextFactory.Create(databaseName);
        var firstProvider = new ProvisioningExecutionLockProvider(firstContext);
        var secondProvider = new ProvisioningExecutionLockProvider(secondContext);
        var jobId = Guid.NewGuid();

        await using var firstLease = await firstProvider.AcquireAsync(
            jobId,
            CancellationToken.None);
        var secondAcquire = secondProvider.AcquireAsync(jobId, CancellationToken.None);

        (await Task.WhenAny(secondAcquire, Task.Delay(100)))
            .Should().NotBe(secondAcquire);

        await firstLease.DisposeAsync();
        await using var secondLease = await secondAcquire.WaitAsync(TimeSpan.FromSeconds(2));
    }

    [Fact]
    public async Task AcquireAsync_ShouldNotSerializeDifferentProvisioningJobs()
    {
        await using var context = TestDbContextFactory.Create();
        var provider = new ProvisioningExecutionLockProvider(context);

        await using var firstLease = await provider.AcquireAsync(
            Guid.NewGuid(),
            CancellationToken.None);
        var secondAcquire = provider.AcquireAsync(Guid.NewGuid(), CancellationToken.None);

        await using var secondLease = await secondAcquire.WaitAsync(TimeSpan.FromSeconds(2));
    }
}
