using FluentAssertions;
using Gateway.Domain.Entities;
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

namespace Gateway.IntegrationTests.Outbox;

public class OutboxRelayServiceTests
{
    [Fact]
    public void Options_Should_DefaultToEnabled_ForApiRelayCompatibility()
    {
        new OutboxRelayOptions().Enabled.Should().BeTrue();
    }

    [Fact]
    public async Task DisabledRelay_Should_ExitWithoutResolvingDatabaseOrPublisherServices()
    {
        var scopeFactory = Substitute.For<IServiceScopeFactory>();
        var options = Options.Create(new OutboxRelayOptions { Enabled = false });
        var service = new OutboxRelayService(
            scopeFactory,
            options,
            NullLogger<OutboxRelayService>.Instance);

        await service.StartAsync(CancellationToken.None);
        await service.StopAsync(CancellationToken.None);

        scopeFactory.DidNotReceive().CreateScope();
    }

    [Fact]
    public async Task DisabledRelay_Should_NotProcessBatchWhenInvokedDirectly()
    {
        var scopeFactory = Substitute.For<IServiceScopeFactory>();
        var options = Options.Create(new OutboxRelayOptions { Enabled = false });
        var service = new OutboxRelayService(
            scopeFactory,
            options,
            NullLogger<OutboxRelayService>.Instance);

        await service.ProcessBatchAsync(CancellationToken.None);

        scopeFactory.DidNotReceive().CreateScope();
    }

    [Fact]
    public async Task ProcessBatch_Should_PublishAndMarkPendingMessages_When_PublishSucceeds()
    {
        await using var fixture = new RelayFixture();
        var first = TestEntityFactory.CreateOutboxMessage();
        var second = TestEntityFactory.CreateOutboxMessage();
        await fixture.SeedAsync(first, second);

        await fixture.Service.ProcessBatchAsync(CancellationToken.None);

        await fixture.Publisher.Received(2).PublishAsync(
            Arg.Any<string>(),
            Arg.Any<string>(),
            Arg.Any<Guid>(),
            Arg.Any<CancellationToken>());

        var messages = await fixture.ReadAsync(first.Id, second.Id);
        messages.Should().OnlyContain(message =>
            message.Status == OutboxMessageStatus.Published &&
            message.PublishedAtUtc != null &&
            message.NextRetryAtUtc == null);
    }

    [Fact]
    public async Task ProcessBatch_Should_RetryAfterBackoff_When_FirstPublishFails()
    {
        await using var fixture = new RelayFixture(initialRetryDelaySeconds: 2);
        var message = TestEntityFactory.CreateOutboxMessage();
        await fixture.SeedAsync(message);

        var callCount = 0;
        fixture.Publisher.PublishAsync(
                Arg.Any<string>(),
                Arg.Any<string>(),
                Arg.Any<Guid>(),
                Arg.Any<CancellationToken>())
            .Returns(_ => ++callCount == 1
                ? Task.FromException(new InvalidOperationException("Service Bus unavailable"))
                : Task.CompletedTask);

        await fixture.Service.ProcessBatchAsync(CancellationToken.None);

        var afterFailure = (await fixture.ReadAsync(message.Id)).Single();
        afterFailure.Status.Should().Be(OutboxMessageStatus.Pending);
        afterFailure.RetryCount.Should().Be(1);
        afterFailure.NextRetryAtUtc.Should().Be(fixture.UtcNow.AddSeconds(2));

        fixture.Advance(TimeSpan.FromSeconds(1));
        await fixture.Service.ProcessBatchAsync(CancellationToken.None);
        callCount.Should().Be(1, "the retry delay has not elapsed");

        fixture.Advance(TimeSpan.FromSeconds(1));
        await fixture.Service.ProcessBatchAsync(CancellationToken.None);

        callCount.Should().Be(2);
        var published = (await fixture.ReadAsync(message.Id)).Single();
        published.Status.Should().Be(OutboxMessageStatus.Published);
        published.RetryCount.Should().Be(1);
        published.NextRetryAtUtc.Should().BeNull();
    }

