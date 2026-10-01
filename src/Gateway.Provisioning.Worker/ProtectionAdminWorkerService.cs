using Azure.Messaging.ServiceBus;
using Gateway.Contracts.Messages;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gateway.Provisioning.Worker;

internal sealed class ProtectionAdminWorkerService : BackgroundService, IAsyncDisposable
{
    private readonly ServiceBusProcessor _processor;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<ProtectionAdminWorkerService> _logger;
    private readonly ProtectionAdminWorkerOptions _options;

    public ProtectionAdminWorkerService(
        ServiceBusClient serviceBusClient,
        IOptions<ProtectionAdminWorkerOptions> options,
        IServiceScopeFactory scopeFactory,
        ILogger<ProtectionAdminWorkerService> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
        _options = options.Value;
        Validate(_options);

        _processor = serviceBusClient.CreateProcessor(
            ProtectionAdminQueueContract.QueueName,
            new ServiceBusProcessorOptions
            {
                MaxConcurrentCalls = _options.MaxConcurrentCalls,
                AutoCompleteMessages = false
            });
    }

    internal static string QueueName => ProtectionAdminQueueContract.QueueName;

    internal static bool ShouldStartProcessing(ProtectionAdminWorkerOptions options) =>
        options.ProcessingEnabled;

    internal static bool IsFinalDelivery(int deliveryCount, int maxDeliveryCount) =>
        deliveryCount >= maxDeliveryCount;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!ShouldStartProcessing(_options))
        {
            _logger.LogWarning("Protection administration queue processing is disabled");
            await Task.Delay(Timeout.Infinite, stoppingToken)
                .ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing);
            return;
        }

        _processor.ProcessMessageAsync += ProcessMessageAsync;
        _processor.ProcessErrorAsync += ProcessErrorAsync;
        await _processor.StartProcessingAsync(stoppingToken);
        await Task.Delay(Timeout.Infinite, stoppingToken)
            .ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing);
        await _processor.StopProcessingAsync();
    }

    private async Task ProcessMessageAsync(ProcessMessageEventArgs args)
    {
        var messageType = args.Message.Subject;
        var payload = args.Message.Body.ToString();

        MessageHandlingResult result;
        try
        {
            using var scope = _scopeFactory.CreateScope();
            var handler = scope.ServiceProvider.GetRequiredService<ProtectionAdminMessageHandler>();
            result = await handler.HandleAsync(
                messageType,
                payload,
                args.CancellationToken);
        }
        catch (OperationCanceledException) when (args.CancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            if (await TryFinalizeRetriesAsync(
                    args,
                    payload,
                    "PROTECTION_ADMIN_UNEXPECTED_FAILURE"))
            {
                return;
            }

            _logger.LogWarning(
                "Abandoning protection administration message {MessageId} after an unverified failure",
                args.Message.MessageId);
            await args.AbandonMessageAsync(
                args.Message,
                cancellationToken: args.CancellationToken);
            return;
        }

        // Settlement failure cannot invalidate a step that already committed.
        await SettleAsync(args, result);
    }

    private async Task<bool> TryFinalizeRetriesAsync(
        ProcessMessageEventArgs args,
        string payload,
        string failureCode)
    {
        if (!IsFinalDelivery(args.Message.DeliveryCount, _options.MaxDeliveryCount))
            return false;

        // Reload durable state rather than entities tracked by the failed attempt.
        using var scope = _scopeFactory.CreateScope();
        var handler = scope.ServiceProvider.GetRequiredService<ProtectionAdminMessageHandler>();
        var result = await handler.HandleRetryExhaustedAsync(
            args.Message.Subject,
            payload,
            failureCode,
            args.CancellationToken);
        if (result is null)
            return false;

        await SettleAsync(args, result);
        return true;
    }

    private Task SettleAsync(ProcessMessageEventArgs args, MessageHandlingResult result) =>
        result.ShouldDeadLetter
            ? DeadLetterAsync(args, result)
            : args.CompleteMessageAsync(args.Message, args.CancellationToken);

    private async Task DeadLetterAsync(
        ProcessMessageEventArgs args,
        MessageHandlingResult result)
    {
        _logger.LogWarning(
            "Dead-lettering protection administration message {MessageId}, reason {Reason}",
            args.Message.MessageId,
            result.DeadLetterReason);
        await args.DeadLetterMessageAsync(
            args.Message,
            result.DeadLetterReason,
            result.DeadLetterDescription,
            args.CancellationToken);
    }

    private Task ProcessErrorAsync(ProcessErrorEventArgs args)
    {
        _logger.LogError(
            "Protection administration Service Bus processing failed at {ErrorSource} for {EntityPath}",
            args.ErrorSource,
            args.EntityPath);
        return Task.CompletedTask;
    }

    private static void Validate(ProtectionAdminWorkerOptions options)
    {
        if (options.MaxConcurrentCalls < 1)
            throw new ArgumentOutOfRangeException(nameof(options.MaxConcurrentCalls));
        if (options.MaxDeliveryCount < 1)
            throw new ArgumentOutOfRangeException(nameof(options.MaxDeliveryCount));
        if (options.MaximumPropagationAttempts < 1)
            throw new ArgumentOutOfRangeException(nameof(options.MaximumPropagationAttempts));
        if (options.PropagationRetryDelaySeconds < 1)
            throw new ArgumentOutOfRangeException(nameof(options.PropagationRetryDelaySeconds));
    }

    public async ValueTask DisposeAsync()
    {
        await _processor.DisposeAsync();
        base.Dispose();
    }
}
