using System.Text.Json;
using FluentAssertions;
using Gateway.Contracts.Messages;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.ValueObjects;
using Gateway.Infrastructure.Outbox;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.IntegrationTests.Fixtures;

namespace Gateway.IntegrationTests.Repositories;

public class OutboxRepositoryTests
{
    [Theory]
    [InlineData("ProvisionAgent", OutboxRouting.ProvisioningDestination)]
    [InlineData(nameof(ProtectionAdminOperationMessage), OutboxRouting.ProtectionAdminDestination)]
    public async Task AddAsync_Should_PersistTheExactMessageDestination(
        string messageType,
        string expectedDestination)
    {
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);
        var message = TestEntityFactory.CreateOutboxMessage();
        message.MessageType = messageType;

        await repository.AddAsync(message, CancellationToken.None);
        await context.SaveChangesAsync();

        context.Entry(message).Property<string>("Destination").CurrentValue
            .Should().Be(expectedDestination);
        OutboxRouting.ResolveQueueName(messageType, "gateway-provisioning-v3")
            .Should().Be(messageType == nameof(ProtectionAdminOperationMessage)
                ? ProtectionAdminQueueContract.QueueName
                : "gateway-provisioning-v3");
    }

    [Theory]
    [InlineData("ProtectionAdminOperationMessageV2")]
    [InlineData("Gateway.Contracts.Messages.ProtectionAdminOperationMessage")]
    public void Routing_Should_RejectNonV1ProtectionAdminMessageTypes(string messageType)
    {
        var action = () => OutboxRouting.ResolveDestination(messageType);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*exact supported v1 contract*");
    }

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

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MarkFailedAsync_Should_AtomicallyFailMatchingProtectionOperation_OnTerminalFailure(
        bool useWorkerWebSerializer)
    {
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);
        var utcNow = new DateTime(2026, 9, 5, 12, 0, 0, DateTimeKind.Utc);
        var claimExpiresAtUtc = utcNow.AddMinutes(2);
        var operation = CreateProtectionOperation();
        var message = CreateProtectionMessage(operation, useWorkerWebSerializer);
        await context.ProtectionAdminOperations.AddAsync(operation);
        await repository.AddAsync(message, CancellationToken.None);
        await context.SaveChangesAsync();
        await repository.ClaimPendingAsync(
            1,
            utcNow,
            claimExpiresAtUtc,
            CancellationToken.None);

        var staleResult = await repository.MarkFailedAsync(
            message.Id,
            claimExpiresAtUtc.AddTicks(1),
            null,
            terminal: true,
            CancellationToken.None);

        staleResult.Should().BeFalse();
        operation.Status.Should().Be(ProtectionAdminOperationStatus.Pending);

        var currentResult = await repository.MarkFailedAsync(
            message.Id,
            claimExpiresAtUtc,
            null,
            terminal: true,
            CancellationToken.None);

        currentResult.Should().BeTrue();
        message.Status.Should().Be(OutboxMessageStatus.Failed);
        operation.Status.Should().Be(ProtectionAdminOperationStatus.Failed);
        operation.RetryDisposition.Should().Be(ProtectionRetryDisposition.Exhausted);
        operation.LastFailureCode.Should().Be("PROTECTION_ADMIN_OUTBOX_PUBLISH_FAILED");
        operation.RequiredAction.Should().Be("ReviewOperationFailure");
        operation.NextAttemptAtUtc.Should().BeNull();
    }

    [Fact]
    public async Task MarkFailedAsync_Should_NotChangeProtectionOperations_ForOrdinaryOutbox()
    {
        await using var context = TestDbContextFactory.Create();
        var repository = new OutboxRepository(context);
        var utcNow = new DateTime(2026, 9, 5, 12, 0, 0, DateTimeKind.Utc);
        var claimExpiresAtUtc = utcNow.AddMinutes(2);
        var operation = CreateProtectionOperation();
        var message = TestEntityFactory.CreateOutboxMessage();
        await context.ProtectionAdminOperations.AddAsync(operation);
        await repository.AddAsync(message, CancellationToken.None);
        await context.SaveChangesAsync();
        await repository.ClaimPendingAsync(
            1,
            utcNow,
            claimExpiresAtUtc,
            CancellationToken.None);

        var result = await repository.MarkFailedAsync(
            message.Id,
            claimExpiresAtUtc,
            null,
            terminal: true,
            CancellationToken.None);

        result.Should().BeTrue();
        message.Status.Should().Be(OutboxMessageStatus.Failed);
        operation.Status.Should().Be(ProtectionAdminOperationStatus.Pending);
        operation.LastFailureCode.Should().BeNull();
        operation.RequiredAction.Should().BeNull();
    }

    private static ProtectionAdminOperation CreateProtectionOperation() => new()
    {
        Id = Guid.NewGuid(),
        WorkflowVersion = ProtectionAdminQueueContract.WorkflowVersion,
        Type = ProtectionAdminOperationType.CreateOrUpdateDlpProfile,
        Status = ProtectionAdminOperationStatus.Pending,
        TenantId = new EntraTenantId(Guid.NewGuid()),
        ActorObjectId = Guid.NewGuid().ToString("D"),
        TargetType = ProtectionAdminTargetType.DlpProfile,
        TargetIdentifier = Guid.NewGuid().ToString("D"),
        ReviewedPayloadHash =
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        IdempotencyKey = new ProtectionIdempotencyKey(Guid.NewGuid()),
        ExpectedRowVersion = [],
        RetryDisposition = ProtectionRetryDisposition.Retryable,
        MaximumAttempts = 3,
        CorrelationId = Guid.NewGuid(),
        CreatedAtUtc = new DateTime(2026, 9, 5, 11, 0, 0, DateTimeKind.Utc),
        UpdatedAtUtc = new DateTime(2026, 9, 5, 11, 0, 0, DateTimeKind.Utc),
    };

    private static OutboxMessage CreateProtectionMessage(
        ProtectionAdminOperation operation,
        bool useWorkerWebSerializer = false) => new()
        {
            Id = Guid.NewGuid(),
            MessageType = nameof(ProtectionAdminOperationMessage),
            Payload = JsonSerializer.Serialize(
            new ProtectionAdminOperationMessage(
                operation.Id,
                operation.WorkflowVersion,
                ExpectedStepIndex: 0,
                operation.CorrelationId),
            useWorkerWebSerializer
                ? new JsonSerializerOptions(JsonSerializerDefaults.Web)
                : null),
            Status = OutboxMessageStatus.Pending,
            CreatedAtUtc = new DateTime(2026, 9, 5, 11, 0, 0, DateTimeKind.Utc),
        };
}
