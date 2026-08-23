using FluentAssertions;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Infrastructure.Outbox;
using Gateway.Infrastructure.Persistence;
using Gateway.Infrastructure.Persistence.Repositories;
using Gateway.IntegrationTests.Fixtures;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using NSubstitute;
using NSubstitute.ExceptionExtensions;

namespace Gateway.IntegrationTests.Outbox;

public class OutboxRelayServiceTests
{
    private static (OutboxRelayService service, IServiceBusPublisher publisher, string dbName) CreateTestServices(
        int batchSize = 50,
        int pollingIntervalSeconds = 1)
    {
        var dbName = Guid.NewGuid().ToString();
        var publisher = Substitute.For<IServiceBusPublisher>();

        var services = new ServiceCollection();
        services.AddDbContext<GatewayDbContext>(options =>
            options.UseInMemoryDatabase(dbName));
        services.AddScoped<IOutboxRepository, OutboxRepository>();
        services.AddScoped<IUnitOfWork, UnitOfWork>();
        services.AddScoped(_ => publisher);

        var serviceProvider = services.BuildServiceProvider();
        var scopeFactory = serviceProvider.GetRequiredService<IServiceScopeFactory>();

        var options = Options.Create(new OutboxRelayOptions
        {
            BatchSize = batchSize,
            PollingIntervalSeconds = pollingIntervalSeconds,
        });

        var logger = NullLogger<OutboxRelayService>.Instance;
        var service = new OutboxRelayService(scopeFactory, options, logger);

        return (service, publisher, dbName);
    }

