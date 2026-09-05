using FluentAssertions;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Services;
using Gateway.IntegrationTests.Fixtures;

namespace Gateway.IntegrationTests.Services;

public sealed class ProtectionAdminOperationLockProviderTests
{
    [Fact]
    public async Task IdempotencyScope_SerializesTenantAndKeyUntilLeaseDisposal()
    {
        var databaseName = Guid.NewGuid().ToString("D");
        await using var firstContext = TestDbContextFactory.Create(databaseName);
        await using var secondContext = TestDbContextFactory.Create(databaseName);
        var firstProvider = new ProtectionAdminOperationLockProvider(firstContext);
        var secondProvider = new ProtectionAdminOperationLockProvider(secondContext);
        var tenantId = new EntraTenantId(Guid.NewGuid());
        var key = new ProtectionIdempotencyKey(Guid.NewGuid());

        var first = await firstProvider.AcquireIdempotencyAsync(
            tenantId,
            key,
            CancellationToken.None);
        var secondTask = secondProvider.AcquireIdempotencyAsync(
            tenantId,
            key,
            CancellationToken.None);

        await Task.Delay(25);
        secondTask.IsCompleted.Should().BeFalse();

        await first.CompleteAsync(CancellationToken.None);
        await first.DisposeAsync();
        await using var second = await secondTask.WaitAsync(TimeSpan.FromSeconds(2));
    }

    [Fact]
    public async Task ExecutionScope_SerializesTheSameOperationButNotDifferentOperations()
    {
        var databaseName = Guid.NewGuid().ToString("D");
        await using var firstContext = TestDbContextFactory.Create(databaseName);
        await using var secondContext = TestDbContextFactory.Create(databaseName);
        var firstProvider = new ProtectionAdminOperationLockProvider(firstContext);
        var secondProvider = new ProtectionAdminOperationLockProvider(secondContext);
        var operationId = Guid.NewGuid();

        var first = await firstProvider.AcquireExecutionAsync(operationId, CancellationToken.None);
        var sameOperation = secondProvider.AcquireExecutionAsync(operationId, CancellationToken.None);
        await using var differentOperation = await secondProvider.AcquireExecutionAsync(
            Guid.NewGuid(),
            CancellationToken.None);

        await Task.Delay(25);
        sameOperation.IsCompleted.Should().BeFalse();

        await first.DisposeAsync();
        await using var second = await sameOperation.WaitAsync(TimeSpan.FromSeconds(2));
    }
}
