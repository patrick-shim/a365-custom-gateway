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
    public async Task ClaimPendingAsync_Should_ClaimOnlyDueAndExpiredRows()
    {
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);
        var utcNow = new DateTime(2026, 8, 24, 12, 0, 0, DateTimeKind.Utc);
        var claimExpiresAtUtc = utcNow.AddMinutes(2);

        var due = TestEntityFactory.CreateOutboxMessage();
        due.NextRetryAtUtc = utcNow;
        var future = TestEntityFactory.CreateOutboxMessage();
        future.NextRetryAtUtc = utcNow.AddMinutes(1);
        var expiredClaim = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Processing);
        expiredClaim.NextRetryAtUtc = utcNow.AddTicks(-1);
        var activeClaim = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Processing);
        activeClaim.NextRetryAtUtc = utcNow.AddMinutes(1);

        await context.OutboxMessages.AddRangeAsync(due, future, expiredClaim, activeClaim);
        await context.SaveChangesAsync();

        var claimed = await repository.ClaimPendingAsync(
            10,
            utcNow,
            claimExpiresAtUtc,
            CancellationToken.None);

        claimed.Select(message => message.Id)
            .Should().BeEquivalentTo([due.Id, expiredClaim.Id]);
        claimed.Should().OnlyContain(message =>
            message.Status == OutboxMessageStatus.Processing &&
            message.NextRetryAtUtc == claimExpiresAtUtc);
    }

    [Fact]
    public async Task MarkPublishedAsync_Should_UpdateOnlyCurrentClaim()
    {
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);
        var utcNow = new DateTime(2026, 8, 24, 12, 0, 0, DateTimeKind.Utc);
        var claimExpiresAtUtc = utcNow.AddMinutes(2);
        var message = TestEntityFactory.CreateOutboxMessage();
        await repository.AddAsync(message, CancellationToken.None);
        await context.SaveChangesAsync();
        await repository.ClaimPendingAsync(1, utcNow, claimExpiresAtUtc, CancellationToken.None);

        var staleResult = await repository.MarkPublishedAsync(
            message.Id,
            claimExpiresAtUtc.AddTicks(1),
            utcNow,
            CancellationToken.None);
        var currentResult = await repository.MarkPublishedAsync(
            message.Id,
            claimExpiresAtUtc,
            utcNow,
            CancellationToken.None);

        staleResult.Should().BeFalse();
        currentResult.Should().BeTrue();
        message.Status.Should().Be(OutboxMessageStatus.Published);
        message.PublishedAtUtc.Should().Be(utcNow);
        message.NextRetryAtUtc.Should().BeNull();
    }

    [Fact]
    public async Task MarkFailedAsync_Should_ReturnMessageToPending_WithRetryMetadata()
    {
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);
        var utcNow = new DateTime(2026, 8, 24, 12, 0, 0, DateTimeKind.Utc);
        var claimExpiresAtUtc = utcNow.AddMinutes(2);
        var retryAtUtc = utcNow.AddSeconds(5);
        var message = TestEntityFactory.CreateOutboxMessage();
        await repository.AddAsync(message, CancellationToken.None);
        await context.SaveChangesAsync();
        await repository.ClaimPendingAsync(1, utcNow, claimExpiresAtUtc, CancellationToken.None);

        var updated = await repository.MarkFailedAsync(
            message.Id,
            claimExpiresAtUtc,
            retryAtUtc,
            terminal: false,
            CancellationToken.None);

        updated.Should().BeTrue();
        message.Status.Should().Be(OutboxMessageStatus.Pending);
        message.RetryCount.Should().Be(1);
        message.NextRetryAtUtc.Should().Be(retryAtUtc);
    }

    [Fact]
    public async Task MarkFailedAsync_Should_MarkTerminalFailure_AndRejectStaleOwner()
    {
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);
        var utcNow = new DateTime(2026, 8, 24, 12, 0, 0, DateTimeKind.Utc);
        var claimExpiresAtUtc = utcNow.AddMinutes(2);
        var message = TestEntityFactory.CreateOutboxMessage();
        await repository.AddAsync(message, CancellationToken.None);
        await context.SaveChangesAsync();
        await repository.ClaimPendingAsync(1, utcNow, claimExpiresAtUtc, CancellationToken.None);

        var staleResult = await repository.MarkFailedAsync(
            message.Id,
            claimExpiresAtUtc.AddTicks(1),
            null,
            terminal: true,
            CancellationToken.None);
        var currentResult = await repository.MarkFailedAsync(
            message.Id,
            claimExpiresAtUtc,
            null,
            terminal: true,
            CancellationToken.None);

        staleResult.Should().BeFalse();
        currentResult.Should().BeTrue();
        message.Status.Should().Be(OutboxMessageStatus.Failed);
        message.RetryCount.Should().Be(1);
        message.NextRetryAtUtc.Should().BeNull();
    }
}
