using Gateway.Domain.Entities;
using Gateway.Domain.Interfaces;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Infrastructure.Outbox;

internal sealed class OutboxRelayService : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly OutboxRelayOptions _options;
    private readonly ILogger<OutboxRelayService> _logger;
    private readonly TimeProvider _timeProvider;

    public OutboxRelayService(
        IServiceScopeFactory scopeFactory,
        IOptions<OutboxRelayOptions> options,
        ILogger<OutboxRelayService> logger)
        : this(scopeFactory, options, logger, TimeProvider.System)
    {
    }

    internal OutboxRelayService(
        IServiceScopeFactory scopeFactory,
        IOptions<OutboxRelayOptions> options,
        ILogger<OutboxRelayService> logger,
        TimeProvider timeProvider)
    {
        _scopeFactory = scopeFactory;
        _options = options.Value;
        _logger = logger;
        _timeProvider = timeProvider;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!Enabled)
        {
            _logger.LogInformation("Outbox relay is disabled");
            return;
        }

        _logger.LogInformation(
            "Outbox relay started with polling interval {IntervalSeconds}s, batch size {BatchSize}, and max retry count {MaxRetryCount}",
            PollingIntervalSeconds,
            BatchSize,
            MaxRetryCount);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await ProcessBatchAsync(stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogError(ex, "Outbox relay batch processing failed");
            }

            await Task.Delay(
                TimeSpan.FromSeconds(PollingIntervalSeconds),
                _timeProvider,
                stoppingToken);
        }
    }

    internal async Task ProcessBatchAsync(CancellationToken ct)
    {
        if (!Enabled)
        {
            return;
        }

        using var scope = _scopeFactory.CreateScope();
        var outboxRepository = scope.ServiceProvider.GetRequiredService<IOutboxRepository>();
        var publisher = scope.ServiceProvider.GetRequiredService<IServiceBusPublisher>();

        // Claim immediately before each send. This prevents later rows in a slow
        // batch from exhausting their leases while earlier sends are still active.
        for (var processed = 0; processed < BatchSize; processed++)
        {
            var utcNow = UtcNow;
            var claimed = await outboxRepository.ClaimPendingAsync(
                1,
                utcNow,
                utcNow.AddSeconds(ClaimLeaseSeconds),
                ct);
            if (claimed.Count == 0)
            {
                return;
            }

            await PublishClaimedMessageAsync(
                outboxRepository,
                publisher,
                claimed[0],
                ct);
        }
    }

    private async Task PublishClaimedMessageAsync(
        IOutboxRepository outboxRepository,
        IServiceBusPublisher publisher,
        OutboxMessage message,
        CancellationToken ct)
    {
        var claimExpiresAtUtc = message.NextRetryAtUtc
            ?? throw new InvalidOperationException(
                "A claimed outbox message must carry its lease expiration.");

        using var publishCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        publishCts.CancelAfter(TimeSpan.FromSeconds(PublishTimeoutSeconds));

        try
        {
            await publisher.PublishAsync(
                message.MessageType,
                message.Payload,
                message.Id,
                publishCts.Token);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            var failureCount = message.RetryCount == int.MaxValue
                ? int.MaxValue
                : message.RetryCount + 1;
            var terminal = failureCount >= MaxRetryCount;
            var retryAtUtc = terminal
                ? (DateTime?)null
                : UtcNow.Add(CalculateRetryDelay(failureCount));

            _logger.LogWarning(
                ex,
                "Failed to publish outbox message {MessageId} on attempt {AttemptNumber}; terminal: {Terminal}",
                message.Id,
                failureCount,
                terminal);

            var markedFailed = await outboxRepository.MarkFailedAsync(
                message.Id,
                claimExpiresAtUtc,
                retryAtUtc,
                terminal,
                ct);

            if (!markedFailed)
            {
                _logger.LogWarning(
                    "Outbox message {MessageId} publish failure was not recorded because its relay claim was no longer current",
                    message.Id);
            }

            return;
        }

        var markedPublished = await outboxRepository.MarkPublishedAsync(
            message.Id,
            claimExpiresAtUtc,
            UtcNow,
            ct);

        if (!markedPublished)
        {
            _logger.LogWarning(
                "Outbox message {MessageId} was sent, but its relay claim was no longer current",
                message.Id);
        }
    }

    private TimeSpan CalculateRetryDelay(int failureCount)
    {
        var exponent = Math.Clamp(failureCount - 1, 0, 30);
        var multiplier = 1L << exponent;
        var delaySeconds = Math.Min(
            (long)InitialRetryDelaySeconds * multiplier,
            MaxRetryDelaySeconds);

        return TimeSpan.FromSeconds(delaySeconds);
    }

    private DateTime UtcNow => _timeProvider.GetUtcNow().UtcDateTime;
    private bool Enabled => _options.Enabled;
    private int PollingIntervalSeconds => Math.Max(1, _options.PollingIntervalSeconds);
    private int BatchSize => Math.Max(1, _options.BatchSize);
    private int MaxRetryCount => Math.Max(1, _options.MaxRetryCount);
    private int InitialRetryDelaySeconds => Math.Max(1, _options.InitialRetryDelaySeconds);
    private int MaxRetryDelaySeconds => Math.Max(InitialRetryDelaySeconds, _options.MaxRetryDelaySeconds);
    private int ClaimLeaseSeconds => Math.Max(30, _options.ClaimLeaseSeconds);
    private int PublishTimeoutSeconds => Math.Max(
        1,
        ClaimLeaseSeconds - Math.Min(30, ClaimLeaseSeconds / 2));
}
