using FluentAssertions;
using Gateway.Domain.Enums;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.IntegrationTests.Fixtures;

namespace Gateway.IntegrationTests.Repositories;

public class OutboxRepositoryTests
{
    [Fact]
    public async Task AddAsync_Should_PersistMessage_When_ValidMessageProvided()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);
        var message = TestEntityFactory.CreateOutboxMessage();

        // Act
        await repository.AddAsync(message, CancellationToken.None);
        await context.SaveChangesAsync();

        // Assert
        var persisted = await context.OutboxMessages.FindAsync(message.Id);
        persisted.Should().NotBeNull();
        persisted!.MessageType.Should().Be(message.MessageType);
        persisted.Payload.Should().Be(message.Payload);
        persisted.Status.Should().Be(OutboxMessageStatus.Pending);
    }

    [Fact]
    public async Task GetPendingAsync_Should_ReturnPendingMessages_When_PendingMessagesExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);

        var pending1 = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Pending);
        var pending2 = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Pending);
        var published = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Published);
        var failed = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Failed);

        await repository.AddAsync(pending1, CancellationToken.None);
        await repository.AddAsync(pending2, CancellationToken.None);
        await repository.AddAsync(published, CancellationToken.None);
        await repository.AddAsync(failed, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var results = await repository.GetPendingAsync(10, CancellationToken.None);

        // Assert
        results.Should().HaveCount(2);
        results.Should().AllSatisfy(m => m.Status.Should().Be(OutboxMessageStatus.Pending));
    }

    [Fact]
    public async Task GetPendingAsync_Should_OrderByCreatedAtUtc_When_MultiplePendingExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);

        var baseTime = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        for (int i = 4; i >= 0; i--)
        {
            var msg = TestEntityFactory.CreateOutboxMessage(
                status: OutboxMessageStatus.Pending,
                createdAtUtc: baseTime.AddMinutes(i));
            await repository.AddAsync(msg, CancellationToken.None);
        }
        await context.SaveChangesAsync();

        // Act
        var results = await repository.GetPendingAsync(10, CancellationToken.None);

        // Assert
        results.Should().HaveCount(5);
        results.Should().BeInAscendingOrder(m => m.CreatedAtUtc);
    }

    [Fact]
    public async Task GetPendingAsync_Should_RespectBatchSize_When_MoreMessagesThanBatchSize()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);

        var baseTime = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        for (int i = 0; i < 10; i++)
        {
            var msg = TestEntityFactory.CreateOutboxMessage(
                status: OutboxMessageStatus.Pending,
                createdAtUtc: baseTime.AddMinutes(i));
            await repository.AddAsync(msg, CancellationToken.None);
        }
        await context.SaveChangesAsync();

        // Act
        var results = await repository.GetPendingAsync(3, CancellationToken.None);

        // Assert
        results.Should().HaveCount(3);
        results.Should().BeInAscendingOrder(m => m.CreatedAtUtc);
    }

    [Fact]
    public async Task GetPendingAsync_Should_ReturnEmpty_When_NoPendingMessages()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);

        var published = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Published);
        await repository.AddAsync(published, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var results = await repository.GetPendingAsync(10, CancellationToken.None);

        // Assert
        results.Should().BeEmpty();
    }

    [Fact]
    public async Task MarkPublishedAsync_Should_UpdateStatusToPublished_When_MessageExists()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);
        var message = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Pending);

        await repository.AddAsync(message, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        await repository.MarkPublishedAsync(message.Id, CancellationToken.None);
        await context.SaveChangesAsync();

        // Assert
        var updated = await context.OutboxMessages.FindAsync(message.Id);
        updated.Should().NotBeNull();
        updated!.Status.Should().Be(OutboxMessageStatus.Published);
        updated.PublishedAtUtc.Should().NotBeNull();
    }

    [Fact]
    public async Task MarkPublishedAsync_Should_NotThrow_When_MessageDoesNotExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);

        // Act
        var act = async () => await repository.MarkPublishedAsync(Guid.NewGuid(), CancellationToken.None);

        // Assert
        await act.Should().NotThrowAsync();
    }

    [Fact]
    public async Task MarkFailedAsync_Should_UpdateStatusToFailed_When_MessageExists()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);
        var message = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Pending);

        await repository.AddAsync(message, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        await repository.MarkFailedAsync(message.Id, CancellationToken.None);
        await context.SaveChangesAsync();

        // Assert
        var updated = await context.OutboxMessages.FindAsync(message.Id);
        updated.Should().NotBeNull();
        updated!.Status.Should().Be(OutboxMessageStatus.Failed);
        updated.RetryCount.Should().Be(1);
    }

    [Fact]
    public async Task MarkFailedAsync_Should_IncrementRetryCount_When_CalledMultipleTimes()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);
        var message = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Pending);

        await repository.AddAsync(message, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        await repository.MarkFailedAsync(message.Id, CancellationToken.None);
        await context.SaveChangesAsync();
        await repository.MarkFailedAsync(message.Id, CancellationToken.None);
        await context.SaveChangesAsync();
        await repository.MarkFailedAsync(message.Id, CancellationToken.None);
        await context.SaveChangesAsync();

        // Assert
        var updated = await context.OutboxMessages.FindAsync(message.Id);
        updated.Should().NotBeNull();
        updated!.RetryCount.Should().Be(3);
    }

    [Fact]
    public async Task GetPendingAsync_Should_NotReturnPublishedMessages_When_PublishedMessagesExist()
    {
        // Arrange
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);

        var pending = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Pending);
        await repository.AddAsync(pending, CancellationToken.None);
        await context.SaveChangesAsync();

        // Mark as published
        await repository.MarkPublishedAsync(pending.Id, CancellationToken.None);
        await context.SaveChangesAsync();

        // Act
        var results = await repository.GetPendingAsync(10, CancellationToken.None);

        // Assert
        results.Should().BeEmpty();
    }
}