    [Fact]
    public async Task ProcessBatch_Should_UseBoundedExponentialBackoff_ThenFailTerminally()
    {
        await using var fixture = new RelayFixture(
            maxRetryCount: 3,
            initialRetryDelaySeconds: 2,
            maxRetryDelaySeconds: 3);
        var message = TestEntityFactory.CreateOutboxMessage();
        await fixture.SeedAsync(message);

        fixture.Publisher.PublishAsync(
                Arg.Any<string>(),
                Arg.Any<string>(),
                Arg.Any<Guid>(),
                Arg.Any<CancellationToken>())
            .Returns(Task.FromException(new InvalidOperationException("Service Bus unavailable")));

        await fixture.Service.ProcessBatchAsync(CancellationToken.None);
        var firstFailure = (await fixture.ReadAsync(message.Id)).Single();
        firstFailure.Status.Should().Be(OutboxMessageStatus.Pending);
        firstFailure.NextRetryAtUtc.Should().Be(fixture.UtcNow.AddSeconds(2));

        fixture.Advance(TimeSpan.FromSeconds(2));
        await fixture.Service.ProcessBatchAsync(CancellationToken.None);
        var secondFailure = (await fixture.ReadAsync(message.Id)).Single();
        secondFailure.Status.Should().Be(OutboxMessageStatus.Pending);
        secondFailure.NextRetryAtUtc.Should().Be(fixture.UtcNow.AddSeconds(3));

        fixture.Advance(TimeSpan.FromSeconds(3));
        await fixture.Service.ProcessBatchAsync(CancellationToken.None);
        var terminal = (await fixture.ReadAsync(message.Id)).Single();
        terminal.Status.Should().Be(OutboxMessageStatus.Failed);
        terminal.RetryCount.Should().Be(3);
        terminal.NextRetryAtUtc.Should().BeNull();

        fixture.Advance(TimeSpan.FromHours(1));
        await fixture.Service.ProcessBatchAsync(CancellationToken.None);
        await fixture.Publisher.Received(3).PublishAsync(
            Arg.Any<string>(),
            Arg.Any<string>(),
            message.Id,
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task ProcessBatch_Should_ReclaimExpiredProcessingMessage_AfterRelayCrash()
    {
        await using var fixture = new RelayFixture();
        var message = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Processing);
        message.NextRetryAtUtc = fixture.UtcNow.AddSeconds(-1);
        await fixture.SeedAsync(message);

        await fixture.Service.ProcessBatchAsync(CancellationToken.None);

        await fixture.Publisher.Received(1).PublishAsync(
            message.MessageType,
            message.Payload,
            message.Id,
            Arg.Any<CancellationToken>());
        var persisted = (await fixture.ReadAsync(message.Id)).Single();
        persisted.Status.Should().Be(OutboxMessageStatus.Published);
    }

    [Fact]
    public async Task ProcessBatch_Should_NotPublishSamePendingRow_FromConcurrentRelayInstances()
    {
        await using var fixture = new RelayFixture();
        var message = TestEntityFactory.CreateOutboxMessage();
        await fixture.SeedAsync(message);

        var secondRelay = fixture.CreateService();
        await Task.WhenAll(
            fixture.Service.ProcessBatchAsync(CancellationToken.None),
            secondRelay.ProcessBatchAsync(CancellationToken.None));

        await fixture.Publisher.Received(1).PublishAsync(
            message.MessageType,
            message.Payload,
            message.Id,
            Arg.Any<CancellationToken>());
        var persisted = (await fixture.ReadAsync(message.Id)).Single();
        persisted.Status.Should().Be(OutboxMessageStatus.Published);
    }

    [Fact]
    public async Task ProcessBatch_Should_RespectBatchSize()
    {
        await using var fixture = new RelayFixture(batchSize: 2);
        var messages = Enumerable.Range(0, 5)
            .Select(_ => TestEntityFactory.CreateOutboxMessage())
            .ToArray();
        await fixture.SeedAsync(messages);

        await fixture.Service.ProcessBatchAsync(CancellationToken.None);

        await fixture.Publisher.Received(2).PublishAsync(
            Arg.Any<string>(),
            Arg.Any<string>(),
            Arg.Any<Guid>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task ProcessBatch_Should_SkipPublishedAndFutureRetryMessages()
    {
        await using var fixture = new RelayFixture();
        var published = TestEntityFactory.CreateOutboxMessage(OutboxMessageStatus.Published);
        published.PublishedAtUtc = fixture.UtcNow.AddMinutes(-1);
        var futureRetry = TestEntityFactory.CreateOutboxMessage();
        futureRetry.NextRetryAtUtc = fixture.UtcNow.AddMinutes(1);
        await fixture.SeedAsync(published, futureRetry);

        await fixture.Service.ProcessBatchAsync(CancellationToken.None);

        await fixture.Publisher.DidNotReceive().PublishAsync(
            Arg.Any<string>(),
            Arg.Any<string>(),
            Arg.Any<Guid>(),
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public async Task ProcessBatch_Should_PassExactTypePayloadAndOutboxId()
    {
        await using var fixture = new RelayFixture();
        var message = TestEntityFactory.CreateOutboxMessage();
        await fixture.SeedAsync(message);

        await fixture.Service.ProcessBatchAsync(CancellationToken.None);

        await fixture.Publisher.Received(1).PublishAsync(
            message.MessageType,
            message.Payload,
            message.Id,
            Arg.Any<CancellationToken>());
    }

    [Fact]
    public void ServiceBusMessage_Should_UseStableOutboxId_ForMessageAndCorrelationIds()
    {
        var outboxId = Guid.NewGuid();

        var message = ServiceBusPublisher.CreateMessage(
            "ProvisioningRequested",
            "{}",
            outboxId);

        message.MessageId.Should().Be(outboxId.ToString("D"));
        message.CorrelationId.Should().Be(outboxId.ToString("D"));
        message.Subject.Should().Be("ProvisioningRequested");
        message.ContentType.Should().Be("application/json");
    }

    private sealed class RelayFixture : IAsyncDisposable
    {
        private readonly string _dbName = Guid.NewGuid().ToString();
        private readonly ServiceProvider _serviceProvider;
        private readonly OutboxRelayOptions _options;
        private readonly ManualTimeProvider _timeProvider = new(
            new DateTimeOffset(2026, 8, 24, 12, 0, 0, TimeSpan.Zero));

        public RelayFixture(
            int batchSize = 50,
            int maxRetryCount = 5,
            int initialRetryDelaySeconds = 5,
            int maxRetryDelaySeconds = 300)
        {
            Publisher = Substitute.For<IServiceBusPublisher>();

            var services = new ServiceCollection();
            services.AddDbContext<GatewayDbContext>(options =>
                options.UseInMemoryDatabase(_dbName));
            services.AddScoped<IOutboxRepository, OutboxRepository>();
            services.AddScoped<IUnitOfWork, UnitOfWork>();
            services.AddScoped(_ => Publisher);
            _serviceProvider = services.BuildServiceProvider();

            _options = new OutboxRelayOptions
            {
                BatchSize = batchSize,
                PollingIntervalSeconds = 1,
                MaxRetryCount = maxRetryCount,
                InitialRetryDelaySeconds = initialRetryDelaySeconds,
                MaxRetryDelaySeconds = maxRetryDelaySeconds,
                ClaimLeaseSeconds = 120,
            };

            Service = CreateService();
        }

        public OutboxRelayService Service { get; }
        public IServiceBusPublisher Publisher { get; }
        public DateTime UtcNow => _timeProvider.GetUtcNow().UtcDateTime;

        public OutboxRelayService CreateService()
        {
            return new OutboxRelayService(
                _serviceProvider.GetRequiredService<IServiceScopeFactory>(),
                Options.Create(_options),
                NullLogger<OutboxRelayService>.Instance,
                _timeProvider);
        }

        public void Advance(TimeSpan amount) => _timeProvider.Advance(amount);

        public async Task SeedAsync(params OutboxMessage[] messages)
        {
            await using var context = TestDbContextFactory.Create(_dbName);
            await context.OutboxMessages.AddRangeAsync(messages);
            await context.SaveChangesAsync();
        }

        public async Task<List<OutboxMessage>> ReadAsync(params Guid[] ids)
        {
            await using var context = TestDbContextFactory.Create(_dbName);
            return await context.OutboxMessages
                .Where(message => ids.Contains(message.Id))
                .OrderBy(message => message.CreatedAtUtc)
                .ToListAsync();
        }

        public ValueTask DisposeAsync() => _serviceProvider.DisposeAsync();
    }

    private sealed class ManualTimeProvider(DateTimeOffset utcNow) : TimeProvider
    {
        private DateTimeOffset _utcNow = utcNow;

        public override DateTimeOffset GetUtcNow() => _utcNow;

        public void Advance(TimeSpan amount) => _utcNow = _utcNow.Add(amount);
    }
}