    [Fact]
    public async Task ProcessBatch_Should_PublishPendingMessages_When_PendingMessagesExist()
    {
        // Arrange
        var (service, publisher, dbName) = CreateTestServices();

        // Seed pending messages
        await using (var context = TestDbContextFactory.Create(dbName))
        {
            var repo = new OutboxRepository(context);
            await repo.AddAsync(TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Pending), CancellationToken.None);
            await repo.AddAsync(TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Pending), CancellationToken.None);
            await context.SaveChangesAsync();
        }

        // Act - invoke StartAsync with a short-lived cancellation to run one cycle
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try
        {
            await service.StartAsync(CancellationToken.None);
            await Task.Delay(TimeSpan.FromSeconds(2), cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected
        }
        finally
        {
            await service.StopAsync(CancellationToken.None);
        }

        // Assert
        await publisher.Received(2).PublishAsync(
            Arg.Any<string>(),
            Arg.Any<string>(),
            Arg.Any<Guid>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task ProcessBatch_Should_MarkMessagesAsPublished_When_PublishSucceeds()
    {
        // Arrange
        var (service, publisher, dbName) = CreateTestServices();

        Guid messageId;
        await using (var context = TestDbContextFactory.Create(dbName))
        {
            var msg = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Pending);
            messageId = msg.Id;
            var repo = new OutboxRepository(context);
            await repo.AddAsync(msg, CancellationToken.None);
            await context.SaveChangesAsync();
        }

        // Act
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try
        {
            await service.StartAsync(CancellationToken.None);
            await Task.Delay(TimeSpan.FromSeconds(2), cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected
        }
        finally
        {
            await service.StopAsync(CancellationToken.None);
        }

        // Assert
        await using var verifyContext = TestDbContextFactory.Create(dbName);
        var message = await verifyContext.OutboxMessages.FindAsync(messageId);
        message.Should().NotBeNull();
        message!.Status.Should().Be(OutboxMessageStatus.Published);
        message.PublishedAtUtc.Should().NotBeNull();
    }

    [Fact]
    public async Task ProcessBatch_Should_MarkMessageAsFailed_When_PublishThrows()
    {
        // Arrange
        var (service, publisher, dbName) = CreateTestServices();

        publisher.PublishAsync(
            Arg.Any<string>(),
            Arg.Any<string>(),
            Arg.Any<Guid>(),
            Arg.Any<CancellationToken>())
            .ThrowsAsync(new InvalidOperationException("Service Bus unavailable"));

        Guid messageId;
        await using (var context = TestDbContextFactory.Create(dbName))
        {
            var msg = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Pending);
            messageId = msg.Id;
            var repo = new OutboxRepository(context);
            await repo.AddAsync(msg, CancellationToken.None);
            await context.SaveChangesAsync();
        }

        // Act
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try
        {
            await service.StartAsync(CancellationToken.None);
            await Task.Delay(TimeSpan.FromSeconds(2), cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected
        }
        finally
        {
            await service.StopAsync(CancellationToken.None);
        }

        // Assert
        await using var verifyContext = TestDbContextFactory.Create(dbName);
        var message = await verifyContext.OutboxMessages.FindAsync(messageId);
        message.Should().NotBeNull();
        message!.Status.Should().Be(OutboxMessageStatus.Failed);
        message.RetryCount.Should().BeGreaterThan(0);
    }

    [Fact]
    public async Task ProcessBatch_Should_RespectBatchSize_When_MoreMessagesThanBatchExist()
    {
        // Arrange
        var (service, publisher, dbName) = CreateTestServices(batchSize: 2);

        await using (var context = TestDbContextFactory.Create(dbName))
        {
            var repo = new OutboxRepository(context);
            for (int i = 0; i < 5; i++)
            {
                await repo.AddAsync(
                    TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Pending),
                    CancellationToken.None);
            }
            await context.SaveChangesAsync();
        }

        // Act - run one cycle
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try
        {
            await service.StartAsync(CancellationToken.None);
            // Wait just enough for one processing cycle
            await Task.Delay(TimeSpan.FromMilliseconds(500), cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected
        }
        finally
        {
            await service.StopAsync(CancellationToken.None);
        }

        // Assert - only batchSize (2) messages should have been published in first cycle
        await publisher.Received(2).PublishAsync(
            Arg.Any<string>(),
            Arg.Any<string>(),
            Arg.Any<Guid>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task ProcessBatch_Should_SkipAlreadySentMessages_When_PublishedMessagesExist()
    {
        // Arrange
        var (service, publisher, dbName) = CreateTestServices();

        await using (var context = TestDbContextFactory.Create(dbName))
        {
            var repo = new OutboxRepository(context);

            // Add one published and one pending
            var published = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Published);
            published.PublishedAtUtc = DateTime.UtcNow.AddMinutes(-5);
            var pending = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Pending);

            await repo.AddAsync(published, CancellationToken.None);
            await repo.AddAsync(pending, CancellationToken.None);
            await context.SaveChangesAsync();
        }

        // Act
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try
        {
            await service.StartAsync(CancellationToken.None);
            await Task.Delay(TimeSpan.FromSeconds(2), cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected
        }
        finally
        {
            await service.StopAsync(CancellationToken.None);
        }

        // Assert - only the pending message should be published (not the already-published one)
        await publisher.Received(1).PublishAsync(
            Arg.Any<string>(),
            Arg.Any<string>(),
            Arg.Any<Guid>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task ProcessBatch_Should_DoNothing_When_NoPendingMessages()
    {
        // Arrange
        var (service, publisher, dbName) = CreateTestServices();

        // No messages seeded

        // Act
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try
        {
            await service.StartAsync(CancellationToken.None);
            await Task.Delay(TimeSpan.FromSeconds(2), cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected
        }
        finally
        {
            await service.StopAsync(CancellationToken.None);
        }

        // Assert
        await publisher.DidNotReceive().PublishAsync(
            Arg.Any<string>(),
            Arg.Any<string>(),
            Arg.Any<Guid>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task ProcessBatch_Should_PassCorrectPayload_When_PublishingMessage()
    {
        // Arrange
        var (service, publisher, dbName) = CreateTestServices();

        Guid messageId;
        const string expectedPayload = """{"agentId":"test-agent-001","operation":"provision"}""";
        const string expectedMessageType = "ProvisioningRequested";

        await using (var context = TestDbContextFactory.Create(dbName))
        {
            var msg = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Pending);
            messageId = msg.Id;
            var repo = new OutboxRepository(context);
            await repo.AddAsync(msg, CancellationToken.None);
            await context.SaveChangesAsync();
        }

        // Act
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try
        {
            await service.StartAsync(CancellationToken.None);
            await Task.Delay(TimeSpan.FromSeconds(2), cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected
        }
        finally
        {
            await service.StopAsync(CancellationToken.None);
        }

        // Assert
        await publisher.Received(1).PublishAsync(
            expectedMessageType,
            expectedPayload,
            messageId,
            Arg.Any<CancellationToken>());
    }
}
